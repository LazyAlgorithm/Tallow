using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Inspector panel.
extension EditorApp
{
	bool BeginProperty(char8* label)
	{
		ImGui.TableNextRow();
		ImGui.TableNextColumn();
		ImGui.AlignTextToFramePadding();
		ImGui.Text(StringView(label));
		ImGui.TableNextColumn();
		ImGui.SetNextItemWidth(-1);
		return true;
	}

	/// A component's fields: the ordinary ones, then any marked [Advanced] under a foldout that starts closed.
	bool DrawFieldList(List<FieldRef> fields, StringView id)
	{
		bool changed = false, anyAdvanced = false;
		if (fields.Count > 0 && BeginPropertyTable(scope String(id)))
		{
			for (let field in fields)
			{
				if (field.advanced)
					anyAdvanced |= !field.hidden;
				else if (!field.hidden)
					changed |= DrawField(field);
			}
			ImGui.EndTable();
		}
		if (anyAdvanced && ImGui.TreeNode(scope $"Advanced###{id}advanced"))
		{
			if (BeginPropertyTable(scope $"{id}advancedtable"))
			{
				for (let field in fields)
				{
					if (field.advanced && !field.hidden)
						changed |= DrawField(field);
				}
				ImGui.EndTable();
			}
			ImGui.TreePop();
		}
		return changed;
	}

	bool BeginPropertyTable(char8* id)
	{
		if (!ImGui.BeginTable(id, 2, ImGui.TableFlags.SizingStretchProp))
			return false;
		ImGui.TableSetupColumn("name", ImGui.ColumnFlags.WidthStretch, 0.38f);
		ImGui.TableSetupColumn("value", ImGui.ColumnFlags.WidthStretch, 0.62f);
		return true;
	}

	/// Turns "moveSpeed" into "Move Speed" for display.
	static void NiceName(StringView name, String outText)
	{
		for (int i < name.Length)
		{
			let c = name[i];
			if (i == 0)
				outText.Append(c.ToUpper);
			else
			{
				if (c.IsUpper && !name[i - 1].IsUpper)
					outText.Append(' ');
				outText.Append(c);
			}
		}
	}

	// The object the Inspector is locked to (0: it follows the selection), and its name when locked, so that opening
	// another scene, whose object may have the same id, unlocks it.
	uint32 mInspectorLock;
	String mInspectorLockName = new .() ~ delete _;

	/// The object the Inspector shows: the one it is locked to, while it still exists, else the selection.
	GameObject InspectedObject
	{
		get
		{
			if (mInspectorLock == 0)
				return Selected;
			let locked = mScene.FindById(mInspectorLock);
			if (locked == null || locked.Name != mInspectorLockName)
			{
				mInspectorLock = 0;
				return Selected;
			}
			return locked;
		}
	}

	/// The lock button beside an object's name: locked, the Inspector keeps showing it whatever is selected, so things
	/// can be dragged into its fields from the Hierarchy, the Scene view and the Project panel.
	void DrawInspectorLock(GameObject gameObject)
	{
		let locked = mInspectorLock == gameObject.Id;
		if (locked)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		if (ImGui.Button(locked ? "\u{f023}##inspectorlock" : "\u{f09c}##inspectorlock", .(ImGui.GetFrameHeight(), 0)))
		{
			mInspectorLock = locked ? 0 : gameObject.Id;
			mInspectorLockName.Set(gameObject.Name);
		}
		if (locked)
			ImGui.PopStyleColor();
		NoteTestRect("lock");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(locked ? "Locked: the Inspector stays on this object whatever is selected. Click to follow the selection again." : "Lock the Inspector to this object, to drag other objects and assets into its fields.");
	}

	void DrawInspector()
	{
		if (ImGui.Begin("Inspector"))
		{
			// Where this panel is docked is where the Model window opens.
			let inspectorDock = ImGui.GetWindowDockID();
			if (inspectorDock != 0)
				mInspectorDock = inspectorDock;
			let selected = InspectedObject;
			let locked = mInspectorLock != 0;
			// Selecting another object takes the Inspector back from an asset clicked in the Project panel.
			if (!locked && mSelectedId != mInspectedObject)
			{
				mInspectedObject = mSelectedId;
				if (mSelectedId != 0)
					mInspectAsset = false;
			}
			if (!locked && mInspectAsset && mSelectedAsset.EndsWith(".tmat"))
			{
				let relative = scope String();
				Assets.MakeRelative(mSelectedAsset, relative);
				let name = scope String();
				Path.GetFileNameWithoutExtension(mSelectedAsset, name);
				ImGui.Text(scope $"{name}  (Material)");
				ImGui.TextDisabled(relative.CStr());
				DrawMaterialInspector(relative);
			}
			else if (!locked && mInspectAsset && mSelectedAsset.EndsWith(".tdata"))
				DrawDataAssetInspector(mSelectedAsset);
			else if (!locked && mInspectAsset && Assets.IsConvertedModel(mSelectedAsset))
				DrawModelImportInspector(mSelectedAsset);
			else if (selected == null)
				DrawSceneSettings();
			else
			{
				DrawObjectInspector(selected);
				// The material its Mesh Renderer uses, under the components, as in Unity.
				let renderer = selected.GetComponent<MeshRenderer>();
				if (renderer && !renderer.material.IsEmpty)
				{
					let name = scope String();
					Path.GetFileNameWithoutExtension(renderer.material, name);
					ImGui.Dummy(.(0, 6));
					if (ImGui.CollapsingHeader(scope $"{name}  (Material)###materialheader" .CStr(), ImGui.TreeFlags.DefaultOpen))
						DrawMaterialInspector(renderer.material);
				}
				DrawInspectorScriptDrop(selected);
			}
		}
		ImGui.End();
	}

