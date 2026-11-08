// Script editor widget for the Tallow editor: a thin C interface over ImGuiColorTextEdit
// (syntax colouring, bracket matching, line folding, find/replace, multi-cursor, undo/redo,
// identifier completion) styled after Visual Studio's dark theme.

#include "imgui.h"
#include "TextEditor.h"
#include "extras/TrieAutoComplete.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <vector>

#define TN_API extern "C"

namespace
{
	struct Document
	{
		TextEditor editor;
		TrieAutoComplete completion;
		std::string text;
		size_t savedUndoIndex = 0;
		size_t lastUndoIndex = 0;
		bool markup = false;
		// Which of the editor's code colour sets this document was last given (tn_code_set_palette).
		int paletteVersion = 0;
		int semanticRequest = 0;
		int semanticCursor = 0;
		std::string semanticHint;
		int hintCursor = -1;
		std::string hintSource;
		std::string signature;
		int signatureCursor = -1;
		size_t semanticUndoIndex = 0;
		std::vector<std::string> cachedCompletions;
		std::string completionBefore, completionAfter, completionPrefix;
		int completionStart = 0;
	};

	// The code colours every document uses, set by the editor's theme (tn_code_set_palette); version 0 is the
	// built-in Visual Studio dark set.
	TextEditor::Palette s_palette;
	int s_paletteVersion = 0;

	// What the editor knows about the engine's and the project's code. The editor (ApiIndex.bf) fills it by reading
	// the source files themselves, so new engine features and the game's own scripts show up without anyone
	// maintaining a list here.
	struct ApiType
	{
		std::string base;
		std::vector<std::string> members;
	};
	std::unordered_map<std::string, ApiType> apiTypes;
	std::vector<std::string> apiWords;      // every type and member name, sorted, for completion away from a dot
	std::unordered_map<std::string, ApiType> apiPending;

	TextEditor::Language& BeefLanguageMutable()
	{
		// Beef is close to C# lexically; start from that definition and add what differs.
		static TextEditor::Language language = *TextEditor::Language::Cs();
		static bool ready = false;
		if (!ready)
		{
			language.name = "Beef";
			for (const char* word : { "let", "var", "scope", "defer", "mut", "append", "extension", "mixin", "where", "function", "delegate",
				"typealias", "comptype", "decltype", "rettype", "nullable", "repeat", "fallthrough", "when", "not", "alloctype",
				"concrete", "implicit", "explicit", "opaque", "offsetof", "strideof", "alignof", "isconst", "nameof", "Self" })
			{
				language.keywords.insert(word);
			}
			for (const char* word : { "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "char8", "char16", "char32",
				"String", "StringView", "List", "Dictionary", "Span", "Result", "Vector2", "Vector3", "Vector4", "Quaternion", "Matrix4",
				"Color", "Component", "GameObject", "Transform", "Scene", "Time", "Input", "Mathf", "Log", "Rigidbody", "MeshRenderer",
				"Camera", "Light", "VoxelTerrain", "VoxelObject", "ParticleSystem", "NetworkBehaviour", "NetworkIdentity", "NetInput",
				"GUI", "Prefab", "KeyCode", "RaycastHit", "Bounds", "Ray",
                "ShowInInspector", "HideInInspector", "NonSerialized", "Range", "GraphNode", "GraphLibrary",
                "NavigationSurface", "NavigationAgent" })
			{
				language.declarations.insert(word);
			}
			ready = true;
		}
		return language;
	}

	const TextEditor::Language* BeefLanguage() { return &BeefLanguageMutable(); }

	bool IsWordChar(char c) { return isalnum((unsigned char)c) || c == '_'; }

	bool StartsWithNoCase(const std::string& word, const std::string& prefix)
	{
		if (prefix.size() > word.size()) return false;
		for (size_t i = 0; i < prefix.size(); i++)
			if (tolower((unsigned char)word[i]) != tolower((unsigned char)prefix[i])) return false;
		return true;
	}

	bool ContainsNoCase(const std::string& word, const std::string& part)
	{
		if (part.empty()) return true;
		for (size_t i = 0; i + part.size() <= word.size(); i++)
		{
			size_t k = 0;
			while (k < part.size() && tolower((unsigned char)word[i + k]) == tolower((unsigned char)part[k])) k++;
			if (k == part.size()) return true;
		}
		return false;
	}

