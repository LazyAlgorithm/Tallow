using System;
using Tallow;

namespace Gameplay;

/// Test both catalog serialization policy and runtime field restoration
/// before C# Awake, without exposing unrelated private implementation data.
[Component]
public sealed class InspectorSerializationSmoke : Script
{
    [ShowInInspector, Range(0, 20)]
    private float privateSpeed = 3f;

    [ShowInInspector]
    private bool privateEnabled = true;

    [SerializeField]
    private int serializedCounter = 4;

    [HideInInspector]
    public float hiddenPublic = 5f;

    [HideInInspector]
    private int hiddenPrivate = 6;

    [SerializeField, HideInInspector]
    private int hiddenSerialized = 11;

    [NonSerialized, ShowInInspector]
    private int skippedNonSerialized = 7;

    private int implementationOnly = 8;

    public override void Awake()
    {
        if (MathF.Abs(privateSpeed - 12.5f) > 0.0001f ||
            privateEnabled || serializedCounter != 19 ||
            MathF.Abs(hiddenPublic - 8.5f) > 0.0001f ||
            hiddenPrivate != 15 || hiddenSerialized != 25 ||
            skippedNonSerialized != 7 || implementationOnly != 8)
            throw new InvalidOperationException(
                "C# private/hidden Inspector state was not restored or private internals were changed.");
    }
}