	void DrawSceneSettings()
	{
		ImGui.TextDisabled("Scene Settings");
		ImGui.Separator();
		let env = mScene.Environment;
		bool changed = false;
		if (ImGui.CollapsingHeader("Lighting", ImGui.TreeFlags.DefaultOpen) && BeginPropertyTable("lighting"))
		{
			BeginProperty("Ambient Sky");
			changed |= ImGui.ColorEdit3("##as", ref env.ambientSky);
			BeginProperty("Ambient Ground");
			changed |= ImGui.ColorEdit3("##ag", ref env.ambientGround);
			BeginProperty("Ambient Intensity");
			changed |= ImGui.SliderFloat("##ai", ref env.ambientIntensity, 0, 2);
			BeginProperty("Ambient From Surroundings");
			changed |= ImGui.Checkbox("##afs", ref env.ambientFromSurroundings);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Light from all around: the sky, and inside a Reflection Probe's box the room it saw,\ninstead of the Ambient Sky and Ground colours. Ambient Intensity still scales it.");
			BeginProperty("Exposure");
			changed |= ImGui.SliderFloat("##ex", ref env.exposure, 0.1f, 4);
			BeginProperty("Bloom");
			changed |= ImGui.SliderFloat("##bl", ref env.bloom, 0, 2);
			BeginProperty("Bloom Threshold");
			changed |= ImGui.SliderFloat("##bt", ref env.bloomThreshold, 0, 4);
			BeginProperty("Shadow Distance");
			changed |= ImGui.DragFloat("##sd", ref env.shadowDistance, 1, 10, 1000);
			BeginProperty("Reflections");
			changed |= ImGui.SliderFloat("##ri", ref env.reflectionIntensity, 0, 2);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("How strongly surfaces mirror the sky and the reflection probes.\nPut a Reflection Probe in each room so that indoors does not mirror the sky.");
			ImGui.EndTable();
		}
		if (ImGui.CollapsingHeader("Sky and Fog", ImGui.TreeFlags.DefaultOpen) && BeginPropertyTable("sky"))
		{
			BeginProperty("Zenith");
			changed |= ImGui.ColorEdit3("##sz", ref env.skyZenith);
			BeginProperty("Horizon");
			changed |= ImGui.ColorEdit3("##sh", ref env.skyHorizon);
			BeginProperty("Ground");
			changed |= ImGui.ColorEdit3("##sg", ref env.skyGround);
			BeginProperty("Fog Color");
			changed |= ImGui.ColorEdit3("##fc", ref env.fogColor);
			BeginProperty("Fog Density");
			changed |= ImGui.DragFloat("##fd", ref env.fogDensity, 0.0002f, 0, 0.2f, "%.4f");
			ImGui.EndTable();
		}
		changed |= DrawScreenEffectsSettings(env);
		changed |= DrawStreamingSettings(env);
		if (changed)
			MarkDirty();
		ImGui.Spacing();
		ImGui.TextDisabled("Select an object to edit its components.");
	}

	void DrawObjectInspector(GameObject gameObject)
	{
		DrawObjectHeader(gameObject);
		if (gameObject.IsFolder)
		{
			DrawFolderInspector(gameObject);
			return;
		}
		DrawObjectConfig(gameObject);
		DrawTransformSection(gameObject.Transform);

		// What the components' menus asked for is done after they are all drawn.
		Component remove = null;
		int move = 0;
		int moveIndex = -1;
		List<FieldRef> fields = scope .();
		for (int index = 0; index < gameObject.Components.Count; index++)
		{
			let component = gameObject.Components[index];
			ImGui.PushID(Internal.UnsafeCastToPtr(component));
			switch (DrawComponentSection(gameObject, index, fields))
			{
			case .Remove:
				remove = component;
			case .MoveUp:
				move = -1;
				moveIndex = index;
			case .MoveDown:
				move = 1;
				moveIndex = index;
			case .None:
			}
			ImGui.PopID();
		}
		if (moveIndex >= 0)
		{
			Swap!(gameObject.Components[moveIndex], gameObject.Components[moveIndex + move]);
			MarkDirty();
		}
		if (remove != null)
		{
			gameObject.RemoveComponent(remove);
			MarkDirty();
		}
		DrawHandleSections(gameObject, fields);
		DrawDataSections(gameObject, fields);
		DrawAddComponent(gameObject);
	}

	// ---- Built-in components that are handles (Light..., HandleComponents) ----

	void DrawHandleSections(GameObject gameObject, List<FieldRef> fields)
	{
		let handles = scope List<HandleComponents.Info>();
		HandleComponents.On(gameObject, handles);
		HandleComponents.Info remove = null;
		for (let info in handles)
		{
			ImGui.PushID(info.index + 100000);
			if (DrawHandleSection(gameObject, info, fields))
				remove = info;
			ImGui.PopID();
		}
		if (remove != null)
		{
			gameObject.RemoveData(remove.dataType);
			MarkDirty();
		}
	}

