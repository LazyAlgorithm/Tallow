using System;
using System.Collections;

namespace Tallow;

/// The rigger's templates (docs/rigging.md): the markers each puts on a model, a first guess at where they go from
/// the model's shape, and the skeleton built from them.
///
/// Humanoid uses Mixamo's markers (chin, wrists, elbows, knees, groin) and bone names (Hips, Spine, LeftArm,
/// LeftHandIndex1...), so Mixamo's animations and the engine's humanoid clips play on it. Quadruped's markers are the
/// nose, the base of the neck, the base and tip of the tail, the paws, the front elbows and the back hocks (heels),
/// and the ear tips; its root bone is called Root, so it is not taken for a humanoid.
static class RigTemplates
{
	static readonly StringView[?] HumanoidMarkers = .("Chin", "Groin", "Left Wrist", "Right Wrist", "Left Elbow", "Right Elbow", "Left Knee", "Right Knee",
		"Left Thumb", "Left Index", "Left Middle", "Left Ring", "Left Pinky", "Right Thumb", "Right Index", "Right Middle", "Right Ring", "Right Pinky");
	/// The fingers (Mixamo's names), thumb first; each has a marker at its tip ("Left Thumb"...).
	public static readonly StringView[5] Fingers = .("Thumb", "Index", "Middle", "Ring", "Pinky");

	/// Which finger a marker is the tip of (0 the thumb ... 4 the little finger), or -1.
	public static int FingerOf(StringView marker)
	{
		for (int f < 5)
		{
			if (marker.EndsWith(Fingers[f]) && (marker.StartsWith("Left ") || marker.StartsWith("Right ")))
				return f;
		}
		return -1;
	}

	/// How many fingers (from the thumb) the rig's settings give each hand: 5, 2 (thumb and mitten) or 0.
	public static int FingerCount(Rig rig) => rig.settings.fingers >= 5 ? 5 : (rig.settings.fingers >= 2 ? 2 : 0);
	static readonly StringView[?] QuadrupedMarkers = .("Nose", "Head", "Neck", "Tail Base", "Tail Tip", "Left Front Paw", "Right Front Paw", "Left Elbow", "Right Elbow",
		"Left Back Paw", "Right Back Paw", "Left Hock", "Right Hock", "Left Ear Tip", "Right Ear Tip");

	/// What a marker is for, shown beside it.
	public static StringView Hint(StringView marker)
	{
		switch (marker)
		{
		case "Chin": return "The point of the chin.";
		case "Groin": return "Where the legs meet.";
		case "Nose": return "The tip of the nose (or beak, or snout).";
		case "Neck": return "The base of the neck, above the front legs.";
		case "Head": return "Where the neck meets the skull, under the ears: the head turns about this point.";
		case "Tail Base": return "Where the tail leaves the body (the back of the hips).";
		case "Tail Tip": return "The end of the tail.";
		}
		switch (FingerOf(marker))
		{
		case 0: return "The tip of the thumb.";
		case 1: return "The tip of the first finger (the mitten's tip, for a hand with thumb and mitten only).";
		case 2: return "The tip of the middle finger.";
		case 3: return "The tip of the ring finger.";
		case 4: return "The tip of the little finger.";
		default:
		}
		if (marker.EndsWith("Wrist"))
			return "The middle of the wrist.";
		if (marker.EndsWith("Elbow"))
			return "The middle of the elbow.";
		if (marker.EndsWith("Knee"))
			return "The middle of the knee.";
		if (marker.EndsWith("Paw"))
			return "The tip of the paw, on the ground.";
		if (marker.EndsWith("Hock"))
			return "The heel of the back leg (the joint that points backwards).";
		if (marker.EndsWith("Ear Tip"))
			return "The tip of the ear.";
		return "";
	}

	/// Gives the rig its template's markers (where they were, or all at the model's middle).
	public static void AddMarkers(Rig rig)
	{
		rig.markers.Clear();
		Span<StringView> names = default;
		switch (rig.template)
		{
		case .Humanoid: names = HumanoidMarkers;
		case .Quadruped: names = QuadrupedMarkers;
		case .Custom:
		}
		for (let name in names)
		{
			RigMarker marker = default;
			marker.name = name;
			marker.position = rig.bounds.Center;
			marker.mirror = -1;
			marker.optional = name.EndsWith("Ear Tip");
			rig.markers.Add(marker);
		}
		for (int i < rig.markers.Count)
		{
			let name = rig.markers[i].name;
			let other = name.StartsWith("Left ") ? scope $"Right {name.Substring(5)}" : (name.StartsWith("Right ") ? scope $"Left {name.Substring(6)}" : null);
			if (other != null)
				rig.markers[i].mirror = (int32)rig.FindMarker(other);
		}
	}

	/// Whether a marker is used with the rig's settings (ears only with ears on, fingers as many as there are).
	public static bool Used(Rig rig, RigMarker marker)
	{
		let finger = FingerOf(marker.name);
		if (finger >= 0 && rig.template == .Humanoid)
			return finger < FingerCount(rig);
		return !marker.optional || rig.settings.ears;
	}

