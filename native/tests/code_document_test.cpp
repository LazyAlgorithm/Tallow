// Standalone editor regressions: no window, graphics device or Beef compiler required.
#include "../tallow_code.cpp"
#include <cassert>
#include <iostream>

extern "C" void tn_imgui_push_mono_font() {}

int main()
{
    ImGui::CreateContext();
    void* handle = tn_code_create("a", 0);
    auto* document = static_cast<Document*>(handle);
    assert(!tn_code_is_dirty(handle));
    document->editor.ReplaceSectionText({0, 0}, {0, 1}, "b");
    assert(tn_code_is_dirty(handle));
    tn_code_mark_saved(handle);
    const auto savedIndex = document->editor.GetUndoIndex();
    const auto savedRevision = tn_code_revision(handle);
    tn_code_undo(handle);
    assert(tn_code_is_dirty(handle));
    tn_code_redo(handle);
    assert(!tn_code_is_dirty(handle));
    assert(tn_code_revision(handle) > savedRevision);
    tn_code_undo(handle);
    document->editor.ReplaceSectionText({0, 0}, {0, 1}, "c");
    // Branching after undo returns to the same undo index but NOT the same saved document.
    assert(document->editor.GetUndoIndex() == savedIndex);
    assert(tn_code_is_dirty(handle));
    assert(document->editor.GetLineText(0) == "c");
    tn_code_mark_saved(handle);
    assert(!tn_code_is_dirty(handle));
    tn_code_semantic_mode(handle, true);
    TextEditor::AutoCompleteState pending;
    RequestCompletion(document, pending);
    uint64_t revision;
    int32_t cursor;
    assert(pending.suggestionsPromise);
    assert(tn_code_completion_request(handle, &revision, &cursor));
    assert(!tn_code_completion_request(handle, &revision, &cursor));
    assert(tn_code_completion_result(handle, revision, cursor, "FromCompiler\n"));
    document->editor.ReplaceSectionText({0, 0}, {0, 1}, "new text");
    assert(!tn_code_completion_result(handle, revision, cursor, "Stale\n"));
    RequestCompletion(document, pending);
    assert(tn_code_completion_request(handle, &revision, &cursor));
    document->editor.SetCursor({0, 1});
    assert(!tn_code_completion_result(handle, revision, cursor, "WrongCursor\n"));
    tn_code_semantic_mode(handle, false);
    assert(!tn_code_completion_result(handle, revision, cursor, "Stopped\n"));
    tn_code_destroy(handle);
    tn_code_api_begin();
    tn_code_api_type("Empty", "", "");
    tn_code_api_type("Unrelated", "", "Surprise");
    tn_code_api_type("Parent", "", "Inherited");
    tn_code_api_type("Child", "Parent", "Own");
    tn_code_api_end();
    assert(std::string(tn_code_api_complete("Empty.Su")).empty());
    assert(std::string(tn_code_api_complete("Child.In")) == "Inherited\n");
    ImGui::DestroyContext();
    std::cout << "Code document regressions passed\n";
}
