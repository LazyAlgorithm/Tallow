using System;
using System.Text;

namespace Tallow;

/// <summary>
/// An object's UI Document (a .tui file drawn over the game). A C# script on the same object is its code-behind:
/// onclick="Method", onchange and onload call that script's methods (taking nothing, a <see cref="UIElement"/> or
/// the element's id), and bind="field" shows and edits its public fields.
/// </summary>
[NativeComponent("Tallow.UIDocument")]
public readonly partial record struct UIDocument(GameObject GameObject) : IComponent
{
    /// <summary>Whether the object still has a UI Document.</summary>
    public bool IsValid => CSharpUI.HasDocument(GameObject.SceneId, GameObject.Id);

    /// <summary>Reads the document file again at once (the next draw reads a changed one by itself).</summary>
    public void Reload() => CSharpUI.ReloadDocument(GameObject.SceneId, GameObject.Id);

    /// <summary>The element with id="...", or null.</summary>
    public UIElement? Find(string id)
    {
        var element = new UIElement(GameObject, id);
        return element.Exists ? element : null;
    }
}

/// <summary>An element of a UI document, by its id. Setting things on one that is gone does nothing.</summary>
public readonly record struct UIElement(GameObject GameObject, string Id)
{
    /// <summary>Whether the document has an element with this id.</summary>
    public bool Exists => !string.IsNullOrEmpty(Id) && CSharpUI.HasElement(GameObject.SceneId, GameObject.Id, Id);

    /// <summary>The document the element is in.</summary>
    public UIDocument Document => new(GameObject);

/// <summary>The element's text (a label's or button's words, a text field's contents).</summary>
    public string Text
    {
        get
        {
            Span<byte> buffer = stackalloc byte[256];
            int length = CSharpUI.CopyText(GameObject.SceneId, GameObject.Id, Id, buffer);
            if (length <= 0)
                return "";
            if (length > buffer.Length)
            {
                buffer = new byte[length];
                length = Math.Min(length, CSharpUI.CopyText(GameObject.SceneId, GameObject.Id, Id, buffer));
            }
            return Encoding.UTF8.GetString(buffer[..length]);
        }
        set => CSharpUI.SetText(GameObject.SceneId, GameObject.Id, Id, value ?? "");
    }

    /// <summary>Sets the element's text (the same as setting Text).</summary>
    public void SetText(string text) => Text = text;

/// <summary>Whether the element is shown; a hidden one takes no room in the layout.</summary>
    public bool Visible
    {
        get => CSharpUI.GetVisible(GameObject.SceneId, GameObject.Id, Id);
        set => CSharpUI.SetVisible(GameObject.SceneId, GameObject.Id, Id, value);
    }

    /// <summary>A slider's or checkbox's value.</summary>
    public float Value
    {
        get => CSharpUI.GetValue(GameObject.SceneId, GameObject.Id, Id);
        set => CSharpUI.SetValue(GameObject.SceneId, GameObject.Id, Id, value);
    }

    /// <summary>Gives the element a class its stylesheet can style, or takes it away (the "chosen" highlight of a
    /// selected option or the current page).</summary>
    public void SetClass(string name, bool on) =>
        CSharpUI.SetClass(GameObject.SceneId, GameObject.Id, Id, name ?? "", on);

    /// <summary>Whether the element has that class.</summary>
    public bool HasClass(string name) =>
        CSharpUI.HasClass(GameObject.SceneId, GameObject.Id, Id, name ?? "");

    /// <summary>Where the element was last drawn, in window pixels, and the document's screen scale.
    /// Zero when it has not been drawn.</summary>
    public (float X, float Y, float Width, float Height, float Scale) ScreenRect
    {
        get
        {
            Span<float> values = stackalloc float[5];
            return CSharpUI.ElementRect(GameObject.SceneId, GameObject.Id, Id, values)
                ? (values[0], values[1], values[2], values[3], values[4])
                : (0, 0, 0, 0, 0);
        }
    }

    /// <summary>Where the element was last drawn, in window pixels.</summary>
    public float ScreenX => ScreenRect.X;
    /// <summary>Where the element was last drawn, in window pixels.</summary>
    public float ScreenY => ScreenRect.Y;
    /// <summary>How wide the element was drawn, in window pixels.</summary>
    public float ScreenWidth => ScreenRect.Width;
    /// <summary>How tall the element was drawn, in window pixels.</summary>
    public float ScreenHeight => ScreenRect.Height;
    /// <summary>Window pixels per document unit when it was last drawn.</summary>
    public float ScreenScale => ScreenRect.Scale;

    /// <summary>An attribute of the element ("value", "caption", "action", "font-size"...); "" without one.</summary>
    public string Attribute(string name)
    {
        if (string.IsNullOrEmpty(name))
            return "";
        byte[] buffer = new byte[256];
        int length = CSharpUI.CopyAttribute(GameObject.SceneId, GameObject.Id, Id, name, buffer);
        if (length < 0)
            return "";
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpUI.CopyAttribute(GameObject.SceneId, GameObject.Id, Id, name, buffer));
        }
        return global::System.Text.Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0));
    }

    /// <summary>Sets an attribute of the element (a picture's "src", a control's "disabled"...).</summary>
    public void SetAttribute(string name, string value) =>
        CSharpUI.SetAttribute(GameObject.SceneId, GameObject.Id, Id, name ?? "", value ?? "");
}
