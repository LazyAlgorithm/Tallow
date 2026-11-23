using System.Numerics;

namespace Tallow;

/// <summary>
/// One Limb IK on an object: a character usually carries two (one per arm), so each is told apart by its place on
/// the object or by its tip bone (<see cref="IK.Limb(GameObject, GameObject)"/>, <see cref="IK.Limbs"/>).
/// </summary>
public readonly record struct Limb(GameObject Owner, int Index)
{
    /// <summary>The hand or foot it moves, if it has one.</summary>
    public GameObject? Tip => CSharpIK.Tip(Owner.SceneId, Owner.Id, 0, Index) is var id and not 0 ? new GameObject(Owner.SceneId, id) : null;

    /// <summary>The blend between animation (0) and IK (1). Setting it is not sent; <see cref="FadeWeight"/> is.</summary>
    public float Weight
    {
        get => CSharpIK.Weight(Owner.SceneId, Owner.Id, 0, Index);
        set => Must(CSharpIK.SetWeight(Owner.SceneId, Owner.Id, 0, Index, value));
    }

    /// <summary>Whether it is held on a target (weight above 0 and a target set).</summary>
    public bool IsHolding => CSharpIK.LimbIsHolding(Owner.SceneId, Owner.Id, Index);

    /// <summary>How far the target is along the limb's reach: 1 and over is out of reach, and the limb is straight.</summary>
    public float Reach => CSharpIK.LimbReach(Owner.SceneId, Owner.Id, Index);

    /// <summary>Takes the limb off its target over some seconds, back to its animation: to throw, wave or reload.
    /// Followed on every machine when the server or the object's owner calls it.</summary>
    public void LetGo(float seconds = 0.15f) => Must(CSharpIK.LimbHold(Owner.SceneId, Owner.Id, Index, 0, seconds));

    /// <summary>Puts the limb back on its target over some seconds. Followed on every machine like LetGo.</summary>
    public void Grab(float seconds = 0.15f) => Must(CSharpIK.LimbHold(Owner.SceneId, Owner.Id, Index, 1, seconds));

    /// <summary>Moves the weight to a value over some seconds. Followed on every machine like LetGo.</summary>
    public void FadeWeight(float to, float seconds = 0.2f) => Must(CSharpIK.FadeWeight(Owner.SceneId, Owner.Id, 0, Index, to, seconds));

    /// <summary>Moves to another target over some seconds without a jump (the next weapon's grip). Not sent: call it
    /// on every machine. Null clears the target.</summary>
    public void SetTarget(GameObject? target, float seconds = 0.15f) =>
        Must(CSharpIK.LimbSetTarget(Owner.SceneId, Owner.Id, Index, target?.Id ?? 0, seconds));

    private void Must(bool found)
    {
        if (!found)
            throw ActionText.Missing(Owner, $"Limb IK number {Index + 1}");
    }
}

public readonly partial record struct LookAtIK
{
    /// <summary>With no Target, looks at a point in the world (where the camera aims). Not sent: set it on every
    /// machine.</summary>
    public void LookAt(Vector3 point)
    {
        if (!CSharpIK.LookAt(GameObject.SceneId, GameObject.Id, 0, point))
            throw ActionText.Missing(GameObject, "Look At IK");
    }

    /// <summary>Moves the weight to a value over some seconds, followed on every machine when the server or owner
    /// calls it.</summary>
    public void FadeWeight(float to, float seconds = 0.2f)
    {
        if (!CSharpIK.FadeWeight(GameObject.SceneId, GameObject.Id, 1, 0, to, seconds))
            throw ActionText.Missing(GameObject, "Look At IK");
    }
}

public readonly partial record struct FootPlacement
{
    /// <summary>How many feet it places: 2, or 4 on a four-legged character.</summary>
    public int FootCount => Math.Max(CSharpIK.FootCount(GameObject.SceneId, GameObject.Id), 0);

    /// <summary>Whether a foot (0 left, 1 right, 2 and 3 the other pair of a four-legged character) found ground
    /// this frame.</summary>
    public bool IsGrounded(int foot) => CSharpIK.FootGrounded(GameObject.SceneId, GameObject.Id, foot) == 1;

    /// <summary>Moves the weight to a value over some seconds, followed on every machine when the server or owner
    /// calls it.</summary>
    public void FadeWeight(float to, float seconds = 0.2f)
    {
        if (!CSharpIK.FadeWeight(GameObject.SceneId, GameObject.Id, 2, 0, to, seconds))
            throw ActionText.Missing(GameObject, "Foot Placement");
    }
}

public readonly partial record struct HandPose
{
    /// <summary>Takes a ready-made shape, blended over Blend Time or the seconds given. Followed on every machine
    /// when the server or the object's owner calls it.</summary>
    public void SetShape(HandShape shape, float seconds = -1)
    {
        if (!CSharpIK.HandSetShape(GameObject.SceneId, GameObject.Id, 0, (int)shape, seconds))
            throw ActionText.Missing(GameObject, "Hand Pose");
    }

    /// <summary>Curls one finger (0 thumb, 1 index, 2 middle, 3 ring, 4 pinky) from 0 straight to 1 closed; the shape
    /// becomes Custom. Not sent.</summary>
    public void Curl(int finger, float amount)
    {
        if (!CSharpIK.HandCurl(GameObject.SceneId, GameObject.Id, 0, finger, amount))
            throw ActionText.Missing(GameObject, "Hand Pose");
    }

    /// <summary>Moves the weight to a value over some seconds, followed on every machine when the server or owner
    /// calls it.</summary>
    public void FadeWeight(float to, float seconds = 0.2f)
    {
        if (!CSharpIK.FadeWeight(GameObject.SceneId, GameObject.Id, 3, 0, to, seconds))
            throw ActionText.Missing(GameObject, "Hand Pose");
    }
}