	/// A handle component, drawn like a script component: enable toggle, icon, menu and fields. True when its menu
	/// asked to remove it.
	bool DrawHandleSection(GameObject gameObject, HandleComponents.Info info, List<FieldRef> fields)
	{
		let world = gameObject.Scene.World;
		let title = scope String();
		NiceName(info.name, title);
		ImGui.Separator();
		let open = ImGui.CollapsingHeader(scope String()..AppendF("            {}###handle", title).CStr(), ImGui.TreeFlags.DefaultOpen | ImGui.TreeFlags.AllowOverlap);
		bool remove = false;
		let size = info.dataType.Size;
		if (ImGui.BeginPopupContextItem("HandleMenu"))
		{
			let value = (uint8*)gameObject.GetData(info.dataType);
			if (ImGui.MenuItem("Reset"))
			{
				HandleComponents.Reset(gameObject, info);
				MarkDirty();
			}
			if (ImGui.MenuItem("Copy Component"))
			{
				ClearDataClipboard();
				mDataClipboardType = info.dataType;
				mDataClipboardHandle = info;
				mDataClipboard.AddRange(Span<uint8>(value, size));
				// The clipboard keeps lists of its own, so the copy outlives the component.
				HandleComponents.OwnLists(mDataClipboard.Ptr, info);
			}
			if (ImGui.MenuItem("Paste Component Values", null, false, mDataClipboardType == info.dataType))
			{
				HandleComponents.Assign(value, mDataClipboard.Ptr, info);
				MarkDirty();
			}
			ImGui.Separator();
			if (ImGui.MenuItem("Remove Component"))
				remove = true;
			ImGui.EndPopup();
		}
		ImGui.SameLine(30);
		ImGui.PushStyleVar(ImGui.StyleVar.FramePadding, ImGui.Vec2(1, 1));
		bool enabled = world.IsEnabled(gameObject.Entity, info.index);
		if (ImGui.Checkbox("##enabled", ref enabled))
		{
			world.Enable(gameObject.Entity, info.index, enabled);
			MarkDirty();
		}
		ImGui.PopStyleVar();
		ImGui.SameLine(54);
		ImGui.TextColored(Icons.ComponentColor, ComponentIcon(info.name));
		ImGui.SameLine(ImGui.GetWindowWidth() - 30);
		if (ImGui.SmallButton(Icons.Menu))
			ImGui.OpenPopup("HandleMenu");
		if (!open || remove)
			return remove;
		fields.Clear();
		HandleComponents.GetFields(gameObject, info, fields);
		bool changed = false;
		changed |= DrawFieldList(fields, "handlefields");
		if (changed)
		{
			MarkDirty();
			if (info.onValidate != null)
				info.onValidate(gameObject);
		}
		DrawHandleTools(gameObject, info);
		return false;
	}

	/// The extra tools under a built-in component's fields (Stick to Surface, Bake...).
	void DrawHandleTools(GameObject gameObject, HandleComponents.Info info)
	{
		if (info.handleType == typeof(Decal))
			DrawDecalTools(gameObject.GetComponent<Decal>());
		else if (info.handleType == typeof(AudioSource))
			DrawAudioTools(gameObject.GetComponent<AudioSource>());
		else if (info.handleType == typeof(ReflectionProbe))
			DrawReflectionProbeTools(gameObject.GetComponent<ReflectionProbe>());
		else if (info.handleType == typeof(SkinnedMeshRenderer))
			DrawSkinnedClips(gameObject.GetComponent<SkinnedMeshRenderer>());
		else if (info.handleType == typeof(Foliage))
			DrawFoliageTools(gameObject.GetComponent<Foliage>());
		else if (info.handleType == typeof(VoxelObject))
			DrawVoxelObjectTools(gameObject.GetComponent<VoxelObject>());
		else if (info.handleType == typeof(LODGroup))
			DrawLODGroupTools(gameObject.GetComponent<LODGroup>());
		else if (info.handleType == typeof(ViewmodelPose))
			DrawViewmodelPoseTools(gameObject.GetComponent<ViewmodelPose>());
		else if (info.handleType == typeof(SequencePlayer))
			DrawSequencePlayerTools(gameObject.GetComponent<SequencePlayer>());
		else if (info.handleType == typeof(DialogueRunner))
			DrawDialogueRunnerTools(gameObject.GetComponent<DialogueRunner>());
	}

	// ---- Data components ([Component] structs in the object's entity, DataComponents) ----

	/// The copied data component: its type and bytes (data components hold plain values only).
	Type mDataClipboardType;
	List<uint8> mDataClipboard = new .() ~ delete _;
	/// The built-in component the clipboard was copied from, whose lists it owns (null for a data component).
	HandleComponents.Info mDataClipboardHandle;

	/// Empties the component clipboard, freeing the lists a built-in component's copy owned.
	void ClearDataClipboard()
	{
		if (mDataClipboardHandle != null && mDataClipboard.Count >= mDataClipboardHandle.defaults.Count)
			HandleComponents.FreeLists(mDataClipboard.Ptr, mDataClipboardHandle);
		mDataClipboardHandle = null;
		mDataClipboardType = null;
		mDataClipboard.Clear();
	}

	void DrawDataSections(GameObject gameObject, List<FieldRef> fields)
	{
		let data = scope List<DataComponents.Info>();
		DataComponents.On(gameObject, data);
		DataComponents.Info remove = null;
		for (let info in data)
		{
			ImGui.PushID(info.index);
			if (DrawDataSection(gameObject, info, fields))
				remove = info;
			ImGui.PopID();
		}
		if (remove != null)
		{
			gameObject.RemoveData(remove.type);
			MarkDirty();
		}
	}

	/// One data component: a header with its menu, and its fields. True when its menu asked to remove it.
	bool DrawDataSection(GameObject gameObject, DataComponents.Info info, List<FieldRef> fields)
	{
		let title = scope String();
		NiceName(info.name, title);
		ImGui.Separator();
		let open = ImGui.CollapsingHeader(scope String()..AppendF("      {}###data", title).CStr(), ImGui.TreeFlags.DefaultOpen | ImGui.TreeFlags.AllowOverlap);
		bool remove = false;
		let size = info.type.Size;
		if (ImGui.BeginPopupContextItem("DataMenu"))
		{
			let value = (uint8*)gameObject.GetData(info.type);
			if (ImGui.MenuItem("Reset"))
			{
				Internal.MemSet(value, 0, size);
				MarkDirty();
			}
			if (ImGui.MenuItem("Copy Component"))
			{
				ClearDataClipboard();
				mDataClipboardType = info.type;
				mDataClipboard.AddRange(Span<uint8>(value, size));
			}
			if (ImGui.MenuItem("Paste Component Values", null, false, mDataClipboardType == info.type))
			{
				Internal.MemCpy(value, mDataClipboard.Ptr, size);
				MarkDirty();
			}
			ImGui.Separator();
			if (ImGui.MenuItem("Remove Component"))
				remove = true;
			ImGui.EndPopup();
		}
		ImGui.SameLine(30);
		ImGui.TextColored(Icons.ComponentColor, Icons.Transform);
		ImGui.SameLine(ImGui.GetWindowWidth() - 30);
		if (ImGui.SmallButton(Icons.Menu))
			ImGui.OpenPopup("DataMenu");
		if (!open || remove)
			return remove;
		fields.Clear();
		DataComponents.GetFields(info.type, gameObject.GetData(info.type), fields, gameObject);
		bool changed = false;
		changed |= DrawFieldList(fields, "datafields");
		if (changed)
			MarkDirty();
		return false;
	}

