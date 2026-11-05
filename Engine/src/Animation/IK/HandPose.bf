using System;
using System.Collections;

namespace Tallow;

/// The ready-made hand shapes of a Hand Pose.
[Reflect(.All)]
enum HandShape : int32
{
	/// The five sliders are set by hand.
	Custom,
	Open,
	Relaxed,
	Fist,
	/// Wrapped round a handle or a weapon's grip.
	Grip,
	/// A grip with the index finger out on a trigger.
	Trigger,
	Point,
	Pinch,
	ThumbsUp
}

/// Poses the fingers of a hand without animating fifteen bones: one slider for each finger (0 straight, 1 curled), one
/// for how far they are spread, and ready-made shapes (Open, Fist, Grip, Trigger, Point, Pinch...). Put it on the hand
/// bone, or name the hand in Hand.
///
/// The fingers are found by name among the hand's children (thumb, index, middle, ring, pinky or little; when none of
/// the names match they are taken in order; a child named only "finger" takes the first free slot from the middle).
/// Each finger is that child and the bones below it. If the fingers curl backwards on your model, tick Flip Curl; if
/// only the thumb does, Flip Thumb.
///
/// It is a layer over the clip like the other IK components: Weight 0 leaves the fingers to their animation. Change
/// shape from code with SetShape (blended over Blend Time, and followed on every machine when the object's owner
/// calls it). To keep a pose in a clip, open the clip in the Animation window and press Key IK.
[Component]
class HandPose : IKComponent
{
	/// The hand bone. Empty: the object this component is on.
	public Transform hand;
	/// A ready-made shape, or Custom to use the sliders as they are.
	public HandShape shape = .Custom;
	[Range(0, 1)] public float thumb = 0;
	[Range(0, 1)] public float index = 0;
	[Range(0, 1)] public float middle = 0;
	[Range(0, 1)] public float ring = 0;
	[Range(0, 1)] public float pinky = 0;
	/// Fans the fingers apart (above 0) or presses them together (below 0).
	[Range(-1, 1)] public float spread = 0;
	/// Squeezes the index finger a little further on top of its slider: animate it or set it from code as the trigger is pulled.
	[Range(0, 1)] public float trigger = 0;
	[Range(0, 1)] public float weight = 1;
	/// Seconds a change of shape takes while the game runs.
	public float blendTime = 0.12f;
	/// Tick when the fingers curl towards the back of the hand.
	public bool flipCurl;
	/// Tick when the thumb bends the wrong way.
	public bool flipThumb;
	/// The fingers' straight pose, remembered the first time the hand is bound so that curls are always measured from
	/// the same place whatever animation is playing. "Use Current Pose As Straight" in the Inspector sets it again.
	[HideInInspector]
	public String restPose = new .() ~ delete _;

	class Finger
	{
		public List<Transform> bones = new .() ~ delete _;
		public List<Quaternion> rest = new .() ~ delete _;
		public List<Vector3> curlAxis = new .() ~ delete _;
		public Vector3 spreadAxis;
		public float spreadSign;
	}

	Finger[5] mFingers ~ { for (let finger in _) delete finger; };
	Transform mBound;
	float[7] mNow;
	bool mHasNow;
	HandShape mAppliedShape = .Custom;

	public override float Weight { get => weight; set => weight = value; }
	public override int32 Order => 30;

	public Transform Hand => hand != null ? hand : Transform;
	/// How many bones were found for a finger (0 thumb, 1 index, 2 middle, 3 ring, 4 pinky): 0 means it was not found.
	public int BoneCount(int finger) => (finger >= 0 && finger < 5 && mFingers[finger] != null) ? mFingers[finger].bones.Count : 0;

	static float[6] Curls(HandShape shape)
	{
		switch (shape)
		{
		case .Open: return .(0, 0, 0, 0, 0, 0.3f);
		case .Relaxed: return .(0.25f, 0.2f, 0.25f, 0.3f, 0.35f, 0);
		case .Fist: return .(0.8f, 1, 1, 1, 1, 0);
		case .Grip: return .(0.55f, 0.75f, 0.8f, 0.85f, 0.9f, 0);
		case .Trigger: return .(0.55f, 0.3f, 0.8f, 0.85f, 0.9f, 0);
		case .Point: return .(0.7f, 0, 1, 1, 1, 0);
		case .Pinch: return .(0.6f, 0.55f, 0.15f, 0.1f, 0.1f, 0.2f);
		case .ThumbsUp: return .(0, 1, 1, 1, 1, 0);
		default: return .(0, 0, 0, 0, 0, 0);
		}
	}

