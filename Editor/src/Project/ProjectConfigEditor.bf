using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Project Settings for ProjectConfig (physics layers and which collide, tags, world states), and the matching row at
/// the top of the Inspector for a selected object.
extension EditorApp
{
	String mNewTag = new .() ~ delete _;
	String mNewWorldState = new .() ~ delete _;

	void SaveProjectConfig()
	{
		let path = scope $"{Assets.ProjectPath}/{ProjectConfig.FileName}";
		if (!ProjectConfig.Save(path))
			Log.Error(scope $"Could not write {path}");
	}

	void DrawProjectConfigSettings()
	{
		bool changed = DrawLayerSettings();
		changed |= DrawTagSettings();
		changed |= DrawWorldStateSettings();
		if (changed)
			SaveProjectConfig();
	}

	/// The physics layers: their names, Add Layer, and which collide. True when something changed.
	bool DrawLayerSettings()
	{
		bool changed = false;
		ImGui.SeparatorText("Physics Layers");
		ImGui.TextWrapped("Name up to 32 layers. Each object is on one (set at the top of the Inspector); the table says which layers collide, and ray and shape queries can be limited to some layers. Changes apply from the next Play.");
		List<int32> named = scope .();
		for (int32 i < ProjectConfig.MaxLayers)
		{
			if (!ProjectConfig.LayerName(i).IsEmpty)
				named.Add(i);
		}
		int32 removeLayer = -1;
		for (let layer in named)
		{
			ImGui.PushID(layer);
			ImGui.AlignTextToFramePadding();
			ImGui.TextDisabled(scope $"{layer,2}");
			ImGui.SameLine();
			let name = scope String(ProjectConfig.LayerName(layer));
			ImGui.SetNextItemWidth(220);
			if (layer == 0)
				ImGui.Text(name);
			else if (ImGui.InputText("##layer", name) && !name.IsEmpty)
			{
				ProjectConfig.SetLayerName(layer, name);
				changed = true;
			}
			if (layer != 0)
			{
				ImGui.SameLine();
				if (ImGui.SmallButton("Remove"))
					removeLayer = layer;
			}
			ImGui.PopID();
		}
		if (removeLayer > 0)
		{
			ProjectConfig.SetLayerName(removeLayer, "");
			for (int32 other < ProjectConfig.MaxLayers)
				ProjectConfig.SetLayersCollide(removeLayer, other, true);
			changed = true;
		}
		if (named.Count < ProjectConfig.MaxLayers && ImGui.Button("Add Layer"))
		{
			for (int32 i = 1; i < ProjectConfig.MaxLayers; i++)
			{
				if (ProjectConfig.LayerName(i).IsEmpty)
				{
					ProjectConfig.SetLayerName(i, scope $"Layer {i}");
					changed = true;
					break;
				}
			}
		}
		if (named.Count > 1)
			changed |= DrawCollisionMatrix(named);
		return changed;
	}

	/// Which layers collide, as a table of ticks: each pair once, the lower triangle mirroring the upper.
	static bool DrawCollisionMatrix(List<int32> named)
	{
		bool changed = false;
		ImGui.Spacing();
		ImGui.TextDisabled("Which layers collide (ticked: they do)");
		if (ImGui.BeginTable("collisions", (int32)named.Count + 1, ImGui.TableFlags.BordersInnerH | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.BordersOuter | ImGui.TableFlags.SizingFixedFit))
		{
			ImGui.TableSetupColumn("");
			for (let layer in named)
				ImGui.TableSetupColumn(scope String(ProjectConfig.LayerName(layer)).CStr());
			ImGui.TableHeadersRow();
			for (let a in named)
			{
				ImGui.TableNextRow();
				ImGui.TableNextColumn();
				ImGui.Text(ProjectConfig.LayerName(a));
				for (let b in named)
				{
					ImGui.TableNextColumn();
					// Each pair once: the lower triangle mirrors the upper.
					if (b < a)
						continue;
					ImGui.PushID(a * 64 + b);
					var collide = ProjectConfig.LayersCollide(a, b);
					if (ImGui.Checkbox("##c", ref collide))
					{
						ProjectConfig.SetLayersCollide(a, b, collide);
						changed = true;
					}
					ImGui.PopID();
				}
			}
			ImGui.EndTable();
		}
		return changed;
	}

