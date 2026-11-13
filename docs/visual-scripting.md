# Visual scripting

A script graph (`.tgraph`) compiles to an ordinary C#-style Beef component (`<Name>.bf` next to it), so anything it
does works the same as code: networking, hot reload, the Inspector. Graphs are laid out like Unreal's Blueprints.

## Adding nodes

Right-click the canvas (or drag a link into empty space) for the add-node menu. With nothing typed it shows nested
categories in Blueprint order:

| Category | What is in it |
| --- | --- |
| Add Event | On Start (Event BeginPlay), On Update (Event Tick), On Fixed/Late Update, On Awake, On Enable/Disable, On Destroy, On GUI, Custom Event; **Input**: On Input Action Pressed/Released, On Key Pressed/Released; **Networking**: On Network Event |
| Flow Control | Branch, Sequence, For Loop, For Loop with Break, While Loop, Do Once, Do N, Flip Flop, Gate, Delay, Retriggerable Delay, Switch on Int, Switch on String, Is Valid, Call Custom Event |
| Variables | Get and Set for the graph's variables |
| Math | Float, Integer, Boolean, Vector, Vector 2D, Rotation, Interpolation (Lerp, FInterp To, VInterp To, RInterp To, Map Range Clamped...), Trig, Random, Color |
| Utilities | Literals, String (Append, To String...), Self, Is Valid, Select |
| Transformation | Get/Set World Location and Rotation, Add World Offset, Look At, Forward/Right/Up Vector |
| Game | Spawn Prefab, Destroy, Find Object By Name/With Tag, Has Tag, Quit Game; **Time**: game time, delta seconds, time dilation |
| Physics, Collision | Add Force/Impulse/Torque, velocity; Line Trace By Channel, Raycast, Sphere Trace |
| Input | Keyboard, Mouse, Input Actions (Held/Pressed/Released/Value/Vector/Delta) |
| Audio | Play Sound 2D, Play Sound at Location |
| Debug | Print String, Print Number, Draw Debug Line/Sphere |

After the hand-made nodes, each category also lists the engine's classes that belong there (Game > Scene,
Rendering > Light, Networking > Network Manager...) with a node per public member, read from the engine's source.
Your own scripts' public members are under **My Scripts**, `[GraphNode]` methods under **Code**, and data
components under **ECS**.

Typing searches titles, categories and Unreal's names for the same thing, so "BeginPlay", "Tick", "Print String",
"LineTrace" or "SpawnActor" find the Tallow node.

## Nodes for any type

Nodes that exist for several types are one node: place **Add**, **Multiply**, **Lerp**, **Equal**, **Split**,
**Print String**, **To String**, **Select** (or any typed version, such as Add (Float)) and link a value into it; it
switches to the version for that type, as overloads do in code. Linking a vector into Add makes it Add (Vector);
a vector and a float into Multiply makes Multiply (Vector * Float); a rotation and a vector makes Rotate Vector. Its
title shows the version it is. Values you typed in are kept where the pin's type stays the same.

**Split** takes a Vector (X, Y, Z), Vector 2D (X, Y), Rotation (its Euler angles in degrees: X, Y, Z) or Color (R, G,
B, A). **Print String** prints anything: numbers, booleans, vectors, rotations (as Euler angles), colors, objects and
components (by name).

## Variables

A variable can be a Boolean, Integer, Float, String, Vector 2D, Vector, Rotation, Color or **Object**. An Object
variable says what it refers to (GameObject, Transform, or any component, the engine's or your own), and which
object is picked per object in the Inspector, the same as a reference field in code. Game > Get Component has a
node per component type for taking one off an object; Is Valid works on objects and components.

## Comments

Press **C** on the canvas, or pick **Add Comment** at the top of the right-click menu, for a comment box (around the
selected node if there is one). Drag it by any empty part and everything inside moves with it; drag its bottom-right
corner to resize. Select it to change its title and colour; Delete removes the box and leaves its nodes.

## Flow

An exec (white) output links to one input; an exec input takes any number of links, so several paths can run into
the same node. Some flow nodes have more than one exec input, and what they do depends on which one runs:
Do Once and Do N have **Reset**, Gate has **Open**, **Close** and **Toggle**, For Loop with Break has **Break**.

Delay and Retriggerable Delay count down in Update and run **Completed** when the time is up (Delay ignores new
starts while it is counting; Retriggerable Delay starts again). A graph with a Delay gets an Update method even
without an On Update node.

A Custom Event becomes a public method (`Custom_<Name>`); Call Custom Event with the same name runs it, and code can
call it too. Input events run inside Update, each under its own condition.

Nodes that keep state between frames (Do Once, Do N, Flip Flop, Gate, Delay) keep it per object, in fields of the
generated component.

## Test switches

- `--graph-node-test <text>`: writes a graph for every node whose title has the text in it (`*` for every
  hand-made node, plus a graph using the flow-control nodes together) to `src/GraphNodeTest`; build the project to
  check they all compile.
- `--graph-menu-test <graph>`: opens the graph with the add-node menu showing and logs the menu tree
  (`GRAPH-MENU` lines). With `--graph-compile-test` it only compiles the graph to `<graph>.test.bf`.