	void ApplyShape()
	{
		if (shape == .Custom)
			return;
		let curls = Curls(shape);
		thumb = curls[0];
		index = curls[1];
		middle = curls[2];
		ring = curls[3];
		pinky = curls[4];
		spread = curls[5];
	}

	public override void OnValidate()
	{
		// Picking a shape sets the sliders; moving a slider afterwards makes the shape Custom again.
		if (shape != mAppliedShape)
			ApplyShape();
		else if (shape != .Custom)
		{
			let curls = Curls(shape);
			if (thumb != curls[0] || index != curls[1] || middle != curls[2] || ring != curls[3] || pinky != curls[4] || spread != curls[5])
				shape = .Custom;
		}
		mAppliedShape = shape;
	}

	/// Changes to a ready-made shape, blended over Blend Time (or the seconds given). Followed on every machine when
	/// called on the server or by the player who owns the object.
	public void SetShape(HandShape next, float seconds = -1)
	{
		if (seconds >= 0)
			blendTime = seconds;
		NetworkSync.SendEvent(this, "hand.shape", (float)(int)next);
	}

	/// Sets one finger's curl (0 thumb, 1 index, 2 middle, 3 ring, 4 pinky), 0 straight to 1 curled.
	public void Curl(int finger, float amount)
	{
		let value = Mathf.Clamp01(amount);
		switch (finger)
		{
		case 0: thumb = value;
		case 1: index = value;
		case 2: middle = value;
		case 3: ring = value;
		case 4: pinky = value;
		default:
		}
		shape = .Custom;
		mAppliedShape = .Custom;
	}

	public override void OnNetworkEvent(StringView name, float value)
	{
		if (name == "hand.shape")
		{
			shape = (HandShape)(int)Math.Round(value);
			ApplyShape();
			mAppliedShape = shape;
			return;
		}
		base.OnNetworkEvent(name, value);
	}

	/// Takes the fingers' pose at this moment as their straight pose. Set Weight to 0 first, or the pose it is
	/// making now is what gets remembered.
	public void UseCurrentPoseAsRest()
	{
		restPose.Clear();
		mBound = null;
	}

	static bool Named(StringView name, params StringView[] parts)
	{
		let lower = scope String(name)..ToLower();
		for (let part in parts)
		{
			if (lower.Contains(part))
				return true;
		}
		return false;
	}

	/// The next bone along a finger: the first child that is not just a mesh hung on the bone.
	static Transform Next(Transform bone)
	{
		for (let child in bone.Children)
		{
			if (child.Children.Count == 0 && child.GameObject.HasComponent<MeshRenderer>())
				continue;
			return child;
		}
		return null;
	}

	/// Finds the fingers again. Called by itself when the hand changes; call it after adding or renaming finger bones.
	public void Bind()
	{
		let root = Hand;
		mBound = root;
		for (int i < 5)
		{
			delete mFingers[i];
			mFingers[i] = null;
		}
		List<Transform> unnamed = scope .();
		bool anyNamed = false;
		for (let child in root.Children)
		{
			if (Next(child) == null && child.Children.Count == 0 && child.GameObject.HasComponent<MeshRenderer>())
				continue;
			let name = child.GameObject.Name;
			int slot = -1;
			if (Named(name, "thumb"))
				slot = 0;
			else if (Named(name, "index", "pointer", "fore"))
				slot = 1;
			else if (Named(name, "middle", "mid"))
				slot = 2;
			else if (Named(name, "ring"))
				slot = 3;
			else if (Named(name, "pinky", "pinkie", "little"))
				slot = 4;
			if (slot >= 0 && mFingers[slot] == null)
			{
				anyNamed = true;
				mFingers[slot] = Chain(child);
			}
			else
				unnamed.Add(child);
		}
		if (!anyNamed)
		{
			// No names to go by: five children are thumb to pinky, fewer are the fingers from the index on.
			int slot = unnamed.Count >= 5 ? 0 : 1;
			for (let child in unnamed)
			{
				if (slot >= 5)
					break;
				mFingers[slot++] = Chain(child);
			}
		}
		else
		{
			// A finger named only "finger" (POLYGON characters' three fingers in one) takes the first free slot from
			// the middle finger on.
			int slot = 2;
			for (let child in unnamed)
			{
				if (!Named(child.GameObject.Name, "finger", "digit"))
					continue;
				while (slot < 5 && mFingers[slot] != null)
					slot++;
				if (slot >= 5)
					break;
				mFingers[slot] = Chain(child);
			}
		}
		ReadRest();
		FindAxes(root);
	}

