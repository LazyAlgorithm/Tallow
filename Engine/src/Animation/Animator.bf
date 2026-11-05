using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Plays animation clips on the bones (child objects) below this object, blending smoothly when the clip changes.
/// A bone is any descendant GameObject; clips refer to bones by name.
[Component]
class Animator : Component
{
	/// Clip files separated by semicolons, e.g. "Animations/idle.tanim;Animations/walk.tanim".
	public String clips = new .() ~ delete _;
	/// Name of the clip to start with.
	public String defaultClip = new .("Idle") ~ delete _;
	public float speed = 1.0f;
	/// An Animator Controller (.tcontroller) made in the Animator window. With one set, the Animator runs its
	/// state machine: scripts set parameters, and transitions pick the clip. Without one, scripts call Play.
	public String controller = new .() ~ delete _;

	struct Bone
	{
		public Transform transform;
		/// The bone above it in mBones (-1 for a child of the Animator's own object). Bones come after their parents.
		public int32 parent;
		public Vector3 restPosition;
		public Quaternion restRotation;
		public Vector3 restScale;
	}

	// ---- controller state ----
	AnimatorController mController;
	int32 mControllerRevision = -1;
	List<float> mParameters = new .() ~ delete _;
	int32 mState = -1;
	float mStateTime;
	SkinnedMeshRenderer mSkinned;

	public AnimatorController Controller => mController;
	/// The state the controller is in, or "" without a controller.
	public StringView CurrentState => (mController != null && mState >= 0 && mState < mController.states.Count) ? (StringView)mController.states[mState].name : "";
	public int32 CurrentStateIndex => mState;
	/// Seconds spent in the current state, scaled by the state's speed.
	public float StateTime => mStateTime;
	/// How far through its clip the current state is: 0 at the start, 1 at the end, more than 1 once it has looped.
	public float NormalizedTime => (mController != null && mController.UsesLayers) ? NormalizedTimeOn(0) : mStateTime / Math.Max(StateLength(mState), 0.0001f);
	/// True while one state's clip is still fading into the next.
	public bool IsInTransition => (mController != null && mController.UsesLayers) ? (mLayers.Count > 0 && mLayers[0].previous >= 0 && mLayers[0].fade < mLayers[0].fadeDuration) : (mPrevious != null && mFade < mFadeDuration);

	float StateLength(int32 index)
	{
		if (mController == null || index < 0 || index >= mController.states.Count)
			return 1;
		let state = mController.states[index];
		let clip = FindClip(state.clip);
		if (clip != null)
			return clip.duration;
		if (mSkinned && mSkinned.Model != null)
		{
			let modelClip = mSkinned.Model.FindClip(state.clip);
			if (modelClip != null)
				return modelClip.duration;
		}
		return 1;
	}

	AnimationClip FindClip(StringView nameOrPath)
	{
		for (let clip in mClips)
		{
			if (clip.name == nameOrPath)
				return clip;
		}
		if (nameOrPath.EndsWith(".tanim"))
		{
			let clip = AnimationClip.Load(nameOrPath);
			if (clip != null && !mClips.Contains(clip))
				mClips.Add(clip);
			return clip;
		}
		return null;
	}

	void SyncController()
	{
		if (mController == null || mControllerRevision == mController.Revision)
			return;
		// The controller was edited (or has just been loaded): keep the values of parameters that still exist.
		mControllerRevision = mController.Revision;
		while (mParameters.Count < mController.parameters.Count)
			mParameters.Add(mController.parameters[mParameters.Count].defaultValue);
		while (mParameters.Count > mController.parameters.Count)
			mParameters.PopBack();
		if (mState >= mController.states.Count)
			mState = -1;
	}

	int32 Parameter(StringView name)
	{
		SyncController();
		return mController != null ? mController.FindParameter(name) : -1;
	}

	void SetParameter(int32 index, float value)
	{
		if (index < 0 || index >= mParameters.Count || mParameters[index] == value)
			return;
		mParameters[index] = value;
		NetworkSync.AnimatorChanged(this, 0, index, value);
	}

	/// Sets a number parameter of the controller. Unknown names are ignored. In a network session the value is
	/// shared with everyone when set on the server or by the player who owns the object.
	public void SetFloat(StringView name, float value) => SetParameter(Parameter(name), value);
	public void SetInteger(StringView name, int32 value) => SetParameter(Parameter(name), (float)value);
	public void SetBool(StringView name, bool value) => SetParameter(Parameter(name), value ? 1 : 0);
	/// Sets a trigger: it stays set until a transition uses it, then clears itself.
	public void SetTrigger(StringView name) => SetParameter(Parameter(name), 1);
	public void ResetTrigger(StringView name) => SetParameter(Parameter(name), 0);