	// Names starting with what was typed come first, then names that merely contain it.
	void Offer(std::vector<std::string>& out, const std::vector<std::string>& names, const std::string& term, size_t limit)
	{
		for (const auto& name : names)
			if (out.size() < limit && StartsWithNoCase(name, term) && std::find(out.begin(), out.end(), name) == out.end()) out.push_back(name);
		if (term.size() < 2) return;
		for (const auto& name : names)
			if (out.size() < limit && !StartsWithNoCase(name, term) && ContainsNoCase(name, term) && std::find(out.begin(), out.end(), name) == out.end()) out.push_back(name);
	}

	// A type's members followed by those of the types it is built on.
	void MembersOf(const std::string& type, std::vector<std::string>& out)
	{
		std::string current = type;
		for (int depth = 0; depth < 8 && !current.empty(); depth++)
		{
			auto found = apiTypes.find(current);
			if (found == apiTypes.end()) break;
			out.insert(out.end(), found->second.members.begin(), found->second.members.end());
			current = found->second.base;
		}
		std::sort(out.begin(), out.end());
		out.erase(std::unique(out.begin(), out.end()), out.end());
	}

	// Works out what type a variable is from how the script declares or assigns it:
	// "AudioSource radio", "let radio = GetComponent<AudioSource>()", "radio = new AudioSource()".
	std::string TypeOfVariable(const std::string& text, const std::string& name)
	{
		size_t at = 0;
		while ((at = text.find(name, at)) != std::string::npos)
		{
			const size_t end = at + name.size();
			const bool whole = (at == 0 || !IsWordChar(text[at - 1])) && (end >= text.size() || !IsWordChar(text[end]));
			if (whole)
			{
				// The word before it: a declaration names the type there.
				size_t k = at;
				while (k > 0 && (text[k - 1] == ' ' || text[k - 1] == '\t')) k--;
				size_t typeEnd = k;
				if (typeEnd > 0 && (text[typeEnd - 1] == '?' || text[typeEnd - 1] == '*')) typeEnd--;
				size_t typeStart = typeEnd;
				while (typeStart > 0 && IsWordChar(text[typeStart - 1])) typeStart--;
				if (typeEnd > typeStart && typeEnd < at)
				{
					const std::string before = text.substr(typeStart, typeEnd - typeStart);
					if (apiTypes.count(before)) return before;
				}
				// What it is assigned from: the first known type named on the rest of the line.
				size_t a = end;
				while (a < text.size() && (text[a] == ' ' || text[a] == '\t')) a++;
				if (a < text.size() && text[a] == '=' && a + 1 < text.size() && text[a + 1] != '=')
				{
					size_t lineEnd = text.find('\n', a);
					if (lineEnd == std::string::npos) lineEnd = text.size();
					size_t w = a + 1;
					while (w < lineEnd)
					{
						if (IsWordChar(text[w]) && !IsWordChar(text[w - 1]))
						{
							size_t e = w;
							while (e < lineEnd && IsWordChar(text[e])) e++;
							const std::string word = text.substr(w, e - w);
							if (apiTypes.count(word)) return word;
							w = e;
						}
						else w++;
					}
				}
			}
			at = end;
		}
		return "";
	}

	void CompleteBeef(TextEditor* editor, TextEditor::AutoCompleteState& state)
	{
		state.suggestions.clear();
		const std::string line = editor->GetLineText(state.searchTermStart.line);
		size_t start = std::min(state.searchTermStart.index, line.size());
		const std::string& term = state.searchTerm;
		if (start > 0 && line[start - 1] == '.')
		{
			// After a dot: the members of whatever is on the left.
			size_t end = start - 1;
			if (end > 0 && line[end - 1] == '?') end--;
			size_t begin = end;
			while (begin > 0 && IsWordChar(line[begin - 1])) begin--;
			const std::string owner = line.substr(begin, end - begin);
			if (!owner.empty() && isdigit((unsigned char)owner[0])) return;   // a number such as 1.5
			std::vector<std::string> members;
			if (apiTypes.count(owner))
				MembersOf(owner, members);
			else if (!owner.empty())
			{
				std::string type = TypeOfVariable(editor->GetText(), owner);
				// Things every component has without declaring them.
				if (type.empty() && owner == "Transform") type = "Transform";
				if (type.empty() && owner == "GameObject") type = "GameObject";
				if (type.empty() && owner == "Scene") type = "Scene";
				if (!type.empty()) MembersOf(type, members);
			}
			if (!members.empty())
			{
				Offer(state.suggestions, members, term, 200);
				return;
			}
			// Unknown owner: any member name that fits what has been typed so far.
			if (!term.empty()) Offer(state.suggestions, apiWords, term, 30);
			return;
		}
		if (term.empty()) return;
		std::vector<std::string> words;
		if (state.language != nullptr)
			for (const auto& word : state.language->keywords) words.push_back(word);
		editor->IterateIdentifiers([&](const std::string& identifier) { words.push_back(identifier); });
		words.insert(words.end(), apiWords.begin(), apiWords.end());
		std::sort(words.begin(), words.end());
		words.erase(std::unique(words.begin(), words.end()), words.end());
		// The word being typed is itself an identifier in the document; do not offer it back.
		words.erase(std::remove(words.begin(), words.end(), term), words.end());
		Offer(state.suggestions, words, term, 30);
	}

