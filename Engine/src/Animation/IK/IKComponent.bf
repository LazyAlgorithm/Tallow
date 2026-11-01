using System;
using System.Collections;

namespace Tallow;

/// What the IK components share. Each one is a layer over the pose: it remembers how the bones it turns were posed
/// before it (by a clip, by hand, by a script), works from that every frame, and gives it back when its weight is 0,
/// when it is disabled and when the scene is saved. So IK never wears a pose away, and can be added to and taken off
/// an animated character freely.
///
/// IK is worked out after every Update and LateUpdate, and in the editor too, in this order: Foot Placement, Look At
/// IK, Limb IK, Hand Pose (so that arms are solved on a spine that has already turned).
abstract class IKComponent : Component
{
	struct Driven
	{
		public Transform bone;
		public Vector3 inPosition, outPosition;
		public Quaternion inRotation, outRotation;
		public bool written;
	}

	List<Driven> mDriven = new .() ~ delete _;
	List<Transform> mBones = new .() ~ delete _;
	float mFadeFrom, mFadeTo, mFadeTime = -1, mFadeLength;

	/// How much of the solved pose is used, 0 to 1 (the component's Weight field).
	public abstract float Weight { get; set; }
	/// Lower numbers are solved first.
	public abstract int32 Order { get; }
	/// The bones this component turns or moves this frame.
	protected abstract void CollectBones(List<Transform> bones);
	/// Pose the bones. They hold the pose from before IK when this is called.
	protected abstract void Solve();

	public override void OnRegister() => IKSystem.[Friend]sAll.Add(this);

	public override void OnUnregister()
	{
		Release();
		IKSystem.[Friend]sAll.Remove(this);
	}

	/// Scene files hold the pose from before IK, so that a saved scene is not a little more bent each time.
	public override void OnBeforeSave() => Release();

	/// Moves the weight to a value over some seconds. In a network session, called on the server or by the player
	/// who owns the object, every machine follows.
	public void FadeWeight(float to, float seconds = 0.2f)
	{
		mFadeLength = Math.Max(seconds, 0);
		NetworkSync.SendEvent(this, "ik.weight", Mathf.Clamp01(to));
	}

	public override void OnNetworkEvent(StringView name, float value)
	{
		if (name != "ik.weight")
			return;
		mFadeFrom = Weight;
		mFadeTo = value;
		mFadeTime = 0;
		if (mFadeLength <= 0)
			mFadeLength = 0.2f;
	}

	/// The pose a bone had before this component moved it. False when the component does not move that bone.
	public bool InputPose(Transform bone, out Vector3 position, out Quaternion rotation)
	{
		position = default;
		rotation = default;
		for (let driven in mDriven)
		{
			if (driven.bone == bone && driven.written)
			{
				position = driven.inPosition;
				rotation = driven.inRotation;
				return true;
			}
		}
		return false;
	}

	static bool Alive(Transform bone) => bone != null && !bone.GameObject.IsDestroyed;

	static bool Same(Transform bone, Driven driven)
	{
		return (bone.LocalPosition - driven.outPosition).LengthSquared < 1.0e-10f && Math.Abs(Quaternion.Dot(bone.LocalRotation, driven.outRotation)) > 0.9999995f;
	}

	/// Puts back the pose from before IK on every bone that nothing else has moved since.
	public void Release()
	{
		for (var driven in ref mDriven)
		{
			if (driven.written && Alive(driven.bone) && Same(driven.bone, driven))
			{
				driven.bone.LocalPosition = driven.inPosition;
				driven.bone.LocalRotation = driven.inRotation;
			}
			driven.written = false;
		}
	}

