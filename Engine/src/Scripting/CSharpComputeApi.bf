using System;
using System.Collections;

namespace Tallow;

/// Compute shaders run from C# without a Compute Effect (Managed/Tallow.API/Compute.cs): textures and shaders C#
/// makes are kept here by number, freed when C# disposes them or when the game unloads.
[CSharpExpose]
static class CSharpCompute
{
	class Target
	{
		public ComputeTexture texture ~ delete _;
		/// Mesh Renderers that show it: each step swaps its two images, so they are pointed at the new one.
		public List<(uint64 session, uint64 entity)> shownOn = new .() ~ delete _;
	}

	class Runner
	{
		public ShaderAsset shader;
		public Vector4[ShaderAsset.MaxValues] values;
		public bool[ShaderAsset.MaxValues] set;
	}

	static Dictionary<int32, Target> sTargets = new .() ~ DeleteDictionaryAndValues!(_);
	static Dictionary<int32, Runner> sRunners = new .() ~ DeleteDictionaryAndValues!(_);
	static int32 sNext = 1;

	static MeshRenderer Renderer(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		return obj != null ? obj.GetComponent<MeshRenderer>() : default;
	}

	[CSharpExpose]
	public static bool Supported() => Compute.Supported;

	/// A texture to run compute shaders over (sizes 1 to 4096); 0 where compute is not supported.
	[CSharpExpose]
	public static int32 CreateTexture(int32 width, int32 height, bool highPrecision)
	{
		if (!Compute.Supported)
			return 0;
		let target = new Target();
		target.texture = new ComputeTexture(width, height, highPrecision);
		let id = sNext++;
		sTargets[id] = target;
		return id;
	}

	[CSharpExpose]
	public static void ReleaseTexture(int32 id)
	{
		if (sTargets.GetAndRemove(id) case .Ok(let entry))
		{
			Unshow(entry.value);
			delete entry.value;
		}
	}

	static void Unshow(Target target)
	{
		for (let (session, entity) in target.shownOn)
		{
			let renderer = Renderer(session, entity);
			if (renderer && renderer.TextureOverride == target.texture.Texture)
				renderer.TextureOverride = .() { idx = uint16.MaxValue };
		}
		target.shownOn.Clear();
	}

	/// Shows the texture on a Mesh Renderer in place of its own (show false: back to its own). False without a
	/// renderer. A texture that is not there (compute not supported) does nothing and returns true.
	[CSharpExpose]
	public static bool ShowTexture(int32 id, uint64 session, uint64 entity, bool show)
	{
		let renderer = Renderer(session, entity);
		if (!renderer)
			return false;
		// Another texture shown there before lets go of it.
		for (let other in sTargets.Values)
		{
			let at = other.shownOn.IndexOf((session, entity));
			if (at >= 0 && (other != sTargets.GetValueOrDefault(id) || !show))
			{
				other.shownOn.RemoveAtFast(at);
				if (renderer.TextureOverride == other.texture.Texture)
					renderer.TextureOverride = .() { idx = uint16.MaxValue };
			}
		}
		if (!show)
			return true;
		if (!sTargets.TryGetValue(id, let target))
			return true;
		if (!target.shownOn.Contains((session, entity)))
			target.shownOn.Add((session, entity));
		renderer.TextureOverride = target.texture.Texture;
		return true;
	}

	/// A compute shader (.tcompute) to run: the id, -1 when there is no such file, -2 when it is not a compute
	/// shader.
	[CSharpExpose]
	public static int32 CreateShader(StringView path)
	{
		let shader = ShaderAsset.Load(path);
		if (shader == null)
			return -1;
		if (!shader.IsCompute)
			return -2;
		let runner = new Runner();
		runner.shader = shader;
		let id = sNext++;
		sRunners[id] = runner;
		return id;
	}

	[CSharpExpose]
	public static void ReleaseShader(int32 id)
	{
		if (sRunners.GetAndRemove(id) case .Ok(let entry))
			delete entry.value;
	}

	/// Sets a property for the shader's next runs. False when it declares no such (non-texture) property.
	[CSharpExpose]
	public static bool SetShaderValue(int32 id, StringView name, Vector4 value)
	{
		if (!sRunners.TryGetValue(id, let runner))
			return false;
		let property = runner.shader.Find(name);
		if (property == null || property.type == .Texture)
			return false;
		runner.values[property.slot] = value;
		runner.set[property.slot] = true;
		return true;
	}

	/// Whether the shader asks for 16-bit float textures (`precision high`).
	[CSharpExpose]
	public static bool ShaderHighPrecision(int32 id) => sRunners.TryGetValue(id, let runner) && runner.shader.highPrecision;

	/// Runs `steps` steps of the shader over the texture. False when either is not there, the shader is not
	/// compiled or compute is not supported.
	[CSharpExpose]
	public static bool Run(int32 shaderId, int32 textureId, int32 steps)
	{
		if (!sRunners.TryGetValue(shaderId, let runner))
			return false;
		if (!sTargets.TryGetValue(textureId, let target))
			return false;
		Vector4[ShaderAsset.MaxValues] values = default;
		for (let property in runner.shader.properties)
		{
			if (property.type != .Texture)
				values[property.slot] = runner.set[property.slot] ? runner.values[property.slot] : property.defaultValue;
		}
		for (int i < Math.Clamp(steps, 1, 64))
		{
			if (!Compute.Run(runner.shader, target.texture, values))
				return false;
		}
		for (int i = target.shownOn.Count - 1; i >= 0; i--)
		{
			let (session, entity) = target.shownOn[i];
			let renderer = Renderer(session, entity);
			if (renderer)
				renderer.TextureOverride = target.texture.Texture;
			else
				target.shownOn.RemoveAtFast(i);
		}
		return true;
	}

	/// Everything C# made, when the game unloads (renderers showing a texture go back to their own).
	public static void ReleaseAll()
	{
		for (let target in sTargets.Values)
		{
			Unshow(target);
			delete target;
		}
		sTargets.Clear();
		for (let runner in sRunners.Values)
			delete runner;
		sRunners.Clear();
	}
}