	// The markup used by UI documents: tags are keywords, attribute names are declarations.
	const TextEditor::Language* MarkupLanguage()
	{
		static TextEditor::Language language = *TextEditor::Language::Cs();
		static bool ready = false;
		if (!ready)
		{
			language.name = "HTML";
			language.preprocess = 0;
			language.singleLineComment = "";
			language.singleLineCommentAlt = "";
			language.commentStart = "<!--";
			language.commentEnd = "-->";
			language.hasSingleQuotedStrings = true;
			language.hasDoubleQuotedStrings = true;
			// Markup folds on its tags: any element that closes on a later line can be collapsed
			// (see tools/patch_textedit.py, which adds this to the editor widget).
			language.tagBlocks = true;
			language.keywords = { "panel", "text", "button", "image", "input", "bar", "style" };
			language.declarations = { "id", "class", "onclick", "onload", "bind", "src" };
			language.identifiers.clear();
			ready = true;
		}
		return &language;
	}

	// Stylesheets: property words are keywords, common values are declarations, element names are known identifiers.
	const TextEditor::Language* StyleLanguage()
	{
		static TextEditor::Language language = *TextEditor::Language::Cs();
		static bool ready = false;
		if (!ready)
		{
			language.name = "CSS";
			language.preprocess = 0;
			language.singleLineComment = "";
			language.singleLineCommentAlt = "";
			language.commentStart = "/*";
			language.commentEnd = "*/";
			language.hasSingleQuotedStrings = true;
			language.hasDoubleQuotedStrings = true;
			language.keywords = { "width", "height", "padding", "margin", "gap", "flex", "direction", "grow", "align", "items", "justify",
				"content", "background", "color", "font", "size", "border", "radius", "position", "left", "top", "right", "bottom", "display" };
			language.declarations = { "row", "column", "center", "start", "end", "stretch", "absolute", "none", "space", "between", "auto",
				"transparent", "white", "black", "red", "green", "blue", "yellow", "gray", "grey", "rgba", "rgb" };
			language.identifiers = { "panel", "text", "button", "image", "input", "bar" };
			ready = true;
		}
		return &language;
	}

	// Shader files: GLSL, plus the words a .tshader or .tcompute file adds and the names the engine provides.
	const TextEditor::Language* ShaderLanguage()
	{
		static TextEditor::Language language = *TextEditor::Language::Glsl();
		static bool ready = false;
		if (!ready)
		{
			language.name = "Shader";
			for (const char* word : { "property", "surface", "vertex", "compute", "precision", "high", "color", "vector", "texture" })
				language.keywords.insert(word);
			for (const char* word : { "albedo", "alpha", "metallic", "roughness", "emissive", "uv", "worldPosition", "worldNormal", "vertexColor", "time", "position", "normal",
				"mainTexture", "texture1", "texture2", "result", "pixel", "size", "previous", "texture2D", "texture2DLod", "vec2_splat", "vec3_splat", "vec4_splat", "mul" })
				language.identifiers.insert(word);
			ready = true;
		}
		return &language;
	}