	/// Solves now. IKSystem calls this once a frame; call it yourself only to see the result at once.
	public void SolveNow()
	{
		if (mFadeTime >= 0)
		{
			mFadeTime += Time.DeltaTime;
			let t = mFadeLength > 0 ? Mathf.Clamp01(mFadeTime / mFadeLength) : 1;
			Weight = Mathf.Lerp(mFadeFrom, mFadeTo, Mathf.SmoothStep(0, 1, t));
			if (t >= 1)
				mFadeTime = -1;
		}
		mBones.Clear();
		CollectBones(mBones);
		// Bones no longer in the list get their own pose back; new ones start to be remembered.
		for (int i = mDriven.Count - 1; i >= 0; i--)
		{
			let driven = mDriven[i];
			if (Alive(driven.bone) && mBones.Contains(driven.bone))
				continue;
			if (driven.written && Alive(driven.bone) && Same(driven.bone, driven))
			{
				driven.bone.LocalPosition = driven.inPosition;
				driven.bone.LocalRotation = driven.inRotation;
			}
			mDriven.RemoveAt(i);
		}
		for (let bone in mBones)
		{
			if (!Alive(bone))
				continue;
			int found = -1;
			for (int i < mDriven.Count)
			{
				if (mDriven[i].bone == bone)
					found = i;
			}
			if (found < 0)
			{
				Driven driven = default;
				driven.bone = bone;
				mDriven.Add(driven);
				found = mDriven.Count - 1;
			}
			var driven = ref mDriven[found];
			if (driven.written && Same(bone, driven))
			{
				// Nothing has posed the bone since the last solve: start again from what it was given then.
				bone.LocalPosition = driven.inPosition;
				bone.LocalRotation = driven.inRotation;
			}
			else
			{
				driven.inPosition = bone.LocalPosition;
				driven.inRotation = bone.LocalRotation;
			}
		}
		let weight = Mathf.Clamp01(Weight);
		if (weight > 0)
		{
			Solve();
			if (weight < 1)
			{
				for (let driven in mDriven)
				{
					if (!Alive(driven.bone))
						continue;
					driven.bone.LocalPosition = Vector3.Lerp(driven.inPosition, driven.bone.LocalPosition, weight);
					driven.bone.LocalRotation = Quaternion.Slerp(driven.inRotation, driven.bone.LocalRotation, weight);
				}
			}
		}
		for (var driven in ref mDriven)
		{
			if (!Alive(driven.bone))
				continue;
			driven.outPosition = driven.bone.LocalPosition;
			driven.outRotation = driven.bone.LocalRotation;
			driven.written = true;
		}
	}

	/// The pose a bone has from the clip or from hand, before this component: for solvers that measure from it.
	protected Quaternion InputRotation(Transform bone)
	{
		for (let driven in mDriven)
		{
			if (driven.bone == bone)
				return driven.inRotation;
		}
		return bone.LocalRotation;
	}
}

/// Runs every IK component of a scene, in order, once the frame's animation and scripts have posed everything.
static class IKSystem
{
	static List<IKComponent> sAll = new .() ~ delete _;
	static List<IKComponent> sOrdered = new .() ~ delete _;

	/// Solves every enabled IK component in the scene. Scene.Update calls it at the end of each frame; the editor's
	/// Animation window calls it after posing a clip. Solving twice in a frame does no harm.
	public static void Solve(Scene scene)
	{
		sOrdered.Clear();
		for (let component in sAll)
		{
			if (component.GameObject == null || component.GameObject.IsDestroyed || component.Scene != scene)
				continue;
			if (component.IsActiveAndEnabled)
				sOrdered.Add(component);
			else
				component.Release();
		}
		// Few components, and their order within a kind must stay as it is: an insertion sort does both.
		for (int i = 1; i < sOrdered.Count; i++)
		{
			let item = sOrdered[i];
			int j = i - 1;
			while (j >= 0 && sOrdered[j].Order > item.Order)
			{
				sOrdered[j + 1] = sOrdered[j];
				j--;
			}
			sOrdered[j + 1] = item;
		}
		for (let component in sOrdered)
			component.SolveNow();
	}

	/// The pose a bone had before any IK moved it, for tools that must tell a pose made by hand from one made by IK
	/// (the Animation window's recording). False when no IK component moves the bone.
	public static bool InputPose(Transform bone, out Vector3 position, out Quaternion rotation)
	{
		position = default;
		rotation = default;
		// The first solver to move a bone holds the pose from before all of them.
		IKComponent first = null;
		for (let component in sAll)
		{
			Vector3 p;
			Quaternion r;
			if (component.InputPose(bone, out p, out r) && (first == null || component.Order < first.Order))
			{
				first = component;
				position = p;
				rotation = r;
			}
		}
		return first != null;
	}

	/// True when an IK component in the scene moves this bone.
	public static bool Drives(Transform bone)
	{
		Vector3 p;
		Quaternion r;
		return InputPose(bone, out p, out r);
	}

	/// Gives every bone in the scene its pose from before IK (the next Solve applies IK again).
	public static void ReleaseAll(Scene scene)
	{
		for (int i = sAll.Count - 1; i >= 0; i--)
		{
			if (sAll[i].GameObject != null && sAll[i].Scene == scene)
				sAll[i].Release();
		}
	}
}
