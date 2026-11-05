using System;
using System.Collections;
using System.IO;
using System.Reflection;

namespace Tallow;

/// Shows a UI document (.tui) over the game and connects it to code.
///
/// Event attributes name methods on any other component of the same object:
///   onclick="OnPlay"   called when the element is pressed
///   onload="OnOpen"    (on any element) called once when the document is loaded
///   onchange="OnVolume" called when a slider or toggle is moved; read the element's value
///   ondraw="OnRadar"   (on a canvas) called every frame to draw into the element's rectangle
/// A handler takes no parameters, or one UIElement (the element that raised the event).
/// bind="fieldName" links a text, input or bar to a public field of such a component.
[Component]
class UIDocument : Component
{
	/// .tui file relative to the project's asset folder.
	public String document = new .() ~ delete _;
	/// Scale the whole document with the height of the view: sizes in the document are then for a view this many
	/// pixels tall (1080, say) and it fills any window the same way. 0 leaves sizes as real pixels.
	public float referenceHeight = 0;
	/// Optional reference width. When set, scale uniformly to fit both dimensions.
	public float referenceWidth = 0;
	/// Draws the document this much bigger, laid out for a view that much smaller: for a player's interface scale
	/// setting. Suits documents whose parts are placed from the edges (a HUD); a page laid out to fill the
	/// reference size exactly runs off the screen when it is made bigger.
	public float UserScale { get => mUserScale; set => mUserScale = value; }
	float mUserScale = 1;

	/// A version of every document for a kind of screen, used where one exists: with Variant "phone",
	/// UI/lobby.tui is read from UI/phone/lobby.tui (and its stylesheet from UI/phone/lobby.tcss) if that file is
	/// there, and from UI/lobby.tui if not. A game sets it, for instance on a phone held sideways, whose few hundred
	/// points of height make pages laid out for a 1080-line screen too small to read. Empty: no variants.
	public static String Variant = new .() ~ delete _;
	/// The referenceHeight a document read from its Variant is laid out for (0: the component's own). A phone
	/// version laid out for a 600-line screen is drawn nearly twice as big as one laid out for 1080.
	public static float VariantReferenceHeight = 0;
	/// Optional width of a variant's design viewport. When set, the UI uses the smaller of the
	/// width and height scales, so narrow portrait screens cannot enlarge a landscape menu
	/// beyond the available horizontal space. Zero preserves the height-only behavior.
	public static float VariantReferenceWidth = 0;
	static int32 sVariantVersion;

	/// Changes Variant; documents read themselves again from the right files.
	public static void SetVariant(StringView variant, float referenceHeight, float referenceWidth = 0)
	{
		if (Variant == variant && VariantReferenceHeight == referenceHeight && VariantReferenceWidth == referenceWidth)
			return;
		Variant.Set(variant);
		VariantReferenceHeight = referenceHeight;
		VariantReferenceWidth = referenceWidth;
		sVariantVersion++;
	}

	UIDocumentData mData ~ delete _;
	String mLoaded = new .() ~ delete _;
	int32 mLoadedVersion = -1;
	bool mFromVariant;

	/// True when the document was read from its Variant's file.
	public bool FromVariant => mFromVariant;

	public UIDocumentData Data => mData;
	/// The button or toggle under the pointer when the document was last drawn, or null.
	public UIElement Hovered => mData != null ? mData.hovered : null;

	/// Finds an element by its id attribute.
	public UIElement Find(StringView id) => (mData != null && mData.root != null) ? mData.root.Find(id) : null;

