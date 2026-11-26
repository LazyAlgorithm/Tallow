using System;
using System.Collections;

namespace Tallow;

/// `--daynight-net-test`: no window. Plays a host and a client (and one joining late) in one process on loopback for
/// 60 s of ticks, checks the Day / Night clock is the server's (N4a): every machine's time agrees within a tick, a
/// time and a pace change made on the host arrive, the server sends nothing once the settings have been sent, a
/// client joining late matches, a client's own changes are ignored (and warned about once), and an Offline scene
/// keeps its own clock and sends nothing.
static class DayNightNetTest
{
	const int32 Port = 47821;
	const int32 Ticks = 3600;

	static int sFailed;

	static void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"daynight-net: {(ok ? "ok" : "FAIL")} {what}");
		if (!ok)
			sFailed++;
	}

	/// Hours a tick at the scene's day length.
	static double HoursPerTick(float dayLengthMinutes) =>
		dayLengthMinutes > 0 ? (24.0 / (dayLengthMinutes * 60.0)) / Time.TickRate : 0;

	public static int Run()
	{
		let hostScene = scope Scene();
		let clientScene = scope Scene();
		let lateScene = scope Scene();

		Setup(hostScene, 10, 24, 40);
		Setup(clientScene, 0, 60, 0); // Deliberately different: the server's values must win.
		Setup(lateScene, 3, 30, -20);

		let host = new NetworkManager(hostScene);
		hostScene.Network = host;
		host.OptimizeSnapshots = false;
		host.FieldDeltas = false;

		let client = new NetworkManager(clientScene);
		clientScene.Network = client;
		client.OptimizeSnapshots = false;
		client.FieldDeltas = false;

		if (!host.StartServer((uint16)Port, true))
		{
			Check(false, "the host starts listening");
			return 1;
		}
		if (!client.StartClient("127.0.0.1", (uint16)Port))
		{
			Check(false, "the client starts connecting");
			return 1;
		}

		NetworkManager late = null;
		const int32 LateStart = 2400;
		const int32 TimeChange = 900;
		const int32 SpeedChange = 1800;
		const int32 IgnoredAt = 1000;
		int32 bytesBeforeIdle = 0, bytesAfterIdle = 0;
		double worstTicks = 0;
		int32 worstAt = -1;
		int32 settleUntil = 120;
		bool sawTimeChange = false, sawSpeedChange = false, sawLate = false;

		for (int32 i = 0; i < Ticks; i++)
		{
			if (i == TimeChange)
			{
				hostScene.Environment.timeOfDay = 18;
				settleUntil = i + 5;
			}
			if (i == SpeedChange)
			{
				hostScene.Environment.dayLengthMinutes = 12; // Twice as fast.
				settleUntil = i + 5;
			}
			if (i == IgnoredAt)
			{
				// What a script or the inspector does on a client: all of it is the server's.
				clientScene.Environment.timeOfDay = 4;
				clientScene.Environment.dayNightPaused = true;
				clientScene.Environment.dayLengthMinutes = 5;
				clientScene.Environment.latitude = 0;
			}
			if (i == LateStart)
			{
				late = new NetworkManager(lateScene);
				lateScene.Network = late;
				late.OptimizeSnapshots = false;
				late.FieldDeltas = false;
				if (!late.StartClient("127.0.0.1", (uint16)Port))
					Check(false, "the late client starts connecting");
				settleUntil = i + 30;
			}

			host.PreTick();
			host.PostTick();
			client.PreTick();
			client.PostTick();
			if (late != null)
			{
				late.PreTick();
				late.PostTick();
			}
			DayNight.Update(hostScene, Time.FixedDeltaTime);
			DayNight.Update(clientScene, Time.FixedDeltaTime);
			if (late != null)
				DayNight.Update(lateScene, Time.FixedDeltaTime);

			// The picture: both machines' clocks, compared in ticks of the clock's own pace.
			let hostEnv = hostScene.Environment;
			let clientEnv = clientScene.Environment;
			if (i > settleUntil && host.IsConnected && client.IsConnected)
			{
				let perTick = HoursPerTick(hostEnv.dayLengthMinutes);
				if (perTick > 0)
				{
					let ticks = Math.Abs((double)hostEnv.timeOfDay - clientEnv.timeOfDay) / perTick;
					if (ticks > worstTicks)
					{
						worstTicks = ticks;
						worstAt = i;
					}
				}
			}
			if (i == TimeChange + 10)
			{
				sawTimeChange = Math.Abs(clientEnv.timeOfDay - hostEnv.timeOfDay) < (float)HoursPerTick(hostEnv.dayLengthMinutes) * 1.5f &&
					clientEnv.timeOfDay > 17.9f;
				Check(sawTimeChange, scope $"the host's time change reaches the client (host {hostEnv.timeOfDay:F2}, client {clientEnv.timeOfDay:F2})");
			}
			if (i == SpeedChange + 10)
			{
				sawSpeedChange = clientEnv.dayLengthMinutes == 12;
				Check(sawSpeedChange, scope $"the host's pace change reaches the client ({clientEnv.dayLengthMinutes} min a day)");
			}
			if (i == IgnoredAt + 10)
			{
				Check(DayNight.ChangeIgnored(client), "a client that changes Day / Night is warned once");
				Check(!clientEnv.dayNightPaused && clientEnv.dayLengthMinutes == 24 && clientEnv.latitude == 40 &&
					Math.Abs(clientEnv.timeOfDay - hostEnv.timeOfDay) < (float)HoursPerTick(hostEnv.dayLengthMinutes) * 1.5f,
					scope $"a client's changes are ignored (time {clientEnv.timeOfDay:F2}, pause {clientEnv.dayNightPaused}, day {clientEnv.dayLengthMinutes}, latitude {clientEnv.latitude})");
			}
			if (i == 2700)
				bytesBeforeIdle = DayNight.BytesSent(host);
			if (i == 3500)
				bytesAfterIdle = DayNight.BytesSent(host);
			if (i == 3000 && late != null)
			{
				let lateEnv = lateScene.Environment;
				let perTick = HoursPerTick(hostEnv.dayLengthMinutes);
				let ticks = perTick > 0 ? Math.Abs(lateEnv.timeOfDay - hostEnv.timeOfDay) / perTick : 0;
				sawLate = late.IsConnected && ticks <= 1.01;
				Check(sawLate, scope $"a client joining late matches the server (host {hostEnv.timeOfDay:F2}, late {lateEnv.timeOfDay:F2}, {ticks:F2} ticks)");
				Check(Math.Abs(lateEnv.latitude - 40) < 1e-4f && Math.Abs(lateEnv.dayLengthMinutes - 12) < 1e-4f, "a client joining late gets the server's settings");
			}

			SDL.SDL_DelayNS(1000000);
		}

		Check(host.IsConnected && client.IsConnected, "the session stayed up for the whole run");
		Check(worstTicks <= 1.01, scope $"the clocks agree within a tick all through (worst {worstTicks:F3} ticks at {worstAt})");
		Check(sawTimeChange && sawSpeedChange && sawLate, "the change and late-join checks ran");
		Check(DayNight.BytesSent(host) > 0, "the server sent the clock's settings");
		Check(bytesBeforeIdle == bytesAfterIdle, scope $"nothing is sent while the clock is idle ({bytesBeforeIdle} B, then {bytesAfterIdle} B)");
		Check(DayNight.BytesSent(client) == 0 && DayNight.BytesSent(late) == 0, "clients send no clock messages");

		// The simulation clock is on the server's tick, and the drawn time is the eased view of it.
		let hostNow = DayNight.SimulationTime(hostScene);
		let perSimTick = HoursPerTick(hostScene.Environment.dayLengthMinutes);
		Check(Math.Abs(hostNow - DayNight.SimulationTime(clientScene)) / perSimTick <= 2.01,
			scope $"the simulation clocks are on ticks (host {hostNow:F4} h, client {DayNight.SimulationTime(clientScene):F4} h)");
		Check(Math.Abs(DayNight.ViewTime(hostScene) - hostScene.Environment.timeOfDay) < 1e-6, "the host draws the clock's view time");

		// An Offline scene keeps its own clock and sends nothing.
		let offlineScene = scope Scene();
		let offline = new NetworkManager(offlineScene);
		offlineScene.Network = offline;
		Setup(offlineScene, 8, 24, 40);
		for (int32 i = 0; i < 3600; i++)
			DayNight.Update(offlineScene, Time.FixedDeltaTime);
		Check(Math.Abs(offlineScene.Environment.timeOfDay - 9) < 1e-3f, scope $"an Offline scene's clock runs by itself (60 s is 1 h: {offlineScene.Environment.timeOfDay:F3})");
		Check(DayNight.BytesSent(offline) == 0, "an Offline scene sends nothing");
		Check(DayNight.SimulationTime(offlineScene) == offlineScene.Environment.timeOfDay, "an Offline scene's simulation time is its own clock");

		Console.WriteLine(sFailed == 0 ? "DAYNIGHT NET TEST PASS" : scope $"DAYNIGHT NET TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}

	static void Setup(Scene scene, float timeOfDay, float dayLengthMinutes, float latitude)
	{
		let env = scene.Environment;
		env.dayNight = true;
		env.timeOfDay = timeOfDay;
		env.dayLengthMinutes = dayLengthMinutes;
		env.latitude = latitude;
		env.dayOfYear = 172;
		env.autoColors = false;
	}
}
