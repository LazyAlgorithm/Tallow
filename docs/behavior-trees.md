# Behaviour trees

A behaviour tree decides what an AI character does: patrol, chase what it sees, go and look where it last saw it. Trees are drawn in the **Behavior** tab, saved as `.tbt` files, and run by a **Behavior Tree Runner** component. While the game plays, the tab shows the tree of the selected object live.

## Making a tree

1. In the Project panel click **+** and choose **Behavior Tree**. The new tree opens with a working example: chase an object named `Player` on sight, otherwise wander.
2. Add a **Behavior Tree Runner** (Add Component > AI) to the character and set **Tree** to the file, for example `AI/Guard.tbt`.
3. Movement nodes drive a **Navigation Agent** on the same object, so add one and bake a Navigation Surface.

The canvas works like the Graph tab: right-click to add a node (type to search), middle-drag to pan, wheel to zoom, Delete to remove the selected node. **Fit View** shows the whole tree. Flow runs downward:

- A node's parent connects to the dot on its top, its children to the dot on its bottom.
- Drag from a node's bottom dot onto another node to make that node its child. Dropping on empty canvas offers a new node already connected.
- Alt+click a dot to disconnect it.
- **Children run left to right.** The small numbers beside them show the order; drag a node sideways to change it.

Select a node to edit its settings in the box at the top left, which also says what the node does. **Ctrl+D** copies the selected node and everything under it beside it (link the copy to a parent to use it).

## How a tree runs

The runner ticks the tree from the Root once per frame (or every **Tick Interval** seconds). Each node answers **Success**, **Failure** or **Running**. An action that takes time, such as walking somewhere, answers Running until it is done, and is resumed on the next tick.

| Flow node | What it does |
|---|---|
| Sequence | Runs children left to right. Fails as soon as one fails; succeeds when all have. "Do this, then this." |
| Selector | Tries children left to right. Succeeds as soon as one does; fails when all have. "Do the first of these that works." |
| Reactive Sequence | A Sequence that rechecks from the left every tick. A condition that turns false interrupts the action after it. |
| Reactive Selector | A Selector that rechecks from the left every tick. A higher-priority branch interrupts a lower one. |
| Parallel | Runs all children together. |

The reactive versions are what make a character respond. A plain Sequence that has moved on to "walk to the target" will not look at "can I still see it?" again until the walk ends; a Reactive Sequence asks every tick and stops the walk the moment the answer is no. Put conditions first and use a Reactive Selector at the top with the most urgent branch on the left.

**Random Selector** is a Selector that tries its children in a random order, shuffled each time it starts: idle animations, routes, taunts.

Decorators have one child: **Invert**, **Always Succeed**, **Repeat** (a number of times, or forever), **Repeat Until Failure**, **Cooldown**, **Timeout** and **Run Once** (runs its child until it finishes once, then answers with that result without running it again: an introduction, a one-time alarm).

## Subtrees

**Run Subtree** runs another `.tbt` file in its place: what is under that file's Root runs as if it were drawn there, with the same blackboard, and the node's result is that tree's. Use it to share a behaviour between characters (one `Wander.tbt` used by guards, animals and villagers) and to keep a big tree readable.

- Select a Run Subtree node and press **Open** (or double-click it) to edit the file it names; **New Subtree File** makes that file if it does not exist yet.
- While the game plays, an open subtree file is shown live for the selected object too, as it runs inside that object's tree.
- Saving a subtree while playing reloads every object whose tree uses it.
- A tree that runs itself, directly or through other files, is refused (that Run Subtree node fails, with a warning) rather than built forever. A file used twice in one tree is shown live for the copy that ran last.

Tree files are read once and shared by every runner that uses them, so a crowd running one tree costs one copy of it.

## The nodes

**Navigation** (needs a Navigation Agent on the object):

| Node | What it does |
|---|---|
| Move To Position | Walks to a fixed point. |
| Move To Object | Walks to the object with a given name, following it. |
| Move To Target | Walks to something remembered on the blackboard, such as what Can See found. With Follow on it keeps up with a moving target. |
| Patrol | Walks to the next child of a named object, in order, wrapping around. Each run visits one waypoint, so pair it with a Wait in a Sequence. |
| Wander | Walks to a random point within a radius of where the character started. |
| Stop Moving, Face Target | Stop the agent; turn toward a remembered object or position. |

**Detection:**

| Node | What it does |
|---|---|
| Can See | Succeeds if an object with a given name is within Range, inside the Field Of View cone in front of the character, and not hidden behind anything with a collider. End the name with `*` to match a prefix (`Enemy*`). |
| Is Near | Succeeds if such an object is within a distance, in any direction and through walls. Use it for hearing or touch. |
| Target Within | Succeeds while a remembered object or position is within a distance. |
| Heard Noise | Succeeds if a noise was made within earshot in the last **Within Seconds**. Remembers where under **Store As** and who made it under Store As + `.source`. Each noise is heard once, so a guard goes to look and then carries on. |

Instead of a name, Can See, Is Near and Move To Object take `#Tag` for any object with that tag (`#Enemy`, `#Player`). What a name or tag matches is gathered once a frame (and again when objects are added, removed or tagged), not looked for through the whole scene by every tree; when many objects match (a crowd looking for each other) they are also sorted into squares, so each looks only at those near it. Of two objects found at exactly the same distance, the older one is kept. Can See's **Sight Points** is 1 for one ray to the middle of the target, 2 to also try its head, 3 to try its head and feet: a target crouched behind low cover is still seen when its head shows.

