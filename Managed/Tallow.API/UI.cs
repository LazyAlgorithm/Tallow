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
}
