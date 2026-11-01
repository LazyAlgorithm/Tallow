using System;
using System.Collections;
using System.IO;

namespace Tallow;

enum AnimatorParameterType : int32 { Float, Int, Bool, Trigger }

/// How a transition's condition compares a parameter. If and IfNot are for booleans and triggers.
enum AnimatorConditionMode : int32 { If, IfNot, Greater, Less, Equals, NotEqual }

/// How a layer's pose goes onto the layers below it.
enum AnimatorLayerBlend : int32
{
	/// Replaces the pose of the bones it animates (within its mask), by its weight.
	Override,
	/// Adds its movement to the pose below: a recoil, a breath, a lean, on top of whatever is playing.
	Additive
}

/// How a blend tree mixes its clips.
enum BlendTreeType : int32
{
	/// Along one number: walk at 1, run at 3, sprint at 6.
	Simple1D,
	/// Over two numbers, with clips placed anywhere on a plane: strafing by sideways and forward speed.
	Freeform2D
}

/// A state machine for an Animator: states that each play a clip, parameters that scripts set, and transitions
/// between states that fire when their conditions on those parameters hold. Made in the Animator window and saved
/// as a .tcontroller file.
class AnimatorController
{
	public class Parameter
	{
		public String name = new .() ~ delete _;
		public AnimatorParameterType type;
		public float defaultValue;
	}

	/// One state machine laid over the others. Layer 0, the Base Layer, is the whole body; the ones above it can
	/// play something else on part of it (the upper body aiming while the legs run) or add to it.
	public class Layer
	{
		public String name = new .() ~ delete _;
		/// How much of the layer is used, 0 to 1 (changed from code with Animator.SetLayerWeight).
		public float weight = 1;
		public AnimatorLayerBlend blending = .Override;
		/// The bones the layer moves: each named bone and everything below it, separated by semicolons
		/// ("spine_02;neck"). Empty: every bone.
		public String mask = new .() ~ delete _;
		/// The state the layer starts in (for the Base Layer, the controller's defaultState).
		public int32 defaultState = -1;
	}

	/// One clip of a blend tree, and where it sits.
	public class Motion
	{
		public String clip = new .() ~ delete _;
		/// Simple 1D: the parameter's value at which this clip plays alone.
		public float threshold;
		/// Freeform 2D: the parameters' values at which this clip plays alone.
		public Vector2 position;
	}

	/// Clips mixed by parameters: a state with one plays them all at once, in step, weighted by where the parameters
	/// are among the clips' places.
	public class BlendTree
	{
		public BlendTreeType type = .Simple1D;
		public int32 parameterX = -1;
		public int32 parameterY = -1;
		public List<Motion> motions = new .() ~ DeleteContainerAndItems!(_);

		/// The weight of each clip for the parameters' values (they add up to 1).
		public void Weights(float x, float y, List<float> output)
		{
			output.Clear();
			let count = motions.Count;
			for (int i < count)
				output.Add(0);
			if (count == 0)
				return;
			if (count == 1)
			{
				output[0] = 1;
				return;
			}
			if (type == .Simple1D)
			{
				// Between the two clips whose thresholds are either side of the value, by how near it is to each.
				int below = -1, above = -1;
				for (int i < count)
				{
					let t = motions[i].threshold;
					if (t <= x && (below < 0 || t > motions[below].threshold))
						below = i;
					if (t >= x && (above < 0 || t < motions[above].threshold))
						above = i;
				}
				if (below < 0)
					output[above] = 1;
				else if (above < 0 || below == above)
					output[below] = 1;
				else
				{
					let span = motions[above].threshold - motions[below].threshold;
					let t = span > 0.00001f ? (x - motions[below].threshold) / span : 0;
					output[below] = 1 - t;
					output[above] += t;
				}
				return;
			}
			// Gradient band interpolation (as Unity's Freeform Cartesian): each clip's weight is how far the point is
			// from being past any other clip, measured along the line between them; then they are made to add to 1.
			let p = Vector2(x, y);
			float total = 0;
			for (int i < count)
			{
				var weight = 1.0f;
				let pi = motions[i].position;
				for (int j < count)
				{
					if (i == j)
						continue;
					let pij = motions[j].position - pi;
					let length = pij.x * pij.x + pij.y * pij.y;
					if (length < 1.0e-8f)
						continue;
					let along = ((p.x - pi.x) * pij.x + (p.y - pi.y) * pij.y) / length;
					weight = Math.Min(weight, Mathf.Clamp01(1 - along));
				}
				output[i] = weight;
				total += weight;
			}
			if (total > 0)
			{
				for (int i < count)
					output[i] /= total;
			}
			else
			{
				// Outside them all: the nearest clip.
				int nearest = 0;
				float best = float.MaxValue;
				for (int i < count)
				{
					let d = motions[i].position - p;
					if (d.x * d.x + d.y * d.y < best)
					{
						best = d.x * d.x + d.y * d.y;
						nearest = i;
					}
				}
				output[nearest] = 1;
			}
		}
	}