	/// Reads the document from disk again.
	public void Reload()
	{
		mLoaded.Set(document);
		mLoadedVersion = sVariantVersion;
		mFromVariant = false;
		delete mData;
		mData = null;
		if (document.IsEmpty)
			return;
		let path = scope String();
		Assets.ResolvePath(document, path);
		if (!Variant.IsEmpty)
		{
			// Build the variant as an asset-relative path first, then resolve it.
			// The resolved base path may be a physical project path or a packed asset path.
			let slash = Math.Max(document.LastIndexOf('/'), document.LastIndexOf('\\'));
			let variantAsset = scope String();
			variantAsset.Append(document, 0, slash + 1);
			variantAsset.AppendF("{}/", Variant);
			variantAsset.Append(document, slash + 1);
			let variantPath = scope String();
			Assets.ResolvePath(variantAsset, variantPath);
			if (AssetPack.Exists(variantPath))
			{
				path.Set(variantPath);
				mFromVariant = true;
			}
		}
		let data = new UIDocumentData();
		if (!data.Load(path))
		{
			Log.Warning(scope $"UI document not found: {document}");
			delete data;
			return;
		}
		mData = data;
	}

	public override void Start()
	{
		Reload();
		if (mData != null && mData.root != null)
			RaiseLoad(mData.root);
	}

	void RaiseLoad(UIElement element)
	{
		let handler = element.attributes.Get("onload");
		if (!handler.IsEmpty)
			Invoke(handler, element);
		for (let child in element.children)
			RaiseLoad(child);
	}

	public override void OnGUI()
	{
		if (mLoaded != document || mLoadedVersion != sVariantVersion)
			Reload();
		if (mData == null)
			return;
		let reference = (mFromVariant && VariantReferenceHeight > 0) ? VariantReferenceHeight : referenceHeight;
		var baseScale = reference > 0 ? Math.Max(GUI.Height / reference, 0.1f) : 1.0f;
		let widthReference = mFromVariant && VariantReferenceWidth > 0 ? VariantReferenceWidth : referenceWidth;
		if (widthReference > 0)
			baseScale = Math.Min(baseScale, Math.Max(GUI.Width / widthReference, 0.1f));
		let scale = baseScale * Math.Clamp(mUserScale, 0.25f, 4.0f);
		mData.scale = scale;
		mData.Layout(GUI.Width / scale, GUI.Height / scale);
		mData.Draw(GUI.Origin, this, true);
		if (mData.clicked != null)
		{
			let handler = mData.clicked.attributes.Get("onclick");
			if (!handler.IsEmpty)
				Invoke(handler, mData.clicked);
		}
		if (mData != null && mData.changed != null)
		{
			let handler = mData.changed.attributes.Get("onchange");
			if (!handler.IsEmpty)
				Invoke(handler, mData.changed);
		}
	}

	/// Calls a method by name on the other components of this object.
	public void Invoke(StringView methodName, UIElement source)
	{
		for (let component in GameObject.Components)
		{
			if (component == this)
				continue;
			let type = component.GetType() as TypeInstance;
			if (type == null)
				continue;
			if (type.GetMethod(methodName, .Instance | .Public | .NonPublic) case .Ok(let method))
			{
				if (method.ParamCount == 1)
					method.Invoke(component, source).IgnoreError();
				else
					method.Invoke(component).IgnoreError();
				return;
			}
		}
		Log.Warning(scope $"UI handler '{methodName}' was not found on '{GameObject.Name}'. Add a component with a method of that name.");
	}

	bool FindField(StringView name, out FieldRef result)
	{
		result = default;
		List<FieldRef> fields = scope .();
		for (let component in GameObject.Components)
		{
			if (component == this)
				continue;
			fields.Clear();
			ComponentRegistry.GetFields(component, fields);
			for (let field in fields)
			{
				if (field.name == name)
				{
					result = field;
					return true;
				}
			}
		}
		return false;
	}

	/// Text form of a bound field.
	public bool ReadBinding(StringView name, String text)
	{
		FieldRef field;
		if (!FindField(name, out field))
			return false;
		if (field.kind == .String)
		{
			text.Append(StringFields.Get(field.ptr, field.type));
		}
		else
			SceneSerializer.WriteValue(field, text);
		return true;
	}

	public void WriteBinding(StringView name, StringView text)
	{
		FieldRef field;
		if (!FindField(name, out field))
			return;
		StringView[1] tokens = .(text);
		SceneSerializer.ReadValue(field, tokens);
	}
}
