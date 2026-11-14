using System;
using Tallow;

namespace Gameplay;

/// Test both catalog serialization policy and runtime field restoration
/// before C# Awake, without exposing unrelated private implementation data.
public enum InspectorMotion
{
    Idle = 0,
    Hover = 2,
    Jump = 9
}

[Component]
public sealed class InspectorSerializationSmoke : Script
{
    [SerializedFieldId("motion-state-v1")]
    public InspectorMotion movementMode = InspectorMotion.Hover;

    [ShowInInspector]
    private InspectorMotion privateMode = InspectorMotion.Idle;

    [HideInInspector]
    private InspectorMotion hiddenMode = InspectorMotion.Jump;

    public string statusText = "Idle";

    [ShowInInspector]
    private string privateStatus = "Private default";

    [HideInInspector]
    private string hiddenStatus = "Hidden default";

    [NonSerialized]
    public string skippedString = "Unmodified";

    [ShowInInspector, Range(0, 20)]
    private float privateSpeed = 3f;

    [ShowInInspector]
    private bool privateEnabled = true;

    [ShowInInspector]
    private int serializedCounter = 4;

    [HideInInspector]
    public float hiddenPublic = 5f;

    [HideInInspector]
    private int hiddenPrivate = 6;

    [HideInInspector]
    private int hiddenSerialized = 11;

    [NonSerialized, ShowInInspector]
    private int skippedNonSerialized = 7;

    private int implementationOnly = 8;

    // A stable ID alone must not opt a private field into serialization.
    [SerializedFieldId("nonpersistent-private-state")]
    private int privateIdOnly = 12;

    public override void Awake()
    {
        if (MathF.Abs(privateSpeed - 12.5f) > 0.0001f ||
            privateEnabled || serializedCounter != 19 ||
            MathF.Abs(hiddenPublic - 8.5f) > 0.0001f ||
            hiddenPrivate != 15 || hiddenSerialized != 25 ||
            movementMode != InspectorMotion.Jump ||
            privateMode != InspectorMotion.Hover ||
            hiddenMode != InspectorMotion.Idle ||
            skippedNonSerialized != 7 || implementationOnly != 8 ||
            privateIdOnly != 12 ||
            statusText != "Ready to play" ||
            privateStatus != "saved private text" ||
            hiddenStatus != "saved hidden text" ||
            skippedString != "Unmodified")
            throw new InvalidOperationException(
                "C# private/hidden Inspector state was not restored or private internals were changed.");
    }
}