	public float GetFloat(StringView name)
	{
		let index = Parameter(name);
		return index >= 0 && index < mParameters.Count ? mParameters[index] : 0;
	}

	public int32 GetInteger(StringView name) => (int32)Math.Round(GetFloat(name));
	public bool GetBool(StringView name) => GetFloat(name) != 0;
	/// A parameter's value by its position in the controller, for showing live values.
	public float GetParameter(int32 index) => index >= 0 && index < mParameters.Count ? mParameters[index] : 0;

	/// Applies a change that arrived from the network. kind 0: a parameter value. kind 1: enter a state. kind 2: a
	/// layer's weight.
	public void ApplyRemote(int32 kind, int32 index, float value)
	{
		SyncController();
		if (kind == 0 && index >= 0 && index < mParameters.Count)
			mParameters[index] = value;
		else if (kind == 1 && mController != null && index >= 0 && index < mController.states.Count)
		{
			if (mController.UsesLayers)
				EnterLayerState(index, Math.Clamp(value, 0, 10));
			else
				EnterState(index, Math.Clamp(value, 0, 10));
		}
		else if (kind == 2)
		{
			SyncLayers();
			if (index >= 0 && index < mLayers.Count)
				mLayers[index].weight = Mathf.Clamp01(value);
		}
	}

	// ---- layers and blend trees ----

	/// Where one layer is in its state machine.
	class LayerRun
	{
		public int32 state = -1;
		public float time;
		public int32 previous = -1;
		public float previousTime;
		public float fade;
		public float fadeDuration;
		public float weight = 1;
		public bool weightSet;
	}

	List<LayerRun> mLayers = new .() ~ DeleteContainerAndItems!(_);
	List<float> mWeights = new .() ~ delete _;
	Vector3[] mPosePosition ~ delete _;
	Quaternion[] mPoseRotation ~ delete _;
	Vector3[] mPoseScale ~ delete _;
	Vector3[] mLayerPosition ~ delete _;
	Quaternion[] mLayerRotation ~ delete _;
	Vector3[] mLayerScale ~ delete _;
	Vector3[] mZeroPosition ~ delete _;
	Quaternion[] mZeroRotation ~ delete _;
	Vector3[] mZeroScale ~ delete _;
	float[] mTrack ~ delete _;
	float[] mZeroTrack ~ delete _;
	bool[] mMasked ~ delete _;

	/// How many layers the controller has (1 without layers).
	public int32 LayerCount => mController != null ? (int32)mController.layers.Count : 1;

	void SyncLayers()
	{
		if (mController == null)
			return;
		while (mLayers.Count < mController.layers.Count)
			mLayers.Add(new LayerRun());
		while (mLayers.Count > mController.layers.Count)
			delete mLayers.PopBack();
		for (int i < mLayers.Count)
		{
			if (!mLayers[i].weightSet)
				mLayers[i].weight = mController.layers[i].weight;
		}
	}

	/// Sets how much of a layer is used, 0 to 1 (the Base Layer is always whole). In a network session the weight is
	/// shared when set on the server or by the player who owns the object.
	public void SetLayerWeight(int32 layer, float weight)
	{
		SyncLayers();
		if (layer <= 0 || layer >= mLayers.Count)
			return;
		let value = Mathf.Clamp01(weight);
		mLayers[layer].weightSet = true;
		if (mLayers[layer].weight == value)
			return;
		mLayers[layer].weight = value;
		NetworkSync.AnimatorChanged(this, 2, layer, value);
	}

	public void SetLayerWeight(StringView layer, float weight) => SetLayerWeight(mController != null ? mController.FindLayer(layer) : -1, weight);

	public float GetLayerWeight(int32 layer)
	{
		SyncLayers();
		return layer >= 0 && layer < mLayers.Count ? mLayers[layer].weight : 0;
	}

	/// The state a layer is in, or -1.
	public int32 StateIndexOn(int32 layer)
	{
		if (mController == null || !mController.UsesLayers)
			return layer == 0 ? mState : -1;
		return layer >= 0 && layer < mLayers.Count ? mLayers[layer].state : -1;
	}

	/// How far through its clip (or blend tree) a layer's state is, as NormalizedTime.
	public float NormalizedTimeOn(int32 layer)
	{
		if (mController == null || !mController.UsesLayers)
			return layer == 0 ? NormalizedTime : 0;
		if (layer < 0 || layer >= mLayers.Count || mLayers[layer].state < 0)
			return 0;
		return mLayers[layer].time / Math.Max(LayeredLength(mLayers[layer].state), 0.0001f);
	}

