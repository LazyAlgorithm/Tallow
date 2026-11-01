using System;
using System.Collections;

namespace Tallow;

/// A finger on a touch screen, in window pixels.
class Finger
{
	public uint64 id;
	public Vector2 position, start;
	/// When it came down (Time.RealTime).
	public float startTime;
	/// Movement since the last frame.
	public Vector2 delta;
	public bool down = true;
	/// The on-screen control this finger works, or null.
	public TouchControl owner;
}

/// Fingers on a touch screen (phones, tablets, touch laptops). Filled from the window's events by Application.
static class Touch
{
	static List<Finger> sFingers = new .() ~ DeleteContainerAndItems!(_);
	static Vector2 sPendingMove;
	static float sLastTouchTime = -100;

	/// The fingers on the screen this frame.
	public static List<Finger> Fingers => sFingers;
	/// When a finger last touched the screen (Time.RealTime).
	public static float LastTouchTime => sLastTouchTime;

	static Vector2 ToPixels(ref SDL.Event event)
	{
		// In the interface's units (points), where the controls are drawn.
		let width = Application.Instance != null ? Application.Instance.InterfaceWidth : 1;
		let height = Application.Instance != null ? Application.Instance.InterfaceHeight : 1;
		// SDL_TouchFingerEvent: x and y from 0 to 1 across the window.
		return .(event.ReadFloat(32) * width, event.ReadFloat(36) * height);
	}

	static uint64 FingerId(ref SDL.Event event) => *(uint64*)((uint8*)&event + 24);

	/// Called by Application for each window event.
	public static void OnEvent(ref SDL.Event event)
	{
		switch (event.type)
		{
		case SDL.EVENT_FINGER_DOWN:
			let finger = new Finger();
			finger.id = FingerId(ref event);
			finger.position = finger.start = ToPixels(ref event);
			finger.startTime = Time.RealTime;
			sFingers.Add(finger);
			sLastTouchTime = Time.RealTime;
			TouchControls.FingerDown(finger);
		case SDL.EVENT_FINGER_MOTION:
			for (let finger in sFingers)
			{
				if (finger.id == FingerId(ref event) && finger.down)
				{
					let position = ToPixels(ref event);
					finger.delta += position - finger.position;
					finger.position = position;
				}
			}
			sLastTouchTime = Time.RealTime;
		case SDL.EVENT_FINGER_UP,SDL.EVENT_FINGER_CANCELED:
			for (let finger in sFingers)
			{
				if (finger.id == FingerId(ref event))
					finger.down = false;
			}
		default:
		}
	}

	/// Called once a frame by Input.Poll, after the events: works the on-screen controls, then forgets lifted fingers.
	public static void Update()
	{
		TouchControls.Update();
		for (int i = sFingers.Count - 1; i >= 0; i--)
		{
			let finger = sFingers[i];
			finger.delta = .(0, 0);
			if (!finger.down)
			{
				sFingers.RemoveAt(i);
				delete finger;
			}
		}
	}

	/// True while a finger is on the screen.
	public static bool Touching
	{
		get
		{
			for (let finger in sFingers)
			{
				if (finger.down)
					return true;
			}
			return false;
		}
	}
}

enum TouchControlKind
{
	/// A thumbstick that appears where the thumb lands in its area: a direction, like a controller stick.
	Stick,
	/// An area to drag across to turn the view: movement, like the mouse.
	Look,
	/// A round button: down while touched.
	Button,
	/// A flick across another control (usually a look area), seen when the finger lifts: it never takes a finger of
	/// its own, and is down for the one frame the flick ends on.
	Swipe
}

