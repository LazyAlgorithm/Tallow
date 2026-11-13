using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

extension EditorApp
{
	List<ComponentRegistry.Info> mScriptDropChoices = new .() ~ delete _;
	List<String> mCSharpDropChoices = new .() ~ DeleteContainerAndItems!(_);
	bool mOpenCSharpDropChoices;
	bool mOpenScriptDropChoices;
	uint32 mScriptDropTarget;

	/// One file can contain multiple [Component] classes, so use compiler source
	/// mapping rather than guessing from its filename.
	void AttachManagedScriptAsset(GameObject target, StringView absolutePath)
	{
		if (target == null || target.IsFolder || Project.Current == null)
			return;
		ClearAndDeleteItems!(mCSharpDropChoices);
		let catalog = scope $"{Project.Current.Path}/.tallow-csharp/component-sources.tsv";
		let contents = scope String();
		if (File.ReadAllText(catalog, contents) case .Err)
		{
			mStatus.Set("Compile the C# project before dropping scripts onto a scene object.");
			Log.Warning(mStatus);
			return;
		}
		for (let line in contents.Split('\n', .RemoveEmptyEntries))
		{
			let split = line.IndexOf('\t');
			if (split <= 0 || !Path.Equals(line.Substring(0, split), absolutePath, .Lenient))
				continue;
			mCSharpDropChoices.Add(new String(line.Substring(split + 1)));
		}
		if (mCSharpDropChoices.Count == 1)
		{
			let component = target.AddComponent<CSharpBehaviour>();
			if (component != null)
			{
				component.scriptType.Set(mCSharpDropChoices[0]);
				MarkDirty();
			}
		}
		else if (mCSharpDropChoices.Count > 1)
		{
			mScriptDropTarget = target.Id;
			mOpenCSharpDropChoices = true;
			mSelectedId = target.Id;
		}
		else
		{
			mStatus.Set("No compiled [Component] class found in this C# file. Save it and compile first.");
			Log.Warning(mStatus);
		}
	}

	void DrawInspectorScriptDrop(GameObject target)
	{
		if (target.IsFolder) return;
		let payload = ImGui.GetDragDropPayload();
		if (payload != null && ImGui.PayloadIsType(payload, "ASSET"))
		{
			let asset = StringView((char8*)payload.data, payload.dataSize);
			if (HasExtension(asset, ".bf", ".tgraph") || asset.EndsWith(".cs", .OrdinalIgnoreCase))
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
						if (full.EndsWith(".cs", .OrdinalIgnoreCase))
						{
							AttachManagedScriptAsset(target, full);
						}
						else
						{
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
					}
					ImGui.EndDragDropTarget();
				}
			}
		}
		if (mOpenCSharpDropChoices)
		{
			ImGui.OpenPopup("ChooseManagedScriptComponent");
			mOpenCSharpDropChoices = false;
		}
		if (ImGui.BeginPopup("ChooseManagedScriptComponent"))
		{
			ImGui.Text("Choose C# component from file:");
			for (let typeName in mCSharpDropChoices)
			{
				if (ImGui.Selectable(typeName.CStr()))
				{
					let owner = mScene.FindById(mScriptDropTarget);
					if (owner != null)
					{
						let component = owner.AddComponent<CSharpBehaviour>();
						if (component != null)
						{
							component.scriptType.Set(typeName);
							MarkDirty();
						}
					}
					ImGui.CloseCurrentPopup();
				}
			}
			ImGui.EndPopup();
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
