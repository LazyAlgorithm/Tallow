using System;
using Bgfx;

namespace Tallow;

/// GPU skinning (docs/gpu-skinning.md): a compute shader bends skinned models' vertices on the graphics card, straight
/// into the vertex buffers every pass draws from. The CPU only works out each joint's matrix and the model's bounds.
static class GpuSkinning
{
	/// Turns GPU skinning off for every model (a setting, or to compare with the CPU path). Models already loaded
	/// keep vertex buffers the GPU can write, so it can be turned on again.
	public static bool Enabled = true;

	static bgfx.ProgramHandle sProgram = .() { idx = uint16.MaxValue };
	static bgfx.UniformHandle sSkin = .() { idx = uint16.MaxValue };
	static bgfx.VertexLayout sVec4Layout;
	static bool sTried;
	/// How many times a model has been bent on the graphics card since the start (for checking it is in use).
	public static int64 Bends;

	/// Whether the graphics card can do it: compute shaders, and the skinning shader for this backend.
	public static bool Available
	{
		get
		{
			if (!sTried && Gfx.Initialized)
			{
				sTried = true;
				if (Compute.Supported)
				{
					// Quietly absent for backends without it (the web build): models skin on the CPU there.
					let path = scope String()..AppendF("{}/shaders/{}/cs_skin.bin", Gfx.EngineAssetPath, Gfx.ShaderFolder);
					let shader = Gfx.LoadShaderFile(path);
					if (shader.Valid)
					{
						sProgram = bgfx.create_compute_program(shader, true);
						sSkin = bgfx.create_uniform("u_skin", .Vec4, 1);
						bgfx.vertex_layout_begin(&sVec4Layout, .Noop);
						bgfx.vertex_layout_add(&sVec4Layout, .TexCoord0, 4, .Float, false, false);
						bgfx.vertex_layout_end(&sVec4Layout);
					}
				}
				Log.Info(!sProgram.Valid ? "Skinning: on the CPU (no compute shaders)" : (Enabled ? "Skinning: on the GPU" : "Skinning: on the CPU (turned off)"));
			}
			return sProgram.Valid;
		}
	}

	/// A buffer of vec4s the shader reads.
	public static bgfx.DynamicVertexBufferHandle ReadBuffer(uint32 count) => bgfx.create_dynamic_vertex_buffer(count, &sVec4Layout, (uint16)bgfx.BufferFlags.ComputeRead);

	/// Bends a mesh: source and bones are ReadBuffers, target the mesh's compute-writable vertex buffer.
	public static void Dispatch(bgfx.DynamicVertexBufferHandle source, bgfx.DynamicVertexBufferHandle bones, bgfx.DynamicVertexBufferHandle target, int32 vertexCount)
	{
		Vector4 skin = .(vertexCount, 0, 0, 0);
		bgfx.set_uniform(sSkin, &skin, 1);
		bgfx.set_compute_dynamic_vertex_buffer(0, source, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(1, bones, .Read, 0, uint32.MaxValue);
		bgfx.set_compute_dynamic_vertex_buffer(2, target, .ReadWrite, 0, uint32.MaxValue);
		bgfx.dispatch(Compute.View, sProgram, (uint32)((vertexCount + 63) / 64), 1, 1, 0xff);
		Bends++;
	}

	public static void Shutdown()
	{
		if (Bends > 0)
			Log.Info(scope $"Skinning: {Bends} bends on the GPU");
		if (sProgram.Valid)
			bgfx.destroy_program(sProgram);
		if (sSkin.Valid)
			bgfx.destroy_uniform(sSkin);
		sProgram.idx = uint16.MaxValue;
		sSkin.idx = uint16.MaxValue;
		sTried = false;
	}
}

extension SkinnedMeshRenderer
{
	bgfx.DynamicVertexBufferHandle mGpuSource = .() { idx = uint16.MaxValue };
	bgfx.DynamicVertexBufferHandle mGpuBones = .() { idx = uint16.MaxValue };
	// Each joint's box round the vertices it moves, at rest (model space), to bound the bent mesh without its vertices.
	Bounds[] mJointBounds ~ delete _;
	Vector4[] mBoneRows ~ delete _;
	bool mGpuSkinned;

	/// Whether the last bend was done on the graphics card (Mesh.Vertices then stay at rest).
	public bool SkinnedOnGpu => mGpuSkinned;

