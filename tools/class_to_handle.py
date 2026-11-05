#!/usr/bin/env python3
"""Converts a Tallow class component to [HandleData] struct + handle + state class (docs/ecs-plan.md Phase 4/5 recipe).
usage: tohandle.py file.bf ClassName first_setting_marker end_marker [step-doc]
Settings: lines from the marker line (a doc comment of the first setting) up to end_marker (exclusive).
Lifecycle overrides become state methods driven by the handle's FrameAll / OnGUI / OnSaving / OnLoaded."""
import re, sys
path, name, first, end = sys.argv[1:5]
s = open(path).read()
cls = f'[Component]\nclass {name} : Component\n{{\n'
ci = s.index(cls)
ds = s.rindex('\n\n', 0, ci) + 2
doc = s[ds:ci]
body = s[ci + len(cls):].rstrip()
assert body.endswith('}'); body = body[:-1]
a = body.index(first); b = body.index(end)
settings = body[a:b].replace(' ~ delete _;', ';')
logic = body[:a] + body[b:]
hooks = {}
for hook, new in [('Awake', 'Awake'), ('Start', 'Start'), ('OnDisable', 'OnDisable'), ('OnLocalUpdate', 'Frame'),
                  ('OnGUI', 'OnGUI'), ('OnSaving', 'OnSaving'), ('OnLoaded', 'OnLoaded'), ('OnDestroy', 'OnDestroy'),
                  ('OnValidate', 'OnValidate')]:
    pat = f'public override void {hook}()'
    if pat in logic:
        hooks[hook] = True
        logic = logic.replace(pat, f'public void {new}()')
left = re.findall(r'override [^\n]*', logic)
if left: print('LEFT OVERRIDES', left)
pubs = []
events = []
for m in re.finditer(r'^\tpublic (?!static)([^\n]+)$', logic, re.M):
    sig = m.group(1)
    if sig.startswith('Event<'):
        mm = re.match(r'(Event<.*>) (\w+) ~', sig); events.append((mm.group(1), mm.group(2))); continue
    pubs.append(sig)
fwd = []
skip = {'Awake', 'Start', 'OnDisable', 'Frame', 'OnGUI', 'OnSaving', 'OnLoaded', 'OnDestroy', 'OnValidate'}
for sig in pubs:
    m = re.match(r'([\w<>\[\]., ?]+?) (\w+)\((.*?)\)', sig)
    if m and '=>' not in sig.split('(')[0]:
        typ, nm, params = m.groups()
        if nm in skip: continue
        args = []
        for prm in [x.strip() for x in params.split(',') if x.strip()]:
            toks = prm.split('=')[0].split()
            args.append((toks[0] + ' ' if toks[0] in ('out', 'ref') else '') + toks[-1])
        fwd.append(f'\tpublic {typ} {nm}({params}) => Runtime.{nm}({", ".join(args)});')
        continue
    m = re.match(r'([\w<>\[\]., ?]+?) (\w+)( =>|$| \{| =|;)', sig)
    if m:
        typ, nm = m.group(1), m.group(2)
        if m.group(3) in (' =', ';'):
            fwd.append(f'\tpublic ref {typ} {nm} => ref Runtime.{nm};')
        else:
            fwd.append(f'\tpublic {typ} {nm} => Runtime.{nm};')
        continue
    print('SKIP', sig)
for typ, nm in events:
    fwd.append(f'\tpublic ref {typ} {nm} => ref Runtime.{nm};')
