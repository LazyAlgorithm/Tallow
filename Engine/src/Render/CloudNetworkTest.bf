using System;
using System.Collections;

namespace Tallow;

/// `--cloud-test network`: no window. Plays a host, a client and a late joiner in one process on loopback (C3c) and
/// checks the clouds are the same on every peer without any cloud network state: the weather offset (the wind's drift
/// on the shared clock plus the seed) agrees within a tick, a client joining late finds the same weather, and the
/// weather keeps drifting while the Day / Night clock is paused. The cloud settings are the scene's, so a client
/// never sends cloud messages.
static class CloudNetworkTest
{
	const int32 Port = 47831;
	const int32 Ticks = 900;

	static int sFailed;

	static void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"cloud-net: {(ok ? "ok" : "FAIL")} {what}");
		if (!ok)
			sFailed++;
	}

	/// A portrait for every peer: the same cloud settings (the scene file), but a different local time of day (the
	/// server's clock still wins).
	static void Setup(Scene scene, float timeOfDay)
	{
		let env = scene.Environment;
		env.dayNight = true;
		env.timeOfDay = timeOfDay;
		env.dayLengthMinutes = 24;
		env.latitude = 40;
		env.dayOfYear = 172;
		env.autoColors = false;
		env.clouds = true;
		env.cloudMode = .Volumetric;
		env.cloudCoverage = 0.62f;
		env.cloudDensity = 0.035f;
		env.cloudHeight = 1850;
		env.cloudThickness = 2100;
		env.cloudWindSpeed = 14;
		env.cloudWindDirection = 210;
		env.cloudSeed = 424242;
		env.cloudAnisotropy = 0.55f;
		env.cloudAmbient = 0.5f;
		env.cloudTint = .(0.95f, 0.97f, 1);
		env.cloudDistance = 14000;
		env.cloudResolution = 0.5f;
	}

	/// The world offset both cloud paths sample the weather at (the wind's drift plus the seed's move).
	static Vector2 WeatherOffset(Scene scene) => Clouds.Offset(scene.Environment, Clouds.Seconds(scene));

	/// How far apart two peers' weather clocks are, in ticks of the shared clock.
	static float TickGap(Scene a, Scene b) =>
		(float)(Math.Abs(Clouds.Seconds(a) - Clouds.Seconds(b)) * Time.TickRate);

	static bool Near(Vector2 a, Vector2 b, float metres) =>
		Math.Abs(a.x - b.x) <= metres && Math.Abs(a.y - b.y) <= metres;

	static bool Same(Vector2 a, Vector2 b) => a.x == b.x && a.y == b.y;

	public static int Run()
	{
		let hostScene = scope Scene();
		let clientScene = scope Scene();
		let lateScene = scope Scene();
		Setup(hostScene, 11);
		Setup(clientScene, 19); // Deliberately different: the server's clock wins.
		Setup(lateScene, 3);

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
		const int32 LateStart = 300;
		const int32 PauseAt = 600;
		int32 settleUntil = 60;
		int32 worstAt = -1;
		float worstGap = 0;
		Vector2 worstHost = .(0, 0), worstClient = .(0, 0);
		Vector2 offsetAtPause = .(0, 0);
		double simAtPause = 0;
		bool sawLate = false;
		bool sawPause = false;

		for (int32 i = 0; i < Ticks; i++)
		{
			if (i == PauseAt)
			{
				hostScene.Environment.dayNightPaused = true;
				offsetAtPause = WeatherOffset(hostScene);
				settleUntil = i + 5;
			}
			if (i == PauseAt + 1)
				simAtPause = DayNight.SimulationTime(hostScene);
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

			if (i > settleUntil && host.IsConnected && client.IsConnected)
			{
				let gap = TickGap(hostScene, clientScene);
				if (gap > worstGap)
				{
					worstGap = gap;
					worstAt = i;
					worstHost = WeatherOffset(hostScene);
					worstClient = WeatherOffset(clientScene);
				}
			}
			if (i == LateStart + 60 && late != null)
			{
				let lateOffset = WeatherOffset(lateScene);
				let hostOffset = WeatherOffset(hostScene);
				let gap = TickGap(lateScene, hostScene);
				// A tick of clock difference is a tick of wind drift: that much apart, and no more.
				let drift = lateScene.Environment.cloudWindSpeed * 1.01f / Time.TickRate;
				sawLate = late.IsConnected && gap <= 1.01f && Near(lateOffset, hostOffset, drift);
				Check(sawLate, scope $"a client joining late finds the same weather (gap {gap:F2} ticks, offset ({lateOffset.x:F2}, {lateOffset.y:F2}) vs ({hostOffset.x:F2}, {hostOffset.y:F2}), wind {drift:F2} m a tick)");
			}
			if (i == PauseAt + 30)
			{
				// The weather clock is the server's tick, not the Day / Night time: pausing that clock keeps the clouds
				// drifting, and both peers still agree.
				let now = WeatherOffset(hostScene);
				let sim = DayNight.SimulationTime(hostScene);
				sawPause = hostScene.Environment.dayNightPaused && Math.Abs(sim - simAtPause) < 1e-6 &&
					!Same(now, offsetAtPause) && TickGap(hostScene, clientScene) <= 1.01f;
				Check(sawPause, scope $"the weather drifts while the Day / Night clock is paused (time {sim:F4} h, offset moved ({now.x - offsetAtPause.x:F2}, {now.y - offsetAtPause.y:F2}) m, peers {TickGap(hostScene, clientScene):F2} ticks apart)");
			}

			SDL.SDL_DelayNS(1000000);
		}

		let hostEnv = hostScene.Environment;
		let clientEnv = clientScene.Environment;
		Check(host.IsConnected && client.IsConnected && late != null && late.IsConnected, "the session stayed up for the whole run");
		Check(hostEnv.clouds && hostEnv.cloudCoverage == 0.62f && hostEnv.cloudSeed == 424242 &&
			hostEnv.cloudWindSpeed == 14 && hostEnv.cloudWindDirection == 210 && hostEnv.cloudHeight == 1850 &&
			hostEnv.cloudThickness == 2100, "the host keeps the scene's cloud settings");
		Check(clientEnv.clouds && clientEnv.cloudCoverage == hostEnv.cloudCoverage && clientEnv.cloudSeed == hostEnv.cloudSeed &&
			clientEnv.cloudDensity == hostEnv.cloudDensity && clientEnv.cloudHeight == hostEnv.cloudHeight &&
			clientEnv.cloudThickness == hostEnv.cloudThickness && clientEnv.cloudWindSpeed == hostEnv.cloudWindSpeed &&
			clientEnv.cloudWindDirection == hostEnv.cloudWindDirection && clientEnv.cloudAnisotropy == hostEnv.cloudAnisotropy &&
			clientEnv.cloudAmbient == hostEnv.cloudAmbient && clientEnv.cloudTint == hostEnv.cloudTint &&
			clientEnv.cloudDistance == hostEnv.cloudDistance && clientEnv.cloudResolution == hostEnv.cloudResolution,
			"both peers have the same cloud settings");
		Check(worstGap <= 1.01f, scope $"the peers' weather clocks agree within a tick all through (worst {worstGap:F3} ticks at {worstAt}: ({worstHost.x:F2}, {worstHost.y:F2}) vs ({worstClient.x:F2}, {worstClient.y:F2}))");
		let drift = hostEnv.cloudWindSpeed * 1.01f / Time.TickRate;
		Check(Near(WeatherOffset(hostScene), WeatherOffset(clientScene), drift), "the peers sample the same weather offset, so the same coverage");
		Check(sawLate && sawPause, "the late-join and paused-clock checks ran");
		Check(DayNight.BytesSent(host) > 0, "the server sent the clock's settings");
		Check(DayNight.BytesSent(client) == 0 && DayNight.BytesSent(late) == 0, "clients send no cloud (or clock) messages");

		// The same settings and clock give the same offset; the seed moves the weather.
		let a = scope Scene();
		let b = scope Scene();
		Setup(a, 11);
		Setup(b, 11);
		Check(Same(Clouds.Offset(a.Environment, 123.25), Clouds.Offset(b.Environment, 123.25)),
			"the same seed and clock give the same weather offset");
		b.Environment.cloudSeed = 424243;
		Check(!Same(Clouds.Offset(a.Environment, 123.25), Clouds.Offset(b.Environment, 123.25)),
			"a different seed moves the weather");

		Console.WriteLine(sFailed == 0 ? "CLOUD NETWORK TEST PASS" : scope $"CLOUD NETWORK TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}
}