	public class State
	{
		public String name = new .() ~ delete _;
		/// A .tanim clip file, or the name of a clip in the object's skinned model.
		public String clip = new .() ~ delete _;
		public float speed = 1;
		public bool loop = true;
		/// Where the state sits in the Animator window.
		public Vector2 position;
		/// The layer the state belongs to.
		public int32 layer;
		/// With a blend tree the state plays its clips mixed instead of Clip.
		public BlendTree blend ~ delete _;
	}

	public struct Condition
	{
		public int32 parameter;
		public AnimatorConditionMode mode;
		public float threshold;
	}

	public class Transition
	{
		/// The state it leaves, or -1 for Any State.
		public int32 from;
		public int32 to;
		/// Seconds of cross-fade.
		public float duration = 0.15f;
		/// Wait until the state has played this fraction of its clip (1 is the end) before the transition can fire.
		public bool hasExitTime;
		public float exitTime = 1;
		/// For a transition from Any State: the layer it belongs to (otherwise the layer of the state it leaves).
		public int32 layer;
		public List<Condition> conditions = new .() ~ delete _;
	}

	public List<Parameter> parameters = new .() ~ DeleteContainerAndItems!(_);
	public List<State> states = new .() ~ DeleteContainerAndItems!(_);
	public List<Transition> transitions = new .() ~ DeleteContainerAndItems!(_);
	/// At least the Base Layer.
	public List<Layer> layers = new .() ~ DeleteContainerAndItems!(_);
	/// The state entered when the Animator starts.
	public int32 defaultState;
	/// Goes up when the controller is edited, so running Animators pick the change up.
	public int32 Revision;

	static Dictionary<String, AnimatorController> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	public this()
	{
		AddLayer("Base Layer");
	}

	/// True when the controller uses layers above the Base Layer or blend trees.
	public bool UsesLayers
	{
		get
		{
			if (layers.Count > 1)
				return true;
			for (let state in states)
			{
				if (state.blend != null)
					return true;
			}
			return false;
		}
	}

	/// The layer a transition belongs to.
	public int32 LayerOf(Transition transition) => transition.from >= 0 && transition.from < states.Count ? states[transition.from].layer : transition.layer;

	/// The state a layer starts in, or -1 when it has none.
	public int32 DefaultStateOf(int32 layer)
	{
		var wanted = layer == 0 ? defaultState : (layer < layers.Count ? layers[layer].defaultState : -1);
		if (wanted >= 0 && wanted < states.Count && states[wanted].layer == layer)
			return wanted;
		for (int32 i < (int32)states.Count)
		{
			if (states[i].layer == layer)
				return i;
		}
		return -1;
	}

	public Layer AddLayer(StringView name)
	{
		let layer = new Layer();
		layer.name.Set(name);
		layers.Add(layer);
		Revision++;
		return layer;
	}