	/// The object's icon, active toggle and name.
	void DrawObjectHeader(GameObject gameObject)
	{
		ImGui.AlignTextToFramePadding();
		ImGui.TextColored(gameObject.IsFolder ? Icons.FolderColor : Icons.ObjectColor, ObjectIcon(gameObject));
		ImGui.SameLine();
		bool active = gameObject.ActiveSelf;
		if (ImGui.Checkbox("##active", ref active))
		{
			gameObject.SetActive(active);
			MarkDirty();
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-(ImGui.GetFrameHeight() + 6));
		if (ImGui.InputText("##name", gameObject.Name))
		{
			if (mInspectorLock == gameObject.Id)
				mInspectorLockName.Set(gameObject.Name);
			MarkDirty();
		}
		ImGui.SameLine();
		DrawInspectorLock(gameObject);
		DrawStreamingObject(gameObject);
		ImGui.Spacing();
	}

	void DrawFolderInspector(GameObject gameObject)
	{
		ImGui.Separator();
		ImGui.Spacing();
		ImGui.TextWrapped("Folder. It only groups objects in the Hierarchy: it has no transform or components and does not affect its children.");
		ImGui.Spacing();
		if (ImGui.Button("Convert to GameObject"))
		{
			gameObject.IsFolder = false;
			MarkDirty();
		}
	}

	void DrawTransformSection(Transform transform)
	{
		ImGui.Separator();
		if (!ImGui.CollapsingHeader(scope String()..AppendF("{}  Transform", StringView(Icons.Transform)).CStr(), ImGui.TreeFlags.DefaultOpen) || !BeginPropertyTable("transform"))
			return;
		var position = transform.LocalPosition;
		var euler = transform.LocalEulerAngles;
		var scale = transform.LocalScale;
		BeginProperty("Position");
		if (DrawVector3("pos", ref position, 0.05f))
		{
			transform.LocalPosition = position;
			MarkDirty();
		}
		BeginProperty("Rotation");
		if (DrawVector3("rot", ref euler, 0.5f))
		{
			transform.LocalEulerAngles = euler;
			MarkDirty();
		}
		BeginProperty("Scale");
		if (DrawVector3("scl", ref scale, 0.02f))
		{
			transform.LocalScale = scale;
			MarkDirty();
		}
		ImGui.EndTable();
	}

	/// What a component's menu asked to be done with it.
	enum ComponentRequest
	{
		None,
		Remove,
		MoveUp,
		MoveDown
	}

	/// A component's header (enable toggle, icon, menu) and, unfolded, its fields and tools.
	ComponentRequest DrawComponentSection(GameObject gameObject, int index, List<FieldRef> fields)
	{
		let component = gameObject.Components[index];
		let info = ComponentRegistry.Find(component.GetType());
		let title = scope String();
		NiceName(info != null ? (StringView)info.name : "Component", title);
		ImGui.Separator();
		// The label leaves room for the enable checkbox and icon drawn over the header.
		let open = ImGui.CollapsingHeader(scope String()..AppendF("            {}###header", title).CStr(), ImGui.TreeFlags.DefaultOpen | ImGui.TreeFlags.AllowOverlap);
		let request = DrawComponentMenu(gameObject, index);
		ImGui.SameLine(30);
		ImGui.PushStyleVar(ImGui.StyleVar.FramePadding, ImGui.Vec2(1, 1));
		bool enabled = component.Enabled;
		if (ImGui.Checkbox("##enabled", ref enabled))
		{
			component.Enabled = enabled;
			MarkDirty();
		}
		ImGui.PopStyleVar();
		ImGui.SameLine(54);
		ImGui.TextColored(Icons.ComponentColor, ComponentIcon(info != null ? (StringView)info.name : ""));
		ImGui.SameLine(ImGui.GetWindowWidth() - 30);
		if (ImGui.SmallButton(Icons.Menu))
			ImGui.OpenPopup("ComponentMenu");
		if (!open)
			return request;

		fields.Clear();
		ComponentRegistry.GetFields(component, fields);
		bool changed = false;
		changed |= DrawFieldList(fields, "fields");
		if (changed)
		{
			component.OnValidate();
			MarkDirty();
		}
		DrawComponentTools(component);
		return request;
	}

	/// The menu on a component's header (right-click, or its ≡ button).
	ComponentRequest DrawComponentMenu(GameObject gameObject, int index)
	{
		if (!ImGui.BeginPopupContextItem("ComponentMenu"))
			return .None;
		let component = gameObject.Components[index];
		var request = ComponentRequest.None;
		if (ImGui.MenuItem("Reset"))
		{
			ResetComponent(component);
			MarkDirty();
		}
		if (ImGui.MenuItem("Copy Component"))
			mComponentClipboard.Copy(component);
		if (ImGui.MenuItem("Paste Component Values", null, false, mComponentClipboard.CanPaste(component)))
		{
			mComponentClipboard.PasteValues(component);
			MarkDirty();
		}
		if (ImGui.MenuItem("Paste Component As New", null, false, mComponentClipboard.HasData))
		{
			mComponentClipboard.PasteNew(gameObject);
			MarkDirty();
		}
		if (ImGui.MenuItem("Move Up", null, false, index > 0))
			request = .MoveUp;
		if (ImGui.MenuItem("Move Down", null, false, index < gameObject.Components.Count - 1))
			request = .MoveDown;
		ImGui.Separator();
		if (ImGui.MenuItem("Remove Component"))
			request = .Remove;
		ImGui.EndPopup();
		return request;
	}