	// ---- the model's shape ----

	/// The middle of the vertices whose height is between `from` and `to` (shares of the model's height), on one side
	/// (-1 left, 1 right, 0 both) of a line `middle` across. The middle of the model when there are none.
	static Vector3 Slice(Rig rig, float from, float to, int side = 0, float middle = 0)
	{
		let y0 = rig.bounds.min.y;
		let h = Math.Max(rig.bounds.max.y - y0, 1e-6f);
		let right = rig.Right;
		var sum = Vector3.Zero;
		var count = 0;
		for (let p in rig.positions)
		{
			let t = (p.y - y0) / h;
			if (t < from || t > to)
				continue;
			let lateral = Vector3.Dot(p, right) - middle;
			if ((side < 0 && lateral > 0) || (side > 0 && lateral < 0))
				continue;
			sum = sum + p;
			count++;
		}
		return count > 0 ? sum / count : rig.bounds.Center;
	}

	/// Which way a humanoid faces, guessed from its feet (toes point forward of the shins): one of ±X, ±Z.
	public static Vector3 GuessHumanoidFacing(Rig rig)
	{
		let feet = Slice(rig, 0, 0.04f);
		let shins = Slice(rig, 0.1f, 0.22f);
		let d = feet - shins;
		if (Math.Max(Math.Abs(d.x), Math.Abs(d.z)) < (rig.bounds.max.y - rig.bounds.min.y) * 0.005f)
			return .(0, 0, -1);
		return Math.Abs(d.x) > Math.Abs(d.z) ? Vector3(Math.Sign(d.x), 0, 0) : Vector3(0, 0, Math.Sign(d.z));
	}

	/// What a still model probably is: a four-legged animal when it is a good deal longer than it is tall (a person,
	/// even with arms out, is about as wide as tall), else a person.
	public static RigTemplate GuessTemplate(Rig rig)
	{
		let size = rig.bounds.Size;
		return Math.Max(size.x, size.z) > size.y * 1.15f ? .Quadruped : .Humanoid;
	}

	/// The fingertip markers, from the hands' shape beyond the wrist markers (with the arms out, palms down, the thumb
	/// to the front): the thumb's tip is the point sticking out furthest to the front, and the other four are the
	/// farthest points of four strips across the end of the hand, from the front (the first finger) to the back.
	public static void GuessFingers(Rig rig)
	{
		let h = Math.Max(rig.bounds.Size.y, 1e-3f);
		for (let side in StringView[?]("Left", "Right"))
		{
			let wristIndex = rig.FindMarker(scope $"{side} Wrist");
			let elbowIndex = rig.FindMarker(scope $"{side} Elbow");
			if (wristIndex < 0 || elbowIndex < 0)
				continue;
			let wrist = rig.markers[wristIndex].position;
			var armDir = wrist - rig.markers[elbowIndex].position;
			armDir = armDir.LengthSquared > 1e-10f ? armDir.Normalized : Vector3(0, -1, 0);
			// Across the hand, towards the thumb: the way the model faces, square to the arm.
			var across = rig.facing - armDir * Vector3.Dot(rig.facing, armDir);
			across = across.LengthSquared > 1e-6f ? across.Normalized : Vector3.Cross(armDir, .(0, 1, 0)).Normalized;
			// The hand: beyond the wrist, near the arm's line.
			let hand = scope List<Vector3>();
			var handLength = 0.0f;
			for (let p in rig.positions)
			{
				let along = Vector3.Dot(p - wrist, armDir);
				if (along < 0)
					continue;
				let off = (p - wrist) - armDir * along;
				if (off.Length > 0.12f * h || along > 0.2f * h)
					continue;
				hand.Add(p);
				handLength = Math.Max(handLength, along);
			}
			// The middle of the points near one (the tip of a finger, not one corner of it).
			Vector3 Around(Vector3 point)
			{
				var sum = Vector3.Zero;
				var count = 0;
				for (let p in hand)
				{
					if ((p - point).Length < 0.008f * h)
					{
						sum = sum + p;
						count++;
					}
				}
				return count > 0 ? sum / count : point;
			}
			Vector3[5] tips = default;
			if (hand.Count < 8 || handLength < 0.02f * h)
			{
				// No hand to measure: the usual shape of one.
				let length = 0.1f * h;
				tips[0] = wrist + armDir * (0.45f * length) + across * (0.35f * length);
				for (int f = 1; f < 5; f++)
					tips[f] = wrist + armDir * ((f == 2 ? 1.0f : (f == 4 ? 0.8f : 0.92f)) * length) + across * ((2.5f - f) * 0.12f * length);
			}
			else
			{
				// The thumb: furthest to the front, short of the fingertips.
				var best = -float.MaxValue;
				for (let p in hand)
				{
					let along = Vector3.Dot(p - wrist, armDir);
					if (along < 0.1f * handLength || along > 0.75f * handLength)
						continue;
					let a = Vector3.Dot(p - wrist, across) + 0.25f * along;
					if (a > best)
					{
						best = a;
						tips[0] = p;
					}
				}
				tips[0] = Around(tips[0]);
				// The four fingers: strips across the end of the hand.
				var low = float.MaxValue;
				var high = -float.MaxValue;
				for (let p in hand)
				{
					if (Vector3.Dot(p - wrist, armDir) < 0.6f * handLength)
						continue;
					let a = Vector3.Dot(p - wrist, across);
					low = Math.Min(low, a);
					high = Math.Max(high, a);
				}
				let width = Math.Max(high - low, 1e-5f);
				for (int f = 1; f < 5; f++)
				{
					// The first finger's strip is at the front (highest across).
					let stripHigh = high - (f - 1) * width / 4;
					let stripLow = stripHigh - width / 4;
					var farthest = -float.MaxValue;
					tips[f] = wrist + armDir * handLength;
					for (let p in hand)
					{
						let a = Vector3.Dot(p - wrist, across);
						if (a < stripLow || a > stripHigh)
							continue;
						let along = Vector3.Dot(p - wrist, armDir);
						if (along > farthest)
						{
							farthest = along;
							tips[f] = p;
						}
					}
					tips[f] = Around(tips[f]);
				}
			}
			for (int f < 5)
				Put(rig, scope $"{side} {Fingers[f]}" , tips[f]);
		}
	}