	const TextEditor::Palette& VisualStudioDark()
	{
		static TextEditor::Palette palette = TextEditor::GetDarkPalette();
		static bool ready = false;
		if (!ready)
		{
			auto set = [&](TextEditor::Color color, int r, int g, int b, int a = 255) { palette[(size_t)color] = IM_COL32(r, g, b, a); };
			set(TextEditor::Color::text, 212, 212, 212);
			set(TextEditor::Color::keyword, 86, 156, 214);
			set(TextEditor::Color::declaration, 78, 201, 176);
			set(TextEditor::Color::number, 181, 206, 168);
			set(TextEditor::Color::string, 206, 145, 120);
			set(TextEditor::Color::punctuation, 212, 212, 212);
			set(TextEditor::Color::preprocessor, 197, 134, 192);
			set(TextEditor::Color::identifier, 156, 220, 254);
			set(TextEditor::Color::knownIdentifier, 220, 220, 170);
			set(TextEditor::Color::comment, 106, 153, 85);
			set(TextEditor::Color::background, 30, 30, 30);
			set(TextEditor::Color::cursor, 174, 175, 173);
			set(TextEditor::Color::selection, 38, 79, 120);
			set(TextEditor::Color::whitespace, 64, 64, 64);
			set(TextEditor::Color::matchingBracketBackground, 62, 62, 66);
			set(TextEditor::Color::matchingBracketActive, 255, 215, 0);
			set(TextEditor::Color::matchingBracketLevel1, 255, 215, 0);
			set(TextEditor::Color::matchingBracketLevel2, 218, 112, 214);
			set(TextEditor::Color::matchingBracketLevel3, 23, 159, 255);
			set(TextEditor::Color::matchingBracketError, 244, 71, 71);
			set(TextEditor::Color::lineNumber, 133, 133, 133);
			set(TextEditor::Color::currentLineNumber, 198, 198, 198);
			set(TextEditor::Color::currentLineHighlight, 42, 42, 44);
			set(TextEditor::Color::currentLineHighlightBorder, 54, 54, 58);
			ready = true;
		}
		return palette;
	}

}

TN_API void tn_imgui_push_mono_font();

// The colours of every code editor: TextEditor::Color::count colours (text, keyword, ... currentLineHighlightBorder,
// in that order) as 0xAABBGGRR, from the editor's theme (EditorTheme.CodeColors).
TN_API void tn_code_set_palette(const uint32_t* colors, int count)
{
	if (count != (int)TextEditor::Color::count) return;
	for (int i = 0; i < count; i++) s_palette[i] = colors[i];
	s_paletteVersion++;
}

// The colours last set (for the editor's tests): false when none were.
TN_API bool tn_code_get_palette(uint32_t* colors, int count)
{
	if (count != (int)TextEditor::Color::count || s_paletteVersion == 0) return false;
	for (int i = 0; i < count; i++) colors[i] = s_palette[i];
	return true;
}

// Markup convenience: typing the '>' that ends an opening tag writes the matching closing tag
// after the cursor, so "<panel>" becomes "<panel>|</panel>".
static void CloseTypedTag(Document* document)
{
	TextEditor& editor = document->editor;
	const size_t undoIndex = editor.GetUndoIndex();
	const bool typed = undoIndex > document->lastUndoIndex;
	document->lastUndoIndex = undoIndex;
	if (!typed) return;

	const TextEditor::DocPos cursor = editor.GetMainCursorPosition();
	const std::string line = editor.GetLineText(cursor.line);
	if (cursor.index == 0 || cursor.index > line.size() || line[cursor.index - 1] != '>') return;
	const size_t open = line.rfind('<', cursor.index - 1);
	if (open == std::string::npos) return;
	const std::string tag = line.substr(open + 1, cursor.index - open - 2);
	// Closing tags, comments, self-closed tags and tags broken by an earlier '>' are left alone.
	if (tag.empty() || tag[0] == '/' || tag[0] == '!' || tag.back() == '/' || tag.find('>') != std::string::npos) return;
	size_t nameEnd = 0;
	while (nameEnd < tag.size() && (isalnum((unsigned char)tag[nameEnd]) || tag[nameEnd] == '-' || tag[nameEnd] == '_')) nameEnd++;
	if (nameEnd == 0) return;
	const std::string name = tag.substr(0, nameEnd);
	// Elements that never have content are written without a closing tag.
	if (name == "input" || name == "bar" || name == "image") return;
	const std::string closer = "</" + name + ">";
	if (line.compare(cursor.index, closer.size(), closer) == 0) return;
	editor.ReplaceSectionText(cursor, cursor, closer);
	editor.SetCursor(cursor);
	document->lastUndoIndex = editor.GetUndoIndex();
}

