#!/usr/bin/env python3
"""Adds tag-based folding to the bundled ImGuiColorTextEdit (third_party/TextEdit).

The widget folds on brackets and on indentation. Markup has neither reliably, so this adds a
Language::tagBlocks flag: an element whose closing tag is on a later line becomes a fold region.
Safe to run repeatedly; build.sh runs it before compiling the native code.
"""
import os, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'third_party', 'TextEdit')
header = os.path.join(root, 'TextEditor.h')
source = os.path.join(root, 'TextEditor.cpp')

h = open(header, encoding='utf-8').read()
if 'tagBlocks' not in h:
    anchor = '\t\tbool indentationForBlocks = false;\n'
    assert anchor in h, 'TextEditor.h layout changed'
    h = h.replace(anchor, anchor + '\n\t\t// does the language use <tag> ... </tag> pairs for blocks (markup)\n\t\tbool tagBlocks = false;\n', 1)
    open(header, 'w', encoding='utf-8').write(h)

c = open(source, encoding='utf-8').read()
if 'tagBlocks' not in c:
    anchor = '\t\tupdated = previous != *this;\n'
    assert c.count(anchor) == 1, 'TextEditor.cpp layout changed'
    block = r'''		// process invisible blocks for markup: an element that closes on a later line can be folded
		if (language && language->tagBlocks) {
			struct OpenTag { std::string name; size_t line; };
			std::vector<OpenTag> open;

			for (size_t line = 0; line < document.size(); line++) {
				auto& glyphs = document[line];

				for (size_t index = 0; index < glyphs.size(); index++) {
					if (glyphs[index].codepoint != '<' || !isBracketCandidate(glyphs[index])) {
						continue;
					}

					bool closing = index + 1 < glyphs.size() && glyphs[index + 1].codepoint == '/';
					size_t k = index + (closing ? 2 : 1);
					std::string name;

					while (k < glyphs.size()) {
						auto cp = glyphs[k].codepoint;
						if (!((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || (cp >= '0' && cp <= '9') || cp == '-' || cp == '_')) {
							break;
						}
						name += static_cast<char>(cp);
						k++;
					}

					if (name.empty()) {
						continue;
					}

					if (closing) {
						// close the nearest open element with this name (and anything left open inside it)
						for (size_t s = open.size(); s-- > 0;) {
							if (open[s].name == name) {
								if (line > open[s].line) {
									emplace_back(DocPos(open[s].line, 0), DocPos(line, glyphs.size()));
								}
								open.resize(s);
								break;
							}
						}

					} else {
						// <tag ... /> has no content to fold
						bool selfClosing = false;
						for (size_t e = k; e < glyphs.size(); e++) {
							if (glyphs[e].codepoint == '>') {
								selfClosing = glyphs[e - 1].codepoint == '/';
								break;
							}
						}
						if (!selfClosing) {
							open.push_back({name, line});
						}
					}
				}
			}

			std::sort(begin(), end(), [](const BracketPair& a, const BracketPair& b) {
				return a.start < b.start;
			});
		}

'''
    c = c.replace(anchor, block + anchor, 1)
    open(source, 'w', encoding='utf-8').write(c)
print('TextEdit tag folding patch applied')

# Completion after a dot: the widget only starts suggesting while a word is being typed, so "Audio." showed
# nothing until another letter followed. Start on '.' as well; the application decides what to offer.
c = open(source, encoding='utf-8').read()
old = "\tif (CodePoint::isWord(character)) {\n\t\tif (!cursors.hasMultiple() && autocomplete.startTyping(cursors)) {"
new = "\tif (CodePoint::isWord(character) || character == '.') {\n\t\tif (!cursors.hasMultiple() && autocomplete.startTyping(cursors)) {"
if new not in c:
    assert c.count(old) == 1, 'TextEditor.cpp layout changed (completion trigger)'
    open(source, 'w', encoding='utf-8').write(c.replace(old, new, 1))

# A completed asynchronous request must release the pending state, including an empty result.
c = open(source, encoding='utf-8').read()
old = "void TextEditor::AutoComplete::setSuggestions(const std::vector<std::string>& suggestions) {\n\tstate.suggestions = suggestions;"
new = old + "\n\tstate.suggestionsPromise = false;"
if new not in c:
    assert c.count(old) == 1, 'TextEditor.cpp layout changed (asynchronous completion)'
    open(source, 'w', encoding='utf-8').write(c.replace(old, new, 1))
