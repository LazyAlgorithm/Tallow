using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Views for modelling (docs/modeling.md):
/// - The view selector in the Scene view's top right corner, as Unity's: click an axis to look along it (front,
///   back, left, right, top, bottom), the middle to switch between perspective and orthographic.
/// - Window > Model Views: four views of the scene in one window, as 3ds Max has (Top, Front, Left and Perspective
///   to start; each can be changed, and double-clicking one's bar fills the window with it). Everything the Scene view
///   does with a model works in them: picking, edit mode, every tool, the object gizmo. The view the pointer was last
///   over takes the mouse and keys; the others only draw.
/// - Shading, in each view as Blender has: Rendered, Material Preview, Solid, Unlit and Wireframe (ViewShading).
/// - Keys in the view the pointer is over: F frames the selection, Shift+Z wireframe, and the keypad's 1, 3, 7 (with
///   Ctrl the opposite side) look from the front, right and top, 5 switches perspective and orthographic.
extension EditorApp
{
	enum ModelViewKind
	{
		Perspective,
		Top,
		Bottom,
		Front,
		Back,
		Left,
		Right
	}

	static StringView[7] sModelViewNames = .("Perspective", "Top", "Bottom", "Front", "Back", "Left", "Right");

	/// An orthographic camera stands this far behind what it looks at, so nothing in front of it is cut off.
	const float OrthoBack = 500;

	class ModelViewport
	{
		public ModelViewKind kind;
		public RenderView view ~ delete _;
		public Vector3 position;
		public float yaw;
		public float pitch;
		public float orthoSize = 3;
		public CameraData camera;
		public ImGui.Vec2 origin;
		public ImGui.Vec2 size;
		public bool hovered;
		public bool visible;
		public bool flying;
		/// Every view shows textures to start, lit the same from all sides (the scene's lights only in Rendered).
		public ViewShading shading = .MaterialPreview;
		/// What Shift+Z goes back to from Wireframe.
		public ViewShading unwired = .MaterialPreview;
	}

	static StringView[5] sShadingNames = .("Rendered", "Material Preview", "Solid", "Unlit", "Wireframe");
	static StringView[5] sShadingTips = .("Lit by the scene's lights, with shadows and reflections, as the game shows it.",
		"Textures and colours, lit the same from every side.", "Colours without textures, lit the same from every side: the shape alone.",
		"Textures and colours as they are, without light.", "Only the edges, seen through (Shift+Z).");
	ViewShading mSceneShading = .Rendered;
	ViewShading mSceneUnwired = .Rendered;

	List<ModelViewport> mModelViewports ~ DeleteContainerAndItems!(_);
	bool mShowModelViews;
	/// Brings the Model Views window to the front next frame (opening it from a menu).
	bool mFocusModelViews;
	/// Docks the Model Views window beside the Scene view the next time it is drawn (opened the first time).
	bool mDockModelViews;
	/// The view that takes the mouse: -1 the Scene view, else a Model View.
	int mModelViewActive = -1;
	/// The Model View filling the window (-1: all four).
	int mModelViewMaximised = -1;

	bool mSceneOrtho;
	float mSceneOrthoSize = 5;
	/// How far in front of the camera the orthographic view's pivot is (where it came back to perspective).
	float mSceneOrthoDistance = 10;

	bool ModelViewsShown => mShowModelViews && mModelViewports != null;

	/// Whether the view the mouse is over may take it: nothing is being dragged or run.
	bool ModelViewsCanSwitch => !ModelToolActive && !mModelDragging && !mModelBoxing && !mFlying && !ImGui.IsMouseDown(0) && !ImGui.IsMouseDown(1) && !ImGui.IsMouseDown(2)
		&& !ImGui.tn_gizmo_is_using();