	/// The length of a clip by name: a .tanim file or clip, or a clip of the skinned model.
	float MotionLength(StringView name)
	{
		let clip = FindClip(name);
		if (clip != null)
			return clip.duration;
		if (mSkinned && mSkinned.Model != null)
		{
			let modelClip = mSkinned.Model.FindClip(name);
			if (modelClip != null)
				return modelClip.duration;
		}
		return 1;
	}

	/// How each of a state's clips is weighted now: one clip, or a blend tree by its parameters.
	void StateWeights(AnimatorController.State state, List<float> output)
	{
		output.Clear();
		if (state.blend == null)
		{
			output.Add(1);
			return;
		}
		let x = state.blend.parameterX >= 0 && state.blend.parameterX < mParameters.Count ? mParameters[state.blend.parameterX] : 0;
		let y = state.blend.parameterY >= 0 && state.blend.parameterY < mParameters.Count ? mParameters[state.blend.parameterY] : 0;
		state.blend.Weights(x, y, output);
	}

	/// A state's length: its clip's, or a blend tree's clips' by their weights now.
	float LayeredLength(int32 stateIndex)
	{
		let state = mController.states[stateIndex];
		if (state.blend == null)
			return MotionLength(state.clip);
		List<float> weights = scope .();
		StateWeights(state, weights);
		float length = 0;
		for (int i < weights.Count)
			length += weights[i] * MotionLength(state.blend.motions[i].clip);
		return Math.Max(length, 0.0001f);
	}

	/// One bone's pose in a clip at a time (seconds), as the bone's own local pose. False when the clip does not move
	/// that bone.
	bool SampleMotion(StringView clipName, AnimationClip clip, float time, bool loop, int boneIndex, out Vector3 position, out Quaternion rotation, out Vector3 scale)
	{
		let bone = mBones[boneIndex];
		position = bone.restPosition;
		rotation = bone.restRotation;
		scale = bone.restScale;
		if (clip != null)
		{
			let track = TrackOf(clip, boneIndex);
			if (track == null)
				return false;
			let t = loop ? (clip.duration > 0 ? time % clip.duration : 0) : Math.Min(time, clip.duration);
			Vector3 offset, grow;
			Quaternion turn;
			track.Sample(t, out offset, out turn, out grow);
			position = bone.restPosition + offset;
			rotation = (bone.restRotation * turn).Normalized;
			scale = .(bone.restScale.x * grow.x, bone.restScale.y * grow.y, bone.restScale.z * grow.z);
			return true;
		}
		// A clip of the rigged model, onto its bone objects (Expose Bones).
		if (mSkinned && mSkinned.Model != null && mSkinned.exposeBones)
		{
			let model = mSkinned.Model;
			let modelClip = model.FindClip(clipName);
			if (modelClip == null)
				return false;
			let joint = model.FindJoint(bone.transform.GameObject.Name);
			if (joint < 0)
				return false;
			Vector3 p, k;
			Quaternion q;
			model.SampleJoint(modelClip, time, loop, joint, out p, out q, out k);
			// The model's space is right-handed: mirrored in Z, as the renderer does.
			position = .(p.x, p.y, -p.z);
			rotation = .(-q.x, -q.y, q.z, q.w);
			scale = k;
			return true;
		}
		return false;
	}

	/// A state's pose at a time into the given arrays (each bone's weighted sum; track says how much of each bone
	/// the state moves).
	void SampleLayeredState(int32 stateIndex, float time, bool atStart, Vector3[] positions, Quaternion[] rotations, Vector3[] scales, float[] track)
	{
		let state = mController.states[stateIndex];
		List<float> weights = scope .();
		StateWeights(state, weights);
		let length = LayeredLength(stateIndex);
		// Every clip of a blend tree at the same point of its own length, so that feet stay in step.
		let phase = atStart ? 0 : (state.loop ? (time / length) % 1.0f : Math.Min(time / length, 1.0f));
		for (int b < mBones.Count)
		{
			positions[b] = .Zero;
			rotations[b] = .(0, 0, 0, 0);
			scales[b] = .Zero;
			track[b] = 0;
		}
		for (int m < weights.Count)
		{
			let weight = weights[m];
			if (weight <= 0.0001f)
				continue;
			let clipName = state.blend != null ? (StringView)state.blend.motions[m].clip : (StringView)state.clip;
			let clipTime = phase * MotionLength(clipName);
			let clip = FindClip(clipName);
			for (int b < mBones.Count)
			{
				Vector3 p, k;
				Quaternion q;
				if (!SampleMotion(clipName, clip, clipTime, false, b, out p, out q, out k))
					continue;
				positions[b] = positions[b] + p * weight;
				scales[b] = scales[b] + k * weight;
				// Quaternions are summed on the same side of the sphere, then normalised.
				let r = rotations[b];
				if (r.x * q.x + r.y * q.y + r.z * q.z + r.w * q.w < 0)
					q = .(-q.x, -q.y, -q.z, -q.w);
				rotations[b] = .(r.x + q.x * weight, r.y + q.y * weight, r.z + q.z * weight, r.w + q.w * weight);
				track[b] += weight;
			}
		}
		for (int b < mBones.Count)
		{
			if (track[b] <= 0)
				continue;
			// Clips that do not move a bone leave the rest of the weight to its rest pose.
			let rest = mBones[b];
			let missing = Math.Max(1 - track[b], 0);
			positions[b] = (positions[b] + rest.restPosition * missing) / Math.Max(track[b] + missing, 0.0001f);
			scales[b] = (scales[b] + rest.restScale * missing) / Math.Max(track[b] + missing, 0.0001f);
			var r = rotations[b];
			var q = rest.restRotation;
			if (r.x * q.x + r.y * q.y + r.z * q.z + r.w * q.w < 0)
				q = .(-q.x, -q.y, -q.z, -q.w);
			rotations[b] = Quaternion(r.x + q.x * missing, r.y + q.y * missing, r.z + q.z * missing, r.w + q.w * missing).Normalized;
		}
	}