/// <summary>
/// Inverse kinematics from code: the Limb IKs on a character, and the solver functions under the components for
/// anything they do not cover. Call the solvers from LateUpdate (tallowengine.com/docs/ik).
/// </summary>
public static class IK
{
    /// <summary>Every Limb IK on the object, in the order they were added.</summary>
    public static Limb[] Limbs(GameObject character)
    {
        var limbs = new Limb[CSharpIK.Count(character.SceneId, character.Id, 0)];
        for (int i = 0; i < limbs.Length; i++)
            limbs[i] = new Limb(character, i);
        return limbs;
    }

    /// <summary>Adds another Limb IK to the character and gives it (AddComponent&lt;LimbIK&gt; gives the first one
    /// back if there is one, and a character needs one per arm). Set its Tip and Target in the Inspector, or
    /// through <see cref="Limb.SetTarget"/>.</summary>
    public static Limb AddLimb(GameObject character)
    {
        int index = CSharpIK.AddLimb(character.SceneId, character.Id);
        if (index < 0)
            throw new InvalidOperationException($"Tallow could not add a Limb IK to {character}.");
        return new Limb(character, index);
    }

    /// <summary>The Limb IK on the character that moves that hand or foot, or null.</summary>
    public static Limb? Limb(GameObject character, GameObject tip)
    {
        foreach (Limb limb in Limbs(character))
            if (limb.Tip == tip)
                return limb;
        return null;
    }

    /// <summary>The Limb IK on the character whose tip bone has that name ("RightHand"), or null.</summary>
    public static Limb? Limb(GameObject character, string tipName)
    {
        foreach (Limb limb in Limbs(character))
            if (limb.Tip?.Name == tipName)
                return limb;
        return null;
    }

    /// <summary>Works every IK component in the scene out now, rather than at the end of the frame.</summary>
    public static void Solve(Scene scene) => CSharpIK.Solve(scene.SessionId);

    /// <summary>Bends a two-bone limb (an arm or a leg) so the tip reaches the target; with usePole the middle joint
    /// points towards the pole.</summary>
    public static void TwoBone(GameObject upper, GameObject middle, GameObject tip, Vector3 target, bool usePole = false,
        Vector3 pole = default)
    {
        if (!CSharpIK.SolveTwoBone(upper.SceneId, upper.Id, middle.Id, tip.Id, target, usePole, pole))
            throw new InvalidOperationException("IK.TwoBone: a bone is not in the scene.");
    }

    /// <summary>Bends a chain of bones, root first (a tail, a tentacle, a finger), so the tip reaches the target; the
    /// distance left between them.</summary>
    public static float Chain(GameObject[] bones, GameObject tip, Vector3 target, int iterations = 12)
    {
        Span<ulong> ids = Ids(bones);
        float left = CSharpIK.SolveChain(tip.SceneId, ids, tip.Id, target, iterations);
        if (left < 0)
            throw new InvalidOperationException("IK.Chain: a bone is not in the scene.");
        return left;
    }

    /// <summary>Turns bones, root first and the head last, so the last one's localForward faces the target,
    /// sharing the turn among them, no further than maxDegrees, blended by weight.</summary>
    public static void LookAt(GameObject[] bones, Vector3 localForward, Vector3 target, float weight = 1, float maxDegrees = 80)
    {
        if (bones.Length == 0 || !CSharpIK.SolveLookAt(bones[0].SceneId, Ids(bones), localForward, target, weight, maxDegrees))
            throw new InvalidOperationException("IK.LookAt: a bone is not in the scene.");
    }

    /// <summary>The turn that takes one direction to another.</summary>
    public static Quaternion FromTo(Vector3 from, Vector3 to)
    {
        if (from.LengthSquared() < 1e-12f || to.LengthSquared() < 1e-12f)
            return Quaternion.Identity;
        Vector3 a = Vector3.Normalize(from), b = Vector3.Normalize(to);
        float dot = Vector3.Dot(a, b);
        if (dot > 0.999999f)
            return Quaternion.Identity;
        if (dot < -0.999999f)
        {
            Vector3 axis = Vector3.Cross(Vector3.UnitX, a);
            if (axis.LengthSquared() < 1e-6f)
                axis = Vector3.Cross(Vector3.UnitY, a);
            return Quaternion.CreateFromAxisAngle(Vector3.Normalize(axis), MathF.PI);
        }
        Vector3 cross = Vector3.Cross(a, b);
        return Quaternion.Normalize(new Quaternion(cross.X, cross.Y, cross.Z, 1 + dot));
    }

    private static ulong[] Ids(GameObject[] bones)
    {
        var ids = new ulong[bones.Length];
        for (int i = 0; i < bones.Length; i++)
            ids[i] = bones[i].Id;
        return ids;
    }
}