/// One on-screen control. Its place is an anchor on the screen (0 to 1 each way: (1, 1) is the bottom right) plus an
/// offset in screen units, so the layout keeps its shape on any phone. A screen unit is the screen's short side: its
/// height when held sideways, its width when upright, so a layout made for landscape keeps its proportions in portrait
/// instead of reaching past the screen's narrow width.
class TouchControl
{
	public String name = new .() ~ delete _;
	public String label = new .() ~ delete _;
	public TouchControlKind kind;
	/// Button: centre. Stick: where it rests when not touched.
	public Vector2 anchor, offset;
	/// Button or stick size, in screen units (the short side).
	public float radius = 0.07f;
	/// Stick and look: the screen area where a touch takes the control, as fractions of the screen (x, y, width, height).
	public Vector4 area;
	/// Button: dragging the finger also turns the view through this look control, so a player can fire and aim
	/// with one thumb.
	public String dragLooks = new .() ~ delete _;
	public bool visible = true;
	/// A button drawn filled in, for a switch that is on.
	public bool lit;
	/// A button drawn faded: it keeps its place (so the layout never shifts under the player's thumb) but does
	/// nothing right now, such as Grenade with none left. It still takes touches, so a tap on it is not a look drag.
	public bool dimmed;
	/// Stick: drawn only while a thumb is on it, where the thumb landed; with none, nothing on screen at all.
	public bool hideWhenIdle;
	/// Swipe: the control whose fingers it watches, and the way a flick must go (screen directions: (0, 1) is down).
	public String swipeSource = new .() ~ delete _;
	public Vector2 swipeDirection;
	/// Swipe: how far a flick must travel, in screen units (the short side), and the longest it may take from touch to lift, in
	/// seconds. A slow drag (aiming) is never a flick, however far it goes.
	public float swipeDistance = 0.12f, swipeTime = 0.25f;
	/// Swipe on a look area: while a stroke could still become a flick (mostly the flick's way, and fast enough to
	/// finish in time), the view does not turn the flick's way; if it becomes a flick that turn never happens, and if
	/// it does not (it slows, turns aside or takes too long) the view catches up at once. Ordinary aiming is never
	/// held, and only a stroke that fast and that way is held, for at most swipeTime.
	public bool swipeHoldsLook = true;
	// The stroke being watched: its finger, the turn held back from it, and whether it can still be a flick.
	uint64 mStrokeFinger;
	Vector2 mHeld;
	bool mStroking, mCandidate;

	// This frame.
	public float value, previous;
	public Vector2 vector;
	public Vector2 delta;
	public Finger finger;
	public Vector2 origin;

	public Vector2 Center(Vector2 screen)
	{
		let scale = TouchControls.Scale;
		// Kept in from the edges it is anchored to by EdgeMargin (not at all from a centre anchor).
		let unit = TouchControls.Unit(screen);
		let margin = TouchControls.EdgeMargin * unit;
		return .(anchor.x * screen.x + offset.x * scale * unit + (1 - 2 * anchor.x) * margin.x, anchor.y * screen.y + offset.y * scale * unit + (1 - 2 * anchor.y) * margin.y);
	}

	public float RadiusPixels(Vector2 screen) => radius * TouchControls.Scale * TouchControls.Unit(screen);

