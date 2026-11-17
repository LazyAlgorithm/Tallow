using System.Text;

namespace Tallow;

/// <summary>
/// An object's Animator: plays its clips on the bones below it, blending when the clip changes, or runs its
/// Animator Controller (set parameters, and the transitions pick the clip). A value handle like Rigidbody: get one
/// with GetComponent&lt;Animator&gt;() or GetComponentInChildren&lt;Animator&gt;(); on an object without an
/// Animator it does nothing and reads zero.
/// </summary>
[NativeComponent("Tallow.Animator")]
public readonly partial record struct Animator(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpAnimation.HasAnimator(GameObject.SceneId, GameObject.Id);

    /// <summary>Plays a clip by name, fading from the one playing.</summary>
    public void Play(string clip, float fadeSeconds = 0.15f) =>
        CSharpAnimation.Play(GameObject.SceneId, GameObject.Id, clip, fadeSeconds);

    /// <summary>With a controller: moves to a state by name, fading.</summary>
    public void CrossFade(string state, float fadeSeconds = 0.15f) =>
        CSharpAnimation.CrossFade(GameObject.SceneId, GameObject.Id, state, fadeSeconds);

    public bool HasClip(string clip) => CSharpAnimation.HasClip(GameObject.SceneId, GameObject.Id, clip);

    /// <summary>The clip playing ("" without an Animator).</summary>
    public string CurrentClip => Read(static (scene, id, buffer) => CSharpAnimation.CopyCurrentClip(scene, id, buffer));

    /// <summary>The controller state playing ("" without one).</summary>
    public string CurrentState => Read(static (scene, id, buffer) => CSharpAnimation.CopyCurrentState(scene, id, buffer));

    public bool IsFinished => CSharpAnimation.IsFinished(GameObject.SceneId, GameObject.Id);
    public bool IsInTransition => CSharpAnimation.IsInTransition(GameObject.SceneId, GameObject.Id);
    public float NormalizedTime => CSharpAnimation.GetNormalizedTime(GameObject.SceneId, GameObject.Id);
    public float StateTime => CSharpAnimation.GetStateTime(GameObject.SceneId, GameObject.Id);

    /// <summary>Playback speed (1 is normal).</summary>
    public float Speed
    {
        get => CSharpAnimation.GetSpeed(GameObject.SceneId, GameObject.Id);
        set => CSharpAnimation.SetSpeed(GameObject.SceneId, GameObject.Id, value);
    }

    public void SetFloat(string name, float value) => CSharpAnimation.SetFloat(GameObject.SceneId, GameObject.Id, name, value);
    public void SetInteger(string name, int value) => CSharpAnimation.SetInteger(GameObject.SceneId, GameObject.Id, name, value);
    public void SetBool(string name, bool value) => CSharpAnimation.SetBool(GameObject.SceneId, GameObject.Id, name, value);
    public void SetTrigger(string name) => CSharpAnimation.SetTrigger(GameObject.SceneId, GameObject.Id, name);
    public void ResetTrigger(string name) => CSharpAnimation.ResetTrigger(GameObject.SceneId, GameObject.Id, name);
    public float GetFloat(string name) => CSharpAnimation.GetFloat(GameObject.SceneId, GameObject.Id, name);
    public int GetInteger(string name) => CSharpAnimation.GetInteger(GameObject.SceneId, GameObject.Id, name);
    public bool GetBool(string name) => CSharpAnimation.GetBool(GameObject.SceneId, GameObject.Id, name);
    public int LayerCount => CSharpAnimation.GetLayerCount(GameObject.SceneId, GameObject.Id);
    public void SetLayerWeight(int layer, float weight) => CSharpAnimation.SetLayerWeight(GameObject.SceneId, GameObject.Id, layer, weight);
    public float GetLayerWeight(int layer) => CSharpAnimation.GetLayerWeight(GameObject.SceneId, GameObject.Id, layer);

    private delegate int Copier(ulong scene, ulong id, Span<byte> buffer);

    private string Read(Copier copy)
    {
        Span<byte> buffer = stackalloc byte[128];
        int length = copy(GameObject.SceneId, GameObject.Id, buffer);
        if (length <= 0)
            return "";
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(GameObject.SceneId, GameObject.Id, buffer));
        }
        return Encoding.UTF8.GetString(buffer[..length]);
    }
}
