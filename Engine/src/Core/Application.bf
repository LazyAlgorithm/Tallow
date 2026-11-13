using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Owns the window, the graphics device and the main loop. The editor and built players both derive from it.
///
/// Common command line options:
///   --renderer vulkan|opengl|gles|metal|d3d11|d3d12   pick a graphics backend
///   --frames N                                         quit after N frames
///   --screenshot file.png                              save the last frame before quitting (with --frames)
///   --headless                                         no window or renderer (dedicated servers)
class Application
{
	/// The window's title.
	public String Title = new .("Tallow") ~ delete _;
	/// The SDL window.
	public void* Window;
	/// The window's width, in pixels.
	public int32 Width = 1600;
	/// The window's height, in pixels.
	public int32 Height = 900;
	/// The window's size for the interface, in points: the same as Width and Height except on a screen with more
	/// than one pixel to a point (phones, high-density laptops), where the interface library measures in points and
	/// draws its text and shapes at full sharpness by itself.
	public float InterfaceWidth = 1600;
	public float InterfaceHeight = 900;
	/// False ends the program after this frame: `Application.Instance.Running = false` (or Quit) is how a game
	/// quits. In the editor, while the game is playing, it stops Play instead and leaves the editor open, so the same
	/// game code works in both. Close always ends the program.
	public bool Running
	{
		get => mRunning;
		set
		{
			if (!value && mRunning && OnQuitRequested())
				return;
			mRunning = value;
		}
	}

	/// Running with no window and no graphics (a dedicated server).
	public bool Headless;
	/// Opens the window maximized.
	public bool StartMaximized;
	/// The command line, without the program's name.
	public List<String> Args = new .() ~ DeleteContainerAndItems!(_);

	bool mRunning = true;
	int32 mRendererOverride = -1;
	int64 mFrameLimit = -1;
	String mScreenshotPath = new .() ~ delete _;
	/// --profile-save: where the profiler's recording is written when the program ends.
	String mProfileSavePath = new .() ~ delete _;
	/// --profile-report: where a text report of the recording is written when the program ends.
	String mProfileReportPath = new .() ~ delete _;
	static ProfilerMarker sEventsMarker = .("Events and Input", .Other);
	static ProfilerMarker sFixedMarker = .("Fixed Update", .Scripts);
	static ProfilerMarker sUpdateMarker = .("Update", .Scripts);
	static ProfilerMarker sRenderMarker = .("Render", .Rendering);
	static ProfilerMarker sPresentMarker = .("Present (waiting for the GPU)", .Waiting);
	static ProfilerMarker sSleepMarker = .("Sleep (no vsync)", .Waiting);
	String mEngineRootHint = new .() ~ delete _;
	double mAccumulator;
	double mRealTime;
	uint64 mLastTicks;

	/// The application that is running.
	public static Application Instance;

	/// Quits the game: a built game closes; in the editor, Play stops.
	public static void Quit()
	{
		if (Instance != null)
			Instance.Running = false;
	}

	/// Ends the program, even in the editor while playing.
	public void Close() => mRunning = false;

	/// Something asked to quit (Running set to false, or Quit). Return true to have handled it and keep running.
	protected virtual bool OnQuitRequested() => false;

	/// Sets Instance to this application.
	public this()
	{
		Instance = this;
	}