	/// A button: touched this frame and not the last.
	public bool Pressed => value > 0.5f && previous <= 0.5f;
	/// A button: held down.
	public bool Held => value > 0.5f;
	/// Swipe: follows the stroke of the finger on its source control this frame (TouchControls.Update).
	public void WatchStroke(Vector2 screen)
	{
		if (kind != .Swipe)
			return;
		let source = TouchControls.Find(swipeSource);
		let finger = source != null ? source.finger : null;
		let length = swipeDirection.Length;
		if (!visible || finger == null || length <= 0)
		{
			if (mStroking && source != null)
				source.delta += mHeld;
			mStroking = false;
			mHeld = .(0, 0);
			return;
		}
		if (!mStroking || mStrokeFinger != finger.id)
		{
			mStroking = true;
			mStrokeFinger = finger.id;
			mHeld = .(0, 0);
			mCandidate = true;
		}
		let way = swipeDirection / length;
		let travel = finger.position - finger.start;
		let along = travel.x * way.x + travel.y * way.y;
		let across = Math.Abs(travel.x * way.y - travel.y * way.x);
		let elapsed = Time.RealTime - finger.startTime;
		let distance = swipeDistance * TouchControls.Unit(screen);
		let looks = swipeHoldsLook && source.kind == .Look;
		if (!finger.down)
		{
			// Lifted: a flick if it was quick, far enough and mostly the flick's way.
			if (elapsed <= swipeTime && along >= distance && along > across * 1.8f)
			{
				value = 1;
				// The turn it held back never happens, and whatever of the flick's way got through is undone: the
				// view ends up where it was before the stroke began, the flick's way.
				if (looks)
					source.delta -= Vector2(way.x * along - mHeld.x, way.y * along - mHeld.y);
			}
			else if (looks)
				source.delta += mHeld;
			mStroking = false;
			mHeld = .(0, 0);
			return;
		}
		if (!looks || !mCandidate)
			return;
		// Could it still be a flick? Not backwards or aside, and on pace to cover the distance in time.
		let onPace = along >= distance * Math.Min(elapsed / swipeTime, 1) * 0.999f;
		if (elapsed <= swipeTime && along >= 0 && along >= across * 1.8f && onPace)
		{
			// Hold back this frame's turn the flick's way.
			let forward = finger.delta.x * way.x + finger.delta.y * way.y;
			let step = Vector2(way.x * forward, way.y * forward);
			source.delta -= step;
			mHeld += step;
		}
		else
		{
			mCandidate = false;
			source.delta += mHeld;
			mHeld = .(0, 0);
		}
	}

	public bool AreaContains(Vector2 point, Vector2 screen) => point.x >= area.x * screen.x && point.x <= (area.x + area.z) * screen.x && point.y >= area.y * screen.y && point.y <= (area.y + area.w) * screen.y;
}

/// The game's on-screen controls for touch screens. A game adds them once (AddStick, AddLook, AddButton) and binds
/// them to its input actions in its .tinput file ("bind touch Fire"), so the same actions work from a keyboard,
/// a controller or a touch screen. The controls only appear on a touch screen, and only while Shown is true (a game
/// turns it off in menus, where a tap is a click).
static class TouchControls
{
	static List<TouchControl> sControls = new .() ~ DeleteContainerAndItems!(_);
	// Binding numbers: a .tinput file can name a control before the game adds it.
	static List<String> sNames = new .() ~ DeleteContainerAndItems!(_);

	/// The game is in play (not in a menu): the controls are drawn and take touches.
	public static bool Shown = true;
	/// How the controls look: the colour of their outlines and labels, and of the disc behind each button that keeps
	/// it readable over a bright scene.
	public static Color Tint = Color(1, 1, 1, 0.7f);
	public static Color Backing = Color(0.02f, 0.05f, 0.1f, 0.35f);
	/// Makes every control bigger or smaller (and further from or nearer to its corner), for a player's taste or
	/// a game's interface scale setting.
	public static float Scale = 1;
	/// How far every control is kept in from the edge of the screen it sits by, in screen units (the short side) (x from the sides,
	/// y from the top and bottom): phones with curved or rounded edges hide what is right at them.
	public static Vector2 EdgeMargin = .(0.06f, 0.03f);

	/// True when the controls are on screen: a touch screen is in use and the game shows them.
	public static bool Active => Shown && Input.UsingTouch && sControls.Count > 0;

	public static List<TouchControl> Controls => sControls;

	public static int32 NameId(StringView name)
	{
		for (int i < sNames.Count)
		{
			if (sNames[i] == name)
				return (int32)i;
		}
		sNames.Add(new String(name));
		return (int32)(sNames.Count - 1);
	}

	public static StringView NameOf(int32 id) => id >= 0 && id < sNames.Count ? sNames[id] : "";

	public static TouchControl Find(StringView name)
	{
		for (let control in sControls)
		{
			if (control.name == name)
				return control;
		}
		return null;
	}

