using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// Replaces game components at a frame boundary without rebuilding scene objects,
/// renderers or physics bodies. Names and supported field types identify saved values.
class ScriptStateMigration
{
	class Value
	{
		public String name = new .() ~ delete _;
		public String type = new .() ~ delete _;
		public String text = new .() ~ delete _;
		public FieldKind kind;
	}

	class Saved
	{
		public Component old;
		public Component replacement;
		public GameObject owner;
		public Type type;
		public int index;
		public bool enabled;
		public bool awake;
		public bool started;
		public List<Value> fields = new .() ~ DeleteContainerAndItems!(_);
	}

	class Reference
	{
		public Component owner;
		public String field = new .() ~ delete _;
		public Component target;
	}

	List<Saved> mSaved = new .() ~ DeleteContainerAndItems!(_);
	List<Reference> mReferences = new .() ~ DeleteContainerAndItems!(_);

	public void Capture(Scene scene, List<ScriptReload.TypeUpdate> types)
	{
		List<FieldRef> fields = scope .();
		for (let component in scene.Components)
		{
			fields.Clear();
			ComponentRegistry.GetFields(component, fields, true);
			for (let field in fields)
			{
				if (field.kind == .ObjectReference && !ObjectRefs.Is(field.type))
				{
					if (let target = (*(Object*)field.ptr) as Component)
					{
						let reference = new Reference() { owner = component, target = target };
						reference.field.Set(field.name);
						mReferences.Add(reference);
					}
				}
			}
			for (let update in types)
			{
				if (update.script && component.GetType() == update.original)
				{
					let saved = new Saved()
						{
							old = component, owner = component.GameObject, type = update.original,
							index = component.GameObject.Components.IndexOf(component), enabled = component.Enabled,
							awake = component.[Friend]mAwake, started = component.[Friend]mStarted
						};
					for (let field in fields)
					{
						let value = new Value() { kind = field.kind };
						value.name.Set(field.name);
						field.type.GetFullName(value.type);
						SceneSerializer.WriteValue(field, value.text);
						saved.fields.Add(value);
					}
					mSaved.Add(saved);
					break;
				}
			}
		}
	}

	Component Remapped(Component old)
	{
		for (let saved in mSaved)
		{
			if (saved.old == old)
				return saved.replacement;
		}
		return old;
	}

	public void Restore(Scene scene)
	{
		let active = Scene.Active;
		Scene.Active = scene;
		defer
		{
			Scene.Active = active;
		}
		for (let saved in mSaved)
		{
			let replacement = ComponentRegistry.Create(saved.type);
			saved.replacement = replacement;
			replacement.[Friend]mGameObject = saved.owner;
			replacement.[Friend]mEnabled = saved.enabled;
			replacement.[Friend]mAwake = saved.awake;
			replacement.[Friend]mStarted = saved.started;
			replacement.[Friend]mRegistered = true;
			saved.owner.Components[saved.index] = replacement;
			scene.[Friend]ReplaceComponent(saved.old, replacement);
		}
		scene.[Friend]RebuildCallbackLists();
		List<FieldRef> fields = scope .();
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		for (let saved in mSaved)
		{
			fields.Clear();
			ComponentRegistry.GetFields(saved.replacement, fields, true);
			for (let value in saved.fields)
			{
				for (let field in fields)
				{
					if (field.name != value.name || field.kind != value.kind) continue;
					let typeName = scope String();
					field.type.GetFullName(typeName);
					if (typeName != value.type) continue;
					tokens.Clear();
					SceneSerializer.Tokenize(value.text, tokens, storage);
					SceneSerializer.ReadValue(field, .(tokens.Ptr, tokens.Count));
					break;
				}
			}
		}
		// Include references held by resident engine components and private script fields.
		for (let reference in mReferences)
		{
			let owner = Remapped(reference.owner);
			let target = Remapped(reference.target);
			fields.Clear();
			ComponentRegistry.GetFields(owner, fields, true);
			for (let field in fields)
			{
				if (field.name == reference.field && field.kind == .ObjectReference)
				{
					// An engine proxy (Foliage's renderer) belongs to no object, so it cannot be looked up on one.
					if (target.GameObject == null)
						*(Object*)field.ptr = target;
					else
						ComponentRegistry.AssignReference(field, target.GameObject, target.GameObject.Components.IndexOf(target));
					break;
				}
			}
		}
		for (let saved in mSaved)
			saved.replacement.OnValidate();
		// Old native delegates may still contain their original targets. Retain retired
		// allocations for this development session; they no longer receive scene updates.
		for (let saved in mSaved)
		{
			saved.old.[Friend]mRegistered = false;
			saved.old.[Friend]mAwake = false;
			ScriptReload.Retire(saved.old);
		}
	}
}