# Expose the active compiler completion for a ghost-text suffix; acceptance still uses the widget's undo path.
h = open(header, encoding='utf-8').read()
anchor = '\tinline void SetAutoCompleteSuggestions(const std::vector<std::string>& suggestions) { autocomplete.setSuggestions(suggestions); }'
addition = '\n\tinline std::string GetAutoCompletePreview() { return autocomplete.isActive() ? autocomplete.getReplacement() : ""; }\n\tinline DocPos GetAutoCompleteStart() const { return autocomplete.getStart(); }'
if 'GetAutoCompletePreview()' not in h:
    assert h.count(anchor) == 1, 'TextEditor.h layout changed (completion preview)'
    open(header, 'w', encoding='utf-8').write(h.replace(anchor, anchor + addition, 1))

# A stale async result can retry the active popup or release its promise without showing obsolete choices.
h = open(header, encoding='utf-8').read()
anchor = '\tinline DocPos GetAutoCompleteStart() const { return autocomplete.getStart(); }'
addition = '\n\tinline bool IsAutoCompleteActive() const { return autocomplete.isActive(); }\n\tinline void ClearAutoCompleteSuggestions(bool pending) { autocomplete.clearSuggestions(pending); }'
if 'ClearAutoCompleteSuggestions' not in h:
    assert h.count(anchor) == 1, 'TextEditor.h layout changed (pending completion)'
    h = h.replace(anchor, anchor + addition, 1)
anchor = '\t\tvoid setSuggestions(const std::vector<std::string>& suggestions);'
addition = '\n\t\tinline void clearSuggestions(bool pending) { state.suggestions.clear(); state.suggestionsPromise = pending; currentSelection = 0; }'
if 'void clearSuggestions(bool pending)' not in h:
    assert h.count(anchor) == 1, 'TextEditor.h layout changed (clear completion)'
    h = h.replace(anchor, anchor + addition, 1)
open(header, 'w', encoding='utf-8').write(h)

# Ghost text belongs to the editor child draw list, above its opaque background, with the text-area clip.
h = open(header, encoding='utf-8').read()
anchor = '\tinline bool IsDocPosVisible(DocPos pos) const { return isDocPosVisible(normalizePos(pos)); }'
addition = '\n\tvoid DrawInlineText(DocPos pos, const char* text, ImU32 color);'
if 'void DrawInlineText(' not in h:
    assert h.count(anchor) == 1, 'TextEditor.h layout changed (inline text)'
    h = h.replace(anchor, anchor + addition, 1)
anchor = '\tImDrawList* drawList;\n\n\tImFont* font;'
if 'ImVec2 textClipMin, textClipMax;' not in h:
    assert h.count(anchor) == 1, 'TextEditor.h layout changed (text clip)'
    h = h.replace(anchor, '\tImDrawList* drawList;\n\tImVec2 textClipMin, textClipMax;\n\n\tImFont* font;', 1)
open(header, 'w', encoding='utf-8').write(h)
c = open(source, encoding='utf-8').read()
anchor = '\t\t// render parts in the text area\n'
if 'textClipMin = drawList->GetClipRectMin();' not in c:
    assert c.count(anchor) == 1, 'TextEditor.cpp layout changed (text clip)'
    c = c.replace(anchor, '\t\ttextClipMin = drawList->GetClipRectMin();\n\t\ttextClipMax = drawList->GetClipRectMax();\n\n' + anchor, 1)
c = c.replace('visPos.row >= firstVisibleRow && visPos.row < lastVisibleRow &&', 'visPos.row >= firstVisibleRow && visPos.row <= lastVisibleRow &&', 1)
anchor = 'bool TextEditor::isDocPosVisible(DocPos docPos) const {'
addition = """// Draw on the editor child, after its text, using the same font and text-area clip.
void TextEditor::DrawInlineText(DocPos pos, const char* text, ImU32 color) {
    if (IsDocPosVisible(pos)) {
        drawList->PushClipRect(textClipMin, textClipMax, true);
        drawList->AddText(font, fontSize, DocPos2ScreenPos(pos), color, text);
        drawList->PopClipRect();
    }
}

""".replace('    ', '\t')
if 'void TextEditor::DrawInlineText(' not in c:
    assert c.count(anchor) == 1, 'TextEditor.cpp layout changed (inline text)'
    c = c.replace(anchor, addition + anchor, 1)
