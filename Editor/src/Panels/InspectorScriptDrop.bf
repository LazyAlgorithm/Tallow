using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

extension EditorApp
{
	List<ComponentRegistry.Info> mScriptDropChoices = new .() ~ delete _;
	bool mOpenScriptDropChoices;
	uint32 mScriptDropTarget;

	void DrawInspectorScriptDrop(GameObject target)
	{
		if (target.IsFolder) return;
		let payload = ImGui.GetDragDropPayload();
		if (payload != null && ImGui.PayloadIsType(payload, "ASSET"))
		{
			let asset = StringView((char8*)payload.data, payload.dataSize);
			if (HasExtension(asset, ".bf", ".tgraph"))
			{
				let start = ImGui.GetWindowPos();
				let size = ImGui.GetWindowSize();
				if (ImGui.BeginDragDropTargetCustom(start, .(start.x + size.x, start.y + size.y), ImGui.GetID("InspectorScriptDrop")))
				{
					let accepted = ImGui.AcceptDragDropPayload("ASSET");
					if (accepted != null)
					{
						let full = scope String();
						Assets.ResolvePath(StringView((char8*)accepted.data, accepted.dataSize), full);
						ScriptAssetResolver.Find(full, Project.Current.Name, mScriptDropChoices);
						if (mScriptDropChoices.Count == 1)
						{
							target.AddComponent(mScriptDropChoices[0].type);
							MarkDirty();
						}
						else if (mScriptDropChoices.Count > 1)
						{
							mScriptDropTarget = target.Id;
							mOpenScriptDropChoices = true;
						}
						else
						{
							mStatus.Set("No compiled component found. Save the graph if needed, then wait for automatic script reload.");
							Log.Warning(mStatus);
						}
					}
					ImGui.EndDragDropTarget();
				}
			}
		}
		if (mOpenScriptDropChoices)
		{
			ImGui.OpenPopup("ChooseScriptComponent");
			mOpenScriptDropChoices = false;
		}
		if (ImGui.BeginPopup("ChooseScriptComponent"))
		{
			ImGui.Text("Add component from script:");
			for (let info in mScriptDropChoices)
			{
				if (ImGui.Selectable(info.fullName.CStr()))
				{
					let owner = mScene.FindById(mScriptDropTarget);
					if (owner != null)
					{
						owner.AddComponent(info.type);
						MarkDirty();
					}
					ImGui.CloseCurrentPopup();
				}
			}
			ImGui.EndPopup();
		}
	}
}
