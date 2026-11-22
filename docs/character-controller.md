# Character controller

`CharacterController` moves an object by sweeping a shape through the world with Jolt's virtual character. It walks up steps, stands on slopes up to a limit, follows the floor downhill, rides moving platforms and pushes dynamic bodies. Use it instead of a Rigidbody and collider on anything that walks: players, props a player controls, creatures.

Add it from Add Component > Physics. The object needs no Rigidbody and no collider; rays and shape queries still hit the character and report its object.

## Shapes

| Field | Meaning |
|---|---|
| Shape | Capsule or Box. |
| Radius, Height | Capsule size; height includes the rounded tips. |
| Box Size | Full width, height and depth of the box. |
| Edge Radius | How far the box's edges and corners are rounded. |
| Center | Middle of the shape relative to the object's origin. Use `(0, height / 2, 0)` when the origin is at the feet. |
| Turn Shape With Object | Rotate the shape with the object. Off by default. |

A capsule slides around obstacles most smoothly and suits people and creatures. A box matches crates and furniture. Rounding its edges (0.05 to 0.15 works well) stops it catching on the seams between floor triangles and on small lips, and lets it ride over an edge instead of stopping dead.

The box stays axis-aligned unless Turn Shape With Object is on. Rotation is not swept, so turning a long box beside a wall can push a corner into the wall. Keep the box square in X and Z and rotate only the visual model, or turn the option on for boxes that are nearly square.

## Movement settings

| Field | Meaning |
|---|---|
| Step Height | Tallest step it walks up, and how far it follows the floor down. |
| Max Slope | Steepest slope in degrees it can stand and walk on. |
| Mass, Push Strength | How hard it pushes dynamic bodies, in kilograms and newtons. |
| Gravity Scale | Multiplies scene gravity in `SimpleMove`. |
| Jump Grace | Seconds after leaving the ground during which a jump is still allowed. It covers the ticks a rounded shape spends rolling over a step's edge, and a press that comes just past a ledge. |
| Soft Character Contact | Other soft characters ease this one aside instead of stopping against it. Turn off for a character that should be a solid obstacle. |
| Separation Speed | How quickly overlapping soft characters are pushed apart, in metres per second per metre of overlap. |

## Moving it

The controller moves only when a script tells it to. Call one of these once per tick, from `Update` with the tick's
input (the same on the server and every client in a network session):

```csharp
public override void Update(TickInput input, float deltaTime)
{
    var controller = GetComponent<CharacterController>();

    // Walking: you give the horizontal velocity; falling, gravity and jumping are handled.
    controller.SimpleMove(input.MoveDirection * speed, deltaTime, input.Pressed("Jump") ? 6.5f : 0f);

    // Full control: exactly this velocity, no gravity added (flying, swimming, ladders).
    controller.Move(velocity, deltaTime);
}
```

After a move, `IsGrounded`, `CanJump` (grounded, or within Jump Grace of it), `AirTime`, `IsOnSteepGround`, `Velocity` (already reduced by whatever it hit), `GroundNormal` and `GroundVelocity` describe the result. `Teleport(position, velocity)` places it somewhere; setting `Transform.Position` directly also works and is picked up on the next move.

## Changing shape at run time

```csharp
if (!controller.SetBox(new Vector3(1.2f, 0.8f, 1.2f), 0.1f))
    Log.Info("Not enough room to become that here.");
controller.SetCapsule(0.35f, 1.8f);
```

`SetBox` and `SetCapsule` return false and change nothing when the new shape does not fit where the character
stands. (Engine code that edits the component's fields itself calls `ApplyShape()`, which gives the same answer.)

## Characters meeting characters

Two characters with Soft Character Contact on pass through each other's shape and are eased apart over a few ticks, the lighter one moving more. A walking character nudges a standing one aside and gets past, so players cannot wall each other in. The push is applied when a character moves, so a character that no script is moving stays where it is.

A character with the option off is solid: others stop against it and it is not moved. Rays, shape queries and dynamic bodies hit every character either way. Call `ApplyShape()` after changing the option while playing.

## Ready-made drivers

- **CharacterMotor** is the networked player: WASD, Shift to sprint, Space to jump, mouse to turn. Its fields set walk and sprint speed, jump speed, acceleration, air control and whether the object turns to face the look direction. For a different character, derive from it and override `WishVelocity` (how input becomes a direction and speed), `GatherInput` (which keys do what) or `Simulate` (everything). It runs inside the network tick, so prediction and replay work; a character's position and velocity are part of the state that is rewound.
- **NavigationAgent** on the same object walks its path through the controller, so agents climb steps and stay on slopes. Set the agent's Base Offset to match where the controller's feet are.

Characters that still have a Rigidbody and collider instead of a controller keep working with both drivers, without step climbing.

## Limits

- The shape is a capsule or a box. Hit detection that needs a prop's exact outline should use a separate collider query against the prop's own shape.
- On the rounded edge of a step a capsule's `IsGrounded` is false for a few ticks while it rolls over. Use `CanJump` for anything that should not flicker there; `SimpleMove` already does.
- Crouching is a shape change: call `SetCapsule` with the lower height and check the result before standing up again.

CPU tests cover standing, stairs up and down for both shapes, a ledge taller than the step height, a ramp, an unstandable slope, jumping, ray hits, shape changes that fit and that do not, network state restore including the jump grace, a late jump past a ledge, jump availability on every tick of a stair climb, soft and solid contact between characters, the character motor, pushing a crate and a navigation agent climbing steps.