	/// The way a fixed view looks (yaw 0 looks along +Z, at a model's front; positive pitch looks down).
	static void ModelViewAngles(ModelViewKind kind, out float yaw, out float pitch)
	{
		yaw = 0;
		pitch = 0;
		switch (kind)
		{
		case .Top: pitch = 90;
		case .Bottom: pitch = -90;
		case .Front: yaw = 0;
		case .Back: yaw = 180;
		case .Left: yaw = -90;
		case .Right: yaw = 90;
		case .Perspective:
			yaw = -35;
			pitch = 25;
		}
	}

	static Vector3 AnglesForward(float yaw, float pitch) => Quaternion.Euler(pitch, yaw, 0) * Vector3.Forward;

	/// What the views look at: the selected object's middle, or the point ahead of the Scene view's camera.
	void ModelViewTarget(out Vector3 centre, out float radius)
	{
		centre = mCamPosition + AnglesForward(mCamYaw, mCamPitch) * 10;
		radius = 2;
		let selected = Selected;
		MeshRenderer renderer = selected != null ? selected.GetComponent<MeshRenderer>() : default;
		if (renderer && renderer.ActiveMesh != null)
		{
			let bounds = renderer.WorldBounds;
			centre = bounds.Center;
			radius = Math.Max(bounds.Extents.Length, 0.25f);
		}
		else if (selected != null)
			centre = selected.Transform.Position;
	}

	void FrameModelView(ModelViewport viewport, Vector3 centre, float radius)
	{
		let forward = AnglesForward(viewport.yaw, viewport.pitch);
		if (viewport.kind == .Perspective)
			viewport.position = centre - forward * (radius * 2.8f + 0.5f);
		else
		{
			viewport.position = centre - forward * OrthoBack;
			viewport.orthoSize = radius * 1.25f;
		}
	}

	void EnsureModelViews()
	{
		if (mModelViewports != null)
			return;
		mModelViewports = new .();
		ModelViewKind[4] kinds = .(.Top, .Front, .Left, .Perspective);
		Vector3 centre;
		float radius;
		ModelViewTarget(out centre, out radius);
		for (int i < 4)
		{
			let viewport = new ModelViewport();
			viewport.kind = kinds[i];
			// After the Scene and Game views and the asset previews, before the reflection captures.
			// After the Scene and Game views (2) and the asset previews (one view's worth and a copy view).
			viewport.view = new RenderView((uint16)(10 + RenderView.ViewCount * (4 + i)));
			viewport.view.DrawGizmos = true;
			viewport.view.drawEditorOnly = true;
			viewport.view.ShowDepthOfField = false;
			viewport.view.ShowMotionBlur = false;
			ModelViewAngles(viewport.kind, out viewport.yaw, out viewport.pitch);
			FrameModelView(viewport, centre, radius);
			mModelViewports.Add(viewport);
		}
	}

	void UpdateModelViewCamera(ModelViewport viewport, float aspect)
	{
		let rotation = Quaternion.Euler(viewport.pitch, viewport.yaw, 0);
		let forward = rotation * Vector3.Forward;
		let ortho = viewport.kind != .Perspective;
		viewport.camera.position = viewport.position;
		viewport.camera.forward = forward;
		viewport.camera.near = ortho ? 1 : 0.1f;
		viewport.camera.far = 2000;
		viewport.camera.fieldOfView = 60;
		viewport.camera.aspect = aspect;
		viewport.camera.orthographic = ortho;
		viewport.camera.orthographicSize = viewport.orthoSize;
		viewport.camera.occlusionCulling = false;
		viewport.camera.view = Matrix4.LookAt(viewport.position, viewport.position + forward, rotation * Vector3.Up);
		viewport.camera.projection = ortho ? Matrix4.Ortho(-viewport.orthoSize * aspect, viewport.orthoSize * aspect, -viewport.orthoSize, viewport.orthoSize, 1, 2000, Gfx.HomogeneousDepth)
			: Matrix4.Perspective(60, aspect, 0.1f, 2000, Gfx.HomogeneousDepth);
	}

	/// The Scene view's camera and mouse, put aside while a Model View stands in for it.
	struct SceneContext
	{
		public CameraData camera;
		public ImGui.Vec2 origin;
		public ImGui.Vec2 size;
		public bool hovered;
		public bool flying;
		public Vector3 position;
		public float yaw;
		public float pitch;
	}