// language: 0 Beef, 1 UI markup (HTML-like), 2 stylesheet (CSS-like), 3 shader files (GLSL inside .tshader/.tcompute)
TN_API void* tn_code_create(const char* text, int language)
{
	Document* document = new Document();
	TextEditor& editor = document->editor;
	editor.SetLanguage(language == 1 ? MarkupLanguage() : (language == 2 ? StyleLanguage() : (language == 3 ? ShaderLanguage() : BeefLanguage())));
	document->markup = language == 1;
	editor.SetPalette(VisualStudioDark());
	editor.SetTabSize(4);
	editor.SetInsertSpacesOnTabs(false);
	editor.SetShowLineNumbersEnabled(true);
	editor.SetShowMatchingBrackets(true);
	editor.SetLineFoldingEnabled(true);
	editor.SetCompletePairedGlyphs(true);
	editor.SetAutoIndentEnabled(true);
	editor.SetShowCurrentLineHighlightEnabled(true);
	editor.SetShowScrollbarMiniMapEnabled(true);
	editor.SetShowWhitespacesEnabled(false);
	editor.SetText(std::string_view(text != nullptr ? text : ""));
	if (language == 0)
	{
		TextEditor::AutoCompleteConfig config;
		config.suggestionWidth = 40;
		config.callback = [document](TextEditor::AutoCompleteState& state)
		{
			state.suggestions.clear();
			const std::string source = document->editor.GetText();
			const size_t start = document->editor.GetSectionText(TextEditor::DocPos(0, 0), state.searchTermStart).size();
			const size_t end = document->editor.GetSectionText(TextEditor::DocPos(0, 0), state.searchTermEnd).size();
			const std::string prefix = source.substr(start, end - start);
			// Reuse only a narrower prefix on the identical receiver and unchanged surrounding source.
			if (!document->cachedCompletions.empty() && source.substr(0, start) == document->completionBefore &&
				source.substr(end) == document->completionAfter && prefix.rfind(document->completionPrefix, 0) == 0)
			{
				for (const auto& word : document->cachedCompletions)
					if (StartsWithNoCase(word, prefix)) state.suggestions.push_back(word);
				state.suggestionsPromise = false;
				document->semanticRequest = 0;
				return;
			}
			state.suggestionsPromise = true;
			document->completionStart = (int)start;
			document->semanticRequest = 1;
			document->semanticCursor = (int)end;
		};
		editor.SetAutoCompleteConfig(&config);
		editor.SetTextHoverCallback([document](TextEditor::PopupData& data)
		{
			const int cursor = (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), data.pos).size();
			const std::string source = document->editor.GetText();
			if (cursor == document->hintCursor && source == document->hintSource)
			{
				if (!document->semanticHint.empty())
					ImGui::TextUnformatted(document->semanticHint.c_str());
			}
			else if (document->semanticRequest == 0)
			{
				document->semanticRequest = 2;
				document->semanticCursor = cursor;
			}
		});
	}
	else
		document->completion.Connect(&editor);
	document->savedUndoIndex = editor.GetUndoIndex();
	document->lastUndoIndex = document->savedUndoIndex;
	return document;
}

// The editor describes the code it found: begin, one call per type (members separated by newlines), end.
TN_API void tn_code_api_begin() { apiPending.clear(); }

TN_API void tn_code_api_type(const char* name, const char* base, const char* members)
{
	if (name == nullptr || name[0] == 0) return;
	ApiType& type = apiPending[name];
	if (base != nullptr && base[0] != 0 && type.base.empty()) type.base = base;
	const char* at = members != nullptr ? members : "";
	while (*at != 0)
	{
		const char* end = strchr(at, '\n');
		const size_t length = end != nullptr ? (size_t)(end - at) : strlen(at);
		if (length > 0) type.members.emplace_back(at, length);
		if (end == nullptr) break;
		at = end + 1;
	}
}

TN_API void tn_code_api_end()
{
	apiTypes.swap(apiPending);
	apiPending.clear();
	apiWords.clear();
	TextEditor::Language& language = BeefLanguageMutable();
	for (auto& entry : apiTypes)
	{
		std::sort(entry.second.members.begin(), entry.second.members.end());
		entry.second.members.erase(std::unique(entry.second.members.begin(), entry.second.members.end()), entry.second.members.end());
		apiWords.push_back(entry.first);
		apiWords.insert(apiWords.end(), entry.second.members.begin(), entry.second.members.end());
		language.declarations.insert(entry.first);   // types are coloured as types
	}
	std::sort(apiWords.begin(), apiWords.end());
	apiWords.erase(std::unique(apiWords.begin(), apiWords.end()), apiWords.end());
}