	/// The extra buttons and lists some components have under their fields.
	void DrawComponentTools(Component component)
	{
		if (let surface = component as NavigationSurface)
			DrawNavigationTools(surface);
		if (let limb = component as LimbIK)
			DrawLimbIKTools(limb);
		if (let link = component as NavigationLink)
			DrawNavigationLinkTools(link);
		if (let obstacle = component as NavigationObstacle)
			DrawNavigationObstacleTools(obstacle);
		if (let area = component as NavigationArea)
			DrawNavigationAreaTools(area);
		if (let hand = component as HandPose)
			DrawHandPoseTools(hand);
		if (let feet = component as FootPlacement)
			DrawFootPlacementTools(feet);
		if (let soft = component as SoftBody)
			DrawSoftBodyTools(soft);
		if (let terrain = component as VoxelTerrain)
			DrawTerrainTools(terrain);
	}

	/// A rigged model's parts, and the clips found in its file: click one to play it.
	void DrawSkinnedClips(SkinnedMeshRenderer skinned)
	{
		if (skinned.Model == null)
			return;
		ImGui.TextDisabled(scope String()..AppendF("{} bones, {} clips, {} vertices bent on the {}", skinned.Model.Joints.Count, skinned.Model.Clips.Count, skinned.Model.Positions.Count, skinned.SkinnedOnGpu ? "GPU" : "CPU").CStr());
		DrawBoneMapLine(skinned);
		DrawSkinnedParts(skinned);
		for (let animation in skinned.Model.Clips)
		{
			// Clips from a Clip Library are marked, since they are fitted to this model rather than made for it.
			let label = skinned.Model.IsImported(animation) ? scope String()..AppendF("{}  (library)", animation.name) : scope String(animation.name);
			if (ImGui.Selectable(label.CStr(), skinned.CurrentClip == animation.name))
			{
				skinned.clip.Set(animation.name);
				skinned.Play(animation.name);
				MarkDirty();
			}
		}
	}

	/// The Add Component button and its menu: components by category, or those matching what is typed.
	void DrawAddComponent(GameObject gameObject)
	{
		ImGui.Separator();
		ImGui.Spacing();
		ImGui.Spacing();
		let width = Math.Min(ImGui.GetContentRegionAvail().x, 230);
		ImGui.SetCursorPosX((ImGui.GetWindowWidth() - width) * 0.5f);
		if (ImGui.Button("Add Component", .(width, 26)))
		{
			mScriptCatalog.Refresh(Assets.ProjectPath, Project.Current.Name);
			mComponentSearch.Clear();
			mFocusComponentSearch = true;
			ImGui.OpenPopup("AddComponent");
		}
		if (!ImGui.BeginPopup("AddComponent"))
			return;
		ImGui.SetNextItemWidth(260);
		if (mFocusComponentSearch)
		{
			ImGui.SetKeyboardFocusHere();
			mFocusComponentSearch = false;
		}
		ImGui.InputText("##filter", mComponentSearch, 0, "Search");
		ImGui.BeginChild("list", .(260, 320));
		let searching = !mComponentSearch.IsEmpty;
		for (let category in StringView[?]("Rendering", "Physics", "Animation", "Audio", "UI", "Particles", "World", "Networking", "AI", "Scripts"))
		{
			if (!searching && !ImGui.BeginMenu(scope String(category).CStr()))
				continue;
			AddComponentChoices(gameObject, category, searching);
			if (!searching)
				ImGui.EndMenu();
		}
		// Data components: [Component] structs, for systems (docs/ecs-plan.md).
		if (!DataComponents.Types.IsEmpty && (searching || ImGui.BeginMenu("Data")))
		{
			for (let info in DataComponents.Types)
			{
				let label = scope String();
				NiceName(info.name, label);
				if (searching && !info.name.Contains(mComponentSearch, true) && !label.Contains(mComponentSearch, true) && !StringView("Data").Contains(mComponentSearch, true))
					continue;
				let has = gameObject.GetData(info.type) != null;
				if (ImGui.Selectable(scope $"{StringView(Icons.Transform)}  {label}##data{info.fullName}" , false, has ? ImGui.SelectableFlags.Disabled : 0))
				{
					gameObject.AddData(info.type);
					MarkDirty();
					ImGui.CloseCurrentPopup();
				}
			}
			if (!searching)
				ImGui.EndMenu();
		}
		if (mComponentClipboard.HasData)
		{
			ImGui.Separator();
			if (ImGui.Selectable("Paste Copied Component"))
			{
				mComponentClipboard.PasteNew(gameObject);
				MarkDirty();
				ImGui.CloseCurrentPopup();
			}
		}
		ImGui.EndChild();
		ImGui.EndPopup();
	}

	/// The components of one category that can be added (those matching the search, when searching).
	void AddComponentChoices(GameObject gameObject, StringView category, bool searching)
	{
		// Built-in components that are handles (Light...): one of each per object.
		for (let info in HandleComponents.Types)
		{
			if (ComponentCategory(info.fullName, info.name) != category)
				continue;
			let label = scope String();
			NiceName(info.name, label);
			if (searching && !info.name.Contains(mComponentSearch, true) && !label.Contains(mComponentSearch, true) && !category.Contains(mComponentSearch, true))
				continue;
			let has = gameObject.GetData(info.dataType) != null;
			if (ImGui.Selectable(scope $"{StringView(ComponentIcon(info.name))}  {label}##{info.fullName}" , false, has ? ImGui.SelectableFlags.Disabled : 0))
			{
				HandleComponents.Add(gameObject, info);
				MarkDirty();
				ImGui.CloseCurrentPopup();
			}
		}
		for (let info in ComponentRegistry.Types)
		{
			if (!mScriptCatalog.IsVisible(info) || ComponentCategory(info.fullName, info.name) != category)
				continue;
			let label = scope String();
			NiceName(info.name, label);
			if (searching && !info.name.Contains(mComponentSearch, true) && !label.Contains(mComponentSearch, true) && !category.Contains(mComponentSearch, true))
				continue;
			if (ImGui.Selectable(scope $"{StringView(ComponentIcon(info.name))}  {label}##{info.fullName}"))
			{
				gameObject.AddComponent(info.type);
				MarkDirty();
				ImGui.CloseCurrentPopup();
			}
		}
	}