	/// The project's tags: each with a button that removes it, and a box to add one. True when something changed.
	bool DrawTagSettings()
	{
		bool changed = false;
		ImGui.SeparatorText("Tags");
		ImGui.TextWrapped("Labels for objects, set in the Inspector. Scripts find tagged objects quickly with Scene.FindWithTag and FindAllWithTag; behaviour trees can look for them too.");
		String removeTag = null;
		for (let tag in ProjectConfig.Tags)
		{
			ImGui.PushID(tag.CStr());
			if (ImGui.SmallButton(scope $"{tag}  x"))
				removeTag = tag;
			ImGui.SameLine();
			ImGui.PopID();
		}
		ImGui.NewLine();
		if (removeTag != null)
		{
			ProjectConfig.RemoveTag(scope String(removeTag));
			changed = true;
		}
		ImGui.SetNextItemWidth(220);
		let enter = ImGui.InputText("##newtag", mNewTag, ImGui.InputFlags.EnterReturnsTrue, "New tag");
		ImGui.SameLine();
		if ((ImGui.Button("Add Tag") || enter) && !mNewTag.IsEmpty)
		{
			ProjectConfig.AddTag(mNewTag);
			mNewTag.Clear();
			changed = true;
		}
		return changed;
	}

	/// The world states: each one's name, a box to add one, and Remove Last. True when something changed.
	bool DrawWorldStateSettings()
	{
		bool changed = false;
		ImGui.SeparatorText("World States");
		ImGui.TextWrapped("Versions of the same place that the game switches between (a past and a present, a real and a dream world). Each object is in all of them unless set otherwise in the Inspector; Scene.WorldState switches which one is shown, collides, is heard and is walked on, all at once.");
		for (int32 i < (int32)ProjectConfig.WorldStates.Count)
		{
			ImGui.PushID(i);
			ImGui.AlignTextToFramePadding();
			ImGui.TextDisabled(scope $"{i,2}");
			ImGui.SameLine();
			let name = scope String(ProjectConfig.WorldStates[i]);
			ImGui.SetNextItemWidth(220);
			if (ImGui.InputText("##state", name) && !name.IsEmpty)
			{
				ProjectConfig.RenameWorldState(i, name);
				changed = true;
			}
			ImGui.PopID();
		}
		ImGui.SetNextItemWidth(220);
		let enterState = ImGui.InputText("##newstate", mNewWorldState, ImGui.InputFlags.EnterReturnsTrue, "New world state");
		ImGui.SameLine();
		if ((ImGui.Button("Add State") || enterState) && !mNewWorldState.IsEmpty)
		{
			ProjectConfig.AddWorldState(mNewWorldState);
			mNewWorldState.Clear();
			changed = true;
		}
		if (ProjectConfig.WorldStates.Count > 1)
		{
			ImGui.SameLine();
			if (ImGui.Button("Remove Last"))
			{
				ProjectConfig.RemoveLastWorldState();
				changed = true;
			}
		}
		return changed;
	}

	/// Layer, tags and world states of an object, under its name in the Inspector.
	void DrawObjectConfig(GameObject gameObject)
	{
		if (!BeginPropertyTable("objectconfig"))
			return;
		BeginProperty("Layer");
		let current = scope String(ProjectConfig.LayerName(gameObject.Layer));
		if (current.IsEmpty)
			current.AppendF("Layer {}", gameObject.Layer);
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##layer", current.CStr()))
		{
			for (int32 i < ProjectConfig.MaxLayers)
			{
				let name = ProjectConfig.LayerName(i);
				if (name.IsEmpty)
					continue;
				if (ImGui.Selectable(scope String(name).CStr(), gameObject.Layer == i))
				{
					gameObject.Layer = i;
					MarkDirty();
				}
			}
			ImGui.EndCombo();
		}

		BeginProperty("Tags");
		String remove = null;
		for (int i < gameObject.TagCount)
		{
			ImGui.PushID((int32)i);
			if (ImGui.SmallButton(scope $"{gameObject.GetTag(i)}  x"))
				remove = scope:: String(gameObject.GetTag(i));
			ImGui.SameLine();
			ImGui.PopID();
		}
		if (remove != null)
		{
			gameObject.RemoveTag(remove);
			MarkDirty();
		}
		if (ImGui.SmallButton("+"))
			ImGui.OpenPopup("addtag");
		if (ImGui.BeginPopup("addtag"))
		{
			if (ProjectConfig.Tags.Count == 0)
				ImGui.TextDisabled("No tags yet: add them in Project Settings.");
			for (let tag in ProjectConfig.Tags)
			{
				if (!gameObject.HasTag(tag) && ImGui.Selectable(tag.CStr()))
				{
					gameObject.AddTag(tag);
					MarkDirty();
				}
			}
			ImGui.EndPopup();
		}

		if (ProjectConfig.WorldStates.Count > 1)
		{
			BeginProperty("World States");
			for (int32 i < (int32)ProjectConfig.WorldStates.Count)
			{
				ImGui.PushID(i);
				var member = gameObject.InWorldState(i);
				if (ImGui.Checkbox(ProjectConfig.WorldStates[i].CStr(), ref member))
				{
					gameObject.SetInWorldState(i, member);
					MarkDirty();
				}
				ImGui.SameLine();
				ImGui.PopID();
			}
			ImGui.NewLine();
		}
		ImGui.EndTable();
	}
}