// What completion would offer for a script with the cursor at the end of the given text. For tests.
TN_API const char* tn_code_api_complete(const char* text)
{
	static std::string result;
	Document document;
	document.editor.SetLanguage(BeefLanguage());
	document.editor.SetText(std::string_view(text != nullptr ? text : ""));
	const std::string all = text != nullptr ? text : "";
	const size_t lineStart = all.rfind('\n') == std::string::npos ? 0 : all.rfind('\n') + 1;
	const size_t lineIndex = (size_t)std::count(all.begin(), all.end(), '\n');
	size_t termStart = all.size();
	while (termStart > lineStart && IsWordChar(all[termStart - 1])) termStart--;
	TextEditor::AutoCompleteState state;
	state.searchTerm = all.substr(termStart);
	state.searchTermStart = TextEditor::DocPos(lineIndex, termStart - lineStart);
	state.searchTermEnd = TextEditor::DocPos(lineIndex, all.size() - lineStart);
	state.language = BeefLanguage();
	CompleteBeef(&document.editor, state);
	result.clear();
	for (const auto& suggestion : state.suggestions) { result += suggestion; result += '\n'; }
	return result.c_str();
}

// Recolours an open script after the known types changed.
TN_API void tn_code_refresh(void* handle)
{
	Document* document = (Document*)handle;
	if (document == nullptr || document->markup || document->editor.GetLanguageName() != "Beef") return;
	document->editor.SetLanguage(nullptr);
	document->editor.SetLanguage(BeefLanguage());
}

TN_API void tn_code_destroy(void* handle)
{
	Document* document = (Document*)handle;
	if (document == nullptr) return;
	document->completion.Disconnect();
	delete document;
}

TN_API const char* tn_code_get_text(void* handle)
{
	Document* document = (Document*)handle;
	document->text = document->editor.GetText();
	return document->text.c_str();
}

// The selected completion's remaining suffix is presentation only. Tab/Enter and Escape use TextEdit's
// normal acceptance/dismissal, preserving its selection, undo history and multi-choice popup.
static std::string InlineSuffix(Document* document)
{
	const std::string selected = document->editor.GetAutoCompletePreview();
	const auto start = document->editor.GetAutoCompleteStart();
	const auto cursor = document->editor.GetMainCursorPosition();
	if (selected.empty() || cursor < start) return "";
	const std::string prefix = document->editor.GetSectionText(start, cursor);
	if (!StartsWithNoCase(selected, prefix)) return "";
	return selected.substr(prefix.size());
}

TN_API void tn_code_render(void* handle, const char* id, float width, float height)
{
	Document* document = (Document*)handle;
	if (document->paletteVersion != s_paletteVersion)
	{
		document->editor.SetPalette(s_palette);
		document->paletteVersion = s_paletteVersion;
	}
	tn_imgui_push_mono_font();
	document->editor.Render(id, ImVec2(width, height));
	const std::string suffix = InlineSuffix(document);
	if (!suffix.empty() && ImGui::IsItemVisible())
		document->editor.DrawInlineText(document->editor.GetMainCursorPosition(), suffix.c_str(), ImGui::GetColorU32(ImGuiCol_TextDisabled));
	ImGui::PopFont();
	if (document->markup) CloseTypedTag(document);
	if (document->editor.GetLanguageName() == "Beef")
	{
		const size_t revision = document->editor.GetUndoIndex();
		const int caret = (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetMainCursorPosition()).size();
		if (revision == document->semanticUndoIndex && caret != document->signatureCursor) document->signature.clear();
		document->signatureCursor = caret;
		if (revision != document->semanticUndoIndex)
		{
			document->semanticUndoIndex = revision;
			const auto cursor = document->editor.GetMainCursorPosition();
			const std::string before = document->editor.GetSectionText(TextEditor::DocPos(0, 0), cursor);
			if (!before.empty() && (before.back() == '(' || before.back() == ','))
			{
				// Parameter hints are not completion lists: keep the active suggestion popup intact.
				if (document->semanticRequest != 1)
				{
					document->semanticRequest = 3;
					document->semanticCursor = (int)before.size();
				}
			}
			if (!before.empty() && (before.back() == ')' || before.back() == ';')) document->signature.clear();
		}
		if (!document->signature.empty())
		{
			ImVec2 position = document->editor.DocPos2ScreenPos(document->editor.GetMainCursorPosition());
			position.y += document->editor.GetLineHeight();
			ImGui::SetNextWindowPos(position);
			ImGui::BeginTooltip();
			ImGui::TextUnformatted(document->signature.c_str());
			ImGui::EndTooltip();
		}
	}
}