	/// Where an animal's head joins its neck, from its other markers: under the ears (the back of the skull is between
	/// them), measured along the body; without ears, part way from the neck to the nose.
	public static Vector3 GuessHead(Rig rig)
	{
		Vector3 M(StringView name)
		{
			let i = rig.FindMarker(name);
			return i >= 0 ? rig.markers[i].position : rig.bounds.Center;
		}
		let nose = M("Nose");
		let neck = M("Neck");
		let toNose = nose - neck;
		let flatToNose = Vector3.Dot(toNose, rig.facing);
		var t = 0.55f;
		if (rig.settings.ears && Math.Abs(flatToNose) > 1e-6f)
		{
			let ears = (M("Left Ear Tip") + M("Right Ear Tip")) * 0.5f;
			t = Math.Clamp(Vector3.Dot(ears - neck, rig.facing) / flatToNose, 0.15f, 0.85f);
		}
		return neck + toNose * t;
	}

	/// Which way a quadruped faces: along its longer side, towards -Z or -X (glTF's front) until turned round.
	public static Vector3 GuessQuadrupedFacing(Rig rig)
	{
		let size = rig.bounds.Size;
		return size.x > size.z ? Vector3(-1, 0, 0) : Vector3(0, 0, -1);
	}

	static void Put(Rig rig, StringView name, Vector3 position)
	{
		let i = rig.FindMarker(name);
		if (i >= 0)
			rig.markers[i].position = position;
	}

