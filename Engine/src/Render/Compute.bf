using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// A texture a compute shader draws into, step after step. It keeps two images: the one being written, and the one
/// from the step before, which the shader reads as "previous". Show it on a mesh with
/// MeshRenderer.TextureOverride, or let a Compute Effect component do that.
class ComputeTexture
{
	public int32 Width { get; private set; }
	public int32 Height { get; private set; }
	public bool HighPrecision { get; private set; }
	bgfx.TextureHandle[2] mTextures;
	int mCurrent;

	public this(int32 width, int32 height, bool highPrecision = false)
	{
		Width = Math.Clamp(width, 1, 4096);
		Height = Math.Clamp(height, 1, 4096);
		HighPrecision = highPrecision;
		for (int i < 2)
			mTextures[i] = bgfx.create_texture_2d((uint16)Width, (uint16)Height, false, 1, Format, (uint64)bgfx.TextureFlags.ComputeWrite, null, 0);
	}

	public ~this()
	{
		// After shutdown the graphics card's textures are already gone.
		if (!Gfx.Initialized)
			return;
		for (int i < 2)
		{
			if (mTextures[i].Valid)
				bgfx.destroy_texture(mTextures[i]);
		}
	}

	public bgfx.TextureFormat Format => HighPrecision ? .RGBA16F : .RGBA8;
	/// The finished image: what the last step wrote.
	public bgfx.TextureHandle Texture => mTextures[mCurrent];
	/// The image the next step writes into.
	public bgfx.TextureHandle Next => mTextures[1 - mCurrent];
	public void Swap() => mCurrent = 1 - mCurrent;
}

/// Runs compute shaders (.tcompute files): programs that run on the graphics card for every pixel of a texture at
/// once. Good for things that would be far too slow in a script: ripples, fire, cellular automata, noise.
static class Compute
{
	static bgfx.UniformHandle sPrevious = .() { idx = uint16.MaxValue };
	/// Compute work is done in this view, before any camera draws.
	public const uint16 View = 1;

	/// False on graphics cards and backends without compute shaders. Run does nothing there.
	public static bool Supported => Gfx.Initialized && (bgfx.get_caps().supported & (uint64)bgfx.CapsFlags.Compute) != 0;

	/// Runs one step of a compute shader over a texture. `values` are the shader's properties in the order it
	/// declares them (use ComputeEffect, or ShaderAsset.properties, to go by name). Returns false if the shader
	/// is not compiled or compute is not supported.
	public static bool Run(ShaderAsset shader, ComputeTexture target, Span<Vector4> values = default)
	{
		return target != null && Dispatch(shader, target, values, target.Texture, 0);
	}

	/// The editor's shader graph previews: a step over `target` that reads `previous` (another texture) as the
	/// texture before it, with u_surface.x set to `preview` (see ShaderGraphCode).
	public static bool RunPreview(ShaderAsset shader, ComputeTexture target, bgfx.TextureHandle previous, float preview)
	{
		return target != null && Dispatch(shader, target, default, previous, preview);
	}

	static bool Dispatch(ShaderAsset shader, ComputeTexture target, Span<Vector4> values, bgfx.TextureHandle previous, float preview)
	{
		if (shader == null || target == null || !shader.IsCompute || !Supported)
			return false;
		let program = shader.ComputeProgram;
		if (program.idx == uint16.MaxValue)
			return false;
		if (sPrevious.idx == uint16.MaxValue)
			sPrevious = bgfx.create_uniform("s_previous", .Sampler, 1);
		RenderResources.EnsureCreated();
		Vector4[ShaderAsset.MaxValues] slots = default;
		for (let property in shader.properties)
		{
			if (property.type != .Texture)
				slots[property.slot] = property.slot < values.Length ? values[property.slot] : property.defaultValue;
		}
		Vector4 surface = .(preview, Time.RealTime, target.Width, target.Height);
		bgfx.set_uniform(RenderResources.uSurface, &surface, 1);
		bgfx.set_uniform(RenderResources.uParams, &slots, ShaderAsset.MaxValues);
		bgfx.set_image(0, target.Next, 0, .Write, target.Format);
		bgfx.set_texture(1, sPrevious, previous, uint32.MaxValue);
		bgfx.dispatch(View, program, (uint32)((target.Width + 7) / 8), (uint32)((target.Height + 7) / 8), 1, 0xff);
		target.Swap();
		return true;
	}

	public static void Shutdown()
	{
		if (sPrevious.idx != uint16.MaxValue)
			bgfx.destroy_uniform(sPrevious);
		sPrevious.idx = uint16.MaxValue;
	}
}

/// Runs a compute shader every frame and shows the result as the texture of this object's Mesh Renderer. No script
/// needed: add it, pick a .tcompute file, press Play.
[Component]
class ComputeEffect : Component
{
	/// The compute shader (.tcompute).
	public String shader = new .() ~ delete _;
	public int32 width = 256;
	public int32 height = 256;
	/// How many steps to run each frame. More makes a simulation move faster.
	public int32 stepsPerFrame = 1;
	/// Off: the shader runs only when Step is called.
	public bool everyFrame = true;

	ComputeTexture mTexture ~ delete _;
	ShaderAsset mShader;
	String mResolved = new .() ~ delete _;
	Vector4[ShaderAsset.MaxValues] mValues;
	bool[ShaderAsset.MaxValues] mSet;

	/// The texture being drawn into, or null before the first step.
	public ComputeTexture Texture => mTexture;

	ShaderAsset Resolve()
	{
		if (mResolved != shader)
		{
			mResolved.Set(shader);
			mShader = ShaderAsset.Load(shader);
			mSet = default;
		}
		return mShader;
	}

	/// Sets one of the shader's properties by name. Unknown names are ignored.
	public void SetVector(StringView name, Vector4 value)
	{
		let property = Resolve()?.Find(name);
		if (property == null || property.type == .Texture)
			return;
		mValues[property.slot] = value;
		mSet[property.slot] = true;
	}

	public void SetFloat(StringView name, float value) => SetVector(name, .(value, 0, 0, 0));
	public void SetColor(StringView name, Color value) => SetVector(name, .(value.r, value.g, value.b, value.a));

	/// Runs the shader once now.
	public bool Step()
	{
		let compiled = Resolve();
		if (compiled == null || !Compute.Supported)
			return false;
		if (mTexture == null || mTexture.Width != Math.Clamp(width, 1, 4096) || mTexture.Height != Math.Clamp(height, 1, 4096) || mTexture.HighPrecision != compiled.highPrecision)
		{
			delete mTexture;
			mTexture = new ComputeTexture(width, height, compiled.highPrecision);
		}
		Vector4[ShaderAsset.MaxValues] values = default;
		for (let property in compiled.properties)
		{
			if (property.type != .Texture)
				values[property.slot] = mSet[property.slot] ? mValues[property.slot] : property.defaultValue;
		}
		if (!Compute.Run(compiled, mTexture, values))
			return false;
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null)
			renderer.TextureOverride = mTexture.Texture;
		return true;
	}

	public override void OnFrame()
	{
		if (!everyFrame || shader.IsEmpty)
			return;
		for (int i < Math.Clamp(stepsPerFrame, 1, 64))
		{
			if (!Step())
				break;
		}
	}

	public override void OnDisable()
	{
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null)
			renderer.TextureOverride = .() { idx = uint16.MaxValue };
	}
}