// Match the compiler worker's resolved absolute paths, including projects reached through symlinks.
TN_API const char* tn_code_canonical_path(const char* path)
{
	static thread_local std::string result;
	std::error_code error;
	#if defined(__cpp_char8_t)
	const std::filesystem::path input((const char8_t*)(path ? path : ""));
#else
	const auto input = std::filesystem::u8path(path ? path : "");
#endif
	const auto resolved = std::filesystem::weakly_canonical(input, error);
	if (error) result = path ? path : "";
	else
	{
		const auto utf8 = resolved.generic_u8string();
		result.assign((const char*)utf8.data(), utf8.size());
	}
	return result.c_str();
}

// Semantic requests and results are transferred on the UI thread; the compiler runs in a separate process.
TN_API int tn_code_take_semantic_request(void* handle, int* cursor)
{
	Document* document = (Document*)handle;
	const int request = document->semanticRequest;
	*cursor = document->semanticCursor;
	document->semanticRequest = 0;
	return request;
}

TN_API void tn_code_invalidate_semantics(void* handle)
{
	Document* document = (Document*)handle;
	document->cachedCompletions.clear();
	document->hintSource.clear();
	document->signature.clear();
}

// Drop a stale response without leaving an unresolved popup behind. A visible completion retries at the current cursor.
TN_API void tn_code_discard_semantic_results(void* handle, bool retry)
{
	Document* document = (Document*)handle;
	document->cachedCompletions.clear();
	const bool pending = retry && document->editor.IsAutoCompleteActive();
	document->editor.ClearAutoCompleteSuggestions(pending);
	if (pending)
	{
		document->completionStart = (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetAutoCompleteStart()).size();
		document->semanticCursor = (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetMainCursorPosition()).size();
		document->semanticRequest = 1;
	}
	else if (document->semanticRequest == 1)
		document->semanticRequest = 0;
}

TN_API void tn_code_semantic_signature(void* handle, const char* signature)
{
	Document* document = (Document*)handle;
	document->signature = signature ? signature : "";
	document->signatureCursor = (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetMainCursorPosition()).size();
}

TN_API void tn_code_semantic_hint(void* handle, int cursor, const char* hint)
{
	Document* document = (Document*)handle;
	document->hintCursor = cursor;
	document->hintSource = document->editor.GetText();
	document->semanticHint = hint ? hint : "";
}

TN_API int tn_code_cursor_byte(void* handle)
{
	Document* document = (Document*)handle;
	return (int)document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetMainCursorPosition()).size();
}

TN_API void tn_code_semantic_results(void* handle, const char* words)
{
	std::vector<std::string> suggestions;
	const char* at = words ? words : "";
	while (*at)
	{
		const char* end = strchr(at, '\n');
		const size_t length = end ? (size_t)(end - at) : strlen(at);
		if (length) suggestions.emplace_back(at, length);
		if (!end) break;
		at = end + 1;
	}
	Document* document = (Document*)handle;
	document->editor.SetAutoCompleteSuggestions(suggestions);
	const std::string source = document->editor.GetText();
	const size_t end = document->editor.GetSectionText(TextEditor::DocPos(0, 0), document->editor.GetMainCursorPosition()).size();
	const size_t start = std::min((size_t)std::max(document->completionStart, 0), end);
	document->cachedCompletions = suggestions;
	document->completionBefore = source.substr(0, start);
	document->completionAfter = source.substr(end);
	document->completionPrefix = source.substr(start, end - start);
}

static TextEditor::DocPos BytePosition(const std::string& text, size_t offset)
{
	TextEditor::DocPos pos(0, 0);
	for (size_t i = 0; i < std::min(offset, text.size()); i++)
	{
		if (text[i] == '\n') { pos.line++; pos.index = 0; }
		else if (((unsigned char)text[i] & 0xc0) != 0x80) pos.index++;
	}
	return pos;
}

TN_API void tn_code_goto_byte(void* handle, int offset)
{
	Document* document = (Document*)handle;
	document->editor.SetCursor(BytePosition(document->editor.GetText(), (size_t)std::max(offset, 0)));
}

// A whole-document replacement is one ordinary editor undo step, used by the project rename transaction.
TN_API void tn_code_replace_text(void* handle, const char* text)
{
	Document* document = (Document*)handle;
	const std::string previous = document->editor.GetText();
	const auto cursor = document->editor.GetMainCursorPosition();
	document->editor.ReplaceSectionText(TextEditor::DocPos(0, 0), BytePosition(previous, previous.size()), text ? text : "");
	document->editor.SetCursor(cursor);
}

