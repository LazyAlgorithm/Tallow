using System;
using System.Collections;

namespace Tallow;

/// A value snapshot: no ownership of the copied component or its objects.
class ComponentClipboard
{
	public String TypeName = new .() ~ delete _;
	String mValues = new .() ~ delete _;
	Scene mSourceScene;
	bool mEnabled;
	public bool HasData => !TypeName.IsEmpty;

	public void Copy(Component component)
	{
		TypeName.Clear();
		component.GetType().GetFullName(TypeName);
		mSourceScene = component.Scene;
		mEnabled = component.Enabled;
		mValues.Clear();
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(component, fields);
		for (let field in fields)
		{
			mValues.AppendF("{} ", SceneSerializer.Quote(field.name, .. scope .()));
			SceneSerializer.WriteValue(field, mValues);
			mValues.Append('\n');
		}
	}

	public bool CanPaste(Component target)
	{
		let name = scope String();
		target.GetType().GetFullName(name);
		return HasData && name == TypeName;
	}

	public bool PasteValues(Component target)
	{
		if (!CanPaste(target)) return false;
		let previous = Scene.Active;
		Scene.Active = target.Scene;
		defer
		{
			Scene.Active = previous;
		}
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(target, fields);
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		for (let line in mValues.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2) continue;
			for (let field in fields)
			{
				if (field.name != tokens[0]) continue;
				if (field.kind == .ObjectReference && mSourceScene != target.Scene)
					ComponentRegistry.AssignReference(field, null);
				else if (field.HoldsReferences && mSourceScene != target.Scene)
				{
					// References into another scene mean nothing here: the list keeps what it had.
				}
				else
					SceneSerializer.ReadValue(field, .(tokens.Ptr + 1, tokens.Count - 1));
				break;
			}
		}
		target.Enabled = mEnabled;
		target.OnValidate();
		return true;
	}

	public Component PasteNew(GameObject target)
	{
		let info = ComponentRegistry.Find(TypeName);
		if (info == null) return null;
		let component = target.AddComponent(info.type);
		if (component != null)
			PasteValues(component);
		return component;
	}
}
