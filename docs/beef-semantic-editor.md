# Beef semantic editor integration

Phase 7f implementation checkpoint, 2026-11-06. The built-in editor now connects to a persistent, isolated Beef
compiler helper for member completion, overload signatures, definition navigation, documentation and unsaved-buffer
diagnostics. ApiIndex remains the visibly labelled fallback. Full 7f acceptance remains open.

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

## Implemented and tested

`tools/semantic/build_helper.py` builds the C++ resolve helper. `service.py` reads the generated Beef workspace,
loads its dependency graph and maintains parser revisions. `BeefAnalysisClient` owns the process and performs pipe
I/O on a worker thread. `ScriptSemantic` debounces edits (200 ms for completion; 750 ms for diagnostics), replaces
queued work with the latest request, and rejects responses when project generation, any open buffer revision or the
requested cursor has changed. A stalled compiler is killed after a 30-second timeout; stopping the editor joins its
worker. Results never save or overwrite script files.

The editor toolbar exposes **Definition**, **Signature** and **Info**. Completion follows the native widget's normal
completion trigger; opening an argument list or typing a comma requests signatures. Info displays compiler-supplied
`///` documentation. Diagnostics use the native editor's zero-based line numbers. The compiler uses UTF-8 byte
offsets; CRLF files are normalised when loaded, consistently with the editor document representation.

The helper manifest hashes the linked compiler library. A different compiler fails closed to basic completion;
rebuild the helper against that installation. Linux uses the compiler's static libraries; Windows loads its installed
compiler DLLs. The service supports the generated `src` layout, Debug/Release and Linux64/Win64, and explicitly
rejects unsupported configuration selections or custom source layouts.

Local Linux checks passed for inherited/generic members, two overloads, declaration locations, compiler documentation,
unsaved type and syntax errors, clearing corrected diagnostics, revision echoes and invalid cursor rejection. The
actual EcsBench/engine dependency graph resolves comptime-generated Light members. The Beef process client passed
startup, round-trip and repeated shutdown checks. The updated editor and `PatrolExample` compile in Linux Debug.
Windows helper integration and packaged startup are covered by the ECS CI steps but await results for this checkpoint.

## Still required

- Interactive editor checks for project switching, hot reload and completion/diagnostic presentation.
- Find-references, version-validated rename and safe suggested fixes; the current toolbar does not offer these.
- Wider compiler/configuration compatibility, missing-import/changed-API fixtures and Unicode cursor fixtures.
- Comparative responsiveness, memory and edit-to-play measurements. A successful prototype resolve is not an editor
  performance acceptance result.

The original implementation requirements above remain the acceptance checklist; implemented parts are not a claim
that every requirement has passed.