	void ReleaseGpuSkinning()
	{
		if (Gfx.Initialized)
		{
			if (mGpuSource.Valid)
				bgfx.destroy_dynamic_vertex_buffer(mGpuSource);
			if (mGpuBones.Valid)
				bgfx.destroy_dynamic_vertex_buffer(mGpuBones);
		}
		mGpuSource.idx = uint16.MaxValue;
		mGpuBones.idx = uint16.MaxValue;
		DeleteAndNullify!(mJointBounds);
		DeleteAndNullify!(mBoneRows);
		mGpuSkinned = false;
	}

	public ~this()
	{
		ReleaseGpuSkinning();
	}

	/// The rest pose, joints and weights for the shader, and each joint's box. Made on the first GPU bend.
	void PrepareGpuSkinning()
	{
		let count = mModel.Positions.Count;
		let joints = mModel.Joints.Count;
		Vector4[] data = new .[count * 4];
		defer delete data;
		for (int v < count)
		{
			let p = mModel.Positions[v];
			let n = mModel.Normals[v];
			data[v * 4] = .(p.x, p.y, p.z, 1);
			data[v * 4 + 1] = .(n.x, n.y, n.z, 0);
			float[4] indices = default, weights = default;
			for (int k < 4)
			{
				let joint = mModel.JointIndices[v * 4 + k];
				let weight = mModel.Weights[v * 4 + k];
				indices[k] = joint;
				weights[k] = weight;
			}
			data[v * 4 + 2] = .(indices[0], indices[1], indices[2], indices[3]);
			data[v * 4 + 3] = .(weights[0], weights[1], weights[2], weights[3]);
		}
		PrepareJointBounds();
		mGpuSource = GpuSkinning.ReadBuffer((uint32)(count * 4));
		bgfx.update_dynamic_vertex_buffer(mGpuSource, 0, bgfx.copy(data.Ptr, (uint32)(data.Count * sizeof(Vector4))));
		mGpuBones = GpuSkinning.ReadBuffer((uint32)(joints * 3));
		mBoneRows = new Vector4[joints * 3];
	}

	/// Each joint's box round the vertices it moves, at rest.
	void PrepareJointBounds()
	{
		let joints = mModel.Joints.Count;
		delete mJointBounds;
		mJointBounds = new Bounds[joints];
		for (int j < joints)
			mJointBounds[j] = .Empty;
		for (int v < mModel.Positions.Count)
		{
			for (int k < 4)
			{
				if (mModel.Weights[v * 4 + k] > 0)
					mJointBounds[mModel.JointIndices[v * 4 + k]].Encapsulate(mModel.Positions[v]);
			}
		}
	}

	/// The box round the bent mesh worked out from its joints alone, as GPU skinning does (no vertex is bent): each
	/// joint's resting box, moved with the joint. It holds the bent mesh, a little loosely. In Tallow's space.
	public Bounds BoundsFromJoints()
	{
		if (mModel == null || mSkin == null)
			return .Empty;
		if (mJointBounds == null)
			PrepareJointBounds();
		var bounds = Bounds.Empty;
		for (int j < mModel.Joints.Count)
		{
			if (mJointBounds[j].IsValid)
				bounds.EncapsulateBounds(mJointBounds[j].Transformed(mSkin[j]));
		}
		if (!bounds.IsValid)
			return bounds;
		return .(.(bounds.min.x, bounds.min.y, -bounds.max.z), .(bounds.max.x, bounds.max.y, -bounds.min.z));
	}

	/// Bends the mesh on the graphics card, if it can and should. False leaves it to the CPU.
	bool SkinOnGpu()
	{
		if (!gpuSkinning || !GpuSkinning.Enabled || !GpuSkinning.Available || !mMesh.IsComputeWritable)
		{
			mGpuSkinned = false;
			return false;
		}
		if (!mGpuSource.Valid)
			PrepareGpuSkinning();
		let joints = mModel.Joints.Count;
		for (int j < joints)
		{
			let m = mSkin[j].m;
			mBoneRows[j * 3] = .(m[0], m[4], m[8], m[12]);
			mBoneRows[j * 3 + 1] = .(m[1], m[5], m[9], m[13]);
			mBoneRows[j * 3 + 2] = .(m[2], m[6], m[10], m[14]);
		}
		bgfx.update_dynamic_vertex_buffer(mGpuBones, 0, bgfx.copy(mBoneRows.Ptr, (uint32)(mBoneRows.Count * sizeof(Vector4))));
		GpuSkinning.Dispatch(mGpuSource, mGpuBones, mMesh.DynamicBuffer, (int32)mModel.Positions.Count);
		let bounds = BoundsFromJoints();
		if (bounds.IsValid)
			mMesh.Bounds = bounds;
		for (let part in mParts)
			part.mesh.Bounds = mMesh.Bounds;
		mSkinnedOnce = true;
		mGpuSkinned = true;
		return true;
	}
}
