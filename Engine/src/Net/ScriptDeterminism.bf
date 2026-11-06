using System;
using System.Collections;

namespace Tallow;

/// Warnings for networked script code that would come out differently on different machines (6i): what runs in a
/// networked `Update(TickInput input, float deltaTime)` or a behaviour's `Simulate` runs on the server, on clients
/// predicting it and again in replays, and must give the same result everywhere. The script editor shows these on
/// the lines after each check. A rough text check, not the compiler: it looks inside those two methods only.
static class ScriptDeterminism
{
	public struct Warning
	{
		/// 0-based line.
		public int line;
		public String message;
	}

	/// Adds a warning (message owned by `into`) for every suspicious use in `source`.
	public static void Check(StringView source, List<Warning> into)
	{
		// Random objects made without a seed anywhere in the file: drawing from them in the tick is the problem.
		List<String> unseeded = scope .();
		defer { for (let name in unseeded) delete name; }
		for (let line in source.Split('\n'))
		{
			let code = CodePart(line);
			if (!code.Contains("Random") || !(code.Contains("new Random()") || code.Contains("new .()") || code.Contains("new Random ()")))
				continue;
			let random = code.IndexOf("Random ");
			if (random < 0)
				continue;
			var rest = code.Substring(random + 7);
			rest.TrimStart();
			int length = 0;
			while (length < rest.Length && (rest[length].IsLetterOrDigit || rest[length] == '_'))
				length++;
			if (length > 0)
				unseeded.Add(new String(rest.Substring(0, length)));
		}

		int lineNumber = 0;
		int depth = 0;
		int bodyDepth = -1;
		bool waitingForBody = false;
		StringView method = default;
		for (let line in source.Split('\n'))
		{
			defer { lineNumber++; }
			let code = CodePart(line);
			if (bodyDepth < 0 && (code.Contains("Update(TickInput") || code.Contains("Simulate(NetInput")) && code.Contains("void "))
			{
				waitingForBody = true;
				method = code.Contains("Simulate(") ? "Simulate" : "Update";
			}
			if (bodyDepth >= 0)
				CheckLine(code, lineNumber, method, unseeded, into);
			for (let c in code.RawChars)
			{
				if (c == '{')
				{
					if (waitingForBody)
					{
						waitingForBody = false;
						bodyDepth = depth;
					}
					depth++;
				}
				else if (c == '}')
				{
					depth--;
					if (depth == bodyDepth)
						bodyDepth = -1;
				}
			}
			// An expression-bodied method (=> ...;) is one line.
			if (waitingForBody && code.Contains("=>"))
			{
				CheckLine(code, lineNumber, method, unseeded, into);
				waitingForBody = false;
			}
		}
	}

	/// The line without its comment and string contents (so text in them is not taken for code).
	static StringView CodePart(StringView line)
	{
		var end = line.Length;
		bool inString = false;
		for (int i < line.Length)
		{
			let c = line[i];
			if (c == '"' && (i == 0 || line[i - 1] != '\\'))
				inString = !inString;
			else if (!inString && c == '/' && i + 1 < line.Length && line[i + 1] == '/')
			{
				end = i;
				break;
			}
		}
		return line.Substring(0, end);
	}

	static void CheckLine(StringView code, int line, StringView method, List<String> unseeded, List<Warning> into)
	{
		void Add(String message)
		{
			Warning warning;
			warning.line = line;
			warning.message = message;
			into.Add(warning);
		}
		if (code.Contains("new Random()") || code.Contains("new Random ()") || code.Contains("gRand") || code.Contains("Random.Shared"))
			Add(new $"networked {method}: a random number with no shared seed differs on every machine; use NetRandom.Value(this) (the same everywhere)");
		else
		{
			for (let name in unseeded)
			{
				if (code.Contains(scope $"{name}.Next") || code.Contains(scope $"{name}.Range"))
				{
					Add(new $"networked {method}: {name} is a Random made with no seed, so it differs on every machine; use NetRandom.Value(this) (the same everywhere)");
					break;
				}
			}
		}
		if (code.Contains("Time.DeltaTime"))
			Add(new $"networked {method}: Time.DeltaTime is this machine's frame time; use the deltaTime it is given (the fixed tick)");
		if (code.Contains("Time.Time") || code.Contains("Time.RealTime") || code.Contains("Time.FrameCount") || code.Contains("DateTime.Now") || code.Contains("DateTime.UtcNow") || code.Contains("Stopwatch") || code.Contains("GetTicks"))
			Add(new $"networked {method}: the clock or frame count differs between machines and in replays; count ticks instead");
		if (code.Contains("Input.Get") || code.Contains("Input.Mouse"))
			Add(new $"networked {method}: reads this machine's keys and mouse directly, which other machines never see; read the controls it is given (input), filled in GatherInput");
	}
}