	/// A first guess at every marker from the model's shape, each put in the middle of the body from the front. The
	/// rig's facing is guessed too.
	public static void GuessMarkers(Rig rig)
	{
		AddMarkers(rig);
		let y0 = rig.bounds.min.y;
		let h = Math.Max(rig.bounds.max.y - y0, 1e-6f);
		let up = Vector3(0, 1, 0);
		switch (rig.template)
		{
		case .Humanoid:
			rig.facing = GuessHumanoidFacing(rig);
			let right = rig.Right;
			let torso = Slice(rig, 0.45f, 0.62f);
			let middle = Vector3.Dot(torso, right);
			let chin = Slice(rig, 0.84f, 0.89f);
			Put(rig, "Chin", .(chin.x, y0 + 0.865f * h, chin.z));
			let groin = Slice(rig, 0.44f, 0.52f);
			Put(rig, "Groin", .(groin.x, y0 + 0.48f * h, groin.z));
			for (let side in int[?](-1, 1))
			{
				let label = side < 0 ? "Left" : "Right";
				let knee = Slice(rig, 0.25f, 0.31f, side, middle);
				Put(rig, scope $"{label} Knee" , .(knee.x, y0 + 0.28f * h, knee.z));
				// The hand: the vertex furthest out on that side, above the legs.
				var tip = torso;
				var furthest = 0.0f;
				for (let p in rig.positions)
				{
					if (p.y < y0 + 0.35f * h || p.y > y0 + 0.95f * h)
						continue;
					let lateral = (Vector3.Dot(p, right) - middle) * side;
					if (lateral > furthest)
					{
						furthest = lateral;
						tip = p;
					}
				}
				let shoulder = torso + right * (side * 0.11f * h);
				let shoulderPoint = Vector3(shoulder.x, y0 + 0.81f * h, shoulder.z);
				let toShoulder = (shoulderPoint - tip).Normalized;
				// The wrist: the narrowest part of the arm between the hand and the forearm, from 5% to 14% of the
				// height in from the fingertips (where it is, a hand's length varies with how the fingers lie).
				var wristDistance = 0.09f * h;
				{
					const int Slices = 18;
					let nearest = 0.05f * h;
					let width = (0.14f * h - nearest) / Slices;
					var thinnest = float.MaxValue;
					for (int i < Slices)
					{
						let d = nearest + (i + 0.5f) * width;
						var lowY = float.MaxValue;
						var highY = -float.MaxValue;
						var lowF = float.MaxValue;
						var highF = -float.MaxValue;
						var count = 0;
						for (let p in rig.positions)
						{
							let along = Vector3.Dot(p - tip, toShoulder);
							if (along < d - width * 0.5f || along > d + width * 0.5f)
								continue;
							// Only the arm: near the line from the fingertips to the shoulder.
							let off = (p - tip) - toShoulder * along;
							if (off.Length > 0.08f * h)
								continue;
							let f = Vector3.Dot(p, rig.facing);
							lowY = Math.Min(lowY, p.y);
							highY = Math.Max(highY, p.y);
							lowF = Math.Min(lowF, f);
							highF = Math.Max(highF, f);
							count++;
						}
						if (count < 3)
							continue;
						let thickness = (highY - lowY) + (highF - lowF);
						if (thickness < thinnest)
						{
							thinnest = thickness;
							wristDistance = d;
						}
					}
				}
				let wrist = tip + toShoulder * wristDistance;
				Put(rig, scope $"{label} Wrist" , wrist);
				Put(rig, scope $"{label} Elbow" , Vector3.Lerp(shoulderPoint, wrist, 0.5f));
			}
			GuessFingers(rig);
		case .Quadruped:
			rig.facing = GuessQuadrupedFacing(rig);
			let forward = rig.facing;
			let right = rig.Right;
			var back = float.MaxValue, front = -float.MaxValue;
			var nose = rig.bounds.Center, tailTip = rig.bounds.Center;
			for (let p in rig.positions)
			{
				let s = Vector3.Dot(p, forward);
				if (s > front)
				{
					front = s;
					nose = p;
				}
				if (s < back)
				{
					back = s;
					tailTip = p;
				}
			}
			let length = Math.Max(front - back, 1e-6f);
			let middle = Vector3.Dot(rig.bounds.Center, right);
			// The nose: the middle of the snout's very front (not one corner of it).
			{
				var sum = Vector3.Zero;
				var count = 0;
				for (let p in rig.positions)
				{
					if (Vector3.Dot(p, forward) >= front - 0.015f * length)
					{
						sum = sum + p;
						count++;
					}
				}
				if (count > 0)
					nose = sum / count + forward * (front - Vector3.Dot(sum / count, forward));
			}
			// The middle of the vertices in a stretch of the body (shares of its length from the back), above a height.
			Vector3 Stretch(float from, float to, float above, int side = 0)
			{
				var sum = Vector3.Zero;
				var count = 0;
				for (let p in rig.positions)
				{
					let s = (Vector3.Dot(p, forward) - back) / length;
					if (s < from || s > to || p.y < y0 + above * h)
						continue;
					let lateral = Vector3.Dot(p, right) - middle;
					if ((side < 0 && lateral > 0) || (side > 0 && lateral < 0))
						continue;
					sum = sum + p;
					count++;
				}
				return count > 0 ? sum / count : rig.bounds.Center;
			}
			Put(rig, "Nose", nose);
			// Where the legs stand along the body: the lowest vertices at each end.
			float FeetAt(bool atFront)
			{
				var sum = 0.0f;
				var count = 0;
				for (let p in rig.positions)
				{
					let f = (Vector3.Dot(p, forward) - back) / length;
					if (p.y > y0 + 0.06f * h || (atFront ? f < 0.5f : f > 0.5f))
						continue;
					sum += Vector3.Dot(p, forward);
					count++;
				}
				return count > 0 ? sum / count : back + length * (atFront ? 0.75f : 0.25f);
			}
			let frontFeet = FeetAt(true);
			let backFeet = FeetAt(false);
			// The body between the legs: its underside (the belly) and top (the back), and so its thickness.
			var belly = float.MaxValue;
			var backTop = -float.MaxValue;
			for (let p in rig.positions)
			{
				let f = Vector3.Dot(p, forward);
				let between = (f - backFeet) / Math.Max(frontFeet - backFeet, 1e-6f);
				if (between < 0.35f || between > 0.65f)
					continue;
				belly = Math.Min(belly, p.y);
				backTop = Math.Max(backTop, p.y);
			}
			if (belly > backTop)
			{
				belly = y0 + 0.4f * h;
				backTop = y0 + 0.8f * h;
			}
			let thickness = Math.Max(backTop - belly, 1e-4f);
			// The neck's base: above the front legs, in the upper half of the body there (not the head above it).
			var neck = Stretch(0.72f, 0.78f, 0.5f);
			{
				var sum = Vector3.Zero;
				var count = 0;
				var top = -float.MaxValue;
				for (let p in rig.positions)
				{
					if (Math.Abs(Vector3.Dot(p, forward) - frontFeet) > 0.05f * length || p.y < belly || p.y > backTop + 0.3f * thickness)
						continue;
					sum = sum + p;
					count++;
					top = Math.Max(top, p.y);
				}
				if (count > 0)
				{
					let c = sum / count;
					neck = Vector3(c.x, Math.Lerp(c.y, top, 0.45f), c.z) + forward * (frontFeet + 0.02f * length - Vector3.Dot(c, forward));
				}
			}
			Put(rig, "Neck", neck);
			// The tail's base: going forward from the rear, the first slice reaching down near the belly is the rump
			// (behind it is only tail, which is thin, or high when it curls up).
			var tailBase = Stretch(0.12f, 0.2f, 0.45f);
			var rumpAt = back;
			{
				const int Slices = 40;
				let step = Math.Max(frontFeet - back, 1e-6f) / Slices;
				for (int i < Slices)
				{
					let at = back + (i + 0.5f) * step;
					var low = float.MaxValue;
					var high = -float.MaxValue;
					for (let p in rig.positions)
					{
						if (Math.Abs(Vector3.Dot(p, forward) - at) > step * 0.5f || p.y < belly)
							continue;
						low = Math.Min(low, p.y);
						high = Math.Max(high, p.y);
					}
					if (low < belly + 0.5f * thickness && high > low)
					{
						rumpAt = at - step * 0.5f;
						let top = Math.Min(high, backTop);
						tailBase = Vector3(rig.bounds.Center.x, top - 0.2f * thickness, rig.bounds.Center.z) + right * (middle - Vector3.Dot(rig.bounds.Center, right));
						tailBase = tailBase + forward * (at - Vector3.Dot(tailBase, forward));
						break;
					}
				}
			}
			Put(rig, "Tail Base", tailBase);
			// The tail's tip: the point of the tail (behind the rump or above the back) farthest from its base, so a tail
			// that curls up is followed to its end.
			{
				var farthest = 0.0f;
				for (let p in rig.positions)
				{
					if (Vector3.Dot(p, forward) > Vector3.Dot(tailBase, forward) + 0.05f * length || p.y < belly)
						continue;
					// Only the tail: behind the rump, or above the back (a tail curled over it).
					if (Vector3.Dot(p, forward) > rumpAt && p.y < backTop + 0.05f * thickness)
						continue;
					let d = (p - tailBase).LengthSquared;
					if (d > farthest)
					{
						farthest = d;
						tailTip = p;
					}
				}
				// The middle of the tail's end, not one corner of it.
				var sum = Vector3.Zero;
				var count = 0;
				for (let p in rig.positions)
				{
					if ((p - tailTip).Length < 0.03f * length)
					{
						sum = sum + p;
						count++;
					}
				}
				if (count > 0)
					tailTip = sum / count;
			}
			Put(rig, "Tail Tip", tailTip);
			let bodyHeight = Math.Max(neck.y - y0, 1e-6f);
			for (let side in int[?](-1, 1))
			{
				let label = side < 0 ? "Left" : "Right";
				let frontPaw = Stretch(0.5f, 1, -1, side);
				// The feet: the lowest few vertices at each end.
				Vector3 Foot(bool front)
				{
					var sum = Vector3.Zero;
					var count = 0;
					for (let p in rig.positions)
					{
						let s = (Vector3.Dot(p, forward) - back) / length;
						if (p.y > y0 + 0.06f * h || (front ? s < 0.5f : s > 0.5f))
							continue;
						let lateral = Vector3.Dot(p, right) - middle;
						if ((side < 0 && lateral > 0) || (side > 0 && lateral < 0))
							continue;
						sum = sum + p;
						count++;
					}
					return count > 0 ? sum / count : frontPaw;
				}
				let paw = Foot(true) + forward * (0.03f * length);
				Put(rig, scope $"{label} Front Paw" , Vector3(paw.x, y0, paw.z) + up * (0.01f * h));
				Put(rig, scope $"{label} Elbow" , Vector3(paw.x, y0 + 0.45f * bodyHeight, paw.z) - forward * (0.04f * length));
				let backPaw = Foot(false) + forward * (0.03f * length);
				Put(rig, scope $"{label} Back Paw" , Vector3(backPaw.x, y0, backPaw.z) + up * (0.01f * h));
				Put(rig, scope $"{label} Hock" , Vector3(backPaw.x, y0 + 0.28f * bodyHeight, backPaw.z) - forward * (0.07f * length));
				// The ear tip: the highest point on that side of the head.
				var top = nose;
				var highest = -float.MaxValue;
				for (let p in rig.positions)
				{
					let s = (Vector3.Dot(p, forward) - back) / length;
					let lateral = (Vector3.Dot(p, right) - middle) * side;
					if (s > 0.7f && lateral > 0.01f * length && p.y > highest)
					{
						highest = p.y;
						top = p;
					}
				}
				Put(rig, scope $"{label} Ear Tip" , top);
			}
			Put(rig, "Head", GuessHead(rig));
		case .Custom:
		}
	}