	/// A button by name was pressed this frame (false if there is none, or the controls are not on screen).
	public static bool Pressed(StringView name) => Active && (Find(name)?.Pressed ?? false);
	/// A button by name is held down.
	public static bool Held(StringView name) => Active && (Find(name)?.Held ?? false);

	public static TouchControl FindById(int32 id) => id >= 0 && id < sNames.Count ? Find(sNames[id]) : null;

	static TouchControl Add(StringView name, TouchControlKind kind)
	{
		var control = Find(name);
		if (control == null)
		{
			control = new TouchControl();
			control.name.Set(name);
			sControls.Add(control);
			NameId(name);
		}
		control.kind = kind;
		return control;
	}

	/// A thumbstick taking touches that start in area (fractions of the screen), resting at anchor + offset.
	public static TouchControl AddStick(StringView name, Vector4 area, Vector2 anchor, Vector2 offset, float radius = 0.11f)
	{
		let control = Add(name, .Stick);
		control.area = area;
		control.anchor = anchor;
		control.offset = offset;
		control.radius = radius;
		return control;
	}

	/// An area to drag across to turn the view.
	public static TouchControl AddLook(StringView name, Vector4 area)
	{
		let control = Add(name, .Look);
		control.area = area;
		return control;
	}

	/// A round button at anchor + offset (offset in screen units: the short side) with a short label.
	public static TouchControl AddButton(StringView name, StringView label, Vector2 anchor, Vector2 offset, float radius = 0.07f, StringView dragLooks = "")
	{
		let control = Add(name, .Button);
		control.label.Set(label);
		control.anchor = anchor;
		control.offset = offset;
		control.radius = radius;
		control.dragLooks.Set(dragLooks);
		return control;
	}

	/// A flick across another control, usually a look area: TouchControls.AddSwipe("Crouch", "Look", .(0, 1)) is down
	/// for one frame when a finger that started on Look is flicked downwards and lifted. It never takes a finger of its
	/// own, so the look area works as before; a slow drag is never a flick (swipeTime), and the view does not turn
	/// the flick's way while a stroke could still be one (swipeHoldsLook). Bind it like a button ("bind touch Crouch"); being one frame
	/// long, it suits an action read as pressed, or a switch the game flips.
	public static TouchControl AddSwipe(StringView name, StringView lookSource, Vector2 direction)
	{
		let control = Add(name, .Swipe);
		control.swipeSource.Set(lookSource);
		control.swipeDirection = direction;
		return control;
	}

	public static void Clear()
	{
		ClearAndDeleteItems(sControls);
	}

	/// The length sizes and offsets are measured in: the screen's short side (its height when held sideways).
	public static float Unit(Vector2 screen) => Math.Min(screen.x, screen.y);

	static Vector2 Screen => Application.Instance != null ? Vector2(Application.Instance.InterfaceWidth, Application.Instance.InterfaceHeight) : Vector2(1, 1);

	/// A finger came down: the control under it takes it. Buttons first, then sticks, then look areas.
	public static void FingerDown(Finger finger)
	{
		if (!Shown)
			return;
		let screen = Screen;
		TouchControl best = null;
		// (Hidden controls take no touches: a button a game shows only when it applies leaves the look area there.)
		float bestDistance = float.MaxValue;
		for (let control in sControls)
		{
			if (!control.visible || control.kind != .Button || control.finger != null)
				continue;
			// A little bigger than drawn: thumbs are not precise.
			let distance = (finger.position - control.Center(screen)).Length;
			if (distance < control.RadiusPixels(screen) * 1.3f && distance < bestDistance)
			{
				best = control;
				bestDistance = distance;
			}
		}
		for (let kind in TouchControlKind[2](.Stick, .Look))
		{
			for (let control in sControls)
			{
				if (best == null && control.visible && control.kind == kind && control.finger == null && control.AreaContains(finger.position, screen))
					best = control;
			}
		}
		if (best != null)
		{
			best.finger = finger;
			best.origin = finger.position;
			finger.owner = best;
		}
	}

