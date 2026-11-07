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