open(source, 'w', encoding='utf-8').write(c)

# Preserve visual layout and paired closers while previewing compiler suggestions.
c = open(source, encoding='utf-8').read()
old = "// Draw on the editor child, after its text, using the same font and text-area clip.\nvoid TextEditor::DrawInlineText(DocPos pos, const char* text, ImU32 color) {\n\tif (IsDocPosVisible(pos)) {\n\t\tdrawList->PushClipRect(textClipMin, textClipMax, true);\n\t\tdrawList->AddText(font, fontSize, DocPos2ScreenPos(pos), color, text);\n\t\tdrawList->PopClipRect();\n\t}\n}\n\n"
new = "// Ghost completions are visual only. Shift an existing paired closer and the rest of its\n// line to the right of the preview, without modifying the source or the undo history.\nvoid TextEditor::DrawInlineText(DocPos pos, const char* text, ImU32 color) {\n\tif (!text || !*text || !IsDocPosVisible(pos)) return;\n\tdrawList->PushClipRect(textClipMin, textClipMax, true);\n\tconst ImVec2 screen = DocPos2ScreenPos(pos);\n\tconst auto& line = document[pos.line];\n\tif (pos.index < line.size() && (line[pos.index].codepoint == ')' ||\n\t\tline[pos.index].codepoint == ']' || line[pos.index].codepoint == '}')) {\n\t\t// The ordinary renderer has already drawn the closer at the caret. Redraw the\n\t\t// line tail in its preview position so neither it nor the ghost text is clipped by it.\n\t\tconst float previewWidth = ImGui::CalcTextSize(text).x;\n\t\tdrawList->AddRectFilled(screen, ImVec2(textClipMax.x, screen.y + glyphSize.y),\n\t\t\tpalette.get(Color::background));\n\t\tfloat x = screen.x + previewWidth;\n\t\tfor (size_t i = pos.index; i < line.size() && x < textClipMax.x; ++i) {\n\t\t\tconst auto& glyph = line[i];\n\t\t\tif (glyph.codepoint != ' ' && glyph.codepoint != '\\t')\n\t\t\t\tfont->RenderChar(drawList, fontSize, ImVec2(x, screen.y),\n\t\t\t\t\tpalette.get(glyph.color), glyph.codepoint);\n\t\t\tx += glyph.columns * glyphSize.x;\n\t\t}\n\t\t// This late overlay also covered the editor's caret, so restore it.\n\t\tdrawList->AddLine(screen, ImVec2(screen.x, screen.y + fontSize),\n\t\t\tpalette.get(Color::cursor));\n\t}\n\tdrawList->AddText(font, fontSize, screen, color, text);\n\tdrawList->PopClipRect();\n}\n\n"
if old in c:
    c = c.replace(old, new, 1)
elif new not in c:
    raise AssertionError('TextEditor.cpp layout changed (inline completion layout)')
old_pair = "\tconst auto closer = CodePoint::toPairCloser(opener);\n\n\t// ignore input if it was the closing character for a pair that was automatically inserted"
new_pair = "\tconst auto closer = CodePoint::toPairCloser(opener);\n\n\t// After typing or accepting completion inside a paired expression, typing its\n\t// closing glyph should advance over the existing closer, not insert a duplicate.\n\tif (!cursors.hasMultiple() && !cursors.anyHasSelection() &&\n\t\t(character == ')' || character == ']' || character == '}')) {\n\t\tconst auto at = cursors.getCurrent().getSelectionEnd();\n\t\tif (at.line < document.size() && at.index < document[at.line].size() &&\n\t\t\tdocument[at.line][at.index].codepoint == character) {\n\t\t\tcompletePairCloser = 0;\n\t\t\tmoveRight(false, false);\n\t\t\treturn;\n\t\t}\n\t}\n\n\t// ignore input if it was the closing character for a pair that was automatically inserted"
if old_pair in c:
    c = c.replace(old_pair, new_pair, 1)