	/// Which bones a layer's mask lets it move: the named bones and everything below them (all when empty).
	void MaskFor(AnimatorController.Layer layer, bool[] masked)
	{
		if (layer.mask.IsEmpty)
		{
			for (int b < mBones.Count)
				masked[b] = true;
			return;
		}
		for (int b < mBones.Count)
		{
			masked[b] = false;
			var at = mBones[b].transform;
			while (at != null && at != Transform && !masked[b])
			{
				for (var name in layer.mask.Split(';'))
				{
					name.Trim();
					if (!name.IsEmpty && at.GameObject.Name == name)
						masked[b] = true;
				}
				at = at.Parent;
			}
		}
	}

	void EnterLayerState(int32 index, float fade)
	{
		SyncLayers();
		let state = mController.states[index];
		if (state.layer < 0 || state.layer >= mLayers.Count)
			return;
		let run = mLayers[state.layer];
		run.previous = run.state;
		run.previousTime = run.time;
		run.state = index;
		run.time = 0;
		run.fade = 0;
		run.fadeDuration = run.previous >= 0 ? fade : 0;
		if (state.layer == 0)
		{
			mState = index;
			mStateTime = 0;
		}
		NetworkSync.AnimatorChanged(this, 1, index, fade);
	}

	void EnsurePoseArrays()
	{
		let count = mBones.Count;
		if (mPosePosition != null && mPosePosition.Count == count)
			return;
		delete mPosePosition;
		delete mPoseRotation;
		delete mPoseScale;
		delete mLayerPosition;
		delete mLayerRotation;
		delete mLayerScale;
		delete mZeroPosition;
		delete mZeroRotation;
		delete mZeroScale;
		delete mTrack;
		delete mZeroTrack;
		delete mMasked;
		mPosePosition = new .[count];
		mPoseRotation = new .[count];
		mPoseScale = new .[count];
		mLayerPosition = new .[count];
		mLayerRotation = new .[count];
		mLayerScale = new .[count];
		mZeroPosition = new .[count];
		mZeroRotation = new .[count];
		mZeroScale = new .[count];
		mTrack = new .[count];
		mZeroTrack = new .[count];
		mMasked = new .[count];
	}

	/// A layer's pose now, cross-fading from its previous state, into mLayer*; mTrack says how much each bone moves.
	void SampleLayer(LayerRun run)
	{
		SampleLayeredState(run.state, run.time, false, mLayerPosition, mLayerRotation, mLayerScale, mTrack);
		if (run.previous < 0 || run.fade >= run.fadeDuration)
			return;
		let toward = Mathf.SmoothStep(0, 1, run.fade / Math.Max(run.fadeDuration, 0.0001f));
		SampleLayeredState(run.previous, run.previousTime, false, mZeroPosition, mZeroRotation, mZeroScale, mZeroTrack);
		for (int b < mBones.Count)
		{
			if (mZeroTrack[b] <= 0)
				continue;
			let rest = mBones[b];
			let toP = mTrack[b] > 0 ? mLayerPosition[b] : rest.restPosition;
			let toR = mTrack[b] > 0 ? mLayerRotation[b] : rest.restRotation;
			let toS = mTrack[b] > 0 ? mLayerScale[b] : rest.restScale;
			mLayerPosition[b] = Vector3.Lerp(mZeroPosition[b], toP, toward);
			mLayerRotation[b] = Quaternion.Slerp(mZeroRotation[b], toR, toward);
			mLayerScale[b] = Vector3.Lerp(mZeroScale[b], toS, toward);
			mTrack[b] = Math.Max(mTrack[b], mZeroTrack[b] * (1 - toward));
		}
	}