	/// Removes a layer above the Base Layer, with its states and their transitions.
	public void RemoveLayer(int32 index)
	{
		if (index <= 0 || index >= layers.Count)
			return;
		for (int32 i = (int32)states.Count - 1; i >= 0; i--)
		{
			if (states[i].layer == index)
				RemoveState(i);
		}
		for (int i = transitions.Count - 1; i >= 0; i--)
		{
			if (transitions[i].from == -1 && transitions[i].layer == index)
			{
				delete transitions[i];
				transitions.RemoveAt(i);
			}
		}
		delete layers[index];
		layers.RemoveAt(index);
		for (let state in states)
		{
			if (state.layer > index)
				state.layer--;
		}
		for (let transition in transitions)
		{
			if (transition.layer > index)
				transition.layer--;
		}
		Revision++;
	}

	public int32 FindLayer(StringView name)
	{
		for (int32 i < (int32)layers.Count)
		{
			if (layers[i].name == name)
				return i;
		}
		return -1;
	}

	public int32 FindParameter(StringView name)
	{
		for (int32 i < (int32)parameters.Count)
		{
			if (parameters[i].name == name)
				return i;
		}
		return -1;
	}

	public int32 FindState(StringView name)
	{
		for (int32 i < (int32)states.Count)
		{
			if (states[i].name == name)
				return i;
		}
		return -1;
	}

	public Parameter AddParameter(StringView name, AnimatorParameterType type)
	{
		let parameter = new Parameter();
		parameter.name.Set(name);
		parameter.type = type;
		parameters.Add(parameter);
		Revision++;
		return parameter;
	}

	public State AddState(StringView name, StringView clip, Vector2 position = default)
	{
		let state = new State();
		state.name.Set(name);
		state.clip.Set(clip);
		state.position = position;
		states.Add(state);
		Revision++;
		return state;
	}

	public Transition AddTransition(int32 from, int32 to)
	{
		let transition = new Transition();
		transition.from = from;
		transition.to = to;
		transitions.Add(transition);
		Revision++;
		return transition;
	}

	/// Adds a condition to a transition by parameter name. Returns false if there is no such parameter.
	public bool AddCondition(Transition transition, StringView parameter, AnimatorConditionMode mode, float threshold = 0)
	{
		let index = FindParameter(parameter);
		if (index < 0)
			return false;
		Condition condition;
		condition.parameter = index;
		condition.mode = mode;
		condition.threshold = threshold;
		transition.conditions.Add(condition);
		Revision++;
		return true;
	}

	/// Removes a state and every transition to or from it.
	public void RemoveState(int32 index)
	{
		if (index < 0 || index >= states.Count)
			return;
		delete states[index];
		states.RemoveAt(index);
		for (int i = transitions.Count - 1; i >= 0; i--)
		{
			let transition = transitions[i];
			if (transition.from == index || transition.to == index)
			{
				delete transition;
				transitions.RemoveAt(i);
				continue;
			}
			if (transition.from > index)
				transition.from--;
			if (transition.to > index)
				transition.to--;
		}
		if (defaultState == index)
			defaultState = 0;
		else if (defaultState > index)
			defaultState--;
		for (let layer in layers)
		{
			if (layer.defaultState == index)
				layer.defaultState = -1;
			else if (layer.defaultState > index)
				layer.defaultState--;
		}
		Revision++;
	}

	/// Removes a parameter and the conditions that used it.
	public void RemoveParameter(int32 index)
	{
		if (index < 0 || index >= parameters.Count)
			return;
		delete parameters[index];
		parameters.RemoveAt(index);
		for (let state in states)
		{
			if (state.blend == null)
				continue;
			if (state.blend.parameterX == index)
				state.blend.parameterX = -1;
			else if (state.blend.parameterX > index)
				state.blend.parameterX--;
			if (state.blend.parameterY == index)
				state.blend.parameterY = -1;
			else if (state.blend.parameterY > index)
				state.blend.parameterY--;
		}
		for (let transition in transitions)
		{
			for (int i = transition.conditions.Count - 1; i >= 0; i--)
			{
				if (transition.conditions[i].parameter == index)
					transition.conditions.RemoveAt(i);
				else if (transition.conditions[i].parameter > index)
					transition.conditions[i].parameter--;
			}
		}
		Revision++;
	}

