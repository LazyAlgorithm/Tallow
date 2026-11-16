// Headless checks of the code editor's editing behaviour (pair deletion, override completion). Built and run by
// tools/test_textedit.py; reaches into TextEditor's internals to drive keys and completion without a window.
#include <string>
#include <vector>
#include <functional>
#include <memory>
#include <chrono>
#include <map>
#include <unordered_map>
#include <array>
#include <algorithm>
#include <cstdio>
#include "imgui.h"
#define private public
#define protected public
#include "TextEditor.h"
#undef private
#undef protected

static int failures = 0;
static void check(const char* label, bool ok) { printf("%s: %s\n", ok ? "PASS" : "FAIL", label); if (!ok) failures++; }
static std::string show(std::string s) { std::string o; for (char c : s) { if (c == '\n') o += "\\n"; else if (c == '\t') o += "\\t"; else o += c; } return o; }

static std::string txt(TextEditor& e) { auto t = e.GetText(); if (!t.empty() && t.back() == '\n') t.pop_back(); return t; }
static void typeText(TextEditor& e, const char* text) { for (const char* p = text; *p; p++) e.handleCharacter((ImWchar)*p); }

int main() {
	IMGUI_CHECKVERSION();
	ImGui::CreateContext();
	ImGuiIO& io = ImGui::GetIO();
	io.DisplaySize = ImVec2(800, 600);
	unsigned char* px; int w, h; io.Fonts->GetTexDataAsRGBA32(&px, &w, &h);
	TextEditor e;
	e.SetLanguage(TextEditor::Language::Cpp());
	e.SetCompletePairedGlyphs(true);

	struct Case { const char* open; const char* pair; };
	for (Case c : {Case{"(", "()"}, Case{"[", "[]"}, Case{"{", "{}"}, Case{"\"", "\"\""}, Case{"'", "''"}}) {
		e.SetText("x = ");
		e.SetCursor(TextEditor::DocPos(0, 4));
		typeText(e, c.open);
		bool paired = txt(e) == std::string("x = ") + c.pair;
		e.handleBackspace(false);
		std::string label = std::string("backspace removes the empty pair ") + c.pair + " (" + show(txt(e)) + ")";
		check(label.c_str(), paired && txt(e) == "x = ");
	}
	// Not empty: only the character before the cursor goes.
	e.SetText("f(a)"); e.SetCursor(TextEditor::DocPos(0, 3)); e.handleBackspace(false);
	check("backspace inside a non-empty pair deletes one character", txt(e) == "f()");
	// Then empty: the pair goes together.
	e.handleBackspace(false);
	check("then backspace in the now-empty pair removes both", txt(e) == "f");
	// Cursor after the closer: only the closer goes.
	e.SetText("f()"); e.SetCursor(TextEditor::DocPos(0, 3)); e.handleBackspace(false);
	check("backspace after a closer deletes just the closer", txt(e) == "f(");
	// Mismatched: "(]" is not a pair.
	e.SetText("(]"); e.SetCursor(TextEditor::DocPos(0, 1)); e.handleBackspace(false);
	check("backspace between mismatched brackets deletes one", txt(e) == "]");
	// Selection: normal delete.
	e.SetText("(x)"); e.SetCursor(TextEditor::DocPos(0, 1)); e.cursors.getMain().update(TextEditor::DocPos(0, 1), TextEditor::DocPos(0, 2)); e.handleBackspace(false);
	check("backspace with a selection deletes the selection only", txt(e) == "()");
	// Undo restores both.
	e.SetText("x"); e.SetCursor(TextEditor::DocPos(0, 1)); typeText(e, "("); e.handleBackspace(false); e.Undo();
	check("undo after deleting a pair restores both", txt(e) == "x()");

	// Override completion: trigger after "override ", accept, cursor lands in the body.
	TextEditor::AutoCompleteConfig config;
	config.triggerDelay = std::chrono::milliseconds(0);
	bool asked = false;
	config.callback = [&](TextEditor::AutoCompleteState& state) {
		asked = true;
		state.suggestions = {
			std::string("LateUpdate(float deltaTime)\x1Fvoid LateUpdate(float deltaTime)\x1D    {\x1D        \x1E\x1D    }"),
			std::string("Update(TickInput input, float deltaTime)\x1Fvoid Update(TickInput input, float deltaTime)\x1D    {\x1D        \x1E\x1D    }"),
		};
	};
	e.SetAutoCompleteConfig(&config);
	e.SetText("class A : Script\n{\n    public override");
	e.SetCursor(TextEditor::DocPos(2, 19));
	typeText(e, " ");
	check("typing a space after override asks for completions", e.autocomplete.requestActivation);
	e.autocomplete.requestActivation = false;
	e.autocomplete.startLocation = e.document.findWordStart(e.autocomplete.currentLocation, true);
	check("the replaced word starts at the cursor after the space", e.autocomplete.startLocation == TextEditor::DocPos(2, 20));
	e.autocomplete.updateState(e.document, e.config.language);
	e.autocomplete.refreshSuggestions();
	e.autocomplete.active = true;
	check("suggestions arrived", asked && e.autocomplete.state.suggestions.size() == 2);
	e.autocomplete.currentSelection = 1;
	check("the inline preview is empty for an override item", e.GetAutoCompletePreview().empty());
	check("the list shows the signature", std::string(TextEditor::AutoComplete::displayPart(e.autocomplete.state.suggestions[1])) == "Update(TickInput input, float deltaTime)");
	e.acceptAutoComplete();
	const std::string expected = "class A : Script\n{\n    public override void Update(TickInput input, float deltaTime)\n    {\n        \n    }";
	check(("accepting inserts the whole method: " + show(txt(e))).c_str(), txt(e) == expected);
	auto cursor = e.GetMainCursorPosition();
	check("the cursor lands inside the body", cursor.line == 4 && cursor.index == 8);
	e.Undo();
	check("one undo removes the inserted method", txt(e) == "class A : Script\n{\n    public override ");

	// A partly typed name is replaced.
	e.SetText("    public override Upd"); e.SetCursor(TextEditor::DocPos(0, 23));
	e.autocomplete.startLocation = e.document.findWordStart(TextEditor::DocPos(0, 23), true);
	e.autocomplete.state.suggestions = { std::string("Update(TickInput input, float deltaTime)\x1Fvoid Update(TickInput input, float deltaTime)\x1D\x1C{\x1D\x1C\x1C\x1E\x1D\x1C}") };
	e.autocomplete.currentSelection = 0;
	e.acceptAutoComplete();
	check(("a partly typed name is replaced, tabs kept: " + show(txt(e))).c_str(),
		txt(e) == "    public override void Update(TickInput input, float deltaTime)\n\t{\n\t\t\n\t}" && e.GetMainCursorPosition() == TextEditor::DocPos(2, 2));
	// Plain items are unchanged.
	e.SetText("Pos"); e.SetCursor(TextEditor::DocPos(0, 3));
	e.autocomplete.startLocation = TextEditor::DocPos(0, 0);
	e.autocomplete.state.suggestions = { "Position" }; e.autocomplete.currentSelection = 0;
	check("a plain item previews as before", e.GetAutoCompletePreview() == "Position");
	e.acceptAutoComplete();
	check("a plain item inserts as before", txt(e) == "Position" && e.GetMainCursorPosition() == TextEditor::DocPos(0, 8));

	// Compiler completion items: display \x1F insert \x1F detail \x1F edits \x1F description.
	{
		using AC = TextEditor::AutoComplete;
		const std::string item("StringBuilder\x1F\x1FSystem.Text\x1F" "0\x1B" "0\x1Busing System.Text;\x1D\x1D\x1F" "class System.Text.StringBuilder");
		check("fields: display", AC::displayPart(item) == "StringBuilder");
		check("fields: detail", AC::suggestionField(item, 2) == "System.Text");
		check("fields: description", AC::suggestionField(item, 4) == "class System.Text.StringBuilder");
		check("fields: a missing field is empty", AC::suggestionField("Position", 3).empty());

		// An unimported type: the word is completed and its using added at the top, as one undo step.
		e.SetText("class A { void M() { var b = new StringBu } }"); e.SetCursor(TextEditor::DocPos(0, 41));
		e.autocomplete.startLocation = e.document.findWordStart(TextEditor::DocPos(0, 41), true);
		e.autocomplete.state.suggestions = { item }; e.autocomplete.currentSelection = 0;
		check("an item with edits has no inline preview", e.GetAutoCompletePreview().empty());
		e.acceptAutoComplete();
		check(("the using is added and the word completed: " + show(txt(e))).c_str(),
			txt(e) == "using System.Text;\n\nclass A { void M() { var b = new StringBuilder } }");
		check("the cursor ends after the completed word", e.GetMainCursorPosition() == TextEditor::DocPos(2, 46));
		e.Undo();
		check("one undo takes back the word and the using", txt(e) == "class A { void M() { var b = new StringBu } }");

		// "await" in a void method: several edits before the word (one at the same offset as another).
		e.SetText("class A { void M() { awa } }"); e.SetCursor(TextEditor::DocPos(0, 24));
		e.autocomplete.startLocation = e.document.findWordStart(TextEditor::DocPos(0, 24), true);
		e.autocomplete.state.suggestions = { std::string("await\x1F\x1F\x1F" "10\x1B" "0\x1B" "async \x1A" "10\x1B" "4\x1BTask\x1F" "await Keyword") };
		e.autocomplete.currentSelection = 0;
		e.acceptAutoComplete();
		check(("edits at one offset apply in order: " + show(txt(e))).c_str(), txt(e) == "class A { async Task M() { await } }");
		check("the cursor follows the shifted word", e.GetMainCursorPosition() == TextEditor::DocPos(0, 32));

		// A description alone keeps the inline preview; an insert text differing from the display is used.
		e.SetText("l.Wh"); e.SetCursor(TextEditor::DocPos(0, 4));
		e.autocomplete.startLocation = TextEditor::DocPos(0, 2);
		e.autocomplete.state.suggestions = { std::string("Where<>\x1FWhere\x1F\x1F\x1F(extension) IEnumerable<int> Where") };
		e.autocomplete.currentSelection = 0;
		check("an item with another insert text has no inline preview", e.GetAutoCompletePreview().empty());
		e.acceptAutoComplete();
		check("the insert text is used, not the display", txt(e) == "l.Where");
		e.SetText("Pos"); e.SetCursor(TextEditor::DocPos(0, 3));
		e.autocomplete.startLocation = TextEditor::DocPos(0, 0);
		e.autocomplete.state.suggestions = { std::string("Position\x1F\x1F\x1F\x1FVector3 Transform.Position { get; set; }") };
		e.autocomplete.currentSelection = 0;
		check("an item with only a description previews its name", e.GetAutoCompletePreview() == "Position");
		e.acceptAutoComplete();
		check("an item with only a description inserts its name", txt(e) == "Position");
	}

	ImGui::DestroyContext();
	// Semantic colouring (SetSemanticSpans): a span colours a name only while the glyphs still spell it outside strings
	// and comments, and only as a whole word.
	{
		TextEditor c;
		c.SetLanguage(TextEditor::Language::Cs());
		c.SetText("Speed = Move(speed); // Move\nvar s = \"Move\";");
		c.colorizer.update(c.config, c.document);
		auto span = [](int line, int index, TextEditor::Color color, const char* name) {
			TextEditor::SemanticSpan s; s.line = line; s.index = index; s.color = color;
			for (const char* p = name; *p; p++) s.name.push_back((ImWchar)*p);
			return s;
		};
		std::vector<TextEditor::SemanticSpan> spans;
		spans.push_back(span(0, 8, TextEditor::Color::semanticMethod, "Move"));        // a call: coloured
		spans.push_back(span(0, 0, TextEditor::Color::semanticMember, "Speed"));       // a field: coloured
		spans.push_back(span(0, 13, TextEditor::Color::semanticVariable, "spee"));     // part of a longer name: no
		spans.push_back(span(0, 24, TextEditor::Color::semanticMethod, "Move"));       // inside a comment: no
		spans.push_back(span(1, 9, TextEditor::Color::semanticMethod, "Move"));        // inside a string: no
		spans.push_back(span(1, 4, TextEditor::Color::semanticVariable, "t"));         // the text moved on: no
		spans.push_back(span(5, 0, TextEditor::Color::semanticVariable, "x"));         // past the end: no
		c.SetSemanticSpans(std::move(spans));
		c.semanticSpansForLine(0);
		bool first = c.semanticRow.size() == 2 && c.semanticRow[0].start == 0 && c.semanticRow[0].end == 5 &&
			c.semanticRow[0].color == TextEditor::Color::semanticMember && c.semanticRow[1].start == 8 &&
			c.semanticRow[1].color == TextEditor::Color::semanticMethod;
		check("semantic spans colour whole names, not part of one or inside a comment", first);
		c.semanticSpansForLine(1);
		check("semantic spans skip strings and text that changed", c.semanticRow.empty());
		// After an edit that moves the name, the old span no longer matches.
		c.SetText("  Speed = Move(speed);");
		c.colorizer.update(c.config, c.document);
		c.semanticSpansForLine(0);
		check("a span left over from before an edit is not drawn on other text", c.semanticRow.empty());
	}

	printf(failures ? "%d failed\n" : "all passed\n", failures);
	return failures ? 1 : 0;
}