	/// The controller's work when it has layers or blend trees: each layer's state machine, then the pose, layer by
	/// layer, onto the bones.
	void UpdateLayered()
	{
		SyncController();
		SyncLayers();
		if (mBones.Count == 0)
			Collect(Transform);
		EnsurePoseArrays();
		if (mSkinned)
			mSkinned.posedByAnimator = mSkinned.exposeBones;
		// Only the machine that decides (the server, or the owner) moves between states; the others follow it.
		let decides = NetworkSync.IsMine(this);
		for (int32 l < (int32)mLayers.Count)
			AdvanceLayer(l, decides);
		BlendLayers();
		ApplyPose();
	}

	/// Moves a layer's clock on, and (on the machine that decides) into its first state or along a transition.
	void AdvanceLayer(int32 l, bool decides)
	{
		let run = mLayers[l];
		if (run.state < 0 || run.state >= mController.states.Count || mController.states[run.state].layer != l)
		{
			run.state = -1;
			if (!decides)
				return;
			let first = mController.DefaultStateOf(l);
			if (first < 0)
				return;
			EnterLayerState(first, 0);
		}
		let state = mController.states[run.state];
		let step = Time.DeltaTime * speed * state.speed;
		run.time += step;
		run.previousTime += step;
		run.fade += Time.DeltaTime;
		if (l == 0)
			mStateTime = run.time;
		if (decides && !(run.previous >= 0 && run.fade < run.fadeDuration))
			TakeLayerTransition(l, run);
	}

	/// Takes the first transition out of the layer's state whose exit time has come and whose conditions all hold.
	void TakeLayerTransition(int32 l, LayerRun run)
	{
		let normalized = run.time / Math.Max(LayeredLength(run.state), 0.0001f);
		for (let transition in mController.transitions)
		{
			if (mController.LayerOf(transition) != l)
				continue;
			if ((transition.from != run.state && transition.from != -1) || (transition.to == run.state && transition.from == -1))
				continue;
			if (transition.to < 0 || transition.to >= mController.states.Count || mController.states[transition.to].layer != l)
				continue;
			if (transition.hasExitTime && normalized < transition.exitTime)
				continue;
			if (transition.conditions.Count == 0 && !transition.hasExitTime)
				continue;
			bool all = true;
			for (let condition in transition.conditions)
				all &= Holds(condition);
			if (!all)
				continue;
			// A trigger is used up by the transition it fires.
			for (let condition in transition.conditions)
			{
				if (condition.parameter < mController.parameters.Count && mController.parameters[condition.parameter].type == .Trigger)
					SetParameter(condition.parameter, 0);
			}
			EnterLayerState(transition.to, transition.duration);
			return;
		}
	}

	/// The pose: the rest pose, then the Base Layer, then each layer above it, overriding or added on by its weight
	/// and only on the bones its mask lets through.
	void BlendLayers()
	{
		for (int b < mBones.Count)
		{
			mPosePosition[b] = mBones[b].restPosition;
			mPoseRotation[b] = mBones[b].restRotation;
			mPoseScale[b] = mBones[b].restScale;
		}
		for (int32 l < (int32)mLayers.Count)
		{
			let run = mLayers[l];
			if (run.state < 0)
				continue;
			let layer = mController.layers[l];
			let weight = l == 0 ? 1.0f : Mathf.Clamp01(run.weight);
			if (weight <= 0)
				continue;
			SampleLayer(run);
			MaskFor(layer, mMasked);
			let additive = l > 0 && layer.blending == .Additive;
			if (additive)
				SampleLayeredState(run.state, 0, true, mZeroPosition, mZeroRotation, mZeroScale, mZeroTrack);
			for (int b < mBones.Count)
			{
				if (!mMasked[b] || mTrack[b] <= 0)
					continue;
				let amount = weight * Math.Min(mTrack[b], 1);
				if (additive)
					AddLayerBone(b, amount);
				else
				{
					mPosePosition[b] = Vector3.Lerp(mPosePosition[b], mLayerPosition[b], amount);
					mPoseRotation[b] = Quaternion.Slerp(mPoseRotation[b], mLayerRotation[b], amount);
					mPoseScale[b] = Vector3.Lerp(mPoseScale[b], mLayerScale[b], amount);
				}
			}
		}
	}