	public static void Update()
	{
		let screen = Screen;
		for (let control in sControls)
		{
			control.previous = control.value;
			control.value = 0;
			control.vector = .(0, 0);
			control.delta = .(0, 0);
		}
		for (let control in sControls)
		{
			let finger = control.finger;
			if (finger == null)
				continue;
			switch (control.kind)
			{
			case .Button:
				control.value = finger.down ? 1 : 0;
				if (!control.dragLooks.IsEmpty)
				{
					let look = Find(control.dragLooks);
					if (look != null)
						look.delta += finger.delta;
				}
			case .Stick:
				var offset = finger.position - control.origin;
				let reach = control.RadiusPixels(screen);
				// A thumb that goes past the edge drags the stick along, so it never has to come back to recentre.
				if (offset.Length > reach)
				{
					control.origin += offset.Normalized * (offset.Length - reach);
					offset = finger.position - control.origin;
				}
				control.vector = Vector2(offset.x, -offset.y) / Math.Max(reach, 1);
				control.value = control.vector.Length;
			case .Look:
				control.delta += finger.delta;
			case .Swipe:
				break;
			}
		}
		// Flicks: watched while the stroke lasts, recognised as the finger lifts, while the control it worked still
		// holds the finger.
		for (let control in sControls)
			control.WatchStroke(screen);
		// Lifted fingers, and fingers on controls that have gone, let go.
		for (let control in sControls)
		{
			let finger = control.finger;
			if (finger == null)
				continue;
			if (!finger.down || !Shown || !control.visible)
			{
				finger.owner = null;
				control.finger = null;
			}
		}
	}

	/// Draws the controls. GameApp calls this inside its full-screen interface window.
	public static void Draw()
	{
		if (!Active)
			return;
		let screen = Screen;
		let faint = Color(Tint.r, Tint.g, Tint.b, Tint.a * 0.35f);
		let pressed = Color(Tint.r, Tint.g, Tint.b, Tint.a * 0.45f);
		let thickness = Math.Max(2.0f, Unit(screen) * 0.005f);
		for (let control in sControls)
		{
			if (!control.visible)
				continue;
			switch (control.kind)
			{
			case .Button:
				let center = control.Center(screen);
				let radius = control.RadiusPixels(screen);
				let fade = control.dimmed ? 0.35f : 1.0f;
				let ink = Color(Tint.r, Tint.g, Tint.b, Tint.a * fade);
				ImGui.DrawCircleFilled(.(center.x, center.y), radius, Color(Backing.r, Backing.g, Backing.b, Backing.a * fade));
				if (control.value > 0 || control.lit)
					ImGui.DrawCircleFilled(.(center.x, center.y), radius, control.value > 0 ? pressed : faint);
				ImGui.DrawCircle(.(center.x, center.y), radius, ink, thickness);
				if (!control.label.IsEmpty)
				{
					// The label fits the button: a size from the button's own, smaller for longer words.
					let fontSize = Math.Clamp(radius * 1.9f / Math.Max(control.label.Length, 4), 10.0f, radius * 0.5f);
					ImGui.PushFontSize(fontSize);
					let size = ImGui.CalcTextSize(control.label.CStr());
					ImGui.DrawText(.(Math.Round(center.x - size.x * 0.5f), Math.Round(center.y - size.y * 0.5f)), ink, control.label.CStr());
					ImGui.PopFont();
				}
			case .Stick:
				if (control.hideWhenIdle && control.finger == null)
					continue;
				let reach = control.RadiusPixels(screen);
				let resting = control.Center(screen);
				let center = control.finger != null ? control.origin : resting;
				ImGui.DrawCircle(.(center.x, center.y), reach, faint, thickness);
				let knob = center + Vector2(control.vector.x, -control.vector.y) * reach;
				ImGui.DrawCircleFilled(.(knob.x, knob.y), reach * 0.42f, control.finger != null ? pressed : faint);
			case .Look:
			case .Swipe:
			}
		}
	}
}
