using System;
using System.Threading;

namespace Tallow;

/// Notices when the game stops moving and writes down what it was doing, so that a freeze on a player's machine
/// can be traced from the log file. Started by built games; costs a few assignments a frame.
static class Watchdog
{
	/// What the main loop is doing now. Set it to a string literal before anything that could wait on the
	/// system, a driver or another program.
	public static String Stage = "starting up";
	/// The component whose code is running, while one is.
	public static Component Running;

	static int64 sBeats;
	static Thread sThread;
	static bool sStop;

	/// Called once a frame by the main loop.
	public static void Beat()
	{
		if (Interlocked.Increment(ref sBeats) == 200 && TestStall)
		{
			Stage = "stalling on purpose, for a test";
			Thread.Sleep(5000);
		}
	}

	/// For tests (--teststall): the main loop stops for five seconds at its 200th frame.
	public static bool TestStall;

	public static void Start()
	{
#if BF_PLATFORM_WASM
		// No second thread in a web page; the browser itself reports a page that stops responding.
		return;
#else
		if (sThread != null)
			return;
		sStop = false;
		sThread = new Thread(new => Watch);
		sThread.IsBackground = true;
		sThread.Start(false);
#endif
	}

	public static void Stop()
	{
		sStop = true;
		if (sThread != null)
		{
			sThread.Join();
			delete sThread;
		}
		sThread = null;
	}

	static void Watch()
	{
		int64 seen = -1;
		int still = 0;
		bool reported = false;
		while (!sStop)
		{
			Thread.Sleep(250);
			let beats = Interlocked.Add(ref sBeats, 0);
			if (beats != seen)
			{
				if (reported)
					Log.ToFile(scope $"The game is moving again after about {still / 4} seconds.");
				seen = beats;
				still = 0;
				reported = false;
				continue;
			}
			// Three seconds without a frame, once the game has drawn its first.
			if (++still == 12 && beats > 0)
			{
				reported = true;
				let stage = Stage;
				let running = Running;
				let text = scope String();
				text.AppendF("The game has not moved for 3 seconds (after {} frames). It stopped while: {}", beats, stage);
				if (running != null)
					text.AppendF(", in a {} component", running.GetType().GetName(.. scope .()));
				Log.ToFile(text);
			}
		}
	}
}