Noises are made by the game: `AINoise.Make(Scene, position, radius, source)` for a gunshot (`radius` 30), footsteps (3), a thrown bottle landing. A listener hears it if it is within `radius` times its **Hearing**. The source object does not hear its own noise. `AINoise.Forget()` drops them all, for a new level.

Can See and Is Near remember what they found under **Store As** (default `target`), and where it was under that name plus `.position`. The object keeps updating as it moves; the position is where it was last detected, which is what a guard should go and check after losing sight.

**Blackboard:** the tree's memory, shared by all its nodes and kept while the game runs. **Has Value**, **Forget**, **Set Flag** and **Is Flag Set** read and write it; **Set Number** sets a number or adds to it, **Compare Number** compares one with a value (`<`, `<=`, `>`, `>=`, `==`, `!=`), and **Remember Position** stores where the object is (to come back to with Move To Target).

The runner's **Start Values** fills the blackboard when the game starts, so one tree can be tuned per character in the Inspector: `ammo 3; alert false; post 4 0 -2` (each a key and a number, true or false, or a position).

**Events:** **Event Received** succeeds if the game sent that event to the tree (`runner.SendEvent("Hit")`) in the last **Within Seconds**; with **Consume** each event counts once. **Send Event** tells the game something: the runner's `OnTreeEvent` is called with the name.

```beef
let brain = GetComponent<BehaviorTreeRunner>();
brain.SendEvent("Hit");                                   // from the damage code
brain.OnTreeEvent.Add(new (name) => { if (name == "Alarm") alarm.Ring(); });
```

**Actions:** **Wait** (a fixed time, or random between two), **Log**, **Call Method**, and **Chance** (succeeds with a probability, for "sometimes").

**Wander** picks a point the agent can reach (on its baked Navigation Surface) when there is one.

## Watching a tree while the game runs

Open the tree, press Play, and select an object that runs it. The toolbar names the object being watched; with nothing selected, the first object using the tree is shown.

| Colour | Meaning |
|---|---|
| Amber, pulsing | Running now. |
| Green | Succeeded. |
| Red | Failed. |
| Grey | Stopped part-way by a branch with higher priority. |

Results from the latest tick are bright and older ones fade over about a second, so the path the tree is taking stands out and what it did a moment ago is still visible. Links are coloured the same way. The box at the bottom left lists the watched object's blackboard.

Saving a tree while the game is playing reloads it on every object that uses it, so you can adjust a range or a speed and see the result without stopping.

## Running your own code

**Call Method** calls a method by name on any component of the same object. The method takes no parameters. If it returns `bool`, true is Success and false is Failure; anything else counts as Success.

```beef
[Component]
class GuardActions : Component
{
    public int32 ammo = 3;

    public bool HasAmmo() => ammo > 0;      // use as a condition
    public void Shoot() { ammo--; }           // use as an action
}
```

For a node with its own settings, or one that runs over several ticks, derive from `BTNode` and register it at startup (in `GameSetup.Register`):

```beef
class HasAmmoAtLeast : BTNode
{
    protected override BTStatus OnTick(BTContext context)
    {
        let actions = context.Object.GetComponent<GuardActions>();
        return actions != null && actions.ammo >= (int)Number(0) ? .Success : .Failure;
    }
}

BehaviorLibrary.Add("game.ammo", "Game", "Has Ammo At Least", .Condition, new () => new HasAmmoAtLeast())
    .With("Count", .Number, "1")
    .Describe("Succeeds while the guard has this much ammunition.");
```

`Number(i)`, `Text(i)`, `Flag(i)` and `Vector(i)` read the node's settings in the order they were declared. Override `OnStart` and `OnEnd(context, aborted)` to set up and clean up; `aborted` is true when a higher-priority branch stopped the node. `context` gives the object, its scene, the blackboard, the time since the last tick and the object's Navigation Agent as `Mover`.

From any script, `GetComponent<BehaviorTreeRunner>().Blackboard` lets gameplay talk to the tree: `SetFlag("alert", true)`, `SetObject("target", player)`, `SetVector("noise", position)`.

## Multiplayer

Trees think on the server (and in single-player games) only; clients see what they do through the objects' movement and animation. Call `SendEvent` and `AINoise.Make` on the server, where the trees are: a noise a client's player makes should reach the server first (its shot, as the game already sends it). `OnTreeEvent` is called on the server.

## Limits

- Can See still tests rays to points up the target, not its whole shape.
- A tree is interpreted, not compiled (files are shared, but each runner has its own running nodes). Runners tick one after another on the main thread, oldest object first, because nodes (and a project's own) may touch any object; a node's number settings are read from their text once, not every tick.
- There is no undo in the Behavior tab.
- Hearing ignores walls: a noise is heard within its radius whatever is in between.

Tree files from before these additions load unchanged: settings added to a node kind (Can See's Sight Points) take their default.

CPU tests cover subtrees (a shared blackboard, live status by file, files read once and shared, reading a changed file again, refusing a tree that runs itself), events both ways, hearing (where and who, heard once, out of earshot, its own noise, old noises), `#Tag`, Set and Compare Number, Start Values, Chance, Random Selector, Run Once, Duplicate, Sight Points against low cover, link rules and child order, save and load, each flow node and decorator, interruption by a reactive selector, Call Method, a game-defined node, Move To Position, Patrol order, Can See against range, view cone and a wall, Is Near, and a full patrol, chase and return behaviour.

The Sandbox sample's `Scenes/Navigation.tscene` has a **Guard** running `AI/Guard.tbt`: it wanders using the `AI/Wander.tbt` subtree, and when the crate (a `NoiseMaker`) makes a noise it stops, says so with Send Event, goes to look and waits there. Open it with `--behavior AI/Guard.tbt --play --select Guard` to watch.