	SceneContext EnterModelView(ModelViewport viewport)
	{
		SceneContext saved = default;
		saved.camera = mSceneCamera;
		saved.origin = mSceneOrigin;
		saved.size = mSceneSize;
		saved.hovered = mSceneHovered;
		saved.flying = mFlying;
		saved.position = mCamPosition;
		saved.yaw = mCamYaw;
		saved.pitch = mCamPitch;
		mSceneCamera = viewport.camera;
		mSceneOrigin = viewport.origin;
		mSceneSize = viewport.size;
		mSceneHovered = viewport.hovered;
		mFlying = viewport.flying;
		mCamPosition = viewport.position;
		mCamYaw = viewport.yaw;
		mCamPitch = viewport.pitch;
		return saved;
	}

	void LeaveModelView(ModelViewport viewport, SceneContext saved)
	{
		viewport.position = mCamPosition;
		viewport.orthoSize = mSceneCamera.orthographicSize;
		viewport.flying = mFlying;
		if (viewport.kind == .Perspective)
		{
			viewport.yaw = mCamYaw;
			viewport.pitch = mCamPitch;
		}
		mSceneCamera = saved.camera;
		mSceneOrigin = saved.origin;
		mSceneSize = saved.size;
		mSceneHovered = saved.hovered;
		mFlying = saved.flying;
		mCamPosition = saved.position;
		mCamYaw = saved.yaw;
		mCamPitch = saved.pitch;
	}

	/// Panning and zooming an orthographic Model View: middle drag pans, the wheel zooms about the pointer.
	void HandleOrthoViewInput(ModelViewport viewport)
	{
		if (!viewport.hovered)
			return;
		let rotation = Quaternion.Euler(viewport.pitch, viewport.yaw, 0);
		let right = rotation * Vector3.Right;
		let up = rotation * Vector3.Up;
		let perPixel = 2 * viewport.orthoSize / Math.Max(viewport.size.y, 1);
		if (ImGui.IsMouseDown(2))
		{
			let delta = Input.MouseDelta;
			viewport.position = viewport.position - right * (delta.x * perPixel) + up * (delta.y * perPixel);
		}
		let wheel = Input.MouseWheel;
		if (wheel != 0 && !ModelOwnsWheel)
		{
			// The point under the pointer stays under it.
			let mouse = ImGui.GetMousePos();
			let offsetX = (mouse.x - viewport.origin.x - viewport.size.x * 0.5f) * perPixel;
			let offsetY = (viewport.origin.y + viewport.size.y * 0.5f - mouse.y) * perPixel;
			let scale = Math.Pow(0.85f, wheel);
			viewport.position = viewport.position + right * (offsetX * (1 - scale)) + up * (offsetY * (1 - scale));
			viewport.orthoSize = Math.Clamp(viewport.orthoSize * scale, 0.01f, 1000);
		}
	}