elif new_pair not in c:
    raise AssertionError('TextEditor.cpp layout changed (paired closer)')
open(source, 'w', encoding='utf-8').write(c)


# Parameter signatures belong in autocomplete's header instead of an overlapping tooltip.
h = open(header, encoding='utf-8').read()
old = "\tinline bool IsAutoCompleteActive() const { return autocomplete.isActive(); }\n\tinline void ClearAutoCompleteSuggestions(bool pending)"
new = "\tinline bool IsAutoCompleteActive() const { return autocomplete.isActive(); }\n\tinline void SetAutoCompleteSignature(const std::string& signature) { autocomplete.setSignature(signature); }\n\tinline void ClearAutoCompleteSuggestions(bool pending)"
if old in h:
    h = h.replace(old, new, 1)
elif new not in h:
    raise AssertionError('TextEditor.h layout changed (signature API)')
old = "\t\tvoid setSuggestions(const std::vector<std::string>& suggestions);\n\t\tinline void clearSuggestions"
new = "\t\tvoid setSuggestions(const std::vector<std::string>& suggestions);\n\t\tinline void setSignature(const std::string& value) { signature = value; }\n\t\tinline void clearSuggestions"
if old in h:
    h = h.replace(old, new, 1)
elif new not in h:
    raise AssertionError('TextEditor.h layout changed (signature setter)')
old = "\t\tAutoCompleteConfig configuration;\n\t\tAutoCompleteState state;\n\t\tbool triggeredManually"
new = "\t\tAutoCompleteConfig configuration;\n\t\tAutoCompleteState state;\n\t\tstd::string signature;\n\t\tbool triggeredManually"
if old in h:
    h = h.replace(old, new, 1)
elif new not in h:
    raise AssertionError('TextEditor.h layout changed (signature storage)')
open(header, 'w', encoding='utf-8').write(h)

c = open(source, encoding='utf-8').read()
old = "\tconst auto visibleSuggestions = (suggestions == 0) ? 1 : std::min(static_cast<size_t>(10), suggestions);\n\tconst auto& style = ImGui::GetStyle();\n\tconst auto height = ImGui::GetFrameHeightWithSpacing() * visibleSuggestions + style.WindowPadding.y * 2.0f;\n\tImGui::SetNextWindowSize(ImVec2(configuration.suggestionWidth * glyphSize.x, height));"
new = "\t// Parameter help is a header within the completion window, not another popup on\n\t// top of it. A bounded, scrollable header keeps long overload lists from hiding suggestions.\n\tconst auto visibleSuggestions = (suggestions == 0) ? 1 : std::min(static_cast<size_t>(signature.empty() ? 10 : 8), suggestions);\n\tconst auto& style = ImGui::GetStyle();\n\tconst float signatureHeight = signature.empty() ? 0.0f : ImGui::GetTextLineHeightWithSpacing() * 3.0f;\n\tconst auto height = ImGui::GetFrameHeightWithSpacing() * visibleSuggestions + style.WindowPadding.y * 2.0f +\n\t\t(signature.empty() ? 0.0f : signatureHeight + style.ItemSpacing.y + 1.0f);\n\tImGui::SetNextWindowSize(ImVec2(configuration.suggestionWidth * glyphSize.x, height));"
if old in c:
    c = c.replace(old, new, 1)
elif new not in c:
    raise AssertionError('TextEditor.cpp layout changed (signature popup sizing)')
old = "\t\t} else {\n\t\t\t// do we have any suggestions\n\t\t\tif (suggestions) {"
new = "\t\t} else {\n\t\t\tif (!signature.empty())\n\t\t\t{\n\t\t\t\tImGui::BeginChild(\"##signatureHelp\", ImVec2(0.0f, signatureHeight), false, ImGuiWindowFlags_NoNav);\n\t\t\t\tImGui::TextWrapped(\"%s\", signature.c_str());\n\t\t\t\tImGui::EndChild();\n\t\t\t\tImGui::Separator();\n\t\t\t}\n\t\t\t// do we have any suggestions\n\t\t\tif (suggestions) {"
if old in c:
    c = c.replace(old, new, 1)
elif new not in c:
    raise AssertionError('TextEditor.cpp layout changed (signature header)')
open(source, 'w', encoding='utf-8').write(c)