	/// Puts a point in the middle of the body as seen from the front (along the facing), as Mixamo's markers are.
	public static Vector3 CentreFromFront(Rig rig, RigRays rays, Vector3 point) => rays.Centre(point, rig.facing, Math.Max(rig.bounds.Size.Length, 1e-3f) * 2);

	/// Every marker put in the middle of the body from the front, after GuessMarkers, except those on the surface
	/// (paws, nose, tail tip, ear tips).
	public static void CentreMarkers(Rig rig, RigRays rays)
	{
		for (var marker in ref rig.markers)
		{
			if (OnSurface(marker.name))
				continue;
			// An animal's body runs from front to back, so its middle markers (head, neck, tail base) are centred up
			// and down: centring them from the front would slide them along the body.
			if (marker.name == "Head" || (rig.template == .Quadruped && marker.mirror < 0))
				marker.position = rays.Centre(marker.position, .(0, 1, 0), Math.Max(rig.bounds.Size.Length, 1e-3f) * 2);
			else
				marker.position = CentreFromFront(rig, rays, marker.position);
		}
	}

	/// Markers that go on the model's surface, not inside it.
	public static bool OnSurface(StringView marker) => marker == "Nose" || marker == "Tail Tip" || marker.EndsWith("Paw") || marker.EndsWith("Ear Tip") || FingerOf(marker) >= 0;