	/// Puts every field of a component back to the value a new one would have.
	void ResetComponent(Component component)
	{
		let fresh = ComponentRegistry.Create(component.GetType());
		if (fresh == null)
			return;
		defer delete fresh;
		List<FieldRef> from = scope .();
		List<FieldRef> to = scope .();
		ComponentRegistry.GetFields(fresh, from);
		ComponentRegistry.GetFields(component, to);
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (int i < Math.Min(from.Count, to.Count))
		{
			let text = scope String();
			SceneSerializer.WriteValue(from[i], text);
			tokens.Clear();
			SceneSerializer.Tokenize(text, tokens, storage);
			SceneSerializer.ReadValue(to[i], Span<StringView>(tokens.Ptr, tokens.Count));
		}
		component.OnValidate();
	}

	/// X / Y / Z fields with coloured axis letters, as in Unity's Inspector.
	bool DrawVector3(char8* id, ref Vector3 value, float speed)
	{
		bool changed = false;
		ImGui.PushID(id);
		let spacing = 4.0f;
		let letter = ImGui.CalcTextSize("X").x + 4;
		let width = Math.Max((ImGui.GetContentRegionAvail().x - letter * 3 - spacing * 2) / 3, 24);
		ImGui.AlignTextToFramePadding();
		ImGui.TextColored(EditorTheme.Error, "X");
		ImGui.SameLine(0, 4);
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##x", ref value.x, speed);
		ImGui.SameLine(0, spacing);
		ImGui.TextColored(EditorTheme.Good, "Y");
		ImGui.SameLine(0, 4);
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##y", ref value.y, speed);
		ImGui.SameLine(0, spacing);
		ImGui.TextColored(EditorTheme.Info, "Z");
		ImGui.SameLine(0, 4);
		ImGui.SetNextItemWidth(width);
		changed |= ImGui.DragFloat("##z", ref value.z, speed);
		ImGui.PopID();
		return changed;
	}

	static StringView ComponentCategory(StringView fullName, StringView name)
	{
		if (!fullName.StartsWith("Tallow.")) return "Scripts";
		if (name == "Camera" || name == "Light" || name == "MeshRenderer" || name == "Decal" || name == "LODGroup" || name == "ReflectionProbe" || name == "LightProbeVolume") return "Rendering";
		if (name == "Rigidbody" || name == "SoftBody" || name == "Rope" || name.EndsWith("Collider") || name == "CharacterController") return "Physics";
		if (name == "SkinnedMeshRenderer" || name == "Animator" || name == "SequencePlayer") return "Animation";
		if (name == "UIDocument") return "UI";
		if (name.StartsWith("Audio") || name == "DialogueRunner") return "Audio";
		if (name.StartsWith("Navigation") || name.StartsWith("BehaviorTree")) return "AI";
		if (name == "ParticleSystem") return "Particles";
		if (name.StartsWith("Voxel") || name == "SpawnPoint") return "World";
		if (name.StartsWith("Network") || name == "CharacterMotor") return "Networking";
		return "Scripts";
	}

	static char8* ComponentIcon(StringView typeName)
	{
		if (typeName == "Camera") return Icons.Camera;
		if (typeName == "Light") return Icons.Light;
		if (typeName == "MeshRenderer") return Icons.Cube;
		if (typeName == "SkinnedMeshRenderer" || typeName == "Animator") return Icons.Character;
		if (typeName == "UIDocument") return Icons.Script;
		if (typeName == "Rigidbody" || typeName == "SoftBody" || typeName == "Rope") return Icons.Body;
		if (typeName.EndsWith("Collider")) return Icons.Collider;
		if (typeName == "VoxelTerrain") return Icons.Terrain;
		if (typeName == "VoxelObject") return Icons.Voxel;
		if (typeName == "ParticleSystem") return Icons.Particles;
		if (typeName.StartsWith("Network")) return Icons.Network;
		if (typeName == "CharacterMotor" || typeName == "CharacterController") return Icons.Character;
		return Icons.Script;
	}

	static char8* ObjectIcon(GameObject gameObject)
	{
		if (gameObject.IsFolder) return Icons.Folder;
		if (gameObject.HasComponent<Camera>()) return Icons.Camera;
		for (let component in gameObject.Components)
		{
			if (component is VoxelTerrain) return Icons.Terrain;
		}
		if (gameObject.HasComponent<ParticleSystem>()) return Icons.Particles;
		for (let component in gameObject.Components)
		{
			if (component is NetworkSession) return Icons.Network;
		}
		if (gameObject.HasComponent<Light>()) return Icons.Light;
		return Icons.Cube;
	}

	bool DrawField(FieldRef field)
	{
		let label = scope String();
		NiceName(field.name, label);
		if (field.kind == .List || field.kind == .Array)
			return DrawCollection(field, label);
		BeginProperty(label.CStr());
		ImGui.PushID(field.ptr);
		defer ImGui.PopID();
		return DrawValue(field);
	}

	/// Lists and arrays opened or closed by hand in the Inspector, by their field's address: short ones start open,
	/// long ones closed.
	HashSet<int> mToggledCollections = new .() ~ delete _;