	/// An additive layer's bone: what the clip does relative to its own first frame, added on.
	void AddLayerBone(int b, float amount)
	{
		mPosePosition[b] = mPosePosition[b] + (mLayerPosition[b] - mZeroPosition[b]) * amount;
		let delta = (mZeroRotation[b].Conjugate * mLayerRotation[b]).Normalized;
		mPoseRotation[b] = (mPoseRotation[b] * Quaternion.Slerp(.Identity, delta, amount)).Normalized;
		let zero = mZeroScale[b];
		let grow = Vector3(zero.x != 0 ? mLayerScale[b].x / zero.x : 1, zero.y != 0 ? mLayerScale[b].y / zero.y : 1, zero.z != 0 ? mLayerScale[b].z / zero.z : 1);
		mPoseScale[b] = mPoseScale[b] * Vector3.Lerp(.One, grow, amount);
	}

	void ApplyPose()
	{
		for (int b < mBones.Count)
		{
			let bone = mBones[b];
			if (bone.transform.GameObject.IsDestroyed)
				continue;
			Pose(b, mPosePosition[b], mPoseRotation[b], mPoseScale[b]);
		}
		PosedChanged();
	}

	bool Holds(AnimatorController.Condition condition)
	{
		if (condition.parameter < 0 || condition.parameter >= mParameters.Count)
			return false;
		let value = mParameters[condition.parameter];
		switch (condition.mode)
		{
		case .If: return value != 0;
		case .IfNot: return value == 0;
		case .Greater: return value > condition.threshold;
		case .Less: return value < condition.threshold;
		case .Equals: return Math.Abs(value - condition.threshold) < 0.0001f;
		case .NotEqual: return Math.Abs(value - condition.threshold) >= 0.0001f;
		}
	}

	void EnterState(int32 index, float fade)
	{
		let state = mController.states[index];
		mState = index;
		mStateTime = 0;
		let clip = FindClip(state.clip);
		if (clip != null)
			StartClip(clip, fade);
		else if (mSkinned && mSkinned.HasClip(state.clip))
		{
			mSkinned.loop = state.loop;
			mSkinned.Play(state.clip, fade);
		}
		NetworkSync.AnimatorChanged(this, 1, index, fade);
	}

	/// Jumps to a state of the controller by name, cross-fading over the given time. With layers, the state's own
	/// layer changes to it.
	public void CrossFade(StringView stateName, float fadeSeconds = 0.15f)
	{
		SyncController();
		let index = mController != null ? mController.FindState(stateName) : -1;
		if (index < 0)
			return;
		if (mController.UsesLayers)
			EnterLayerState(index, fadeSeconds);
		else
			EnterState(index, fadeSeconds);
	}

	void UpdateController()
	{
		SyncController();
		if (mController.states.Count == 0)
			return;
		// The machine in charge of the object decides; the others are told which state was entered.
		let decides = NetworkSync.IsMine(this);
		if (mState < 0)
		{
			if (!decides)
				return;
			EnterState(Math.Clamp(mController.defaultState, 0, (int32)mController.states.Count - 1), 0);
		}
		let state = mController.states[mState];
		mStateTime += Time.DeltaTime * speed * state.speed;
		if (mSkinned)
			mSkinned.speed = speed * state.speed;
		if (!decides || IsInTransition)
			return;
		let normalized = NormalizedTime;
		for (let transition in mController.transitions)
		{
			if ((transition.from != mState && transition.from != -1) || (transition.to == mState && transition.from == -1))
				continue;
			if (transition.hasExitTime && normalized < transition.exitTime)
				continue;
			// With neither a condition nor an exit time there is nothing to wait for; Unity ignores such a
			// transition, and so does this.
			if (transition.conditions.Count == 0 && !transition.hasExitTime)
				continue;
			bool all = true;
			for (let condition in transition.conditions)
				all &= Holds(condition);
			if (!all)
				continue;
			// Triggers that let the transition through are used up.
			for (let condition in transition.conditions)
			{
				if (condition.parameter < mController.parameters.Count && mController.parameters[condition.parameter].type == .Trigger)
					SetParameter(condition.parameter, 0);
			}
			EnterState(transition.to, transition.duration);
			break;
		}
	}

	List<AnimationClip> mClips = new .() ~ delete _;
	List<Bone> mBones = new .() ~ delete _;

	/// Which track of a clip moves each bone, so a frame does not look every bone's name up among the clip's tracks.
	class TrackMap
	{
		public AnimationClip clip;
		public int32 revision;
		public AnimationClip.Track[] tracks ~ delete _;
	}

	List<TrackMap> mTrackMaps = new .() ~ DeleteContainerAndItems!(_);
	/// Bones posed this frame, and bones whose branch has been told (PosedChanged).
	bool[] mPosed ~ delete _;
	bool[] mTold ~ delete _;

