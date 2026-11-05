using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Water (docs/water.md). After the solid scene and its decals, the picture so far is copied and each visible Water's
/// surface is drawn over it as a grid moved by its waves (vs_water.sc), reading the copy for what is under the
/// surface and the depth pass for how deep it is (fs_water.sc). After the see-through things, a camera in the water
/// has the picture copied again and fogged by the water, cut at the waterline (fs_underwater.sc).
extension RenderView
{
	/// Water surfaces drawn in the last frame.
	public int32 VisibleWater;
	/// The water the camera was in, in the last frame.
	public Water CameraWater => mCameraWater;

	List<Water> mWaterItems = new .() ~ delete _;
	Water mCameraWater;
	bgfx.TextureHandle mWaterCopy = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mWaterCopyFb = .() { idx = uint16.MaxValue };
	int32 mWaterCopyWidth, mWaterCopyHeight;

	/// Grids of still water, by their cells (a flat one from -0.5 to 0.5) or, for endless water, by the spacing near
	/// the camera. Shared by every view.
	static Dictionary<int64, Mesh> sWaterGrids = new .() ~ DeleteDictionaryAndValues!(_);

	/// Endless water's grid: this many cells of the near spacing out from the middle each way, then cells that grow
	/// out to the horizon.
	const int32 EndlessNearCells = 40;
	const int32 EndlessFarCells = 56;
	const float EndlessReach = 8000;
	/// Most cells along one side of a lake's grid; a bigger lake has its points further apart.
	const int32 MaxWaterCells = 255;

	void ReleaseWaterTargets()
	{
		if (mWaterCopyFb.Valid)
			bgfx.destroy_frame_buffer(mWaterCopyFb);
		mWaterCopyFb.idx = uint16.MaxValue;
		mWaterCopy.idx = uint16.MaxValue;
	}

