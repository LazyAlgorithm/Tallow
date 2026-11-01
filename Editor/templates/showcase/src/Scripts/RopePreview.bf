using System;
using Tallow;

namespace {NAMESPACE};

/// Editor visualization only; Rope owns and updates its simulated mesh during Play.
[Component]
class RopePreview : Component
{
	Mesh preview ~ delete _;
	Vector3 oldStart, oldEnd;
	float oldRadius;
	int oldSegments;
	public override void OnFrame()
	{
		if (Scene.IsPlaying) return;
		let rope = GetComponent<Rope>();
		if (rope == null) return;
		let start = rope.startAttachedTo != null ? rope.startAttachedTo.TransformPoint(rope.startOffset) : Transform.Position;
		var end = start + Vector3.Down * rope.length;
		if (rope.endAttachedTo != null)
		{
			end = rope.endAttachedTo.TransformPoint(rope.endOffset);
			if (rope.endOffset == Vector3.Zero)
				end += Vector3.Up * rope.endAttachedTo.LocalScale.y * 0.5f;
		}
		let segments = (int)Math.Clamp(rope.segments > 0 ? rope.segments : 24, 8, 128);
		let radius = rope.thickness * 0.5f;
		if (preview != null && start == oldStart && end == oldEnd && radius == oldRadius && segments == oldSegments) return;
		oldStart = start;
		oldEnd = end;
		oldRadius = radius;
		oldSegments = segments;
		let mesh = new Mesh();
		let tangent = (end - start).Normalized;
		let right = Vector3.Cross(Math.Abs(Vector3.Dot(tangent, .Up)) > 0.9f ? Vector3.Right : Vector3.Up, tangent).Normalized;
		let up = Vector3.Cross(tangent, right).Normalized;
		for (int i <= segments)
		{
			let t = i / (float)segments;
			let center = Vector3.Lerp(start, end, t) + Vector3.Down * (Math.Sin(t * Math.PI_f) * Math.Max(0, rope.length - (end - start).Length) * 0.4f);
			for (int j < 8)
			{
				let angle = j * Math.PI_f * 2 / 8;
				let normal = right * Math.Cos(angle) + up * Math.Sin(angle);
				mesh.AddVertex(Transform.InverseTransformPoint(center + normal * radius), Transform.WorldToLocal.TransformDirection(normal).Normalized, .White, .(j / 8f, t));
			}
		}
		for (int i < segments)
		{
			for (int j < 8)
			{
				let a = (uint32)(i * 8 + j);
				let b = (uint32)(i * 8 + (j + 1) % 8);
				mesh.AddTriangle(a, a + 8, b);
				mesh.AddTriangle(b, a + 8, b + 8);
			}
		}
		var renderer = GetComponent<MeshRenderer>();
		if (renderer == null)
			renderer = GameObject.AddComponent<MeshRenderer>();
		renderer.RuntimeMesh = mesh;
		delete preview;
		preview = mesh;
	}

	public override void OnUnregister()
	{
		let r = GetComponent<MeshRenderer>();
		if (r != null && r.RuntimeMesh == preview)
			r.RuntimeMesh = null;
	}
}
