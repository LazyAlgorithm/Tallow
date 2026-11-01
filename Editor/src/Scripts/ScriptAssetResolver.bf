using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Resolve only actual component declarations in a source asset, not classes mentioned in comments/strings.
static class ScriptAssetResolver
{
	static bool Next(StringView text, ref int cursor, String token)
	{
		token.Clear();
		while (cursor < text.Length)
		{
			let c = text[cursor];
			if (c == '/' && cursor + 1 < text.Length && text[cursor + 1] == '/')
			{
				while (cursor < text.Length && text[cursor] != '\n')
					cursor++;
				continue;
			}
			if (c == '/' && cursor + 1 < text.Length && text[cursor + 1] == '*')
			{
				cursor += 2;
				while (cursor + 1 < text.Length && !(text[cursor] == '*' && text[cursor + 1] == '/'))
					cursor++;
				cursor = Math.Min(cursor + 2, text.Length);
				continue;
			}
			if (c == '"' || c == '\'')
			{
				let quote = c;
				cursor++;
				while (cursor < text.Length)
				{
					let value = text[cursor++];
					if (value == '\\' && cursor < text.Length)
						cursor++;
					else if (value == quote) break;
				}
				continue;
			}
			if (c.IsWhiteSpace)
			{
				cursor++;
				continue;
			}
			if (c.IsLetterOrDigit || c == '_')
			{
				while (cursor < text.Length && (text[cursor].IsLetterOrDigit || text[cursor] == '_'))
					token.Append(text[cursor++]);
			}
			else
			{
				token.Append(c);
				cursor++;
			}
			return true;
		}
		return false;
	}

	public static void Find(StringView path, StringView projectNamespace, List<ComponentRegistry.Info> matches)
	{
		matches.Clear();
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err) return;
		if (path.EndsWith(".tgraph", .OrdinalIgnoreCase))
		{
			List<StringView> tokens = scope .();
			List<String> storage = scope .();
			defer
			{
				for (let s in storage)
					delete s;
			}
			for (let line in text.Split('\n'))
			{
				tokens.Clear();
				SceneSerializer.Tokenize(line, tokens, storage);
				if (tokens.Count == 2 && tokens[0] == "graph")
				{
					let info = ComponentRegistry.Find(scope $"{projectNamespace}.{tokens[1]}");
					if (info != null)
						matches.Add(info);
					break;
				}
			}
			return;
		}
		if (!path.EndsWith(".bf", .OrdinalIgnoreCase)) return;
		let token = scope String();
		let ns = scope String();
		int cursor = 0;
		while (Next(text, ref cursor, token))
		{
			if (token == "namespace")
			{
				ns.Clear();
				while (Next(text, ref cursor, token))
				{
					if (token == ";" || token == "{") break;
					ns.Append(token);
				}
			}
			else if (token == "class" && Next(text, ref cursor, token))
			{
				for (let info in ComponentRegistry.Types)
				{
					if (info.name != token || (!ns.IsEmpty && !info.fullName.StartsWith(scope $"{ns}."))) continue;
					if (!matches.Contains(info))
						matches.Add(info);
				}
			}
		}
	}
}