	/// The track of a clip that moves a bone, or null.
	AnimationClip.Track TrackOf(AnimationClip clip, int b)
	{
		TrackMap map = null;
		for (let candidate in mTrackMaps)
		{
			if (candidate.clip == clip)
			{
				map = candidate;
				break;
			}
		}
		if (map == null)
		{
			map = new TrackMap();
			map.clip = clip;
			map.revision = -1;
			mTrackMaps.Add(map);
		}
		let name = mBones[b].transform.GameObject.Name;
		if (map.revision != clip.TrackRevision || map.tracks == null || map.tracks.Count != mBones.Count)
		{
			// The clip gained or lost tracks, or the bones changed: looked up again.
			delete map.tracks;
			map.tracks = new .[mBones.Count];
			map.revision = clip.TrackRevision;
			for (int i < mBones.Count)
				map.tracks[i] = clip.FindTrack(mBones[i].transform.GameObject.Name);
		}
		let track = map.tracks[b];
		// A bone renamed since: looked up by its new name.
		if (track != null && track.bone != name)
			map.tracks[b] = clip.FindTrack(name);
		return map.tracks[b];
	}

	/// Sets a bone's local pose; PosedChanged then tells the transforms below.
	void Pose(int b, Vector3 position, Quaternion rotation, Vector3 scale)
	{
		if (mPosed == null || mPosed.Count != mBones.Count)
		{
			delete mPosed;
			delete mTold;
			mPosed = new .[mBones.Count];
			mTold = new .[mBones.Count];
		}
		mBones[b].transform.SetLocalPoseDeferred(position, rotation, scale);
		mPosed[b] = true;
	}

	/// After Pose: the topmost posed bone of each branch tells everything below it once.
	void PosedChanged()
	{
		if (mPosed == null || mPosed.Count != mBones.Count)
			return;
		for (int b < mBones.Count)
		{
			let bone = mBones[b];
			// Told already when its parent bone's branch was told, and it is still that bone's child.
			let told = bone.parent >= 0 && mTold[bone.parent] && bone.transform.Parent == mBones[bone.parent].transform;
			if (mPosed[b] && !told)
				bone.transform.PoseChanged();
			mTold[b] = told || mPosed[b];
			mPosed[b] = false;
		}
	}

	AnimationClip mCurrent;
	AnimationClip mPrevious;
	float mTime;
	float mPreviousTime;
	float mFade;
	float mFadeDuration;

	public StringView CurrentClip => mCurrent != null ? (StringView)mCurrent.name : "";
	/// True once a non-looping clip has reached its end.
	public bool IsFinished => mCurrent != null && !mCurrent.loop && mTime >= mCurrent.duration;

	public override void Start()
	{
		Bind();
		if (mController == null)
			Play(defaultClip, 0);
	}

	/// Collects the bones and remembers their rest pose. Call again after changing the hierarchy.
	public void Bind()
	{
		mClips.Clear();
		for (var path in clips.Split(';'))
		{
			path.Trim();
			if (path.IsEmpty)
				continue;
			let clip = AnimationClip.Load(path);
			if (clip != null)
				mClips.Add(clip);
		}
		mBones.Clear();
		ClearAndDeleteItems!(mTrackMaps);
		Collect(Transform);
		mSkinned = GetComponent<SkinnedMeshRenderer>();
		if (!mSkinned)
		{
			for (let child in Transform.Children)
			{
				mSkinned = child.GameObject.GetComponent<SkinnedMeshRenderer>();
				if (mSkinned)
					break;
			}
		}
		mController = AnimatorController.Load(controller);
		mControllerRevision = -1;
		mParameters.Clear();
		mState = -1;
		SyncController();
	}

	void Collect(Transform parent, int32 parentIndex = -1)
	{
		for (let child in parent.Children)
		{
			Bone bone;
			bone.transform = child;
			bone.parent = parentIndex;
			bone.restPosition = child.LocalPosition;
			bone.restRotation = child.LocalRotation;
			bone.restScale = child.LocalScale;
			mBones.Add(bone);
			Collect(child, (int32)mBones.Count - 1);
		}
	}

	public bool HasClip(StringView name)
	{
		for (let clip in mClips)
		{
			if (clip.name == name)
				return true;
		}
		return false;
	}

	/// Switches to a clip, cross-fading from the current pose over fadeSeconds. Does nothing if it is already playing.
	public void Play(StringView name, float fadeSeconds = 0.15f)
	{
		// With a controller, the name is a state's.
		if (mController != null)
		{
			if (CurrentState != name)
				CrossFade(name, fadeSeconds);
			return;
		}
		if (mCurrent != null && mCurrent.name == name)
			return;
		for (let clip in mClips)
		{
			if (clip.name != name)
				continue;
			StartClip(clip, fadeSeconds);
			// In multiplayer a clip started by the server, or by the player who controls this object, plays everywhere.
			NetworkSync.AnimationPlayed(this, name, fadeSeconds);
			return;
		}
	}