	// ---- building the skeleton ----

	/// Replaces the rig's bones with the template's, built from where its markers are (and its settings). Weights are
	/// cleared (make them again). Custom rigs keep their bones (a Root is made when there are none). With `rays`, the
	/// joints no marker gives (an animal's knees, wrists and paw joints) are put in the middle of the leg.
	public static void Build(Rig rig, RigRays rays = null)
	{
		if (rig.template == .Custom)
		{
			if (rig.bones.IsEmpty)
			{
				let b = rig.bounds;
				let bottom = Vector3(b.Center.x, b.min.y, b.Center.z);
				rig.AddBone("Root", -1, bottom, bottom + Vector3(0, Math.Max(b.Size.y, 0.1f) * 0.5f, 0));
			}
			rig.ResetPose();
			return;
		}
		ClearAndDeleteItems!(rig.bones);
		rig.weights.Clear();
		Vector3 M(StringView name)
		{
			let i = rig.FindMarker(name);
			return i >= 0 ? rig.markers[i].position : rig.bounds.Center;
		}
		let up = Vector3(0, 1, 0);
		let forward = rig.facing;
		let right = rig.Right;
		let h = Math.Max(rig.bounds.Size.y, 1e-3f);
		let y0 = rig.bounds.min.y;
		// A joint put in the middle of the leg it is in, from front to back.
		Vector3 InLeg(Vector3 point) => rays != null ? rays.Centre(point, forward, Math.Max(rig.bounds.Size.Length, 1e-3f) * 2) : point;
		// Adds a bone ending where its first child starts (or at `tail`).
		int Bone(StringView name, int parent, Vector3 head, Vector3 tail, bool deform = true) => rig.AddBone(name, parent, head, tail, deform);
		// A chain of bones from one point to another, `count` long, named name1, name2...; returns the last.
		int Chain(StringView name, int parent, Vector3 from, Vector3 to, int count, bool numberFirst = true)
		{
			var last = parent;
			for (int i < count)
			{
				let a = Vector3.Lerp(from, to, (float)i / count);
				let b = Vector3.Lerp(from, to, (float)(i + 1) / count);
				let label = (i == 0 && !numberFirst) ? scope String(name) : scope $"{name}{i + 1}";
				last = Bone(label, last, a, b);
			}
			return last;
		}

		switch (rig.template)
		{
		case .Humanoid:
			let chin = M("Chin");
			let groin = M("Groin");
			let hips = groin + up * (0.04f * h);
			let neck = Vector3(chin.x, chin.y - 0.07f * h, chin.z) - forward * (0.015f * h);
			let head = Vector3(chin.x, chin.y + 0.01f * h, chin.z) - forward * (0.02f * h);
			let top = Vector3(head.x, Math.Max(rig.bounds.max.y, head.y + 0.05f * h), head.z);
			let hipsBone = Bone("Hips", -1, hips, hips + up * (0.05f * h));
			// Spine, Spine1, Spine2 (Mixamo's names) between the hips and the neck.
			var spineCount = Math.Clamp(rig.settings.spine, 1, 3);
			var chest = hipsBone;
			for (int i < spineCount)
			{
				let a = Vector3.Lerp(hips, neck, (float)(i + 1) / (spineCount + 1));
				let label = i == 0 ? "Spine" : scope:: $"Spine{i}";
				chest = Bone(label, chest, a, Vector3.Lerp(hips, neck, (float)(i + 2) / (spineCount + 1)));
			}
			let neckBone = Bone("Neck", chest, neck, head);
			let headBone = Bone("Head", neckBone, head, top);
			Bone("HeadTop_End", headBone, top, top + up * (0.03f * h), false);
			for (let side in int[?](-1, 1))
			{
				let label = side < 0 ? "Left" : "Right";
				let wrist = M(scope $"{label} Wrist");
				let elbow = M(scope $"{label} Elbow");
				let forearm = (wrist - elbow).Length;
				let toNeck = neck - elbow;
				let arm = elbow + toNeck.Normalized * Math.Min(forearm, toNeck.Length * 0.8f);
				let shoulder = Vector3.Lerp(neck, arm, 0.2f) - up * (0.01f * h);
				let shoulderBone = Bone(scope $"{label}Shoulder" , chest, shoulder, arm);
				let armBone = Bone(scope $"{label}Arm" , shoulderBone, arm, elbow);
				let foreArmBone = Bone(scope $"{label}ForeArm" , armBone, elbow, wrist);
				// The hand points to its middle finger's tip (or the first finger's), and reaches its knuckles.
				let tipName = FingerCount(rig) >= 5 ? scope $"{label} Middle" : scope $"{label} Index";
				let reach = (FingerCount(rig) >= 2 && rig.FindMarker(tipName) >= 0) ? M(tipName) - wrist : (wrist - elbow).Normalized * (0.1f * h);
				let handDir = reach.LengthSquared > 1e-10f ? reach.Normalized : (wrist - elbow).Normalized;
				let handLength = Math.Max(reach.Length, 0.02f * h);
				let handBone = Bone(scope $"{label}Hand" , foreArmBone, wrist, wrist + handDir * (0.45f * handLength));
				// Each finger: three bones from its knuckle to its tip marker, then an end.
				for (int f < FingerCount(rig))
				{
					let name = Fingers[f];
					let marker = scope $"{label} {name}";
					let tip = rig.FindMarker(marker) >= 0 ? M(marker) : wrist + handDir * handLength;
					// The thumb's knuckle is near the wrist; the others' a little short of halfway to their tips.
					let knuckle = Vector3.Lerp(wrist, tip, f == 0 ? 0.2f : 0.45f);
					let finger = Chain(scope $"{label}Hand{name}" , handBone, knuckle, tip, 3);
					let dir = (tip - knuckle).LengthSquared > 1e-10f ? (tip - knuckle).Normalized : handDir;
					Bone(scope $"{label}Hand{name}4" , finger, tip, tip + dir * (0.06f * handLength), false);
				}
				let knee = M(scope $"{label} Knee");
				// The hip joint: level with the hips, out to the side as far as the knee is.
				let thigh = hips + right * Vector3.Dot(knee - hips, right) - up * (0.05f * h);
				let ankle = Vector3(knee.x, y0 + 0.045f * h, knee.z) - forward * (0.01f * h);
				let toe = Vector3(ankle.x, y0 + 0.012f * h, ankle.z) + forward * (0.09f * h);
				let toeEnd = Vector3(ankle.x, y0 + 0.01f * h, ankle.z) + forward * (0.15f * h);
				let upLegBone = Bone(scope $"{label}UpLeg" , hipsBone, thigh, knee);
				let legBone = Bone(scope $"{label}Leg" , upLegBone, knee, ankle);
				let footBone = Bone(scope $"{label}Foot" , legBone, ankle, toe);
				let toeBone = Bone(scope $"{label}ToeBase" , footBone, toe, toeEnd);
				Bone(scope $"{label}Toe_End" , toeBone, toeEnd, toeEnd + forward * (0.02f * h), false);
			}
		case .Quadruped:
			let nose = M("Nose");
			let neckBase = M("Neck");
			let tailBase = M("Tail Base");
			let tailTip = M("Tail Tip");
			let bodyLength = Math.Max((neckBase - tailBase).Length, 1e-3f);
			let along = (neckBase - tailBase).Normalized;
			let rootPoint = tailBase + along * (0.1f * bodyLength) - up * (0.03f * bodyLength);
			let root = Bone("Root", -1, rootPoint, rootPoint + along * (0.2f * bodyLength));
			// The spine from the root to the chest, just behind the neck.
			let chestPoint = neckBase - along * (0.12f * bodyLength) - up * (0.04f * bodyLength);
			let spineCount = Math.Clamp(rig.settings.spine, 1, 6);
			var spine = root;
			for (int i < spineCount)
			{
				let a = Vector3.Lerp(rootPoint, chestPoint, (float)(i + 1) / (spineCount + 1));
				let b = Vector3.Lerp(rootPoint, chestPoint, (float)(i + 2) / (spineCount + 1));
				spine = Bone(scope $"Spine{i + 1}" , spine, a, b);
			}
			let chest = Bone("Chest", spine, chestPoint, neckBase);
			// The head's joint, where the neck meets the skull (its own marker), so a long snout or a nose moved far out
			// only makes the head bone longer, and the neck bones end at the head.
			let headPoint = rig.FindMarker("Head") >= 0 ? M("Head") : GuessHead(rig);
			let neckCount = Math.Clamp(rig.settings.neck, 1, 6);
			let neckEnd = Chain("Neck", chest, neckBase, headPoint, neckCount);
			let headBone = Bone("Head", neckEnd, headPoint, nose);
			let skull = (nose - headPoint).Length;
			// How deep the head is: the jaw hangs this far below the head bone (not more for a long snout).
			let headDepth = Math.Min(skull, 0.3f * bodyLength);
			Bone("HeadEnd", headBone, nose, nose + (nose - headPoint).Normalized * (0.1f * headDepth), false);
			if (rig.settings.jaw)
			{
				let jawStart = headPoint + (nose - headPoint) * 0.15f - up * (0.25f * headDepth);
				let jawEnd = Vector3.Lerp(headPoint, nose, 0.85f) - up * (0.3f * headDepth);
				let jaw = Bone("Jaw", headBone, jawStart, jawEnd);
				Bone("JawEnd", jaw, jawEnd, jawEnd + (jawEnd - jawStart) * 0.1f, false);
			}
			if (rig.settings.tail > 0)
			{
				let tail = Chain("Tail", root, tailBase, tailTip, Math.Clamp(rig.settings.tail, 1, 16));
				Bone("Tail_End", tail, tailTip, tailTip + (tailTip - tailBase).Normalized * (0.03f * bodyLength), false);
			}
			for (let side in int[?](-1, 1))
			{
				let s = side < 0 ? "L" : "R";
				let label = side < 0 ? "Left" : "Right";
				if (rig.settings.ears)
				{
					// The ear starts on top of the skull, under its tip, so it stays the ear's own length wherever the
					// nose is.
					let tip = M(scope $"{label} Ear Tip");
					let toTip = tip - headPoint;
					let earBase = headPoint + toTip * Math.Clamp(0.35f * headDepth / Math.Max(toTip.Length, 1e-6f), 0.2f, 0.6f);
					let ear = Chain(scope $"Ear_{s}" , headBone, earBase, tip, 2);
					Bone(scope $"Ear_{s}_End" , ear, tip, tip + (tip - earBase).Normalized * (0.05f * headDepth), false);
				}
				// Front leg: shoulder blade, upper arm, forearm, wrist, paw.
				let frontPaw = M(scope $"{label} Front Paw");
				let elbow = M(scope $"{label} Elbow");
				let legHeight = Math.Max(chestPoint.y - frontPaw.y, 1e-3f);
				let shoulder = Vector3(elbow.x, elbow.y + (chestPoint.y - elbow.y) * 0.7f, elbow.z) + forward * (0.08f * legHeight);
				let blade = Vector3.Lerp(chestPoint, shoulder, 0.35f) + up * (0.12f * legHeight);
				let pawLength = 0.1f * legHeight;
				let pawJoint = InLeg(Vector3(frontPaw.x, frontPaw.y + 0.06f * legHeight, frontPaw.z) - forward * pawLength);
				let wrist = InLeg(Vector3(pawJoint.x, frontPaw.y + 0.25f * legHeight, pawJoint.z) - forward * (0.02f * legHeight));
				let bladeBone = Bone(scope $"Scapula_{s}" , chest, blade, shoulder);
				let upperArm = Bone(scope $"UpperArm_{s}" , bladeBone, shoulder, elbow);
				let forearm = Bone(scope $"Forearm_{s}" , upperArm, elbow, wrist);
				let wristBone = Bone(scope $"Wrist_{s}" , forearm, wrist, pawJoint);
				let pawBone = Bone(scope $"FrontPaw_{s}" , wristBone, pawJoint, frontPaw);
				Bone(scope $"FrontPaw_{s}_End" , pawBone, frontPaw, frontPaw + forward * (0.03f * legHeight), false);
				// Back leg: thigh, shin (knee forward), hock (heel back), paw.
				let backPaw = M(scope $"{label} Back Paw");
				let hock = M(scope $"{label} Hock");
				let backHeight = Math.Max(rootPoint.y - backPaw.y, 1e-3f);
				let thighPoint = rootPoint + right * (Vector3.Dot(hock - rootPoint, right)) - up * (0.08f * backHeight);
				let knee = InLeg(Vector3.Lerp(thighPoint, hock, 0.5f) + forward * (0.22f * backHeight));
				let backPawJoint = InLeg(Vector3(backPaw.x, backPaw.y + 0.06f * backHeight, backPaw.z) - forward * (0.1f * backHeight));
				let thigh = Bone(scope $"Thigh_{s}" , root, thighPoint, knee);
				let shin = Bone(scope $"Shin_{s}" , thigh, knee, hock);
				let hockBone = Bone(scope $"Hock_{s}" , shin, hock, backPawJoint);
				let backPawBone = Bone(scope $"BackPaw_{s}" , hockBone, backPawJoint, backPaw);
				Bone(scope $"BackPaw_{s}_End" , backPawBone, backPaw, backPaw + forward * (0.03f * backHeight), false);
			}
		case .Custom:
		}
		rig.SortBones();
		rig.ResetPose();
	}
}
