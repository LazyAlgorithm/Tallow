using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// How serious a log message is.
enum LogLevel
{
	Info,
	Warning,
	Error
}

/// Engine log. Entries are kept for the editor console and mirrored to stdout.
/// Explicit UTF-8 input-only methods are available to C# gameplay.
[CSharpExpose]
static class Log
{
	/// One message: how serious it is, and its text.
	public struct Entry
	{
		public LogLevel level;
		public String text;
		/// Source location for a clickable editor diagnostic; null for ordinary messages.
		public String file;
		public int32 line;
		/// How many times the exact same message has been reported.
		public int32 repeats;
	}

	/// The most messages kept; older ones go.
	public const int MaxEntries = 2000;
	/// The messages kept, oldest first (the editor's Console shows them).
	public static List<Entry> Entries = new .() ~
		{
			for (let e in _)
			{
				delete e.text;
				delete e.file;
			}
			delete _;
		};
	/// Goes up with every message, so that a viewer can tell when to redraw.
	public static int Version;
	/// Goes up when messages are cleared, so diagnostic producers can republish active messages once.
	public static int ClearVersion;
	static Monitor sMonitor = new .() ~ delete _;
	static System.IO.FileStream sFile ~ delete _;

	/// Also writes the log to a file from now on, replacing what was in it. Built games do this (log.txt beside
	/// the game, or in the temporary folder if that cannot be written), since they have no console to print to.
	public static bool OpenFile(StringView path)
	{
		using (sMonitor.Enter())
		{
			delete sFile;
			sFile = new .();
			if (sFile.Create(path, .Write, .Read) case .Err)
			{
				delete sFile;
				sFile = null;
				return false;
			}
			return true;
		}
	}

	/// Writes a line to the log file only, straight away. Safe from any thread.
	public static void ToFile(StringView text)
	{
		using (sMonitor.Enter())
		{
			if (sFile == null)
				return;
			sFile.Write(Span<uint8>((uint8*)text.Ptr, text.Length)).IgnoreError();
			sFile.Write(Span<uint8>((uint8*)"\r\n", 2)).IgnoreError();
			sFile.Flush().IgnoreError();
		}
	}

	/// Logs a message.
	[CSharpExpose] public static void Info(StringView text) => Add(.Info, text);
	/// Logs a warning.
	[CSharpExpose] public static void Warning(StringView text) => Add(.Warning, text);
	/// Logs an error.
	[CSharpExpose] public static void Error(StringView text) => Add(.Error, text);

	/// Logs a message of a level.
	public static void Add(LogLevel level, StringView text, StringView file = "", int32 line = -1)
	{
		bool grouped = false;
		using (sMonitor.Enter())
		{
			// Repeated runtime errors and compilation messages should not bury useful new output.
			for (int i = Entries.Count - 1; i >= 0 && i >= Entries.Count - 128; i--)
			{
				var existing = Entries[i];
				if (existing.level != level || existing.line != line || existing.text != text)
					continue;
				if ((existing.file == null && !file.IsEmpty) || (existing.file != null && existing.file != file))
					continue;
				existing.repeats++;
				Entries[i] = existing;
				Version++;
				grouped = true;
				break;
			}
			if (!grouped && Entries.Count >= MaxEntries)
			{
				delete Entries[0].text;
				delete Entries[0].file;
				Entries.RemoveAt(0);
			}
			if (!grouped)
			{
				Entry entry;
				entry.level = level;
				entry.text = new String(text);
				entry.file = file.IsEmpty ? null : new String(file);
				entry.line = line;
				entry.repeats = 1;
				Entries.Add(entry);
				Version++;
			}
		}
		if (grouped)
			return;
		switch (level)
		{
		case .Info: ToFile(text);
		case .Warning: ToFile(scope $"[warning] {text}");
		case .Error: ToFile(scope $"[error] {text}");
		}
		switch (level)
		{
		case .Info: Console.WriteLine(text);
		case .Warning: Console.WriteLine("[warning] {}", text);
		case .Error: Console.WriteLine("[error] {}", text);
		}
	}

	/// Forgets every message.
	public static void Clear()
	{
		using (sMonitor.Enter())
		{
			for (let e in Entries)
			{
				delete e.text;
				delete e.file;
			}
			Entries.Clear();
			Version++;
			ClearVersion++;
		}
	}
}
