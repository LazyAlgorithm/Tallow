using System;
using Tallow;

namespace Sandbox;

/// Left click digs, middle click builds, aimed with the main camera. Works on voxel terrain
/// and on destructible VoxelObjects (which break apart when cut through).
[Component]
class Digger : Component
{
	public float radius = 3.0f;
	public float strength = 1.5f;

	public override void Update()
	{
		let dig = Input.GetMouseButton(0);
		let build = Input.GetMouseButton(2);
		if (!dig && !build)
			return;
		let camera = Scene.FindComponent<Camera>();
		if (camera == null)
			return;
		RaycastHit hit;
		if (!Scene.Physics.Raycast(camera.Transform.Position, camera.Transform.Forward, 200, out hit))
			return;
		let voxels = hit.gameObject != null ? hit.gameObject.GetComponent<VoxelObject>() : null;
		if (voxels != null)
		{
			if (dig)
				voxels.Carve(hit.point, radius * 0.3f);
			return;
		}
		let terrain = Scene.FindComponent<VoxelTerrain>();
		if (terrain != null)
			terrain.ModifySphere(hit.point, radius, (dig ? -strength : strength) * Time.DeltaTime * 4);
	}
}