	void StartClip(AnimationClip clip, float fadeSeconds)
	{
		if (mCurrent == clip)
		{
			mTime = 0;
			return;
		}
		mPrevious = mCurrent;
		mPreviousTime = mTime;
		mCurrent = clip;
		mTime = 0;
		mFadeDuration = mPrevious != null ? fadeSeconds : 0;
		mFade = 0;
	}

	/// Poses the object from a clip at a time, without playing. The Animation window uses it to scrub.
	public void SampleClip(AnimationClip clip, float time)
	{
		if (mBones.Count == 0)
			Collect(Transform);
		for (int b < mBones.Count)
		{
			let bone = mBones[b];
			if (bone.transform.GameObject.IsDestroyed)
				continue;
			let track = TrackOf(clip, b);
			Vector3 position = .Zero, scale = .(1, 1, 1);
			Quaternion rotation = .Identity;
			if (track != null)
				track.Sample(time, out position, out rotation, out scale);
			Pose(b, bone.restPosition + position, (bone.restRotation * rotation).Normalized, .(bone.restScale.x * scale.x, bone.restScale.y * scale.y, bone.restScale.z * scale.z));
		}
		PosedChanged();
	}

	/// The pose a child had before any animation moved it, which keys are measured from.
	public bool RestPose(Transform child, out Vector3 position, out Quaternion rotation, out Vector3 scale)
	{
		position = .Zero;
		rotation = .Identity;
		scale = .(1, 1, 1);
		if (mBones.Count == 0)
			Collect(Transform);
		for (let bone in mBones)
		{
			if (bone.transform == child)
			{
				position = bone.restPosition;
				rotation = bone.restRotation;
				scale = bone.restScale;
				return true;
			}
		}
		return false;
	}

	float Wrap(AnimationClip clip, float time)
	{
		// A controller's state says whether its clip loops; otherwise the clip does.
		let loops = (mController != null && clip == mCurrent && mState >= 0 && mState < mController.states.Count) ? mController.states[mState].loop : clip.loop;
		if (loops)
			return time % clip.duration;
		return Math.Min(time, clip.duration);
	}

	public override void OnLocalUpdate()
	{
		if (mController != null && mController.UsesLayers)
		{
			UpdateLayered();
			return;
		}
		if (mController != null)
			UpdateController();
		if (mCurrent == null)
			return;
		let step = Time.DeltaTime * speed * ((mController != null && mState >= 0 && mState < mController.states.Count) ? mController.states[mState].speed : 1);
		mTime += step;
		mPreviousTime += step;
		mFade += Time.DeltaTime;
		let blending = mPrevious != null && mFade < mFadeDuration;
		let weight = blending ? Mathf.SmoothStep(0, 1, mFade / mFadeDuration) : 1.0f;
		let time = Wrap(mCurrent, mTime);
		let previousTime = blending ? Wrap(mPrevious, mPreviousTime) : 0;

		for (int b < mBones.Count)
		{
			let bone = mBones[b];
			if (bone.transform.GameObject.IsDestroyed)
				continue;
			Vector3 position = .Zero, scale = .(1, 1, 1);
			Quaternion rotation = .Identity;
			let track = TrackOf(mCurrent, b);
			if (track != null)
				track.Sample(time, out position, out rotation, out scale);
			if (blending)
			{
				Vector3 fromPosition = .Zero, fromScale = .(1, 1, 1);
				Quaternion fromRotation = .Identity;
				let fromTrack = TrackOf(mPrevious, b);
				if (fromTrack != null)
					fromTrack.Sample(previousTime, out fromPosition, out fromRotation, out fromScale);
				scale = Vector3.Lerp(fromScale, scale, weight);
				position = Vector3.Lerp(fromPosition, position, weight);
				rotation = Quaternion.Slerp(fromRotation, rotation, weight);
			}
			else if (track == null)
			{
				// Bones this clip does not animate stay in (and return to) their rest pose.
				if (bone.transform.LocalRotation.x == bone.restRotation.x && bone.transform.LocalRotation.w == bone.restRotation.w && bone.transform.LocalPosition == bone.restPosition)
					continue;
			}
			Pose(b, bone.restPosition + position, (bone.restRotation * rotation).Normalized, track != null ? Vector3(bone.restScale.x * scale.x, bone.restScale.y * scale.y, bone.restScale.z * scale.z) : bone.transform.LocalScale);
		}
		PosedChanged();
	}
}
