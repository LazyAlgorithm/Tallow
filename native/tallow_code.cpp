// Script editor widget for the Tallow editor: a thin C interface over ImGuiColorTextEdit
// (syntax colouring, bracket matching, line folding, find/replace, multi-cursor, undo/redo,
// identifier completion) styled after Visual Studio's dark theme.

#include "imgui.h"
#include "TextEditor.h"
#include "extras/TrieAutoComplete.h"

#include <algorithm>
#include <cstring>
#include <cstdint>
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
		std::string savedText;
		uint64_t revision = 0;
		uint64_t dirtyRevision = 0;
		bool dirty = false;
		bool semantic = false;
		bool completionPending = false;
		uint64_t completionRevision = 0;
		int32_t completionCursor = -1;
		size_t lastUndoIndex = 0;
		bool markup = false;
		// Which of the editor's code colour sets this document was last given (tn_code_set_palette).
		int paletteVersion = 0;
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

	int32_t CursorOffset(Document* document)
	{
		const auto cursor = document->editor.GetMainCursorPosition();
		size_t offset = cursor.index;
		for (size_t line = 0; line < cursor.line; ++line)
			offset += document->editor.GetLineText(line).size() + 1;
		return static_cast<int32_t>(offset);
	}

	void RequestCompletion(Document* document, TextEditor::AutoCompleteState& state)
	{
		state.suggestions.clear();
		state.suggestionsPromise = true;
		document->completionPending = true;
		document->completionRevision = document->revision;
		document->completionCursor = CursorOffset(document);
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
			bool knownType = apiTypes.count(owner) != 0;
			if (knownType)
				MembersOf(owner, members);
			else if (!owner.empty())
			{
				std::string type = TypeOfVariable(editor->GetText(), owner);
				// Things every component has without declaring them.
				if (type.empty() && owner == "Transform") type = "Transform";
				if (type.empty() && owner == "GameObject") type = "GameObject";
				if (type.empty() && owner == "Scene") type = "Scene";
				knownType = !type.empty();
				if (knownType) MembersOf(type, members);
			}
			if (knownType)
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
		// Scripts complete from the engine's and the project's own code; see CompleteBeef.
		TextEditor::AutoCompleteConfig config;
		config.suggestionWidth = 40;
		config.callback = [document](TextEditor::AutoCompleteState& state) {
			if (document->semantic)
				RequestCompletion(document, state);
			else
				CompleteBeef(&document->editor, state);
		};
		editor.SetAutoCompleteConfig(&config);
	}
	else
		document->completion.Connect(&editor);
	document->savedText = editor.GetText();
	document->lastUndoIndex = editor.GetUndoIndex();
	editor.SetTransactionCallback([document](const std::vector<TextEditor::Change>& changes) {
		if (changes.empty()) return;
		++document->revision;
		document->completionPending = false;
		// Compiler locations refer to an older buffer as soon as it is edited, including undo/redo.
		document->editor.ClearMarkers();
	});
	return document;
}

// All widget calls, including applying worker results, stay on the UI thread.
TN_API int32_t tn_code_cursor_offset(void* handle) { return CursorOffset(static_cast<Document*>(handle)); }

TN_API void tn_code_semantic_mode(void* handle, bool enabled)
{
	auto* document = static_cast<Document*>(handle);
	if (document->semantic == enabled) return;
	document->semantic = enabled;
	document->completionPending = false;
	document->editor.SetAutoCompleteSuggestions({});
}

TN_API bool tn_code_completion_request(void* handle, uint64_t* revision, int32_t* cursor)
{
	auto* document = static_cast<Document*>(handle);
	if (!document->completionPending) return false;
	document->completionPending = false;
	*revision = document->completionRevision;
	*cursor = document->completionCursor;
	return true;
}

TN_API bool tn_code_completion_result(void* handle, uint64_t revision, int32_t cursor, const char* words)
{
	auto* document = static_cast<Document*>(handle);
	if (!document->semantic || revision != document->revision || cursor != CursorOffset(document) ||
		revision != document->completionRevision || cursor != document->completionCursor) return false;
	std::vector<std::string> suggestions;
	const char* at = words != nullptr ? words : "";
	while (*at)
	{
		const char* end = strchr(at, '\n');
		if (end == nullptr)
			end = at + strlen(at);
		if (end > at)
			suggestions.emplace_back(at, end);
		at = *end ? end + 1 : end;
	}
	document->editor.SetAutoCompleteSuggestions(suggestions);
	return true;
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
	ImGui::PopFont();
	if (document->markup) CloseTypedTag(document);
}

TN_API bool tn_code_is_dirty(void* handle)
{
	Document* document = (Document*)handle;
	if (document->dirtyRevision != document->revision)
	{
		document->dirty = document->editor.GetText() != document->savedText;
		document->dirtyRevision = document->revision;
	}
	return document->dirty;
}

TN_API uint64_t tn_code_revision(void* handle) { return ((Document*)handle)->revision; }

TN_API void tn_code_mark_saved(void* handle)
{
	Document* document = (Document*)handle;
	document->savedText = document->editor.GetText();
	document->dirtyRevision = document->revision;
	document->dirty = false;
}

TN_API void tn_code_set_read_only(void* handle, bool readOnly) { ((Document*)handle)->editor.SetReadOnlyEnabled(readOnly); }
TN_API void tn_code_undo(void* handle) { ((Document*)handle)->editor.Undo(); }
TN_API void tn_code_redo(void* handle) { ((Document*)handle)->editor.Redo(); }
TN_API bool tn_code_can_undo(void* handle) { return ((Document*)handle)->editor.CanUndo(); }
TN_API bool tn_code_can_redo(void* handle) { return ((Document*)handle)->editor.CanRedo(); }
TN_API void tn_code_focus(void* handle) { ((Document*)handle)->editor.SetFocus(); }
TN_API void tn_code_clear_markers(void* handle) { ((Document*)handle)->editor.ClearMarkers(); }

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