	/// A List or array field: its size on its own row, then a row for each element when opened, each with buttons to
	/// move it up and remove it.
	bool DrawCollection(FieldRef field, StringView label)
	{
		let key = (int)field.ptr;
		let count = FieldLists.Count(field);
		var open = (count <= 16) != mToggledCollections.Contains(key);
		let resizable = FieldLists.CanResize(field);
		bool changed = false;
		ImGui.TableNextRow();
		ImGui.TableNextColumn();
		ImGui.PushID(field.ptr);
		defer ImGui.PopID();
		if (ImGui.TreeNode(scope $"{label}###list" , open ? 1 << 5 : 0) != open)
		{
			open = !open;
			if (!mToggledCollections.Remove(key))
				mToggledCollections.Add(key);
		}
		if (open)
			ImGui.TreePop();
		ImGui.TableNextColumn();
		if (resizable)
		{
			var size = (int32)count;
			ImGui.SetNextItemWidth(-1);
			if (ImGui.InputInt("##size", ref size))
			{
				// Growing copies the last element into the new ones, as Unity's Inspector does.
				size = Math.Clamp(size, 0, (int32)count + 1000);
				if (size > count)
				{
					for (int i = count; i < size; i++)
						changed |= FieldLists.Duplicate(field, i - 1);
				}
				else
					changed |= FieldLists.Resize(field, size);
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("How many elements: + adds a copy of the last, - removes the last");
		}
		else
			ImGui.TextDisabled(scope $"{count} (fixed size)");
		if (!open || changed)
			return changed;

		for (int i < FieldLists.Count(field))
		{
			ImGui.TableNextRow();
			ImGui.TableNextColumn();
			ImGui.PushID((int32)i);
			ImGui.AlignTextToFramePadding();
			ImGui.TextDisabled(scope $"    {i}");
			ImGui.TableNextColumn();
			var action = 0;
			if (resizable)
			{
				if (ImGui.SmallButton("^") && i > 0)
					action = 1;
				ImGui.SameLine(0, 2);
				if (ImGui.SmallButton("x"))
					action = 2;
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Remove");
				ImGui.SameLine(0, 4);
			}
			ImGui.SetNextItemWidth(-1);
			changed |= DrawValue(FieldLists.Element(field, i));
			ImGui.PopID();
			if (action == 1)
			{
				FieldLists.Move(field, i, i - 1);
				changed = true;
				break;
			}
			if (action == 2)
			{
				changed |= FieldLists.RemoveAt(field, i);
				break;
			}
		}
		return changed;
	}

	/// The editor for one value of a field (the field itself, or one element of a list).
	bool DrawValue(FieldRef field)
	{
		switch (field.kind)
		{
		case .Float:
			if (field.hasRange)
				return ImGui.SliderFloat("##v", ref *(float*)field.ptr, field.rangeMin, field.rangeMax);
			return ImGui.DragFloat("##v", ref *(float*)field.ptr, 0.02f);
		case .Int:
			if (field.isLayer && field.type == typeof(int32))
				return DrawLayerChoice((int32*)field.ptr);
			return DrawInteger(field);
		case .Bool:
			return ImGui.Checkbox("##v", ref *(bool*)field.ptr);
		case .Double: return DrawDouble(field);
		case .Char:
			let text = scope String();
			let value = FieldNumbers.ReadUnsigned(field);
			if (value != 0)
				text.Append((char32)value);
			if (ImGui.InputText("##v", text)) return FieldNumbers.WriteUnsigned(field, text.IsEmpty ? 0 : (uint64)text.GetChar32(0).c);
			return false;
		case .Vector2: return DragVector("##v", &((Vector2*)field.ptr).x, 2, 0.02f);
		case .Vector4: return DragVector("##v", &((Vector4*)field.ptr).x, 4, 0.02f);
		case .Int3: return DragIntegerVector("##v", &((Int3*)field.ptr).x, 3);
		case .Matrix4:
			bool changed = false;
			let matrix = (Matrix4*)field.ptr;
			for (int i < 4)
			{
				ImGui.PushID((int32)i);
				changed |= DragVector("##row", &matrix.m[i * 4], 4, 0.02f);
				ImGui.PopID();
			}
			return changed;
		case .Vector3:
			return DrawVector3("v", ref *(Vector3*)field.ptr, 0.05f);
		case .Quaternion:
			var euler = ((Quaternion*)field.ptr).EulerAngles;
			if (ImGui.DragFloat3("##v", ref euler, 0.5f))
			{
				*(Quaternion*)field.ptr = Quaternion.Euler(euler);
				return true;
			}
			return false;
		case .Color:
			return ImGui.ColorEdit4("##v", ref *(Color*)field.ptr, ImGui.ColorFlags.Float);
		case .String:
			if (field.type == typeof(SharedString))
			{
				let edited = scope String(((SharedString*)field.ptr).View);
				if (!DrawStringField(edited, field.name))
					return false;
				*(SharedString*)field.ptr = edited;
				return true;
			}
			// A field given a text literal gets its own copy before it can be typed into.
			let original = StringFields.Writable(field.ptr, field.name);
			let temporary = scope String();
			let text = original != null ? original : temporary;
			let changed = DrawStringField(text, field.name);
			if (changed && original == null)
				*(String*)field.ptr = new String(text);
			return changed;
		case .ObjectReference:
			return DrawObjectPicker(field);

		case .Enum:
			bool hasNames = false;
			for (let entry in Enum.GetEnumerator(field.type))
			{
				hasNames = true;
				break;
			}
			if (!hasNames) return DrawInteger(field);
			let current = scope String();
			Enum.EnumToString(field.type, current, FieldNumbers.EnumValue(field));
			bool changed = false;
			if (ImGui.BeginCombo("##v", current.CStr()))
			{
				for (let (name, value) in Enum.GetEnumerator(field.type))
				{
					if (ImGui.Selectable(scope String(name).CStr(), value == FieldNumbers.EnumValue(field)))
					{
						changed = FieldNumbers.Signed(field) ? FieldNumbers.WriteSigned(field, value) : FieldNumbers.WriteUnsigned(field, (uint64)value);
					}
				}
				ImGui.EndCombo();
			}
			return changed;
		case .List,.Array:
			// Not nested: a list's elements are single values.
			return false;
		}
	}

	bool AcceptAssetKind(StringView path, StringView kind)
	{
		if (kind == "mesh" || kind == "model") return IsModelFile(path);
		if (kind == "texture") return IsImageFile(path);
		if (kind == "bakedData") return HasExtension(path, ".tnav");
		if (kind == "audioClip") return IsAudioFile(path);
		if (kind == "tree") return HasExtension(path, ".tbt");
		if (kind == "controller") return HasExtension(path, ".tcontroller");
		if (kind == "material" || kind == "interiorMaterial") return HasExtension(path, ".tmat");
		if (kind == "shader") return HasExtension(path, ".tcompute");
		if (kind == "document") return HasExtension(path, ".tui");
		if (kind == "dialogue") return HasExtension(path, ".tdialogue");
		if (kind == "sequence") return HasExtension(path, ".tsequence");
		if (kind == "scene") return HasExtension(path, ".tscene");
		return HasExtension(path, ".tprefab");
	}

	bool DrawAssetChoices(StringView folder, StringView kind, String path)
	{
		bool changed = false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (IsHidden(name) || !AcceptAssetKind(name, kind)) continue;
			let relative = scope String();
			ToRelative(scope $"{folder}/{name}" , relative);
			if (ImGui.Selectable(relative.CStr(), path == relative))
			{
				path.Set(relative);
				changed = true;
				ImGui.CloseCurrentPopup();
			}
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!IsHidden(name))
				changed |= DrawAssetChoices(scope $"{folder}/{name}" , kind, path);
		}
		return changed;
	}

	bool DrawAssetPicker(String path, StringView kind)
	{
		ImGui.SetNextItemWidth(-28);
		bool changed = ImGui.InputText("##v", path);
		// The text field is the drop target; begin it before drawing another item.
		let drag = ImGui.GetDragDropPayload();
		if (drag != null && ImGui.PayloadIsType(drag, "ASSET") && AcceptAssetKind(StringView((char8*)drag.data, drag.dataSize), kind)
			&& ImGui.BeginDragDropTarget())
		{
			let payload = ImGui.AcceptDragDropPayload("ASSET");
			if (payload != null && AcceptAssetKind(StringView((char8*)payload.data, payload.dataSize), kind))
			{
				path.Set(StringView((char8*)payload.data, payload.dataSize));
				changed = true;
			}
			ImGui.EndDragDropTarget();
		}
		ImGui.SameLine();
		if (ImGui.Button("..."))
			ImGui.OpenPopup("AssetPicker");
		if (ImGui.BeginPopup("AssetPicker"))
		{
			if (ImGui.Selectable("None", path.IsEmpty))
			{
				path.Clear();
				changed = true;
			}
			if (kind == "mesh")
			{
				for (let name in Assets.BuiltinMeshes)
				{
					if (ImGui.Selectable(scope String(name).CStr(), path == name))
					{
						path.Set(name);
						changed = true;
					}
				}
			}
			ImGui.Separator();
			changed |= DrawAssetChoices(Assets.ProjectPath, kind, path);
			ImGui.EndPopup();
		}
		return changed;
	}

	/// A text field's editor: an asset picker for fields named like asset paths, otherwise a text box.
	bool DrawStringField(String text, StringView name)
	{
		if (name == "mesh" || name == "model" || name == "texture" || name == "document" || name == "prefab" || name == "tree" || name == "controller" || name == "material" || name == "interiorMaterial" || name == "scene" || name == "shader" || name == "bakedData" || name == "audioClip" || name == "dialogue" || name == "sequence" || name.EndsWith("Prefab"))
			return DrawAssetPicker(text, name);
		return ImGui.InputText("##v", text);
	}

	bool DrawObjectPicker(FieldRef field)
	{
		bool changed = false;
		let target = ComponentRegistry.ReferenceOwner(field);
		ImGui.SetNextItemWidth(-28);
		let text = scope String(target != null ? (StringView)target.Name : "None");
		ImGui.InputText("##v", text, ImGui.InputFlags.ReadOnly);
		NoteTestRect(scope $"field:{field.name}");
		if (ImGui.BeginDragDropTarget())
		{
			let payload = ImGui.AcceptDragDropPayload("GAMEOBJECT");
			if (payload != null && payload.dataSize == sizeof(uint32))
			{
				let go = mScene.FindById(*(uint32*)payload.data);
				if (go != null)
					changed = ComponentRegistry.AssignReference(field, go);
			}
			ImGui.EndDragDropTarget();
		}
		ImGui.SameLine();
		if (ImGui.Button("..."))
			ImGui.OpenPopup("ObjectPicker");
		if (ImGui.BeginPopup("ObjectPicker"))
		{
			if (ImGui.Selectable("None", target == null))
				changed = ComponentRegistry.AssignReference(field, null);
			// An ObjectRef in a built-in component's data names what it refers to by its T.
			let refType = ObjectRefs.TargetOf(field.type) ?? field.type;
			let current = ObjectRefs.Is(field.type) ? ObjectRefs.Target(field) : *(Object*)field.ptr;
			for (let go in mScene.Objects)
			{
				ImGui.PushID((int32)go.Id);
				let handle = HandleComponents.Find(refType);
				if (handle != null)
				{
					// A built-in component handle: objects that have one.
					if (go.GetData(handle.dataType) != null && ImGui.Selectable(scope $"{go.Name} ({handle.name})" .CStr(), target == go))
						changed = ComponentRegistry.AssignReference(field, go);
				}
				else if (refType == typeof(GameObject) || refType == typeof(Transform))
				{
					if (ImGui.Selectable(go.Name.CStr(), target == go))
						changed = ComponentRegistry.AssignReference(field, go);
				}
				else for (int i < go.Components.Count)
					{
						let component = go.Components[i];
						if (component.GetType() != refType && !component.GetType().IsSubtypeOf(refType)) continue;
						ImGui.PushID((int32)i);
						if (ImGui.Selectable(scope $"{go.Name} ({component.GetType()})" .CStr(), current == component))
							changed = ComponentRegistry.AssignReference(field, go, i);
						ImGui.PopID();
					}
				ImGui.PopID();
			}
			ImGui.EndPopup();
		}
		return changed;
	}
}