state = name + 'State'
data = name + 'Data'
has_strings = bool(re.search(r'public String \w+ = new', settings))
frame = []
frame.append(f'''	/// Starts {name}s that have not started, moves every switched-on one on an active object a frame on, and
	/// tells one that has been switched off (OnDisable).
	public static void FrameAll(Scene scene)
	{{
		if (!scene.IsPlaying)
			return;
		for (let component in scene.FindComponents<{name}>(.. scope .()))
		{{
			let state = component.Runtime;
			if (!component.IsActiveAndEnabled)
			{{
				if (state.[Friend]mWasActive)
				{{
					state.[Friend]mWasActive = false;
					{"state.OnDisable();" if 'OnDisable' in hooks else ""}
				}}
				continue;
			}}
			state.[Friend]mWasActive = true;
			if (!state.[Friend]mStarted)
			{{
				state.[Friend]mStarted = true;
				{"state.Start();" if 'Start' in hooks else ""}
			}}
			{"state.Frame();" if 'OnLocalUpdate' in hooks else ""}
		}}
	}}

	/// When play stops, they start again next time (as Start runs once per play).
	public static void StopAll(Scene scene)
	{{
		for (let (entity, state) in ComponentState<{state}>.In(scene.World, .. scope .()))
		{{
			state.[Friend]mStarted = false;
			state.[Friend]mWasActive = false;
		}}
	}}
''')
if 'OnGUI' in hooks:
    frame.append(f'''	/// GUI.Run: what OnGUI did, for each switched-on one on an active object that has started.
	static void OnGUI(Scene scene)
	{{
		for (let component in scene.Components<{name}>(.. scope .()))
		{{
			if (component.GameObject.ActiveInHierarchy && ComponentState<{state}>.Get(scene.World, component.GameObject.Entity) != null)
				component.Runtime.OnGUI();
		}}
	}}
''')
for h in ('OnSaving', 'OnLoaded'):
    if h in hooks:
        frame.append(f'''	/// SaveSystem: what {h} did.
	static void {h}(GameObject gameObject) => gameObject.GetComponent<{name}>().Runtime.{h}();
''')
onremove = f'''	static void OnRemove(void* world, uint64 entity)
	{{
'''
if 'OnDestroy' in hooks:
    onremove += f'''		// As OnDestroy did, unless the whole scene is going.
		if (let state = ComponentState<{state}>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{{
			let scene = state.[Friend]mGameObject?.Scene;
			if (scene != null && !scene.[Friend]mClearing)
				state.OnDestroy();
		}}
'''
onremove += f'''		ComponentState<{state}>.Release(world, entity);
''' + (f'''		HandleComponents.FreeLists(world, entity, typeof({name}));
''' if has_strings else '') + '''	}
'''
awake = '\n\t\t\t\tstate.Awake();' if 'Awake' in hooks else ''
out = s[:ds] + f'''/// A {name}'s settings, in its entity ({name} is the handle).
[Component, HandleData]
struct {data}
{{
{settings.rstrip()}

	public this() {{ }}
}}

{doc.rstrip()}
///
/// A handle (ComponentHandle): its settings are {data}'s fields, what it keeps between frames its {state}.
/// {name}.FrameAll (a step in the frame pipeline) does what Start, OnLocalUpdate and OnDisable did.
[Component, HandleFields]
struct {name} : ComponentHandle<{data}>
{{
	/// What it keeps between frames, made the first time it is asked for.
	public {state} Runtime
	{{
		get
		{{
			CheckValid();
			let state = ComponentState<{state}>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
			{{
				state.[Friend]mGameObject = mGameObject;{awake}
			}}
			return state;
		}}
	}}

	// The API, unchanged: each member is documented on {state}.
''' + '\n'.join(fwd) + '\n\n' + '\n'.join(frame) + '\n' + onremove + f'''}}

/// What a {name} keeps between frames. Its settings are read from the entity each time.
[DataFields(typeof({data}), "Settings")]
class {state}
{{
	GameObject mGameObject;
	bool mStarted;
	bool mWasActive;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	public {name} Handle => mGameObject.GetComponent<{name}>();
	T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	bool HasComponent<T>() where T : struct, IComponentHandle => mGameObject.HasComponent<T>();
	ref {data} Settings
	{{
		[Inline]
		get => ref *mGameObject.GetComponent<{data}>();
	}}

''' + logic.strip('\n') + '\n}\n'
open(path, 'w').write(out)
print('hooks', list(hooks), 'forwarders', len(fwd))