	void EnsureWaterCopy()
	{
		if (mWaterCopyFb.Valid && mWaterCopyWidth == mWidth && mWaterCopyHeight == mHeight)
			return;
		ReleaseWaterTargets();
		mWaterCopy = bgfx.create_texture_2d((uint16)mWidth, (uint16)mHeight, false, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
		mWaterCopyFb = bgfx.create_frame_buffer_from_handles(1, &mWaterCopy, true);
		mWaterCopyWidth = mWidth;
		mWaterCopyHeight = mHeight;
	}

	/// Copies the scene's picture so far for the passes that read it while drawing over it.
	void CopySceneForWater(uint16 view, StringView name)
	{
		SetUpView(view, name, mWaterCopyFb, 0, 0, mWidth, mHeight);
		bgfx.set_texture(0, RenderResources.sColor, mSceneColor, uint32.MaxValue);
		SubmitFullscreen(view, RenderResources.CopyProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// The box a water's surface and waves can be in, in the world.
	static Bounds WaterBounds(Water water)
	{
		let wave = Math.Max(water.waveHeight, 0) + 0.5f;
		let model = water.Transform.LocalToWorld;
		let scale = Math.Max(model.TransformDirection(.Up).Length, 0.0001f);
		let half = Vector3(water.size.x * 0.5f, 0, water.size.y * 0.5f);
		return Bounds(.(-half.x, -(Math.Max(water.depth, 0) + wave) / scale, -half.z), .(half.x, wave / scale, half.z)).Transformed(model);
	}

	void DrawWater(Scene scene, CameraData camera, Frustum frustum)
	{
		VisibleWater = 0;
		mWaterItems.Clear();
		mCameraWater = default;
		for (let water in scene.Components<Water>(.. scope .()))
		{
			if (!water.GameObject.ActiveInHierarchy || !water.GameObject.InActiveWorld || HidesHere(water.GameObject))
				continue;
			if (!water.endless && !frustum.Intersects(WaterBounds(water)))
				continue;
			mWaterItems.Add(water);
		}
		// Shiny surfaces with Screen Reflections share the water's copy of the picture and its view: bgfx's view ids
		// are all spoken for. They mirror the scene without the water, and the water mirrors them without theirs.
		let mirrors = ScreenEffects.SurfaceReflections && shading == .Rendered && !Capture && !mMirrorItems.IsEmpty && Reflections.Enabled;
		if (mWaterItems.IsEmpty && !mirrors)
			return;
		EnsureDepthPass(camera);
		SetPostCamera(camera);
		EnsureWaterCopy();
		CopySceneForWater((uint16)(ViewBase + WaterCopyView), "Water copy");
		let view = (uint16)(ViewBase + WaterView);
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		SetUpView(view, "Water", mSceneFb, 0, 0, mWidth, mHeight);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		if (mirrors)
			SubmitMirrors(view);
		let time = Water.ViewTime(scene);
		for (let water in mWaterItems)
			SubmitWater(view, water, camera, time);
	}

	/// The surfaces with Screen Reflections, a batch at a time (they were sorted with the other solid items).
	void SubmitMirrors(uint16 view)
	{
		int start = 0;
		while (start < mMirrorItems.Count)
		{
			int end = start + 1;
			while (end < mMirrorItems.Count && mMirrorItems[end].key == mMirrorItems[start].key)
				end++;
			SubmitBatch(view, mMirrorItems, start, end - start, false, true);
			start = end;
		}
	}

	/// Where a water's grid goes and which grid: a lake's covers its rectangle, endless water's follows the camera
	/// in steps of its spacing (so the points near it do not slide over the waves). spacing is how far apart the
	/// points near the camera are.
	Mesh WaterGridFor(Water water, CameraData camera, out Matrix4 model, out float spacing)
	{
		spacing = Math.Max(water.gridSpacing, 0.05f);
		if (water.endless)
		{
			let step = spacing;
			let x = Math.Round(camera.position.x / step) * step;
			let z = Math.Round(camera.position.z / step) * step;
			model = Matrix4.Translate(.(x, water.Level, z));
			return EndlessGrid(spacing);
		}
		let world = water.Transform.LocalToWorld;
		let width = world.TransformDirection(.Right).Length * Math.Abs(water.size.x);
		let length = world.TransformDirection(.Forward).Length * Math.Abs(water.size.y);
		let cellsX = (int32)Math.Clamp(Math.Ceiling(width / spacing), 1, MaxWaterCells);
		let cellsZ = (int32)Math.Clamp(Math.Ceiling(length / spacing), 1, MaxWaterCells);
		spacing = Math.Max(width / cellsX, length / cellsZ);
		model = world * Matrix4.Scale(.(water.size.x, 1, water.size.y));
		return FlatGrid(cellsX, cellsZ);
	}

	static Mesh FlatGrid(int32 cellsX, int32 cellsZ)
	{
		let key = (int64)cellsX * 100000 + cellsZ;
		if (sWaterGrids.TryGetValue(key, let found))
			return found;
		let mesh = new Mesh();
		mesh.Name.Set("Water grid");
		for (int32 z <= cellsZ)
		{
			for (int32 x <= cellsX)
				mesh.AddVertex(.((float)x / cellsX - 0.5f, 0, (float)z / cellsZ - 0.5f), .Up, .White);
		}
		AddGridTriangles(mesh, cellsX + 1, cellsZ + 1);
		mesh.RecalculateBounds();
		mesh.Upload(false);
		sWaterGrids[key] = mesh;
		return mesh;
	}

	/// A grid round the camera: EndlessNearCells cells of the near spacing each way from the middle, then
	/// EndlessFarCells that grow by the same factor each, out to EndlessReach.
	static Mesh EndlessGrid(float spacing)
	{
		let key = -(int64)(spacing * 1000);
		if (sWaterGrids.TryGetValue(key, let found))
			return found;
		// The growth that makes the far cells add up to the rest of the reach, by halving.
		let rest = Math.Max(EndlessReach - spacing * EndlessNearCells, spacing * EndlessFarCells);
		double low = 1, high = 2;
		for (int i < 60)
		{
			let growth = (low + high) * 0.5;
			double sum = 0, cell = spacing;
			for (int j < EndlessFarCells)
			{
				cell *= growth;
				sum += cell;
			}
			if (sum > rest)
				high = growth;
			else
				low = growth;
		}
		let offsets = scope List<float>();
		offsets.Add(0);
		for (int32 i = 1; i <= EndlessNearCells; i++)
			offsets.Add(spacing * i);
		double cell = spacing, at = spacing * EndlessNearCells;
		for (int j < EndlessFarCells)
		{
			cell *= low;
			at += cell;
			offsets.Add((float)at);
		}
		let side = scope List<float>();
		for (int i = offsets.Count - 1; i > 0; i--)
			side.Add(-offsets[i]);
		side.AddRange(offsets);

		let mesh = new Mesh();
		mesh.Name.Set("Endless water grid");
		for (let z in side)
		{
			for (let x in side)
				mesh.AddVertex(.(x, 0, z), .Up, .White);
		}
		AddGridTriangles(mesh, (int32)side.Count, (int32)side.Count);
		mesh.RecalculateBounds();
		mesh.Upload(false);
		sWaterGrids[key] = mesh;
		return mesh;
	}

	static void AddGridTriangles(Mesh mesh, int32 columns, int32 rows)
	{
		for (int32 z < rows - 1)
		{
			for (int32 x < columns - 1)
			{
				let a = (uint32)(z * columns + x);
				let b = a + 1;
				let c = a + (uint32)columns;
				let d = c + 1;
				// Alternate the diagonal, so that facets of a coarse grid do not all lean one way.
				if (((x + z) & 1) == 0)
				{
					mesh.AddTriangle(a, c, b);
					mesh.AddTriangle(b, c, d);
				}
				else
				{
					mesh.AddTriangle(a, c, d);
					mesh.AddTriangle(a, d, b);
				}
			}
		}
	}

	/// The waves' uniforms for a water, its grid's spacing near the camera given: waves too short for the grid fade
	/// out (except in the Low Poly look, which wants its facets), and on endless water each fades out far away.
	void SetWaveUniforms(Water water, float spacing, double time)
	{
		let waves = water.Waves;
		float[Water.WaveCount] phases = default;
		water.Phases(time, ref phases);
		Vector4[Water.WaveCount] first = default;
		Vector4[Water.WaveCount] second = default;
		let lowPoly = water.look == .LowPoly;
		for (int i < Water.WaveCount)
		{
			let wave = waves[i];
			let length = Math.PI_f * 2 / Math.Max(wave.k, 0.0001f);
			let points = length / spacing;
			let keep = lowPoly ? Math.Clamp(points - 1, 0, 1) : Math.Clamp((points - 2) * 0.5f, 0, 1);
			first[i] = .(wave.direction.x, wave.direction.y, wave.k, wave.amplitude);
			second[i] = .(wave.steepness, phases[i], keep, water.endless ? length * 30 : 0);
		}
		Vector4 level = .(water.Level, water.Bottom, water.flow.x, water.flow.y);
		bgfx.set_uniform(RenderResources.uWaveA, &first, Water.WaveCount);
		bgfx.set_uniform(RenderResources.uWaveB, &second, Water.WaveCount);
		bgfx.set_uniform(RenderResources.uWaterLevel, &level, 1);
	}

	/// The underwater colour as the light reaching into the water leaves it: the sun's from above and the sky's.
	Vector4 LitUnderwaterColor(Water water)
	{
		let color = Linear(water.underwaterColor);
		let sun = (mSunColor.x * 0.2126f + mSunColor.y * 0.7152f + mSunColor.z * 0.0722f) * Math.Clamp(mSunDir.y, 0.1f, 1.0f);
		let sky = mAmbientSky.x * 0.2126f + mAmbientSky.y * 0.7152f + mAmbientSky.z * 0.0722f;
		let light = sun * 0.4f + sky * 1.4f;
		return .(color.x * light, color.y * light, color.z * light, Math.Max(water.underwaterVisibility, 0.1f));
	}

	void SubmitWater(uint16 view, Water water, CameraData camera, double time)
	{
		let grid = WaterGridFor(water, camera, var model, let spacing);
		if (grid == null || !grid.HasGpuData)
			return;
		SetFrameUniforms();
		let center = water.endless ? camera.position : water.Transform.Position;
		let radius = water.endless ? 50.0f : Math.Max(water.size.x, water.size.y) * 0.5f;
		Reflections.Bind(Reflections.Pick(center, radius), mReflectionIntensity, mCubeAmbient);
		SetPostUniforms();
		SetWaveUniforms(water, spacing, time);
		let lowPoly = water.look == .LowPoly;
		let shallow = Linear(water.shallowColor);
		let deep = Linear(water.deepColor);
		let foam = Linear(water.foamColor);
		Vector4 parameters = .(lowPoly ? 1 : 0, (float)(time % 3600.0), Math.Max(water.refraction, 0), Math.Clamp(water.roughness, 0, 1));
		Vector4 shallowValues = .(shallow.x, shallow.y, shallow.z, Math.Max(water.clarity, 0.05f));
		Vector4 deepValues = .(deep.x, deep.y, deep.z, Math.Max(water.foam, 0));
		Vector4 foamValues = .(foam.x, foam.y, foam.z, Math.Max(water.shoreFoam, 0.01f));
		// Seen from below when the camera is under the surface where it stands (or, away from the water, under its level).
		var surface = water.Level;
		water.SurfaceAt(camera.position, time, out surface, ?, ?);
		let below = camera.position.y < surface && camera.position.y > water.Bottom;
		Vector4 options = .(water.caustics ? 1 : 0, water.screenReflections && ScreenEffects.WaterReflections ? 1 : 0, below ? 1 : 0, 0);
		var under = LitUnderwaterColor(water);
		bgfx.set_uniform(RenderResources.uWaterModel, &model, 1);
		bgfx.set_uniform(RenderResources.uWaterParams, &parameters, 1);
		bgfx.set_uniform(RenderResources.uWaterShallow, &shallowValues, 1);
		bgfx.set_uniform(RenderResources.uWaterDeep, &deepValues, 1);
		bgfx.set_uniform(RenderResources.uWaterFoam, &foamValues, 1);
		bgfx.set_uniform(RenderResources.uWaterOptions, &options, 1);
		bgfx.set_uniform(RenderResources.uWaterUnder, &under, 1);
		bgfx.set_texture(0, RenderResources.sColor, mWaterCopy, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		bgfx.set_vertex_buffer(0, grid.VertexBuffer, 0, (uint32)grid.VertexCount);
		bgfx.set_index_buffer(grid.IndexBuffer, 0, (uint32)grid.IndexCount);
		// Both sides: from under the water the surface is seen from below.
		bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | Gfx.StateWriteZ | Gfx.StateDepthLess | Gfx.StateMsaa, 0);
		bgfx.submit(view, RenderResources.WaterProgram, 0, 0xff);
		DrawCalls++;
		Triangles += grid.IndexCount / 3;
		VisibleWater++;
	}

	/// The camera in the water: the picture is fogged by it where the near plane is under its surface.
	void DrawUnderwater(Scene scene, CameraData camera)
	{
		if (mWaterItems.IsEmpty || camera.orthographic)
			return;
		let time = Water.ViewTime(scene);
		// The near plane's corners reach this far from the camera.
		let reach = camera.near * 3 + 0.05f;
		Water inside = default;
		float insideLevel = 0;
		for (let water in mWaterItems)
		{
			if (!water.SurfaceAt(camera.position, time, let height, ?, ?))
				continue;
			if (camera.position.y - reach > height || camera.position.y < water.Bottom)
				continue;
			if (!inside || water.Level > insideLevel)
			{
				inside = water;
				insideLevel = water.Level;
			}
		}
		mCameraWater = inside;
		if (!inside)
			return;
		CopySceneForWater((uint16)(ViewBase + UnderwaterCopyView), "Underwater copy");
		let view = (uint16)(ViewBase + UnderwaterView);
		SetUpView(view, "Underwater", mSceneFb, 0, 0, mWidth, mHeight);
		WaterGridFor(inside, camera, var model, let spacing);
		SetWaveUniforms(inside, spacing, time);
		var inverse = model.Inverse;
		var under = LitUnderwaterColor(inside);
		Vector4 parameters = .(camera.near, inside.endless ? 1 : 0, (float)(time % 3600.0), inside.caustics ? 1 : 0);
		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uWaterInverse, &inverse, 1);
		bgfx.set_uniform(RenderResources.uWaterUnder, &under, 1);
		bgfx.set_uniform(RenderResources.uWaterUnderParams, &parameters, 1);
		bgfx.set_uniform(RenderResources.uSunDir, &mSunDir, 1);
		bgfx.set_texture(0, RenderResources.sColor, mWaterCopy, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		SubmitFullscreen(view, RenderResources.UnderwaterProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}
}