	/// Sets the icon shown in the window's title bar and the taskbar from an image file (PNG, JPG...).
	/// Call it once the window exists, for example from OnInit. Returns false if there is no window or the file cannot be read.
	public bool SetWindowIcon(StringView path)
	{
		if (Window == null)
			return false;
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope String(path).CStr(), &width, &height);
		if (pixels == null)
			return false;
		// SDL copies the pixels, so the image can be released straight away.
		let surface = SDL.SDL_CreateSurfaceFrom(width, height, SDL.PIXELFORMAT_RGBA32, pixels, width * 4);
		let ok = surface != null && SDL.SDL_SetWindowIcon(Window, surface);
		if (surface != null)
			SDL.SDL_DestroySurface(surface);
		Native.tn_image_free(pixels);
		return ok;
	}

	protected virtual bool OnInit() => true;
	protected virtual void OnEvent(ref SDL.Event event) { }
	protected virtual void OnFixedUpdate() { }
	protected virtual void OnUpdate() { }
	protected virtual void OnRender() { }
	protected virtual void OnShutdown() { }

	/// Whether a switch is on the command line.
	public bool HasArg(StringView name)
	{
		for (let arg in Args)
		{
			if (arg == name)
				return true;
		}
		return false;
	}

	/// Whether the player's saved graphics settings are applied at start (the editor keeps its own).
	protected virtual bool LoadsPlayerQuality => true;

	/// Value following a named option, e.g. GetArg("--scene", path).
	public bool GetArg(StringView name, String value)
	{
		for (int i = 0; i + 1 < Args.Count; i++)
		{
			if (Args[i] == name)
			{
				value.Set(Args[i + 1]);
				return true;
			}
		}
		return false;
	}

	void ParseCommonArgs()
	{
		let value = scope String();
		if (GetArg("--renderer", value))
		{
			switch (value)
			{
			case "vulkan": mRendererOverride = (int32)bgfx.RendererType.Vulkan;
			case "opengl": mRendererOverride = (int32)bgfx.RendererType.OpenGL;
			case "gles": mRendererOverride = (int32)bgfx.RendererType.OpenGLES;
			case "metal": mRendererOverride = (int32)bgfx.RendererType.Metal;
			case "d3d11": mRendererOverride = (int32)bgfx.RendererType.Direct3D11;
			case "d3d12": mRendererOverride = (int32)bgfx.RendererType.Direct3D12;
			default: Log.Warning(scope $"Unknown renderer '{value}'");
			}
		}
		if (GetArg("--frames", value))
			mFrameLimit = SceneSerializer.ParseInt(value);
		GetArg("--screenshot", mScreenshotPath);
		GetArg("--engine-root", mEngineRootHint);
		// Bend skinned models on the CPU, to compare with the GPU (docs/gpu-skinning.md).
		if (HasArg("--cpu-skinning"))
			GpuSkinning.Enabled = false;
		if (HasArg("--headless"))
			Headless = true;
		// Either one overrides how the game was built to start.
		if (HasArg("--fullscreen"))
			GameWindow.StartsFullscreen = true;
		if (HasArg("--windowed"))
			GameWindow.StartsFullscreen = false;
	}

	/// Opens the window and runs frames until Running is false; returns the program's exit code.
	public int Run(String[] args)
	{
		// The main thread is the profiler's first, whatever else starts threads early.
		Profiler.NameThread("Main Thread");
		for (let arg in args)
			Args.Add(new String(arg));
		ParseCommonArgs();
		// A server with no window has no ears either.
		Audio.Disabled = Headless;

		if (!Headless)
		{
#if BF_PLATFORM_LINUX
			// The renderer is built for X11 windows; Wayland desktops run it through XWayland.
			SDL.SDL_SetHint("SDL_VIDEO_DRIVER", "x11");
#endif
			if (!SDL.SDL_Init(SDL.INIT_VIDEO | SDL.INIT_GAMEPAD))
			{
				Log.Error(scope $"SDL could not start: {StringView(SDL.SDL_GetError())}");
				return 1;
			}
			var flags = SDL.WINDOW_RESIZABLE | SDL.WINDOW_HIGH_PIXEL_DENSITY;
#if BF_PLATFORM_WASM
			// Phones: the interface at the screen's full sharpness, the 3D scene at a resolution the phone can keep up
			// with (the page also caps the pixel density at 2).
			if (WebPlatform.IsMobile)
				Gfx.UseMobileQuality();
#endif
			if (StartMaximized)
				flags |= SDL.WINDOW_MAXIMIZED;
			if (GameWindow.TakeStartState())
				flags |= SDL.WINDOW_FULLSCREEN;
			if (GameWindow.StartWidth > 0 && GameWindow.StartHeight > 0)
			{
				Width = GameWindow.StartWidth;
				Height = GameWindow.StartHeight;
			}
			Window = SDL.SDL_CreateWindow(Title.CStr(), Width, Height, flags);
			if (Window == null)
			{
				Log.Error(scope $"Could not create a window: {StringView(SDL.SDL_GetError())}");
				return 1;
			}
			SDL.SDL_GetWindowSizeInPixels(Window, &Width, &Height);
			if (!Gfx.LocateEngineAssets(mEngineRootHint) || !Gfx.Init(Window, Width, Height, mRendererOverride))
				return 1;
		}

		if (!OnInit())
		{
			Shutdown();
			return 1;
		}
		// The player's saved graphics settings (docs/quality.md), then --quality <low|medium|high|ultra> for this run.
		if (!Headless && LoadsPlayerQuality)
			Quality.Load();
		// To compare: textures without mip levels or compressed copies.
		Textures.Mipmaps = !HasArg("--no-mipmaps");
		Textures.UseCompressed = !HasArg("--no-compressed-textures");
		// To compare: shiny surfaces mirroring the ambient colours, as before reflection cubes.
		Reflections.Enabled = !HasArg("--no-reflections");
		let quality = scope String();
		if (GetArg("--quality", quality) && Quality.Parse(quality, let level))
			Quality.Set(level);
		// To compare: how many point and spot lights cast shadows (0: none).
		let shadowed = scope String();
		if (GetArg("--shadowed-lights", shadowed) && int32.Parse(shadowed) case .Ok(let count))
			RenderView.MaxShadowedLights = Math.Clamp(count, 0, LightClusters.MaxTiles);
		// To compare: lightmaps and baked light probes off (docs/baked-lighting.md).
		if (HasArg("--no-baked-lighting"))
			RenderView.UseBakedLighting = false;
		// The profiler (docs/profiler.md): --profile records from the start, --profile-listen [port] lets an editor
		// connect to watch this run (a dedicated server too), --profile-save <file> writes the recording at the end
		// and --profile-report <file> a text report of it (both record from the start).
		ProfilerModules.Install();
		GetArg("--profile-save", mProfileSavePath);
		GetArg("--profile-report", mProfileReportPath);
		if (HasArg("--profile") || !mProfileSavePath.IsEmpty || !mProfileReportPath.IsEmpty)
			Profiler.Enabled = true;
		if (HasArg("--profile-listen"))
		{
			var port = ProfilerServer.DefaultPort;
			let text = scope String();
			if (GetArg("--profile-listen", text) && int32.Parse(text) case .Ok(let number))
				port = (uint16)Math.Clamp(number, 1, 65535);
			ProfilerServer.Listen(port);
		}

		mLastTicks = SDL.SDL_GetTicksNS();
#if BF_PLATFORM_WASM
		// A web page must not loop forever: the browser would never get to draw or deliver input. The browser calls
		// Frame once per display refresh instead, and this call does not return.
		WebPlatform.RunMainLoop(this);
		return 0;
#else
		while (Running)
			Frame();
		Shutdown();
		return 0;
#endif
	}

	/// One pass of the main loop: events and input, fixed ticks, the frame update and drawing.
	public void Frame()
	{
		// An editor watching this run may have asked to start or stop recording.
		ProfilerServer.Update();
		Profiler.BeginFrame();
		sEventsMarker.Begin();
		Watchdog.Beat();
		// Steam delivers its events here; this does nothing unless the game has started Steam.
		Steam.Update();
		Watchdog.Stage = "anti-cheat: keeping the game's memory closed";
		AntiCheat.Maintain();
		Watchdog.Stage = "reading window events and input";
		if (!Headless)
		{
			SDL.Event event = default;
			while (SDL.SDL_PollEvent(&event))
			{
				switch (event.type)
				{
				case SDL.EVENT_QUIT,SDL.EVENT_WINDOW_CLOSE_REQUESTED:
					Close();
				case SDL.EVENT_WINDOW_PIXEL_SIZE_CHANGED:
					Width = event.WindowData1;
					Height = event.WindowData2;
					Gfx.Resize(Width, Height);
				case SDL.EVENT_MOUSE_WHEEL:
					Input.OnWheel(event.WheelY);
				case SDL.EVENT_GAMEPAD_ADDED,SDL.EVENT_GAMEPAD_REMOVED:
					Gamepad.Rescan();
				case SDL.EVENT_FINGER_DOWN,SDL.EVENT_FINGER_UP,SDL.EVENT_FINGER_MOTION,SDL.EVENT_FINGER_CANCELED:
					Touch.OnEvent(ref event);
				default:
				}
				OnEvent(ref event);
			}
			Input.Poll();
			int32 pointsWide = 0, pointsHigh = 0;
			if (Window != null && SDL.SDL_GetWindowSize(Window, &pointsWide, &pointsHigh) && pointsWide > 0 && pointsHigh > 0)
			{
				InterfaceWidth = pointsWide;
				InterfaceHeight = pointsHigh;
			}
			else
			{
				InterfaceWidth = Width;
				InterfaceHeight = Height;
			}
		}
		Profiler.End();

		let now = SDL.SDL_GetTicksNS();
		var delta = (double)(now - mLastTicks) / 1.0e9;
		mLastTicks = now;
		if (delta > 0.25)
			delta = 0.25;
		Time.UnscaledDeltaTime = (float)delta;
		// Added up in a double: a float stops gaining short frames after a day or so.
		mRealTime += delta;
		Time.RealTime = (float)mRealTime;
		Time.DeltaTime = (float)delta * Time.TimeScale;
		Time.Advance(Time.DeltaTime);
		Time.FrameCount++;
		if (delta > 0)
			Time.SmoothedFps = Mathf.Lerp(Time.SmoothedFps, (float)(1.0 / delta), Time.SmoothedFps <= 0 ? 1.0f : 0.05f);

		mAccumulator += delta * Time.TimeScale;
		int steps = 0;
		Watchdog.Stage = "running simulation ticks";
		var tickLength = (double)Time.FixedDeltaTime / Math.Clamp(Time.TickScale, 0.5f, 2.0f);
		while (mAccumulator >= tickLength && steps < 8)
		{
			using (sFixedMarker.Sample())
				OnFixedUpdate();
			mAccumulator -= tickLength;
			steps++;
			tickLength = (double)Time.FixedDeltaTime / Math.Clamp(Time.TickScale, 0.5f, 2.0f);
		}
		if (steps == 8)
			mAccumulator = 0;
		Time.InterpolationAlpha = (float)Math.Min(mAccumulator / tickLength, 1.0);
		Watchdog.Stage = "running the frame update (scripts, UI, audio)";

		using (sUpdateMarker.Sample())
			OnUpdate();

		if (!Headless)
		{
			bgfx.set_view_rect(0, 0, 0, (uint16)Width, (uint16)Height, 0, 1);
			Watchdog.Stage = "drawing the scene";
			using (sRenderMarker.Sample())
				OnRender();
			Watchdog.Stage = "presenting the frame (graphics driver)";
			if (mFrameLimit > 0 && Time.FrameCount == mFrameLimit - 2 && !mScreenshotPath.IsEmpty)
				Native.tn_gfx_screenshot(mScreenshotPath.CStr());
			sPresentMarker.Begin();
			bgfx.frame(0);
			Profiler.End();
		}
		else
		{
			// Dedicated servers have no vsync to pace them.
			sSleepMarker.Begin();
			SDL.SDL_DelayNS(1000000);
			Profiler.End();
		}
		// A dedicated server draws nothing, but a script's debug lines must not pile up there.
		DebugDraw.Lines.Clear();
		Gizmos.Lines.Clear();
		Gizmos.Triangles.Clear();
		Gizmos.OnTopLines.Clear();
		Gizmos.OnTopTriangles.Clear();
		Material.FreeUnused();
		// The GPU's times (bgfx's latest finished frame) and every module's counters go in with the frame.
		Profiler.EndFrame(Headless ? 0 : ProfilerModules.ReadGpu());

		if (mFrameLimit > 0 && Time.FrameCount >= mFrameLimit)
			Close();
	}

	/// Frees everything the application started (audio, loaders, graphics, the window).
	public void Shutdown()
	{
		Watchdog.EndWithin(8000);
		if (!mProfileSavePath.IsEmpty && !Profiler.Local.Save(mProfileSavePath))
			Log.Error(scope $"Could not write the profile {mProfileSavePath}");
		if (!mProfileReportPath.IsEmpty && !Profiler.Local.SaveReport(mProfileReportPath))
			Log.Error(scope $"Could not write the profile report {mProfileReportPath}");
		ProfilerServer.Stop();
		AntiCheat.Release();
		OnShutdown();
		AssetLoader.Shutdown();
		Jobs.Shutdown();
		VoiceChat.Shutdown();
		Audio.Shutdown();
		Steam.Shutdown();
		Assets.Clear();
		if (!Headless)
		{
			ShaderAsset.ReleaseAll();
			Compute.Shutdown();
			GpuSkinning.Shutdown();
			Reflections.Shutdown();
			Textures.LogTotals();
			Reflections.LogTotals();
			RenderResources.Destroy();
			Gfx.Shutdown();
			if (Window != null)
				SDL.SDL_DestroyWindow(Window);
			SDL.SDL_Quit();
		}
		Watchdog.Stop();
	}
}
