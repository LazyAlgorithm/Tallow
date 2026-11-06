# Beef semantic editor integration

Phase 7f investigation, 2026-11-06. The backend is **not implemented yet**. The native editor still uses ApiIndex
completion; its compiler diagnostics come from background builds of saved files.

## Backend decision

Use an isolated, persistent helper executable linked against the same Beef compiler revision as the project.
Do not embed compiler state in the renderer/UI thread or infer a language server from the presence of BeefBuild.
A compiler crash, incompatible ABI or cancelled request must not terminate the editor or replace the current
project's working code. Keep ApiIndex available, visibly identified as basic completion when the helper is unavailable.

Inspected upstream source at `b62833e327d6b08f3566b31102c57646de6916b0`, the revision in `tools/toolchain.txt`:

- [BfSystem.bf](https://github.com/beefytech/Beef/blob/b62833e327d6b08f3566b31102c57646de6916b0/IDE/src/Compiler/BfSystem.bf):
  `BfSystem_CreateCompiler(system, isResolveOnly)` creates a resolve-only compiler; projects, parser instances,
  compiler locking and metadata updates live in this API.
- [BfParser.bf](https://github.com/beefytech/Beef/blob/b62833e327d6b08f3566b31102c57646de6916b0/IDE/src/Compiler/BfParser.bf):
  source bytes, filename and text version are supplied separately, so unsaved buffers need not overwrite disk.
  SetAutocomplete, Parse, Reduce and BuildDefs prepare the cursor's resolve request.
- [BfCompiler.bf](https://github.com/beefytech/Beef/blob/b62833e327d6b08f3566b31102c57646de6916b0/IDE/src/Compiler/BfCompiler.bf):
  ClassifySource and GetAutocompleteInfo provide semantic results; Cancel, GetSymbolReferences and the resolve
  APIs support further investigation of cancellation/navigation. Their presence is not proof that all requested
  editor features work without the surrounding BeefIDE setup.
- [SourceViewPanel.bf](https://github.com/beefytech/Beef/blob/b62833e327d6b08f3566b31102c57646de6916b0/IDE/src/ui/SourceViewPanel.bf):
  the actual resolve flow builds definitions, creates a classifier, classifies through the compiler, finishes the
  classifier and collects completion data. It carries text versions and treats cancelled results separately.
- `tools/format/BfFmt` already links the compiler for formatting. It is a useful packaging precedent, not a
  semantic service: parsing a single file is insufficient to resolve project dependencies or generic types.
- The vendored TextEdit has an optional LspBridge, but that requires a functioning language server and its own
  dependency. The inspected pinned Beef tree did not contain a ready-made LSP backend to attach to it.

## Implementation requirements before calling 7f complete

1. Build/version the helper for the supported host platforms, tied to the exact compiler ABI. Handshake includes
   protocol version, compiler revision, project/config/platform and engine API revision. Refuse incompatible
   configurations explicitly; a filename matching BeefBuild is not an ABI check.
2. Reuse the project's authoritative dependency graph, source set, defines, platform and configuration. Include
   corlib, the engine, game code, generated visual scripts and any comptime-generated members.
3. Each document has a monotonic revision (the native widget now provides `tn_code_revision`). Requests include
   revisions of all open buffers, cursor byte offset, and a project generation. Results apply only if all relevant
   versions still match. Define UTF-8 byte offsets versus displayed columns explicitly, including CRLF and Unicode.
4. Keep one resolve worker per project; debounce edits, supersede queued requests, and cancel or restart a stuck
   helper. Do not block the UI waiting for a compile. Cache parsers/project symbols and use incremental updates.
5. Translate the compiler's results into completion insertions, overload/signature help, diagnostics, hover and
   navigation. Only offer rename/fixes when exact edits and all affected document versions can be validated.
6. Exercise inherited/generic component members, overload selection, wrong arguments, missing imports, unsaved
   buffers, incomplete syntax, renamed APIs and generated graph code. Test stale replies, process crashes, project
   switching and hot reload. Measure latency, memory and edit-to-play time against ApiIndex on the same hardware.

## Landed prerequisites

The native widget tracks edit transactions, including undo/redo; dirty state compares text to the saved text
once per changed revision. This fixes branched edits reaching a saved undo index without matching the saved file.
Edits clear old diagnostic markers. Background saved-file checks queue a newer save rather than dropping it,
and markers are only applied to a matching, saved document revision. ApiIndex no longer falls back to arbitrary
member words when it has identified a type with no matching members. None of these changes is semantic IntelliSense.
