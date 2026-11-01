using System;
using System.Collections;
using Tallow;

namespace InputTests;

/// Controllers and input actions, with the keyboard, mouse and a controller all pretended.
class Program
{
	static bool Check(bool condition, StringView what)
	{
		Console.WriteLine(scope $"{(condition ? "PASS" : "FAIL")}: {what}");
		return condition;
	}

	/// One pretend frame: what was down is now "before", then `set` says what the devices are doing.
	static void Frame(delegate void() set = null, float seconds = 1.0f / 60)
	{
		Time.UnscaledDeltaTime = seconds;
		Input.SimulateStep(seconds);
		if (set != null)
			set();
		Input.SimulateEnd();
	}

	static bool Near(float a, float b) => Math.Abs(a - b) < 0.001f;

	public static int Main(String[] args)
	{
		bool ok = true;

		// ---- the controller by itself ----
		ok &= Check(Gamepad.Count == 0 && !Gamepad.IsConnected() && !Gamepad.GetButton(.South) && Gamepad.LeftStick == .(0, 0) && Gamepad.Name().IsEmpty, "with no controller every question has a quiet answer");
		Gamepad.Simulate();
		Frame(scope () => Gamepad.SimulateButton(.South, true));
		GamepadButton which;
		let any = Gamepad.AnyButtonDown(out which);
		ok &= Check(Gamepad.Count == 1 && Gamepad.GetButton(.South) && Gamepad.GetButtonDown(.South) && any && which == .South, "a button reads as down, and as just pressed on its first frame");
		Frame();
		ok &= Check(Gamepad.GetButton(.South) && !Gamepad.GetButtonDown(.South), "then only as held");
		Frame(scope () => Gamepad.SimulateButton(.South, false));
		ok &= Check(!Gamepad.GetButton(.South) && Gamepad.GetButtonUp(.South), "and as released once");
		Frame(scope () => Gamepad.SimulateStick(false, .(0.1f, 0.1f)));
		ok &= Check(Gamepad.LeftStick == .(0, 0), "a stick resting slightly off centre reads as centred");
		Frame(scope () => Gamepad.SimulateStick(false, .(0, 1)));
		ok &= Check(Near(Gamepad.LeftStick.y, 1) && Near(Gamepad.LeftStick.x, 0) && Gamepad.NavDirection == 0, "pushed up it reads up, and menus are told once");
		Frame(null, 0.1f);
		ok &= Check(Gamepad.NavDirection == -1, "holding it does not repeat at once");
		Frame(null, 0.35f);
		ok &= Check(Gamepad.NavDirection == 0, "but does after a moment");
		Frame(scope () =>
			{
				Gamepad.SimulateStick(false, .(0, 0));
				Gamepad.SimulateAxis(.RightTrigger, 0.8f);
			}
			);
		ok &= Check(Gamepad.RightTrigger > 0.7f && Gamepad.GetButtonDown(.RightTrigger) && Gamepad.NavDirection == -1, "a trigger is an amount, and a button once past half way");
		Frame(scope () => Gamepad.SimulateAxis(.RightTrigger, 0));
		let names = scope String();
		Gamepad.ButtonName(.South, .Xbox, names);
		names.Append(' ');
		Gamepad.ButtonName(.South, .PlayStation, names);
		names.Append(' ');
		Gamepad.ButtonName(.South, .Nintendo, names);
		names.Append(' ');
		Gamepad.ButtonName(.RightTrigger, .PlayStation, names);
		ok &= Check(names == "A Cross B R2", "buttons are named as each make of controller prints them");

		// ---- the standard actions, with no project file ----
		Frame(scope () => Input.SimulateKey(.Space, true));
		ok &= Check(InputActions.Pressed("Jump") && InputActions.Held("Jump") && !Input.UsingGamepad && !InputActions.FromGamepad("Jump"), "Jump is pressed with the space bar");
		Frame(scope () =>
			{
				Input.SimulateKey(.Space, false);
				Gamepad.SimulateButton(.South, true);
			}
			);
		ok &= Check(InputActions.Held("Jump") && Input.UsingGamepad && InputActions.FromGamepad("Jump"), "or with the controller's bottom button, and the engine knows which is in use");
		Frame(scope () => Gamepad.SimulateButton(.South, false));
		ok &= Check(InputActions.Released("Jump") && !InputActions.Held("Jump"), "letting go is seen once");
		Frame(scope () =>
			{
				Input.SimulateKey(.W, true);
				Input.SimulateKey(.D, true);
			}
			);
		let diagonal = InputActions.Vector("Move");
		ok &= Check(Near(diagonal.Length, 1) && diagonal.x > 0.7f && diagonal.y > 0.7f, "two movement keys give a diagonal no faster than straight ahead");
		Frame(scope () =>
			{
				Input.SimulateKey(.W, false);
				Input.SimulateKey(.D, false);
				Gamepad.SimulateStick(false, .(-0.6f, 0));
			}
			);
		let half = InputActions.Vector("Move");
		ok &= Check(half.x < -0.4f && half.x > -0.6f && Near(half.y, 0), "the left stick moves too, as gently as it is pushed");
		Frame(scope () =>
			{
				Gamepad.SimulateStick(false, .(0, 0));
				Input.SimulateMouseDelta(.(10, -4));
			}
			);
		let mouseLook = InputActions.Delta("Look");
		ok &= Check(Near(mouseLook.x, 10) && Near(mouseLook.y, 4) && !Input.UsingGamepad, "moving the mouse up and right looks up and right");
		Frame(scope () => Gamepad.SimulateStick(true, .(1, 0)), 0.5f);
		let stickLook = InputActions.Delta("Look");
		ok &= Check(Near(stickLook.x, 700) && Near(stickLook.y, 0) && InputActions.FromGamepad("Look"), "the right stick looks at its binding's speed, by the time that passed");
		Frame(scope () =>
			{
				Gamepad.SimulateStick(true, .(0, 0));
				Gamepad.SimulateAxis(.RightTrigger, 0.7f);
			}
			);
		ok &= Check(InputActions.Held("Fire") && InputActions.Value("Fire") > 0.6f && InputActions.Value("Fire") < 0.8f, "Fire on a trigger is held, and says how far it is pulled");
		Frame(scope () => Gamepad.SimulateAxis(.RightTrigger, 0));
		Input.Enabled = false;
		Frame(scope () => Input.SimulateKey(.Space, true));
		ok &= Check(!InputActions.Held("Jump") && !InputActions.Pressed("Jump") && InputActions.Vector("Move") == .(0, 0), "with input switched off (a menu has it) actions read as untouched");
		Input.Enabled = true;
		Frame(scope () => Input.SimulateKey(.Space, false));
		ok &= Check(InputActions.Find("Nonsense") == null && !InputActions.Held("Nonsense") && InputActions.Value("Nonsense") == 0, "an action that does not exist is simply never pressed");

		// ---- a project's own actions ----
		InputActions.LoadText("""
			map Driving
			action Throttle axis
			bind keyaxis S W
			bind padaxis RightTrigger
			action Horn button
			bind key H
			bind pad West
			action Steer vector
			bind keys UpArrow DownArrow LeftArrow RightArrow
			bind stick left scale 90
			map Menu
			action Jump button
			bind key J
			""");
		ok &= Check(InputActions.Maps.Count == 2 && InputActions.Maps[0].actions.Count == 3 && InputActions.Find("Throttle").kind == .Axis && InputActions.Find("Steer").bindings.Count == 2, "a project's actions are read from text");
		Frame(scope () => Input.SimulateKey(.S, true));
		ok &= Check(Near(InputActions.Value("Throttle"), -1), "an axis goes negative on its first key");
		Frame(scope () =>
			{
				Input.SimulateKey(.S, false);
				Gamepad.SimulateAxis(.RightTrigger, 0.5f);
			}
			);
		ok &= Check(InputActions.Value("Throttle") > 0.4f && InputActions.Value("Throttle") < 0.55f, "and follows a trigger");
		Frame(scope () =>
			{
				Gamepad.SimulateAxis(.RightTrigger, 0);
				Input.SimulateKey(.Space, true);
				Input.SimulateKey(.J, true);
			}
			);
		ok &= Check(InputActions.Held("Jump") && InputActions.Find("Jump").bindings[0].key == .J && InputActions.Held("Sprint") == false && InputActions.Find("Sprint") != null, "the project's Jump replaces the standard one; standard actions it does not mention are still there");
		InputActions.SetMapEnabled("Menu", false);
		Frame();
		ok &= Check(!InputActions.Held("Jump") && !InputActions.IsMapEnabled("Menu") && InputActions.IsMapEnabled("Driving"), "an action of a map that is switched off reads as untouched");
		InputActions.SetMapEnabled("Menu", true);
		Frame(scope () =>
			{
				Input.SimulateKey(.Space, false);
				Input.SimulateKey(.J, false);
			}
			);
		let written = scope String();
		InputActions.ToText(written);
		InputActions.LoadText(written);
		let again = scope String();
		InputActions.ToText(again);
		ok &= Check(written == again && written.Contains("bind stick left scale 90") && written.Contains("bind keyaxis S W") && written.Contains("action Steer vector"), "written out and read back they are the same");

		// ---- telling the player, and letting them choose ----
		let what = scope String();
		Frame(scope () => Input.SimulateKey(.H, true));
		InputActions.Describe("Horn", what);
		Frame(scope () =>
			{
				Input.SimulateKey(.H, false);
				Gamepad.SimulateButton(.West, true);
				Gamepad.SimulateKind(.PlayStation);
			}
			);
		what.Append(" / ");
		InputActions.Describe("Horn", what);
		ok &= Check(what == "H / Square", "the prompt for an action names the key, or the button of the controller in the player's hands");
		Frame(scope () => Gamepad.SimulateButton(.West, false));
		Input.Enabled = false;
		Frame(scope () => Input.SimulateKey(.K, true));
		InputBinding captured;
		let got = InputActions.Capture(out captured);
		Input.Enabled = true;
		ok &= Check(got && captured.kind == .Key && captured.key == .K && InputActions.SetBinding("Horn", 0, captured), "the next key pressed can be captured, also while a menu has input switched off, and given to an action");
		Frame();
		ok &= Check(InputActions.Held("Horn"), "which then answers to it");
		Frame(scope () =>
			{
				Input.SimulateKey(.K, false);
				Gamepad.SimulateButton(.DpadLeft, true);
			}
			);
		ok &= Check(InputActions.Capture(out captured) && captured.kind == .PadButton && captured.button == .DpadLeft && Gamepad.NavDirection == 3, "a controller button can be captured the same way");
		Gamepad.StopSimulating();
		ok &= Check(Gamepad.Count == 0, "the pretend controller goes away again");

		Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
		return ok ? 0 : 1;
	}
}