	public void Save(StringView fullPath)
	{
		let text = scope String();
		text.Append("controller 1\n");
		for (let parameter in parameters)
		{
			text.Append("parameter ");
			SceneSerializer.Quote(parameter.name, text);
			text.AppendF(" {} {}\n", (int32)parameter.type, parameter.defaultValue);
		}
		// Layers above the Base Layer (whose name is the only thing kept about it; its default is "default").
		for (int i < layers.Count)
		{
			let layer = layers[i];
			text.Append("layer ");
			SceneSerializer.Quote(layer.name, text);
			text.AppendF(" {} {} ", layer.weight, (int32)layer.blending);
			SceneSerializer.Quote(layer.mask, text);
			text.AppendF(" {}\n", layer.defaultState);
		}
		for (let state in states)
		{
			text.Append("state ");
			SceneSerializer.Quote(state.name, text);
			text.Append(' ');
			SceneSerializer.Quote(state.clip, text);
			text.AppendF(" {} {} {} {} {}\n", state.speed, state.loop ? 1 : 0, state.position.x, state.position.y, state.layer);
			if (state.blend != null)
			{
				text.AppendF("blend {} {} {}\n", (int32)state.blend.type, state.blend.parameterX, state.blend.parameterY);
				for (let motion in state.blend.motions)
				{
					text.Append("motion ");
					SceneSerializer.Quote(motion.clip, text);
					text.AppendF(" {} {} {}\n", motion.threshold, motion.position.x, motion.position.y);
				}
			}
		}
		text.AppendF("default {}\n", defaultState);
		for (let transition in transitions)
		{
			text.AppendF("transition {} {} {} {} {} {}\n", transition.from, transition.to, transition.duration, transition.hasExitTime ? 1 : 0, transition.exitTime, transition.layer);
			for (let condition in transition.conditions)
				text.AppendF("condition {} {} {}\n", condition.parameter, (int32)condition.mode, condition.threshold);
		}
		if (File.WriteAllText(fullPath, text) case .Err)
			Log.Error(scope $"Could not save {fullPath}");
	}

	/// After reading: anything pointing at a state or layer that is not there is dropped (or put on the Base Layer)
	/// rather than trusted.
	void DropBrokenLinks()
	{
		for (int i = transitions.Count - 1; i >= 0; i--)
		{
			let t = transitions[i];
			if (t.to < 0 || t.to >= states.Count || t.from < -1 || t.from >= states.Count)
			{
				delete t;
				transitions.RemoveAt(i);
			}
		}
		defaultState = Math.Clamp(defaultState, 0, Math.Max((int32)states.Count - 1, 0));
		// A file from before layers has none written: it is all the Base Layer.
		if (layers.Count == 0)
			AddLayer("Base Layer");
		for (let state in states)
		{
			if (state.layer >= layers.Count)
				state.layer = 0;
		}
		for (let t in transitions)
		{
			if (t.layer >= layers.Count)
				t.layer = 0;
		}
	}

