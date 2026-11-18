using System;

namespace Tallow;

/// How a crash is reported. On Windows the launcher, editor and player are GUI programs, so Beef's crash catcher shows
/// a message box and waits for someone to close it. Nobody is there for a headless run, a command-line switch or a CI
/// job: the process would wait forever (a CI job then sits until its time limit). Those runs print the crash to the
/// console and exit instead.
static class CrashReports
{
	/// Call first thing in Main. Unattended means: the CI or TALLOW_NO_CRASH_DIALOG environment variable is set, or the
	/// command line has --headless or one of the launcher's command switches (--graph-compile, --write-..., tests).
	public static void UseConsoleWhenUnattended(Span<String> args)
	{
#if BF_PLATFORM_WINDOWS
		if (IsUnattended(args))
		{
			Runtime.SetCrashReportKind(.Console);
			sUnattended = true;
			HandleLeakChecksFirst();
		}
#endif
	}

	static bool sUnattended;
#if BF_PLATFORM_WINDOWS && (BF_DEBUG_ALLOC || BF_ENABLE_OBJECT_DEBUG_FLAGS)
	static void* sLeakHandler;
#endif

	/// Puts the leak-report handler (below) first among the process's exception handlers again; called once .NET has
	/// started, since .NET adds a handler of its own at the front.
	public static void HandleLeakChecksFirst()
	{
#if BF_PLATFORM_WINDOWS && (BF_DEBUG_ALLOC || BF_ENABLE_OBJECT_DEBUG_FLAGS)
		if (!sUnattended)
			return;
		if (sLeakHandler != null)
			RemoveVectoredExceptionHandler(sLeakHandler);
		sLeakHandler = AddVectoredExceptionHandler(1, => OnException);
#endif
	}

#if BF_PLATFORM_WINDOWS && (BF_DEBUG_ALLOC || BF_ENABLE_OBJECT_DEBUG_FLAGS)
	[CRepr]
	struct ExceptionRecord
	{
		public uint32 code;
		public uint32 flags;
		public ExceptionRecord* next;
		public void* address;
	}

	[CRepr]
	struct ExceptionPointers
	{
		public ExceptionRecord* record;
		public uint8* context;
	}

	/// The runtime's message to the debugger (corlib's Runtime.BfDebugMessageData, which is private), same layout.
	[CRepr]
	struct DebugMessage
	{
		public int32 type; // 1: an error
		public int32 stackWindback;
		public int32 length;
		public char8* text;
	}

	[CLink]
	static extern DebugMessage gBfDebugMessageData;

	[CLink, CallingConvention(.Stdcall)]
	static extern void* GetModuleHandleW(char16* name);
	[CLink, CallingConvention(.Stdcall)]
	static extern uint16 RtlCaptureStackBackTrace(uint32 skip, uint32 count, void** frames, uint32* hash);

	[CLink, CallingConvention(.Stdcall)]
	static extern uint32 RemoveVectoredExceptionHandler(void* handler);

	[CLink, CallingConvention(.Stdcall)]
	static extern void* AddVectoredExceptionHandler(uint32 first, function [CallingConvention(.Stdcall)] int32(ExceptionPointers*) handler);

	/// A Debug build's leak check (Beef's GC, at a collection or at exit) breaks into the debugger with its report.
	/// Once .NET is loaded its handler, not Beef's crash catcher, gets that breakpoint and ends the process without a
	/// word (exit 0x80000003). Unattended, print the report instead (each leaked object's type, and a leaked string's
	/// text, which usually says where it came from), step over the breakpoint and go on, as the GC allows.
	[CallingConvention(.Stdcall)]
	static int32 OnException(ExceptionPointers* info)
	{
		const uint32 cBreakpoint = 0x80000003;
		if (info.record.code != cBreakpoint)
			return 0; // EXCEPTION_CONTINUE_SEARCH
		let text = (gBfDebugMessageData.type == 1 && gBfDebugMessageData.text != null) ?
			StringView(gBfDebugMessageData.text, gBfDebugMessageData.length) : StringView();
		if (!text.Contains("leak"))
		{
			// Another breakpoint (a Debug check such as using a deleted object): .NET ends the process at it without a
			// word, so say where it was. Offsets from the launcher's base resolve with
			// `llvm-symbolizer --obj=TallowLauncher.exe 0x140000000+offset`.
			let place = scope String();
			let start = (uint)(int)GetModuleHandleW(null);
			place.AppendF("[breakpoint] at {:X} (launcher base {:X}), stack:", (uint)(int)info.record.address, start);
			void*[48] frames = default;
			let count = RtlCaptureStackBackTrace(0, 48, &frames, null);
			for (int i < count)
				place.AppendF(" {:X}", (uint)(int)frames[i]);
			place.Append('\n');
			if (!text.IsEmpty)
				place.AppendF("{}\n", text);
			Console.Error.Write(place);
			Console.Error.Flush();
			return 0;
		}
		let report = scope String();
		report.Append("[leak check] ");
		int shown = 0;
		for (var line in text.Split('\n'))
		{
			// Lines are "\x1LEAK\t(System.Object)0xADDR" (a marker for the IDE) then "   (Type)0xADDR".
			if (line.StartsWith('\x01'))
			{
				let tab = line.IndexOf('\t');
				let kind = tab > 0 ? line.Substring(1, tab - 1) : StringView();
				if (kind == "LEAK" && shown < 400)
				{
					let hex = line.IndexOf("0x");
					if (hex >= 0)
					{
						let digits = scope String();
						for (let c in line.Substring(hex + 2))
							if (c.IsDigit || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
								digits.Append(c);
						if (uint64.Parse(digits, .HexNumber) case .Ok(let address))
						{
							let obj = Internal.UnsafeCastToObject((void*)(int)address);
							if (let str = obj as String)
							{
								let shownText = str.Length > 120 ? str.Substring(0, 120) : StringView(str);
								report.AppendF("   string \"{}\"\n", shownText);
								shown++;
							}
						}
					}
				}
				else if (kind == "TEXT")
					report.AppendF("{}\n", line.Substring(tab + 1));
				continue;
			}
			report.AppendF("{}\n", line);
		}
		Console.Error.Write(report);
		Console.Error.Flush();
		Console.Out.Flush();
		// The breakpoint instruction (int3) is one byte; carry on after it. Rip is at offset 0xF8 of an x64 CONTEXT.
		*(uint64*)(info.context + 0xF8) += 1;
		gBfDebugMessageData.type = 0;
		return -1; // EXCEPTION_CONTINUE_EXECUTION
	}
#endif

	public static bool IsUnattended(Span<String> args)
	{
		if (IsSet("CI") || IsSet("TALLOW_NO_CRASH_DIALOG"))
			return true;
		for (let arg in args)
		{
			if (arg == "--headless" || arg.EndsWith("-test") || arg.StartsWith("--graph-compile") ||
				arg.StartsWith("--write-") || arg.StartsWith("--csharp-") || arg == "--build-native-project")
				return true;
		}
		return false;
	}

	static bool IsSet(StringView name)
	{
		let value = scope String();
		if (Environment.GetEnvironmentVariable(name, value) case .Err)
			return false;
		return !value.IsEmpty && value != "0";
	}
}