	static Finger Chain(Transform first)
	{
		let finger = new Finger();
		var bone = first;
		while (bone != null && finger.bones.Count < 4)
		{
			finger.bones.Add(bone);
			bone = Next(bone);
		}
		return finger;
	}

	/// The straight pose: from the saved text when it fits the bones found, else from the bones as they are (and saved).
	void ReadRest()
	{
		int count = 0;
		for (let finger in mFingers)
			count += finger != null ? finger.bones.Count : 0;
		List<float> numbers = scope .();
		for (let part in restPose.Split(' ', .RemoveEmptyEntries))
		{
			if (float.Parse(part) case .Ok(let number))
				numbers.Add(number);
		}
		let saved = numbers.Count == count * 4 && count > 0;
		if (!saved)
			restPose.Clear();
		int at = 0;
		for (let finger in mFingers)
		{
			if (finger == null)
				continue;
			finger.rest.Clear();
			for (let bone in finger.bones)
			{
				Quaternion rotation = bone.LocalRotation;
				if (saved)
				{
					rotation = Quaternion(numbers[at], numbers[at + 1], numbers[at + 2], numbers[at + 3]).Normalized;
					at += 4;
				}
				else
					restPose.AppendF("{}{} {} {} {}", restPose.IsEmpty ? "" : " ", rotation.x, rotation.y, rotation.z, rotation.w);
				finger.rest.Add(rotation);
			}
		}
	}

