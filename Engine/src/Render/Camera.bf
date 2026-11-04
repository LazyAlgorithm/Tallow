using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Renders the scene from its Transform. The first enabled camera drives the Game view.
///
/// First-person games: objects on the Viewmodel Layer (the player's own arms and weapon, children of the camera) are
/// drawn in a pass of their own after the world, with their own field of view and a near clip close to the eye, over
/// whatever is in front of the camera, so a gun never pokes into a wall it is held against and keeps its shape however
/// wide the world's field of view is set. See docs/viewmodel.md.
[Component]
class Camera : Component
{
	/// How much the camera sees from top to bottom, in degrees.
	[Range(10, 120)]
	public float fieldOfView = 60.0f;
	/// The nearest distance drawn, in metres. Too small makes far things flicker against each other.
	public float nearClip = 0.1f;
	/// The farthest distance drawn, in metres.
	public float farClip = 1000.0f;
	/// Draws without perspective: far things are as big as near ones (maps, 2D games).
	public bool orthographic = false;
	/// For an orthographic camera: half the height it sees, in metres.
	public float orthographicSize = 5.0f;

	/// The layer (Project Settings) whose objects are drawn as the viewmodel: after the world, over it. None: no
	/// viewmodel pass, and every layer is drawn with the world as usual.
	[Layer]
	public int32 viewmodelLayer = -1;
	/// The viewmodel's own field of view, so the arms and weapon look the same at any world field of view.
	[Range(10, 120)]
	public float viewmodelFieldOfView = 55.0f;
	/// How close to the eye the viewmodel may come before it is cut off.
	public float viewmodelNearClip = 0.01f;
	/// Whether the viewmodel casts shadows onto the world (usually not: a shadow of a gun held up to the eye looks
	/// wrong from the outside, and other players see a full body anyway). It always receives the world's shadows.
	public bool viewmodelCastsShadows = false;
	/// Skips drawing what is wholly hidden behind big solid things (walls, buildings, hills): worth it in towns and
	/// indoors, where much of the scene is behind walls. See docs/occlusion-culling.md.
	public bool occlusionCulling = false;

	/// Where the viewer is this frame: the game's camera, or in the editor the Scene view's while not playing. Lines and
	/// trails turn to face it.
	public static Vector3 ViewerPosition;

	public override void OnRegister() => Scene.Cameras.Add(this);
	public override void OnUnregister()
	{
		Scene.Cameras.Remove(this);
		if (Scene.CameraOverride == this)
			Scene.CameraOverride = null;
	}

	/// From the world to the camera's view.
	public Matrix4 ViewMatrix
	{
		get
		{
			let t = Transform;
			let position = t.Position;
			let rotation = t.Rotation;
			return Matrix4.LookAt(position, position + rotation * Vector3.Forward, rotation * Vector3.Up);
		}
	}

	/// From the camera's view to the screen, for a picture of a width-to-height ratio.
	public Matrix4 GetProjection(float aspect)
	{
		if (orthographic)
		{
			let h = orthographicSize;
			let w = h * aspect;
			return Matrix4.Ortho(-w, w, -h, h, nearClip, farClip, Gfx.HomogeneousDepth);
		}
		return Matrix4.Perspective(fieldOfView, aspect, nearClip, farClip, Gfx.HomogeneousDepth);
	}

	/// Everything a RenderView needs to draw from this camera.
	public CameraData GetCameraData(float aspect)
	{
		CameraData data;
		data.view = ViewMatrix;
		data.projection = GetProjection(aspect);
		data.position = Transform.Position;
		data.forward = Transform.Forward;
		data.near = nearClip;
		data.far = farClip;
		data.fieldOfView = fieldOfView;
		data.aspect = aspect;
		data.orthographic = orthographic;
		data.orthographicSize = orthographicSize;
		data.hasViewmodel = viewmodelLayer >= 0 && !orthographic;
		data.viewmodelLayer = viewmodelLayer;
		data.viewmodelCastsShadows = viewmodelCastsShadows;
		data.occlusionCulling = occlusionCulling;
		data.viewmodelProjection = Matrix4.Perspective(viewmodelFieldOfView, aspect, Math.Max(viewmodelNearClip, 0.001f), 50.0f, Gfx.HomogeneousDepth);
		return data;
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		let data = GetCameraData(16.0f / 9.0f);
		var shortened = data;
		shortened.far = Math.Min(farClip, 8.0f);
		shortened.projection = orthographic ? data.projection : Matrix4.Perspective(fieldOfView, data.aspect, nearClip, shortened.far, Gfx.HomogeneousDepth);
		Gizmos.Lines.Frustum((shortened.projection * shortened.view).Inverse, .(0.9f, 0.9f, 0.9f, 1));
		// The viewmodel's own view, out to an arm's length, in amber: what is on the viewmodel layer and inside it
		// is what the player sees of their arms and weapon.
		if (viewmodelLayer >= 0 && !orthographic)
		{
			let reach = Matrix4.Perspective(viewmodelFieldOfView, data.aspect, Math.Max(viewmodelNearClip, 0.001f), 1.0f, Gfx.HomogeneousDepth);
			Gizmos.Lines.Frustum((reach * data.view).Inverse, .(1, 0.7f, 0.2f, 1));
		}
	}
}

/// Everything the renderer needs to know about a viewpoint.
struct CameraData
{
	/// From the world to the camera's view.
	public Matrix4 view;
	/// From the camera's view to the screen.
	public Matrix4 projection;
	/// Where the camera is, in the world.
	public Vector3 position;
	/// Which way the camera faces, in the world.
	public Vector3 forward;
	/// The nearest distance drawn.
	public float near;
	/// The farthest distance drawn.
	public float far;
	/// The view's height, in degrees.
	public float fieldOfView;
	/// The picture's width over its height.
	public float aspect;
	/// Whether the view has no perspective.
	public bool orthographic;
	/// For an orthographic view: half its height, in metres.
	public float orthographicSize;
	/// A viewmodel pass (Camera.viewmodelLayer): objects on viewmodelLayer are drawn after the world with their own
	/// projection, over it. False (the default, as for the editor's own camera) draws every layer with the world.
	public bool hasViewmodel;
	/// Leave out what is hidden behind big solid things (Camera.occlusionCulling).
	public bool occlusionCulling;
	/// The layer drawn as the viewmodel, when hasViewmodel is set.
	public int32 viewmodelLayer;
	/// Whether the viewmodel casts shadows into the world.
	public bool viewmodelCastsShadows;
	/// The viewmodel's own projection, with its field of view and near clip.
	public Matrix4 viewmodelProjection;

	/// Where a point of the world appears in the viewport, in 0..1 coordinates from the top left (z: its depth,
	/// above 1 or below the near plane when it is behind the camera).
	public Vector3 WorldToViewportPoint(Vector3 point)
	{
		let clip = (projection * view).Project(point);
		return .((clip.x + 1) * 0.5f, (1 - clip.y) * 0.5f, clip.z);
	}

	/// Ray through a viewport point given in 0..1 coordinates, origin at the top left.
	public Ray ViewportPointToRay(float u, float v)
	{
		let invViewProj = (projection * view).Inverse;
		let x = u * 2.0f - 1.0f;
		let y = 1.0f - v * 2.0f;
		let nearPoint = invViewProj.Project(.(x, y, Gfx.HomogeneousDepth ? -1.0f : 0.0f));
		let farPoint = invViewProj.Project(.(x, y, 1.0f));
		return .(nearPoint, (farPoint - nearPoint).Normalized);
	}
}
