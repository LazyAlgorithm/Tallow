using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Scene tab: camera, picking, gizmos.
extension EditorApp
{
	// A left click in the Scene view picks when it is let go; moved further first, it drags the object under it out
	// (into an Inspector field or onto the Hierarchy) without selecting it.
	bool mScenePressed;
	ImGui.Vec2 mScenePressAt;
	float mScenePressU, mScenePressV;
	// The object being dragged out of the Scene view (0: none).
	uint32 mSceneDragId;
	// A prefab or model dragged from the Project panel over the Scene view: made already, following the mouse, and
	// kept when it is dropped (thrown away if the drag leaves the view or is let go elsewhere).
	GameObject mDropPreview;
	String mDropPreviewAsset = new .() ~ delete _;
	bool mDropPreviewSeen;

	void DrawSceneView()
	{
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		// Keeps the view's hidden objects those of the scene open now, even with the Hierarchy closed.
		mSceneView.hiddenHere = Visibility.hidden;
		let open = ImGui.Begin("Scene", null, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		mSceneVisible = false;
		let sceneDock = ImGui.GetWindowDockID();
		if (sceneDock != 0)
			mAssetCenterDock = sceneDock;
		mSceneHovered = false;
		if (open)
		{
			let size = ImGui.GetContentRegionAvail();
			let origin = ImGui.GetCursorScreenPos();
			if (size.x > 8 && size.y > 8)
			{
				mSceneVisible = true;
				mSceneSize = size;
				mSceneOrigin = origin;
				UpdateSceneCamera(size.x / size.y);
				// Queue the image only after resizing: Resize destroys the previous output texture.
				mSceneView.Resize((int32)size.x, (int32)size.y);
				if (mSceneView.Width > 0)
					ImGui.Picture(mSceneView.OutputTexture, .(mSceneView.Width, mSceneView.Height));
				mSceneHovered = ImGui.IsItemHovered();
				mDropPreviewSeen = false;
				if (ImGui.BeginDragDropTarget())
				{
					let asset = ImGui.AcceptDragDropPayload("ASSET", ImGui.DragDropFlags.AcceptBeforeDelivery);
					if (asset != null)
					{
						let mouse = ImGui.GetMousePos();
						let relative = StringView((char8*)asset.data, asset.dataSize);
						let u = (mouse.x - origin.x) / size.x, v = (mouse.y - origin.y) / size.y;
						if (ImGui.IsMouseReleased(0))
						{
							if (mDropPreview != null && mDropPreviewAsset == relative)
								KeepDropPreview(u, v);
							else
								DropAssetIntoScene(relative, true, u, v);
						}
						else
							ShowDropPreview(relative, u, v);
					}
					ImGui.EndDragDropTarget();
				}
				// Dragged away from the view, or let go somewhere else: the preview goes.
				if (!mDropPreviewSeen)
					ClearDropPreview();
				HandleSceneCameraInput();

				let selected = Selected;
				// Only one view takes the mouse each frame: the last one pointed at (the Scene view or a Model View).
				if (mSceneHovered && ModelViewsCanSwitch)
					mModelViewActive = -1;
				if (mModelViewActive == -1 || !ModelViewsShown)
				{
					// An active sculpting or placing tool owns the mouse instead of selection and the transform gizmo.
					bool gizmoActive = UpdateRigTools(selected, origin, size) || UpdateSoftBodyPaint(selected, origin, size) || UpdateModelTools(selected, origin, size) || UpdateBrush(selected, origin, size);
					gizmoActive = ObjectGizmo(selected, origin, size, gizmoActive);
					if (mSceneHovered && ImGui.IsMouseClicked(0) && !gizmoActive && !mFlying && !ViewSelectorHovered(origin, size))
					{
						let mouse = ImGui.GetMousePos();
						let u = (mouse.x - origin.x) / size.x, v = (mouse.y - origin.y) / size.y;
						// A bone is picked at once (and dragged with its own handle); an object when the click is let go.
						if (!PickBone(u, v))
						{
							mScenePressed = true;
							mScenePressAt = mouse;
							mScenePressU = u;
							mScenePressV = v;
						}
					}
				}
				UpdateSceneDrag();
				DrawViewSelector(origin, size);

				UpdateQuickAdd(origin, size);
				DrawSceneOverlays(origin, size);
				let stats = scope String();
				stats.AppendF("{} draws  {} instances  {}k tris", mSceneView.DrawCalls, mSceneView.Instances, mSceneView.Triangles / 1000);
				if (mSceneView.LightCount > 0)
					stats.AppendF("  {} lights", mSceneView.LightCount);
				if (mSceneView.LightsDropped > 0)
					stats.AppendF(" ({} more left out)", mSceneView.LightsDropped);
				if (mSceneView.ShadowTiles > 0)
					stats.AppendF("  {} shadow tiles", mSceneView.ShadowTiles);
				if (mSceneView.LodCulled > 0)
					stats.AppendF("  {} too small (LOD)", mSceneView.LodCulled);
				if (mSceneOcclusion)
					stats.AppendF("  {} hidden by {} occluders ({}k tris)", mSceneView.OcclusionCulled, mSceneView.Occluders, mSceneView.OccluderTriangles / 1000);
				if (mShowOcclusionPicture)
					DrawOcclusionPicture(origin, size);
				ImGui.DrawText(.(origin.x + 10, origin.y + 8), .(1, 1, 1, 0.65f), stats.CStr());
				if (mFlying)
					ImGui.DrawText(.(origin.x + 10, origin.y + size.y - 24), .(1, 1, 1, 0.65f), scope $"WASD move, Q/E down/up, Shift faster, wheel sets speed ({mCamSpeed:0.0} m/s)" .CStr());
			}
		}
		ImGui.End();
	}

	/// The move, turn or scale gizmo on the selected object (when no tool has the mouse). True while it is in use or
	/// pointed at, so a click does not pick.
	bool ObjectGizmo(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size, bool toolActive)
	{
		if (selected == null || toolActive || selected.IsFolder)
			return toolActive;
		ImGui.tn_gizmo_begin(origin.x, origin.y, size.x, size.y, mSceneCamera.orthographic);
		var world = selected.Transform.LocalToWorld;
		var view = mSceneCamera.view;
		var projection = mSceneCamera.projection;
		float[3] snap = .(mSnapMove, mSnapMove, mSnapMove);
		if (mGizmoOperation == 1)
			snap = .(mSnapRotate, mSnapRotate, mSnapRotate);
		else if (mGizmoOperation == 2)
			snap = .(mSnapScale, mSnapScale, mSnapScale);
		let snapping = SnapActive;
		if (ImGui.tn_gizmo_manipulate(&view.m, &projection.m, mGizmoOperation, mGizmoLocal, &world.m, snapping ? &snap : null))
		{
			let parent = selected.Transform.Parent;
			let local = parent != null ? parent.WorldToLocal * world : world;
			Vector3 t, s;
			Quaternion q;
			local.Decompose(out t, out q, out s);
			selected.Transform.LocalPosition = t;
			selected.Transform.LocalRotation = q;
			selected.Transform.LocalScale = s;
			MarkDirty();
		}
		return ImGui.tn_gizmo_is_using() || ImGui.tn_gizmo_is_over();
	}

	/// The Scene view's occlusion picture in its bottom-right corner: nearer occluders brighter, empty dark.
	void DrawOcclusionPicture(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let occlusion = mSceneView.Occlusion;
		let block = 4;
		let width = OcclusionBuffer.Width;
		let height = OcclusionBuffer.Height;
		let corner = ImGui.Vec2(origin.x + size.x - width - 10, origin.y + size.y - height - 10);
		ImGui.DrawRectFilled(corner, .(corner.x + width, corner.y + height), .(0, 0, 0, 0.55f));
		if (occlusion == null || !mSceneOcclusion)
		{
			ImGui.DrawText(.(corner.x + 8, corner.y + 8), .(1, 1, 1, 0.7f), "Turn on Window > Scene Occlusion Culling");
			return;
		}
		let depth = occlusion.Depth;
		for (int y = 0; y < height; y += block)
		{
			for (int x = 0; x < width; x += block)
			{
				let d = depth[(y + block / 2) * width + x + block / 2];
				if (d == float.MaxValue)
					continue;
				let shade = Math.Clamp(1 - Math.Log(Math.Max(d, 1)) / 6.5f, 0.15f, 1);
				ImGui.DrawRectFilled(.(corner.x + x, corner.y + y), .(corner.x + x + block, corner.y + y + block), .(0.3f * shade, 0.75f * shade, shade, 0.9f));
			}
		}
		ImGui.DrawRect(corner, .(corner.x + width, corner.y + height), .(1, 1, 1, 0.4f));
		ImGui.DrawText(.(corner.x + 6, corner.y + 4), .(1, 1, 1, 0.8f), "Occlusion picture");
	}

	void UpdateSceneCamera(float aspect)
	{
		let rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
		let forward = rotation * Vector3.Forward;
		mSceneCamera.position = mCamPosition;
		mSceneCamera.forward = forward;
		mSceneCamera.near = 0.1f;
		mSceneCamera.far = 2000.0f;
		mSceneCamera.fieldOfView = 60;
		mSceneCamera.aspect = aspect;
		mSceneCamera.orthographic = mSceneOrtho;
		mSceneCamera.occlusionCulling = mSceneOcclusion && !mSceneOrtho;
		mSceneCamera.orthographicSize = mSceneOrthoSize;
		mSceneCamera.view = Matrix4.LookAt(mCamPosition, mCamPosition + forward, rotation * Vector3.Up);
		if (mSceneOrtho)
		{
			// Seen from far back (OrthoBack), so nothing in front of the pivot is cut off.
			mSceneCamera.near = 1;
			mSceneCamera.projection = Matrix4.Ortho(-mSceneOrthoSize * aspect, mSceneOrthoSize * aspect, -mSceneOrthoSize, mSceneOrthoSize, 1, 2000, Gfx.HomogeneousDepth);
		}
		else
			mSceneCamera.projection = Matrix4.Perspective(60, aspect, 0.1f, 2000.0f, Gfx.HomogeneousDepth);
	}

	void HandleSceneCameraInput()
	{
		// Right mouse: fly. Middle mouse: pan. Wheel: dolly.
		// A modelling tool takes the right button to cancel (ModelTools.bf).
		if (mSceneHovered && ImGui.IsMouseClicked(1) && !ModelToolActive)
		{
			mFlying = true;
			// Looking round leaves an orthographic view for perspective, as Blender does.
			if (mSceneOrtho)
				SetSceneOrtho(false);
		}
		if (!ImGui.IsMouseDown(1))
			mFlying = false;
		let rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
		let forward = rotation * Vector3.Forward;
		let right = rotation * Vector3.Right;
		let up = rotation * Vector3.Up;
		if (mFlying)
		{
			let delta = Input.MouseDelta;
			mCamYaw += delta.x * 0.18f;
			mCamPitch = Mathf.Clamp(mCamPitch + delta.y * 0.18f, -89, 89);
			// The wheel sets the flying speed, as in Unity.
			let flyWheel = Input.MouseWheel;
			if (flyWheel != 0)
				mCamSpeed = Math.Clamp(mCamSpeed * Math.Pow(1.2f, flyWheel), 0.25f, 400);
			var speed = mCamSpeed * Time.UnscaledDeltaTime;
			if (Input.GetKey(.LeftShift))
				speed *= 4;
			if (Input.GetKey(.W))
				mCamPosition = mCamPosition + forward * speed;
			if (Input.GetKey(.S))
				mCamPosition = mCamPosition - forward * speed;
			if (Input.GetKey(.D))
				mCamPosition = mCamPosition + right * speed;
			if (Input.GetKey(.A))
				mCamPosition = mCamPosition - right * speed;
			if (Input.GetKey(.E))
				mCamPosition = mCamPosition + Vector3.Up * speed;
			if (Input.GetKey(.Q))
				mCamPosition = mCamPosition - Vector3.Up * speed;
		}
		else if (mSceneHovered)
		{
			if (ImGui.IsMouseDown(2))
			{
				let delta = Input.MouseDelta;
				let pan = mSceneOrtho ? 2 * mSceneOrthoSize / Math.Max(mSceneSize.y, 1) : 0.02f * Math.Clamp(mCamSpeed / 12, 0.1f, 10);
				mCamPosition = mCamPosition - right * (delta.x * pan) + up * (delta.y * pan);
			}
			let wheel = Input.MouseWheel;
			if (wheel != 0 && !ModelOwnsWheel)
			{
				if (mSceneOrtho)
					mSceneOrthoSize = Math.Clamp(mSceneOrthoSize * Math.Pow(0.87f, wheel), 0.02f, 1000);
				else
					mCamPosition = mCamPosition + forward * (wheel * 1.5f * Math.Clamp(mCamSpeed / 12, 0.05f, 10));
			}
		}
	}

	void Pick(float u, float v)
	{
		if (PickBone(u, v))
			return;
		let best = PickObject(u, v);
		mSelectedId = best != null ? best.Id : 0;
	}

	/// A pending click in the Scene view: let go where it was pressed, it picks; moved further than a few pixels
	/// with an object under where it was pressed, it drags that object out as a reference, leaving the selection.
	void UpdateSceneDrag()
	{
		if (mScenePressed)
		{
			let mouse = ImGui.GetMousePos();
			let moved = Math.Abs(mouse.x - mScenePressAt.x) + Math.Abs(mouse.y - mScenePressAt.y);
			if (ImGui.IsMouseReleased(0) || !ImGui.IsMouseDown(0))
			{
				mScenePressed = false;
				if (moved < 6)
					Pick(mScenePressU, mScenePressV);
			}
			else if (moved >= 6)
			{
				mScenePressed = false;
				mSceneDragId = PickObject(mScenePressU, mScenePressV)?.Id ?? 0;
			}
		}
		if (mSceneDragId == 0)
			return;
		let dragged = mScene.FindById(mSceneDragId);
		if (dragged != null && ImGui.BeginDragDropSource(ImGui.DragDropFlags.SourceExtern))
		{
			var id = mSceneDragId;
			ImGui.SetDragDropPayload("GAMEOBJECT", &id, sizeof(uint32));
			ImGui.Text(dragged.Name);
			ImGui.EndDragDropSource();
		}
		// The frame it is let go is still a drag (that is when a target takes it); after it, none.
		if (dragged == null || !ImGui.IsMouseDown(0))
			mSceneDragId = 0;
	}

	/// The object under a point of the Scene view (from 0 to 1 across and down), or null.
	GameObject PickObject(float u, float v)
	{
		let ray = mSceneCamera.ViewportPointToRay(u, v);
		GameObject best = null;
		float bestDistance = float.MaxValue;
		for (let renderer in mScene.Renderers)
		{
			// Hidden by the world state shown: not clickable either; nor are reference images, or what Show Only hides.
			if (!renderer.IsActiveAndEnabled || !renderer.GameObject.InActiveWorld || RenderView.EditorOnlyObjects.Contains(renderer.GameObject.Id))
				continue;
			if (mSceneView.onlyObject != 0 && renderer.GameObject.Id != mSceneView.onlyObject)
				continue;
			if (!PickableInScene(renderer.GameObject))
				continue;
			let mesh = renderer.ActiveMesh;
			if (mesh == null)
				continue;
			let boundsHit = renderer.WorldBounds.IntersectRay(ray);
			if (boundsHit < 0 || boundsHit > bestDistance)
				continue;
			var distance = boundsHit;
			if (mesh.Indices.Count > 0 && mesh.Indices.Count < 200000)
			{
				// Refine against the triangles in the mesh's own space.
				let toLocal = renderer.Transform.WorldToLocal;
				let localOrigin = toLocal.TransformPoint(ray.origin);
				let localEnd = toLocal.TransformPoint(ray.origin + ray.direction);
				let localRay = Ray(localOrigin, (localEnd - localOrigin).Normalized);
				let t = mesh.Raycast(localRay);
				if (t < 0)
					continue;
				let worldPoint = renderer.Transform.LocalToWorld.TransformPoint(localRay.GetPoint(t));
				distance = (worldPoint - ray.origin).Length;
			}
			if (distance < bestDistance)
			{
				bestDistance = distance;
				best = renderer.GameObject;
			}
		}
		// A decal is clicked where the ray enters its box before reaching the surface it lies on.
		for (let decal in mScene.Components<Decal>(.. scope .()))
		{
			if (!decal.GameObject.ActiveInHierarchy || !decal.GameObject.InActiveWorld || !PickableInScene(decal.GameObject))
				continue;
			let volume = decal.BoxMatrix;
			let toLocal = volume.Inverse;
			let localOrigin = toLocal.TransformPoint(ray.origin);
			let localEnd = toLocal.TransformPoint(ray.origin + ray.direction);
			let localRay = Ray(localOrigin, (localEnd - localOrigin).Normalized);
			let t = Bounds(.(-0.5f), .(0.5f)).IntersectRay(localRay);
			if (t < 0)
				continue;
			let distance = (volume.TransformPoint(localRay.GetPoint(t)) - ray.origin).Length;
			if (distance <= bestDistance)
			{
				bestDistance = distance;
				best = decal.GameObject;
			}
		}
		// Generated children (voxel chunks) select the object that owns them.
		while (best != null && best.Transient && best.Transform.Parent != null)
			best = best.Transform.Parent.GameObject;
		return best;
	}

	/// The one object the Scene view shows while modelling (Show Only) or rigging (the model on its own); else 0.
	uint32 IsolatedObject => mSceneView.onlyObject != 0 ? mSceneView.onlyObject : ((mRig != null && mSceneView.hideRenderers) ? mRigObject : 0);

	void BuildGizmos()
	{
		if (mShowGrid)
			Gizmos.Lines.Grid(mCamPosition, 60, 1.0f, .(1, 1, 1, 0.07f), .(1, 1, 1, 0.18f));
		let selected = Selected;
		// While one object is shown on its own (modelling, rigging), only its gizmos are drawn.
		let only = IsolatedObject;
		for (let component in mScene.Components)
		{
			// What a Hierarchy eye hides has no gizmos either.
			if (component.IsActiveAndEnabled && (only == 0 || component.GameObject.Id == only) && !SceneHidden(component.GameObject))
				component.OnDrawGizmos(component.GameObject == selected);
		}
		// Built-in components that are handles (Light...) draw theirs from a static DrawGizmos.
		for (let info in HandleComponents.Types)
		{
			if (!info.drawGizmos.IsInitialized)
				continue;
			for (let gameObject in mScene.Objects)
			{
				if (!gameObject.ActiveInHierarchy || (only != 0 && gameObject.Id != only) || SceneHidden(gameObject))
					continue;
				let world = mScene.World;
				if (world.Has(gameObject.Entity, info.index) && world.IsEnabled(gameObject.Entity, info.index))
					info.drawGizmos.Invoke(null, gameObject, gameObject == selected).IgnoreError();
			}
		}
		// A model in edit mode shows its own edges instead of the object's box.
		if (selected != null && !EditedModel.IsValid)
		{
			let renderer = selected.GetComponent<MeshRenderer>();
			if (renderer && renderer.ActiveMesh != null)
				Gizmos.Lines.Box(renderer.ActiveMesh.Bounds, selected.Transform.LocalToWorld, .(1.0f, 0.62f, 0.15f, 1));
		}
		BuildSceneToolGizmos();
		BuildProbePlacementGizmos();
		BuildBoneGizmos();
		BuildModelGizmos();
	}
}