	/// Window > Model Views.
	void DrawModelViews()
	{
		if (mModelViewports != null)
		{
			for (let viewport in mModelViewports)
				viewport.visible = false;
		}
		if (!mShowModelViews)
		{
			if (mModelViewActive >= 0)
				mModelViewActive = -1;
			return;
		}
		EnsureModelViews();
		ImGui.SetNextWindowSize(.(960, 720), ImGui.Cond.FirstUseEver);
		if (mDockModelViews && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockModelViews = false;
		}
		if (mFocusModelViews)
		{
			ImGui.SetNextWindowFocus();
			mFocusModelViews = false;
		}
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let open = ImGui.Begin("Model Views", &mShowModelViews, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		if (open)
		{
			let avail = ImGui.GetContentRegionAvail();
			let start = ImGui.GetCursorScreenPos();
			const float gap = 2;
			let bar = ImGui.GetFrameHeight() + 2;
			for (int i < 4)
			{
				if (mModelViewMaximised >= 0 && i != mModelViewMaximised)
					continue;
				let viewport = mModelViewports[i];
				ImGui.Vec2 cell;
				ImGui.Vec2 cellSize;
				if (mModelViewMaximised >= 0)
				{
					cell = start;
					cellSize = avail;
				}
				else
				{
					cellSize = .((avail.x - gap) * 0.5f, (avail.y - gap) * 0.5f);
					cell = .(start.x + (i % 2) * (cellSize.x + gap), start.y + (i / 2) * (cellSize.y + gap));
				}
				if (cellSize.x < 40 || cellSize.y < bar + 20)
					continue;
				ImGui.PushID((int32)i);
				DrawModelViewBar(viewport, i, cell, cellSize.x, bar);
				viewport.origin = .(cell.x, cell.y + bar);
				viewport.size = .(cellSize.x, cellSize.y - bar);
				UpdateModelViewCamera(viewport, viewport.size.x / viewport.size.y);
				ImGui.SetCursorScreenPos(viewport.origin);
				if (viewport.view.Width > 0)
					ImGui.Picture(viewport.view.OutputTexture, .(viewport.view.Width, viewport.view.Height));
				else
					ImGui.Dummy(viewport.size);
				viewport.hovered = ImGui.IsItemHovered();
				viewport.visible = true;
				if (viewport.hovered && ModelViewsCanSwitch)
					mModelViewActive = i;
				let saved = EnterModelView(viewport);
				if (viewport.kind == .Perspective)
					HandleSceneCameraInput();
				else
				{
					HandleOrthoViewInput(viewport);
					mCamPosition = viewport.position;
					mSceneCamera.orthographicSize = viewport.orthoSize;
				}
				if (mModelViewActive == i)
				{
					let selected = Selected;
					var toolActive = UpdateModelTools(selected, viewport.origin, viewport.size);
					toolActive = ObjectGizmo(selected, viewport.origin, viewport.size, toolActive);
					if (viewport.hovered && ImGui.IsMouseClicked(0) && !toolActive && !mFlying)
					{
						let mouse = ImGui.GetMousePos();
						Pick((mouse.x - viewport.origin.x) / viewport.size.x, (mouse.y - viewport.origin.y) / viewport.size.y);
					}
					ImGui.DrawRect(.(viewport.origin.x + 1, viewport.origin.y + 1), .(viewport.origin.x + viewport.size.x - 1, viewport.origin.y + viewport.size.y - 1), EditorTheme.Accent, 0, 2);
				}
				LeaveModelView(viewport, saved);
				ImGui.PopID();
			}
		}
		ImGui.End();
	}

	/// A Model View's bar: which view it is, Frame, and filling the window (or a double-click on the bar).
	void DrawModelViewBar(ModelViewport viewport, int index, ImGui.Vec2 cell, float width, float height)
	{
		ImGui.DrawRectFilled(cell, .(cell.x + width, cell.y + height), ImGui.GetStyleColor(ImGui.Col.FrameBg));
		ImGui.SetCursorScreenPos(.(cell.x + 4, cell.y + 1));
		ImGui.SetNextItemWidth(120);
		if (ImGui.BeginCombo("##kind", scope String(sModelViewNames[(int)viewport.kind]).CStr()))
		{
			for (int k < sModelViewNames.Count)
			{
				if (ImGui.Selectable(scope String(sModelViewNames[k]).CStr(), (int)viewport.kind == k))
					SetModelViewKind(viewport, (ModelViewKind)k);
			}
			ImGui.EndCombo();
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(140);
		ShadingCombo("##shading", ref viewport.shading);
		ImGui.SameLine();
		if (ImGui.Button("Frame"))
		{
			Vector3 centre;
			float radius;
			ModelViewTarget(out centre, out radius);
			FrameModelView(viewport, centre, radius);
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Show the selected object (Frame All shows it in every view).");
		ImGui.SameLine();
		if (ImGui.Button("Frame All"))
		{
			Vector3 centre;
			float radius;
			ModelViewTarget(out centre, out radius);
			for (let other in mModelViewports)
				FrameModelView(other, centre, radius);
		}
		ImGui.SameLine();
		let maximised = mModelViewMaximised == index;
		if (ImGui.Button(maximised ? "Four Views" : "Fill Window"))
			mModelViewMaximised = maximised ? -1 : index;
		// A double-click on the bar's empty part does the same.
		ImGui.SameLine();
		let barEnd = ImGui.GetCursorScreenPos().x;
		ImGui.NewLine();
		let mouse = ImGui.GetMousePos();
		if (ImGui.IsMouseDoubleClicked(0) && mouse.x > barEnd && mouse.x < cell.x + width && mouse.y >= cell.y && mouse.y < cell.y + height && ImGui.IsWindowHovered())
			mModelViewMaximised = maximised ? -1 : index;
	}

	/// A list of the ways a view can be shaded. True when one was picked.
	bool ShadingCombo(char8* id, ref ViewShading shading)
	{
		var picked = false;
		if (ImGui.BeginCombo(id, scope String(sShadingNames[(int)shading]).CStr()))
		{
			for (int k < sShadingNames.Count)
			{
				if (ImGui.Selectable(scope String(sShadingNames[k]).CStr(), (int)shading == k))
				{
					shading = (ViewShading)k;
					picked = true;
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip(scope String(sShadingTips[k]).CStr());
			}
			ImGui.EndCombo();
		}
		return picked;
	}

	/// The Model View the keys go to: the one taking the mouse, while it is shown (else the Scene view's).
	ModelViewport KeyModelView => (ModelViewsShown && mModelViewActive >= 0 && mModelViewActive < mModelViewports.Count && mModelViewports[mModelViewActive].visible) ? mModelViewports[mModelViewActive] : null;

	/// The view keys (see the top of the file), for the Model View taking the mouse or else the Scene view.
	void HandleViewKeys(bool ctrl)
	{
		let viewport = KeyModelView;
		if (ImGui.IsKeyPressed(ImGui.Key.Z) && ImGui.IsKeyDown(ImGui.Key.LeftShift) && !ctrl)
		{
			if (viewport != null)
				ToggleWire(ref viewport.shading, ref viewport.unwired);
			else
				ToggleWire(ref mSceneShading, ref mSceneUnwired);
		}
		ModelViewKind kind = .Perspective;
		if (ImGui.IsKeyPressed(ImGui.Key.Keypad1))
			kind = ctrl ? .Back : .Front;
		else if (ImGui.IsKeyPressed(ImGui.Key.Keypad3))
			kind = ctrl ? .Left : .Right;
		else if (ImGui.IsKeyPressed(ImGui.Key.Keypad7))
			kind = ctrl ? .Bottom : .Top;
		if (kind != .Perspective)
		{
			if (viewport != null)
				SetModelViewKind(viewport, kind);
			else
			{
				float yaw, pitch;
				ModelViewAngles(kind, out yaw, out pitch);
				LookSceneAlong(AnglesForward(yaw, pitch));
			}
		}
		if (ImGui.IsKeyPressed(ImGui.Key.Keypad5))
		{
			if (viewport == null)
				SetSceneOrtho(!mSceneOrtho);
			else if (viewport.kind != .Perspective)
				SetModelViewKind(viewport, .Perspective);
		}
	}

	static void ToggleWire(ref ViewShading shading, ref ViewShading unwired)
	{
		if (shading == .Wireframe)
			shading = unwired == .Wireframe ? .MaterialPreview : unwired;
		else
		{
			unwired = shading;
			shading = .Wireframe;
		}
	}

	/// F: shows the selected object in the Model View taking the mouse; false when the keys go to the Scene view.
	bool FrameKeyModelView()
	{
		let viewport = KeyModelView;
		if (viewport == null)
			return false;
		Vector3 centre;
		float radius;
		ModelViewTarget(out centre, out radius);
		FrameModelView(viewport, centre, radius);
		return true;
	}

	/// Changes what a Model View shows, looking at the same point.
	void SetModelViewKind(ModelViewport viewport, ModelViewKind kind)
	{
		let forward = AnglesForward(viewport.yaw, viewport.pitch);
		let pivot = viewport.position + forward * (viewport.kind == .Perspective ? 6 : OrthoBack);
		viewport.kind = kind;
		ModelViewAngles(kind, out viewport.yaw, out viewport.pitch);
		let newForward = AnglesForward(viewport.yaw, viewport.pitch);
		viewport.position = pivot - newForward * (kind == .Perspective ? 6 : OrthoBack);
	}

	/// Draws the Model Views (after the Scene view, with the same gizmos and the same objects shown).
	void RenderModelViews()
	{
		if (!ModelViewsShown)
			return;
		for (let viewport in mModelViewports)
		{
			if (!viewport.visible)
				continue;
			viewport.view.onlyObject = mSceneView.onlyObject;
			viewport.view.hiddenHere = mSceneView.hiddenHere;
			viewport.view.shading = viewport.shading;
			viewport.view.hideRenderers = mSceneView.hideRenderers;
			viewport.view.Resize((int32)viewport.size.x, (int32)viewport.size.y);
			viewport.view.Render(mScene, viewport.camera);
		}
	}

	bool AnyModelViewVisible
	{
		get
		{
			if (!ModelViewsShown)
				return false;
			for (let viewport in mModelViewports)
			{
				if (viewport.visible)
					return true;
			}
			return false;
		}
	}

	// ---- the Scene view's view selector ----

	/// Where the view selector is drawn: its middle and radius.
	static void ViewSelectorPlace(ImGui.Vec2 origin, ImGui.Vec2 size, out ImGui.Vec2 centre, out float radius)
	{
		radius = 34;
		centre = .(origin.x + size.x - radius - 16, origin.y + radius + 16);
	}

	bool ViewSelectorHovered(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		ImGui.Vec2 centre;
		float radius;
		ViewSelectorPlace(origin, size, out centre, out radius);
		let mouse = ImGui.GetMousePos();
		let dx = mouse.x - centre.x;
		let dy = mouse.y - centre.y;
		return dx * dx + dy * dy < (radius + 12) * (radius + 12) || (Math.Abs(dx) < 60 && mouse.y > centre.y + radius && mouse.y < centre.y + radius + 44);
	}

	/// Points the Scene view along a direction, about the point it looks at (or the selection).
	void LookSceneAlong(Vector3 forward)
	{
		let oldForward = AnglesForward(mCamYaw, mCamPitch);
		let distance = mSceneOrtho ? OrthoBack : mSceneOrthoDistance;
		var pivot = mCamPosition + oldForward * distance;
		let selected = Selected;
		if (selected != null && !mSceneOrtho)
		{
			let renderer = selected.GetComponent<MeshRenderer>();
			pivot = (renderer && renderer.ActiveMesh != null) ? renderer.WorldBounds.Center : selected.Transform.Position;
			mSceneOrthoDistance = Math.Max((pivot - mCamPosition).Length, 1);
		}
		mCamYaw = Math.Atan2(forward.x, forward.z) * Mathf.Rad2Deg;
		mCamPitch = -Math.Asin(Math.Clamp(forward.y, -1, 1)) * Mathf.Rad2Deg;
		if (Math.Abs(forward.y) > 0.999f)
			mCamYaw = 0;
		mCamPosition = pivot - AnglesForward(mCamYaw, mCamPitch) * (mSceneOrtho ? OrthoBack : mSceneOrthoDistance);
	}

	void SetSceneOrtho(bool ortho)
	{
		if (ortho == mSceneOrtho)
			return;
		let forward = AnglesForward(mCamYaw, mCamPitch);
		if (ortho)
		{
			// The same picture at the pivot: half its height there as the orthographic size.
			let pivot = mCamPosition + forward * mSceneOrthoDistance;
			mSceneOrthoSize = Math.Max(mSceneOrthoDistance * Math.Tan(30 * Mathf.Deg2Rad), 0.05f);
			mCamPosition = pivot - forward * OrthoBack;
		}
		else
		{
			let pivot = mCamPosition + forward * OrthoBack;
			mSceneOrthoDistance = Math.Max(mSceneOrthoSize / Math.Tan(30 * Mathf.Deg2Rad), 0.5f);
			mCamPosition = pivot - forward * mSceneOrthoDistance;
		}
		mSceneOrtho = ortho;
	}

	/// The name of the way the Scene view looks: a fixed view, or Persp / Iso.
	void SceneViewName(String output)
	{
		let forward = AnglesForward(mCamYaw, mCamPitch);
		for (int k = 1; k < 7; k++)
		{
			float yaw, pitch;
			ModelViewAngles((ModelViewKind)k, out yaw, out pitch);
			if (Vector3.Dot(AnglesForward(yaw, pitch), forward) > 0.9999f)
			{
				output.Append(sModelViewNames[k]);
				return;
			}
		}
		output.Append(mSceneOrtho ? "Iso" : "Persp");
	}

	/// Unity's scene gizmo: the six axes as they lie in the view (X red, Y green, Z blue; the far side grey). Click one
	/// to look at the scene from that side; click the middle or the name to switch perspective and orthographic.
	void DrawViewSelector(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (size.x < 160 || size.y < 140)
			return;
		ImGui.Vec2 centre;
		float radius;
		ViewSelectorPlace(origin, size, out centre, out radius);
		let rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
		let right = rotation * Vector3.Right;
		let up = rotation * Vector3.Up;
		let forward = rotation * Vector3.Forward;
		Vector3[6] axes = .(.(1, 0, 0), .(0, 1, 0), .(0, 0, 1), .(-1, 0, 0), .(0, -1, 0), .(0, 0, -1));
		Color[3] colors = .(.(0.90f, 0.30f, 0.28f, 1), .(0.45f, 0.80f, 0.30f, 1), .(0.30f, 0.52f, 0.95f, 1));
		StringView[3] letters = .("X", "Y", "Z");
		let mouse = ImGui.GetMousePos();
		let canClick = mSceneHovered && !mFlying && !ModelToolActive;
		ImGui.DrawCircleFilled(centre, radius + 10, .(0, 0, 0, 0.18f));
		// Far axes first, so the near ones are drawn over them.
		int[6] order = .(0, 1, 2, 3, 4, 5);
		float[6] depth = default;
		for (int i < 6)
			depth[i] = Vector3.Dot(axes[i], forward);
		for (int i < 6)
		{
			for (int j = i + 1; j < 6; j++)
			{
				if (depth[order[j]] > depth[order[i]])
					Swap!(order[i], order[j]);
			}
		}
		int hoveredAxis = -1;
		ImGui.Vec2[6] ends = default;
		for (int i < 6)
		{
			let axis = axes[i];
			ends[i] = .(centre.x + Vector3.Dot(axis, right) * radius, centre.y - Vector3.Dot(axis, up) * radius);
			let dx = mouse.x - ends[i].x;
			let dy = mouse.y - ends[i].y;
			if (canClick && dx * dx + dy * dy < 100 && (hoveredAxis < 0 || depth[i] < depth[hoveredAxis]))
				hoveredAxis = i;
		}
		for (let i in order)
		{
			let positive = i < 3;
			var color = positive ? colors[i % 3] : Color(0.62f, 0.62f, 0.62f, 1);
			if (i == hoveredAxis)
				color = Color.Lerp(color, .(1, 1, 1, 1), 0.45f);
			if (positive)
				ImGui.DrawLine(centre, ends[i], color, 2.5f);
			ImGui.DrawCircleFilled(ends[i], positive ? 9 : 6.5f, color);
			if (positive)
			{
				let letter = scope String(letters[i]);
				let textSize = ImGui.CalcTextSize(letter.CStr());
				ImGui.DrawText(.(ends[i].x - textSize.x * 0.5f, ends[i].y - textSize.y * 0.5f), .(0.08f, 0.08f, 0.08f, 1), letter.CStr());
			}
		}
		// The middle: perspective or orthographic.
		let middleHovered = canClick && hoveredAxis < 0 && Math.Abs(mouse.x - centre.x) < 7 && Math.Abs(mouse.y - centre.y) < 7;
		ImGui.DrawRectFilled(.(centre.x - 5, centre.y - 5), .(centre.x + 5, centre.y + 5), middleHovered ? Color(1, 1, 1, 0.95f) : Color(0.85f, 0.85f, 0.85f, 0.8f), 1);
		let name = SceneViewName(.. scope .());
		let nameSize = ImGui.CalcTextSize(name.CStr());
		let namePos = ImGui.Vec2(centre.x - nameSize.x * 0.5f, centre.y + radius + 6);
		let nameHovered = canClick && mouse.x > namePos.x - 6 && mouse.x < namePos.x + nameSize.x + 6 && mouse.y > namePos.y - 2 && mouse.y < namePos.y + nameSize.y + 2;
		ImGui.DrawText(.(namePos.x + 1, namePos.y + 1), .(0, 0, 0, 0.7f), name.CStr());
		ImGui.DrawText(namePos, nameHovered ? Color(1, 1, 1, 1) : Color(0.92f, 0.92f, 0.92f, 0.9f), name.CStr());
		// Under the name: how the view is shaded, a click to change it.
		let shading = scope String(sShadingNames[(int)mSceneShading]);
		let shadingSize = ImGui.CalcTextSize(shading.CStr());
		let shadingPos = ImGui.Vec2(centre.x - shadingSize.x * 0.5f, namePos.y + nameSize.y + 4);
		let shadingHovered = canClick && mouse.x > shadingPos.x - 6 && mouse.x < shadingPos.x + shadingSize.x + 6 && mouse.y > shadingPos.y - 2 && mouse.y < shadingPos.y + shadingSize.y + 2;
		ImGui.DrawText(.(shadingPos.x + 1, shadingPos.y + 1), .(0, 0, 0, 0.7f), shading.CStr());
		ImGui.DrawText(shadingPos, shadingHovered ? Color(1, 1, 1, 1) : Color(0.85f, 0.85f, 0.85f, 0.85f), shading.CStr());
		if (shadingHovered && ImGui.IsMouseClicked(0))
		{
			ImGui.SetNextWindowPos(.(shadingPos.x, shadingPos.y + shadingSize.y + 4));
			ImGui.OpenPopup("##sceneshading");
		}
		if (ImGui.BeginPopup("##sceneshading"))
		{
			for (int k < sShadingNames.Count)
			{
				if (ImGui.Selectable(scope String(sShadingNames[k]).CStr(), (int)mSceneShading == k))
					mSceneShading = (ViewShading)k;
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip(scope String(sShadingTips[k]).CStr());
			}
			ImGui.EndPopup();
		}
		if (hoveredAxis >= 0)
			ImGui.SetTooltip(scope String()..AppendF("Look from {}", ViewFromAxis(hoveredAxis)));
		else if (shadingHovered)
			ImGui.SetTooltip("How the view is shaded (Shift+Z: wireframe)");
		else if (middleHovered || nameHovered)
			ImGui.SetTooltip(mSceneOrtho ? "Perspective" : "Orthographic (no perspective)");
		if (ImGui.IsMouseClicked(0))
		{
			if (hoveredAxis >= 0)
				LookSceneAlong(-axes[hoveredAxis]);
			else if (middleHovered || nameHovered)
				SetSceneOrtho(!mSceneOrtho);
		}
	}

	/// The side an axis's ball shows the scene from: +X the left (a model faces -Z, so its left is +X), +Y the top,
	/// +Z the back.
	static StringView ViewFromAxis(int axis)
	{
		switch (axis)
		{
		case 0: return "the left";
		case 1: return "the top";
		case 2: return "the back";
		case 3: return "the right";
		case 4: return "below";
		default: return "the front";
		}
	}
}
