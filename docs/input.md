# Input: actions and controllers

Three layers, each usable alone:

- **`Input`** reads the keyboard and mouse directly: `Input.GetKey(KeyCode.Space)`, `Input.MouseDelta`.
- **`Gamepad`** reads controllers directly (engine code): `Gamepad.GetButtonDown(.South)`, `Gamepad.LeftStick`.
- **`InputActions`** is the one to build a game on. The game asks for what the player *means* ("Jump", "Move"), and a list kept in the project says which keys, mouse buttons and controller buttons mean it. The same code then works from the keyboard and mouse and from any controller, and the controls are changed without touching code.

## Input actions

These read this machine's controls, for menus and for what only this player sees. A networked script reads the
same actions from the `TickInput` its `Update(TickInput input, float deltaTime)` gets (`input.MoveDirection`,
`input.Pressed("Jump")`), so the server and every client agree.

```csharp
if (InputActions.Pressed("Jump"))
    Jump();
Vector2 move = InputActions.Vector("Move");   // x right, y forward; no longer than 1
Vector2 look = InputActions.Delta("Look");    // how far to turn this frame
yaw += look.X * sensitivity;
pitch -= look.Y * sensitivity;
```

| Call | Gives |
|---|---|
| `Pressed(name)`, `Held(name)`, `Released(name)` | A button: just went down, is down, just came up. A trigger counts as down past half way. |
| `Value(name)` | How far: 0 to 1 for a button (a trigger gives everything in between), -1 to 1 for an axis. |
| `Vector(name)` | A direction from keys, sticks and the d-pad: x right, y up or forward, length at most 1. |
| `Delta(name)` | How far to move or turn this frame: mouse movement as it comes, plus sticks and keys times their binding's Scale and the time the frame took. For looking around. |
| `FromGamepad(name)` | Whether the action is being worked from a controller right now. |
| `Describe(name)` | What to press for it on the device in the player's hands: "E", or "B" (or "Circle"). For on-screen prompts. |
| `SetMapEnabled(map, on)` | Switches a whole map of actions on or off. |

Directions use one convention everywhere: x is right and y is up or forward, also for mouse movement. An action that does not exist is simply never pressed.

`Input.UsingGamepad` says whether the last thing the player touched was a controller; use it to show the right prompts or to help a controller's aim.

### The Input Actions window

**Window > Input Actions** edits the project's actions; double-clicking `Input.tinput` in the Project window opens it too.

- **Maps** (left) are groups of actions switched on and off together: "Player", "Vehicle", "Menu".
- **Actions** (middle) each give a **Button**, an **Axis** (one number) or a **Direction** (two).
- **Bindings** (right) are the ways of working the chosen action. An action can have any number: a key *and* a controller button, WASD *and* the arrow keys *and* a stick. **Listen** takes the next key, mouse button or controller button you press. **Scale** multiplies what a binding gives; for `Delta` it is how fast a stick or keys turn. **Invert** flips it. The window shows what the action is reading as you try it.

**Save** writes `Input.tinput` in the asset folder. A game that is running picks the change up at once. The file ships with the game (inside its asset pack).

A project with no `Input.tinput` has the engine's **standard actions**, and they stay available by name in a project that does not define them:

| Action | Keyboard and mouse | Controller |
|---|---|---|
| Move | W A S D, arrow keys | Left stick |
| Look | Mouse | Right stick |
| Jump | Space | South (A / Cross) |
| Sprint | Left Shift | Left stick click |
| Crouch | Left Ctrl | East (B / Circle) |
| Fire | Left mouse | Right trigger |
| Use | E | North (Y / Triangle) |
| Reload | R | West (X / Square) |
| Ability1, Ability2 | Q, F | Left and right shoulder |
| Talk (voice chat's push to talk) | V | D-pad down |
| Submit, Cancel | Enter, Esc | South, East |

A project action with **no bindings** of its own that has a standard action's name and kind (a `Jump` button, a `Move` direction) uses the standard bindings until you give it some; the window says so and offers **Copy The Standard Bindings**. `InputActions.CaptureBinding` on such an action copies the standard bindings in first, so rebinding one keeps the rest.

`NetworkScript` and `CharacterMotor` read these for their built-in controls, so a networked player works with a controller with no code. **Start From The Standard Actions** in the window copies them into the project to change.

### Networked action maps

In **Window > Input Actions**, select a gameplay map and check **Networked**. Its actions inherit that setting.
Use the **Networking** selector on an action to override its map. For example, a local push-to-talk action can
live next to networked gameplay actions, and a single vehicle action can opt in from a local map.

```text
map Player networked
action Aim button
bind mouse 1
action Talk button local
bind key V
```

Read these actions from the `TickInput` provided to gameplay. Tallow samples the owner's bindings and uses the
same tick values for prediction, server simulation and replay. Standard gameplay actions such as `Jump`,
`Sprint`, `Crouch`, and `Fire` are already carried by the tick and can be read by name.

```csharp
bool aiming = input.Held("Aim");
bool startedAiming = input.Pressed("Aim");
float throttle = input.Value("Vehicle/Throttle");
Vector2 steering = input.Vector("Vehicle/Steering");
```

`Released(name)` works the same way. Use `Map/Action` when networked maps share an action name. Buttons take one
bit each, axes are sampled from -1 to 1, and vectors use two axes. A project can network up to 32 buttons and 16
axis components. Vector values represent stick or key direction. For mouse look, use the existing tick
`Yaw` and `Pitch`.

The legacy `Input.GetAxis("Horizontal")` and `Input.GetAxis("Vertical")` read local keyboard input.
Use `input.Move.X` and `input.Move.Y` for networked movement. For a custom scalar axis, define an
`axis` action and read it with `InputActions.Value(name)` locally or `input.Value(name)` in a tick.

Host and clients need the same networked action names and kinds. Change those definitions between sessions.
Key and controller bindings can differ. Unmarked maps and actions stay local. Older projects can keep using
the existing `InputButton` controls, including `Custom1` through `Custom8`.

### Letting players change the controls

```csharp
if (InputActions.CaptureBinding("Jump", 0))           // true on the frame a key or button goes down
    Log.Info($"Jump is now {InputActions.BindingName("Jump", 0)}");

string text = InputActions.ToText();                    // save this with the player's settings...
InputActions.LoadText(text);                            // ...and load it when the game starts
```

`CaptureBinding` replaces the action's binding of that number (0 is the first; a number past the end adds one). It
works while input is switched off for a menu.

### The file

`Input.tinput` is plain text, one line each:

```
map Player
action Move vector
bind keys W S A D
bind stick left
action Look vector
bind mousedelta
bind stick right scale 1400
action Jump button
bind key Space
bind pad South
action Throttle axis
bind keyaxis S W
bind padaxis RightTrigger
```

Bindings: `key <Key>`, `mouse <0|1|2>`, `wheel <up|down>`, `mousedelta`, `pad <Button>`, `padaxis <Axis>`, `stick <left|right>`, `dpad`, `keyaxis <minus> <plus>`, `keys <up> <down> <left> <right>`; then optionally `scale <number>` and `invert`.

## Controllers

Any controller SDL knows works with no set-up: Xbox, PlayStation (DualShock 4 and DualSense, by cable or Bluetooth), Switch Pro, Steam Deck and most others. They are noticed when plugged in and when pulled out. Up to four at once; every call takes the controller's number as a last argument, 0 being the first.

Buttons are named by where they sit, so the same code works for every make: **South** is A on an Xbox pad, Cross on a PlayStation pad and B on a Nintendo one.

| | |
|---|---|
| `Gamepad.IsConnected()`, `Gamepad.Count`, `Gamepad.Name()` | Whether there is one, how many, and what it calls itself. |
| `GetButton`, `GetButtonDown`, `GetButtonUp` | A button. `LeftTrigger` and `RightTrigger` count as buttons past half way. |
| `LeftStick`, `RightStick` | x right, y up, length at most 1, with the dead zone (`StickDeadZone`) taken out. |
| `LeftTrigger`, `RightTrigger` | 0 to 1. |
| `Dpad` | The d-pad as a direction. |
| `Rumble(low, high, seconds)` | Shakes it: the heavy and the light motor, 0 to 1. `RumbleEnabled = false` silences every call, for a player's setting. |
| `Kind()` | Xbox, PlayStation, Nintendo or Generic. `ButtonName(button, kind, text)` gives what is printed on the button: "A", "Cross", "R2". |

### Menus

UI documents work with a controller by themselves: the d-pad or left stick moves a highlight between buttons, toggles and sliders, the South button presses, and left and right move a slider. The highlight appears when the player touches the controller and goes when they touch the mouse. The highlight starts on the top-left control, or on the one marked `autofocus` in the markup (`<button autofocus="1" ...>`). Set `UIDocumentData.ControllerNavigation = false` to steer menus yourself.

## Touch screens

On a phone or tablet the game draws its own on-screen controls, made once (at start) with `TouchControls` and bound in the input actions like any other control (`bind touch Fire`), so the game reads them as it reads keys or a controller. They only appear while a touch screen is in use and `TouchControls.Shown` is true (in play, not in a menu, where a tap is a click).

| | |
|---|---|
| `AddStick(name, area, anchor, offset, radius)` | A thumbstick that appears where the thumb lands inside `area` (fractions of the screen: x, y, width, height). Bound as a vector. |
| `AddLook(name, area)` | An area to drag across to turn the view, like the mouse. Bound as a vector (`bind touch Look`). |
| `AddButton(name, label, anchor, offset, radius, dragLooks)` | A round button at `anchor` (0 to 1 each way) plus `offset` in screen units (the short side: the height when held sideways, the width when upright). With `dragLooks`, dragging the finger on it also turns the view through that look area, so one thumb can fire and aim. |
| `AddSwipe(name, source, direction)` | A flick across another control, usually a look area: see below. |

Every control has `visible` (a hidden one is not drawn and takes no touches), `dimmed` (drawn faded: it keeps its place but does nothing right now, which keeps a layout from shifting under the player's thumb), `lit` (drawn filled in, for a switch that is on) and `label`. A stick with `hideWhenIdle` is drawn only while a thumb is on it, where the thumb landed. `TouchControls.Scale` sizes everything at once and `EdgeMargin` keeps it in from the screen's edges (a player's setting, say).

### Flicks

`AddSwipe("CrouchFlick", "Look", .(0, 1))` watches the fingers of the `Look` area without taking any itself, so looking works as before. When a finger that started there is flicked the given way and lifted, the swipe control is down for that one frame. A flick is quick: from touch to lift within `swipeTime` (0.25 s), at least `swipeDistance` screen units (the short side) along the direction (0.12), and mostly along it. A slow drag, however far it goes, is aiming and never a flick.

The view must not move for a flick, yet the look area turns it as the finger moves. So while a stroke could still become a flick (from the moment the finger lands: mostly the flick's way and on pace to cover the distance in time), its turn the flick's way is held back (`swipeHoldsLook`, on by default). If the stroke becomes a flick, the held turn is dropped and the view never moved; as soon as it cannot (it slows, turns aside or runs out of time) the held turn is released at once. Aiming that starts from a resting finger, or moves any other way, is never held; a very quick stroke the flick's way waits at most `swipeTime`.

Being one frame long, a flick suits an action read with `InputActions.Pressed`, or a switch the game flips. Read it once a frame (in `OnUpdate`), not in a network tick's input, which is gathered at the tick rate and could miss it or see it twice. Avoid sideways flicks on a look area: turning quickly is part of aiming.

## Visual scripting

For local input in the graph editor, search for "InputActions", "Gamepad" or "Input". `InputActions > Pressed` with "Jump" typed in, wired to a branch, is the usual start.

For gameplay, drag from **Input** on **On Update**, **On Early Update**, or **On Late Update**.
Choose **Tick Action Held**, **Pressed**, **Released**, **Value**, or **Vector**, and enter an action name.
For example, wire **Tick Action Pressed** with `Jump` into a Branch. The same Input pin feeds movement
and view readers such as **Tick Move Direction** and **Tick Look Rotation**.

## Testing without the hardware

Controllers have been checked this way and through SDL's own mapping; say so if a particular pad misbehaves.