	/// Works out, from the straight pose alone, which way each bone turns to curl towards the palm and to spread.
	void FindAxes(Transform root)
	{
		// The palm faces square to the fan of the fingers. Which of the two sides is the palm cannot be told from
		// the fingers alone (a right hand palm down has the shape of a left hand palm up), so the hand's side
		// decides, from its name; with no side in the name the thumb does: it sits on the palm's side of the
		// fingers. Only the knuckles are used, since the "straight" pose may be an animation's half-curled hand.
		// With neither to go by, Flip Curl is there.
		Finger first = null, last = null;
		for (int i = 1; i < 5; i++)
		{
			if (mFingers[i] == null)
				continue;
			if (first == null)
				first = mFingers[i];
			last = mFingers[i];
		}
		if (first == null)
			return;
		Vector3 Reach(Finger finger)
		{
			// Where the finger's last bone is, in the hand's space, in the straight pose.
			var position = Vector3.Zero;
			var rotation = Quaternion.Identity;
			for (int i < finger.bones.Count)
			{
				position = position + rotation * finger.bones[i].LocalPosition;
				rotation = rotation * finger.rest[i];
			}
			return position;
		}
		let firstBase = first.bones[0].LocalPosition, lastBase = last.bones[0].LocalPosition;
		var along = (firstBase + lastBase) * 0.5f;
		if (along.LengthSquared < 1.0e-10f)
			along = (Reach(first) + Reach(last)) * 0.5f;
		along = along.LengthSquared > 1.0e-10f ? along.Normalized : Vector3.Forward;
		var across = lastBase - firstBase;
		across = across - along * Vector3.Dot(across, along);
		if (across.LengthSquared < 1.0e-10f)
			across = Vector3.Cross(Math.Abs(along.y) < 0.9f ? Vector3.Up : Vector3.Right, along);
		across = across.Normalized;
		// In the scene's left-handed space a left hand's palm is along x across (index to little finger); a right
		// hand's the other way.
		var palm = Vector3.Cross(along, across).Normalized;
		let side = BoneMap.Simplify(root.GameObject.Name, scope String());
		if (side == 1)
			palm = -palm;
		else if (side != -1 && mFingers[0] != null)
		{
			let thumbSide = Vector3.Dot(Reach(mFingers[0]) - firstBase, palm);
			if (thumbSide < 0)
				palm = -palm;
		}
		for (int f < 5)
		{
			let finger = mFingers[f];
			if (finger == null)
				continue;
			finger.curlAxis.Clear();
			var knuckle = finger.bones[0].LocalPosition;
			knuckle = knuckle - palm * Vector3.Dot(knuckle, palm);
			var toHand = Quaternion.Identity;
			for (int i < finger.bones.Count)
			{
				toHand = toHand * finger.rest[i];
				// The way the bone points: towards the next bone, or on from the last one.
				var direction = ((i + 1) < finger.bones.Count) ? toHand * finger.bones[i + 1].LocalPosition : (i > 0 ? toHand * (finger.rest[i].Conjugate * finger.bones[i].LocalPosition) : along);
				direction = direction.LengthSquared > 1.0e-10f ? direction.Normalized : along;
				// Turning about this axis swings the bone's direction towards the palm. A finger bends in one plane,
				// so its knuckle's direction from the wrist serves every bone of it: a bone already curled into the
				// palm points along the palm's normal, which gives no axis.
				var axis = Vector3.Cross(f == 0 || knuckle.LengthSquared < 1.0e-10f ? direction : knuckle, palm);
				if (f == 0)
				{
					// A thumb closes across the palm as much as into it.
					let sweep = Vector3.Dot(Vector3.Cross(palm, direction), across) >= 0 ? palm : -palm;
					axis = axis.Normalized * 0.6f + sweep * 0.8f;
				}
				axis = axis.LengthSquared > 1.0e-10f ? axis.Normalized : Vector3.Right;
				finger.curlAxis.Add(toHand.Conjugate * axis);
				if (i == 0)
				{
					finger.spreadAxis = toHand.Conjugate * palm;
					finger.spreadSign = Vector3.Dot(Vector3.Cross(palm, direction), across) >= 0 ? 1 : -1;
				}
			}
		}
	}

	protected override void CollectBones(List<Transform> bones)
	{
		let root = Hand;
		if (root != mBound || restPose.IsEmpty)
			Bind();
		for (let finger in mFingers)
		{
			if (finger != null)
				bones.AddRange(finger.bones);
		}
	}

	protected override void Solve()
	{
		float[7] wanted = .(thumb, index, middle, ring, pinky, spread, trigger);
		// Shapes blend while the game runs; in the editor the sliders are followed at once.
		let step = (Scene.IsPlaying && mHasNow && blendTime > 0) ? 1 - Math.Exp(-Time.DeltaTime * 4 / blendTime) : 1;
		for (int i < 7)
			mNow[i] = Mathf.Lerp(mNow[i], wanted[i], step);
		mHasNow = true;
		// How far each joint of a finger bends when it is fully curled, from the knuckle out.
		float[4] fingerBend = .(75, 100, 70, 30);
		float[4] thumbBend = .(30, 40, 60, 20);
		// Where each finger goes when they spread: index one way, ring and pinky the other.
		float[5] fan = .(-1.2f, -1, -0.3f, 0.4f, 1);
		for (int f < 5)
		{
			let finger = mFingers[f];
			if (finger == null)
				continue;
			var curl = mNow[f];
			if (f == 1)
				curl = Mathf.Clamp01(curl + mNow[6] * 0.25f);
			let flipped = flipCurl != (f == 0 && flipThumb);
			for (int i < finger.bones.Count)
			{
				let bone = finger.bones[i];
				if (bone.GameObject.IsDestroyed)
					continue;
				var rotation = finger.rest[i];
				if (i == 0)
					rotation = rotation * Quaternion.AngleAxis(mNow[5] * 12 * fan[f] * finger.spreadSign, finger.spreadAxis);
				let degrees = (f == 0 ? thumbBend[i] : fingerBend[i]) * curl * (flipped ? -1 : 1);
				bone.LocalRotation = (rotation * Quaternion.AngleAxis(degrees, finger.curlAxis[i])).Normalized;
			}
		}
	}
}