	public bool Read(StringView fullPath)
	{
		let text = scope String();
		if (AssetPack.ReadAllText(fullPath, text) case .Err)
			return false;
		ClearAndDeleteItems!(parameters);
		ClearAndDeleteItems!(states);
		ClearAndDeleteItems!(transitions);
		ClearAndDeleteItems!(layers);
		defaultState = 0;
		Transition transition = null;
		State lastState = null;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			switch (tokens[0])
			{
			case "parameter":
				if (tokens.Count >= 4)
				{
					let parameter = AddParameter(tokens[1], (AnimatorParameterType)Math.Clamp(SceneSerializer.ParseInt(tokens[2]), 0, 3));
					parameter.defaultValue = SceneSerializer.ParseFloat(tokens[3]);
				}
			case "layer":
				if (tokens.Count >= 6)
				{
					let layer = AddLayer(tokens[1]);
					layer.weight = Mathf.Clamp01(SceneSerializer.ParseFloat(tokens[2]));
					layer.blending = (AnimatorLayerBlend)Math.Clamp(SceneSerializer.ParseInt(tokens[3]), 0, 1);
					layer.mask.Set(tokens[4]);
					layer.defaultState = (int32)SceneSerializer.ParseInt(tokens[5]);
				}
			case "state":
				if (tokens.Count >= 7)
				{
					let state = AddState(tokens[1], tokens[2], .(SceneSerializer.ParseFloat(tokens[5]), SceneSerializer.ParseFloat(tokens[6])));
					state.speed = SceneSerializer.ParseFloat(tokens[3]);
					state.loop = tokens[4] == "1";
					if (tokens.Count >= 8)
						state.layer = (int32)Math.Max(SceneSerializer.ParseInt(tokens[7]), 0);
					lastState = state;
				}
			case "blend":
				if (tokens.Count >= 4 && lastState != null)
				{
					delete lastState.blend;
					lastState.blend = new .();
					lastState.blend.type = (BlendTreeType)Math.Clamp(SceneSerializer.ParseInt(tokens[1]), 0, 1);
					lastState.blend.parameterX = (int32)SceneSerializer.ParseInt(tokens[2]);
					lastState.blend.parameterY = (int32)SceneSerializer.ParseInt(tokens[3]);
				}
			case "motion":
				if (tokens.Count >= 5 && lastState != null && lastState.blend != null)
				{
					let motion = new Motion();
					motion.clip.Set(tokens[1]);
					motion.threshold = SceneSerializer.ParseFloat(tokens[2]);
					motion.position = .(SceneSerializer.ParseFloat(tokens[3]), SceneSerializer.ParseFloat(tokens[4]));
					lastState.blend.motions.Add(motion);
				}
			case "default":
				defaultState = (int32)SceneSerializer.ParseInt(tokens[1]);
			case "transition":
				if (tokens.Count >= 6)
				{
					transition = AddTransition((int32)SceneSerializer.ParseInt(tokens[1]), (int32)SceneSerializer.ParseInt(tokens[2]));
					transition.duration = Math.Max(SceneSerializer.ParseFloat(tokens[3]), 0);
					transition.hasExitTime = tokens[4] == "1";
					transition.exitTime = SceneSerializer.ParseFloat(tokens[5]);
					if (tokens.Count >= 7)
						transition.layer = (int32)Math.Max(SceneSerializer.ParseInt(tokens[6]), 0);
				}
			case "condition":
				if (tokens.Count >= 4 && transition != null)
				{
					Condition condition;
					condition.parameter = (int32)SceneSerializer.ParseInt(tokens[1]);
					condition.mode = (AnimatorConditionMode)Math.Clamp(SceneSerializer.ParseInt(tokens[2]), 0, 5);
					condition.threshold = SceneSerializer.ParseFloat(tokens[3]);
					if (condition.parameter >= 0 && condition.parameter < parameters.Count)
						transition.conditions.Add(condition);
				}
			}
		}
		DropBrokenLinks();
		Revision++;
		return true;
	}

	/// Loads (and caches) a controller. The path is relative to the project's asset folder. Everything using the
	/// same file shares one controller, so an edit in the Animator window shows on every object at once.
	public static AnimatorController Load(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let full = scope String();
		Assets.ResolvePath(path, full);
		let controller = new AnimatorController();
		if (!controller.Read(full))
		{
			delete controller;
			Log.Warning(scope $"Animator controller not found: {path}");
			return null;
		}
		sCache[new String(path)] = controller;
		return controller;
	}
}