TN_API bool tn_code_is_dirty(void* handle)
{
	Document* document = (Document*)handle;
	return document->editor.GetUndoIndex() != document->savedUndoIndex;
}

TN_API void tn_code_mark_saved(void* handle)
{
	Document* document = (Document*)handle;
	document->savedUndoIndex = document->editor.GetUndoIndex();
}

TN_API void tn_code_set_read_only(void* handle, bool readOnly) { ((Document*)handle)->editor.SetReadOnlyEnabled(readOnly); }
TN_API void tn_code_undo(void* handle) { ((Document*)handle)->editor.Undo(); }
TN_API void tn_code_redo(void* handle) { ((Document*)handle)->editor.Redo(); }
TN_API bool tn_code_can_undo(void* handle) { return ((Document*)handle)->editor.CanUndo(); }
TN_API bool tn_code_can_redo(void* handle) { return ((Document*)handle)->editor.CanRedo(); }
TN_API void tn_code_focus(void* handle) { ((Document*)handle)->editor.SetFocus(); }
TN_API void tn_code_clear_markers(void* handle) { ((Document*)handle)->editor.ClearMarkers(); }

// Distinct squiggle categories let compiler, optimization and determinism markers coexist
// with the editor's own search highlights. Lines and columns use zero-based UTF-8 positions.
TN_API void tn_code_clear_diagnostics(void* handle)
{
	TextEditor& editor = ((Document*)handle)->editor;
	for (size_t kind = 50; kind <= 53; ++kind)
		editor.ClearSquiggles(kind);
}

TN_API void tn_code_add_diagnostic(void* handle, int line, int column, int kind, bool isError, const char* message)
{
	if (line < 0) return;
	TextEditor& editor = ((Document*)handle)->editor;
	if ((size_t)line >= editor.GetLineCount()) return;
	const std::string source = editor.GetLineText((size_t)line);
	if (source.empty()) return;

	// Use the compiler's column when available; line-based checks underline the statement.
	size_t begin = 0;
	while (begin < source.size() && std::isspace((unsigned char)source[begin])) ++begin;
	if (begin == source.size()) return;
	size_t end = begin;
	if (kind == 2)
	{
		end = source.find("//", begin);
		if (end == std::string::npos) end = source.size();
		while (end > begin && std::isspace((unsigned char)source[end - 1])) --end;
	}
	else
	{
		if (column >= 0 && (size_t)column < source.size() && !std::isspace((unsigned char)source[(size_t)column]))
			begin = (size_t)column;
		end = begin;
		if (std::isalnum((unsigned char)source[begin]) || source[begin] == '_')
			while (end < source.size() && (std::isalnum((unsigned char)source[end]) || source[end] == '_')) ++end;
		else
			end = begin + 1;
	}
	if (end <= begin) end = begin + 1;
	const size_t squiggleType = isError ? 50 : (kind == 1 ? 51 : (kind == 2 ? 52 : 53));
	const ImU32 color = isError ? IM_COL32(245, 71, 71, 255) :
		(kind == 1 ? IM_COL32(60, 196, 205, 255) :
		(kind == 2 ? IM_COL32(181, 125, 255, 255) : IM_COL32(235, 185, 64, 255)));
	editor.AddSquiggle(TextEditor::DocPos((size_t)line, begin),
		TextEditor::DocPos((size_t)line, end), squiggleType, color, message ? message : "");
}

// line is zero based. Errors are red, warnings amber; the message shows when hovering the line.
TN_API void tn_code_add_marker(void* handle, int line, bool error, const char* message)
{
	Document* document = (Document*)handle;
	if (line < 0 || (size_t)line >= document->editor.GetLineCount()) return;
	const ImU32 gutter = error ? IM_COL32(200, 60, 60, 255) : IM_COL32(200, 160, 50, 255);
	const ImU32 text = error ? IM_COL32(120, 30, 30, 110) : IM_COL32(110, 90, 20, 100);
	document->editor.AddMarker((size_t)line, gutter, text, message, message);
}

TN_API void tn_code_goto_line(void* handle, int line)
{
	Document* document = (Document*)handle;
	if (line < 0) return;
	document->editor.SetCursor(TextEditor::DocPos((size_t)line, 0));
	document->editor.ScrollToLine((size_t)line);
}
