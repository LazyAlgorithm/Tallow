# Beef semantic worker

`main.cpp` calls the C ABI exported by Beef's IDE compiler. The editor communicates through
`tools/beef_language_service.py`, which snapshots workspace sources and open buffers, runs the worker in a
separate process and returns tab-separated records. A per-workspace adapter daemon keeps that compiler process
alive between queries. The worker never writes project files. Compiler crashes
and timeouts are reported to the editor without terminating it.

Build with `python3 tools/build_beef_language_service.py`. The engine build calls this automatically and the
packager includes the result. Linux links the installed toolchain's `libIDEHelper.a` and stages its non-core
shared dependencies. Windows builds a small loader for the installed `IDEHelper64.dll`; Linux cross-builds use
`TALLOW_WIN` and the existing xwin toolchain. The ABI declarations in `api.inc` match Beef's
`IDE/src/Compiler` wrappers. No compiler internals or alternate source parser are implemented here.

The adapter accepts `--project <folder> --request <folder>`. `request.tsv` contains these records:

- `operation<TAB>completion|definition|symbol|diagnostics|references|rename`
- `file<TAB>absolute source path`
- `cursor<TAB>UTF-8 byte offset`
- `new_name<TAB>identifier` for rename
- `overlay<TAB>absolute source path<TAB>snapshot file`, once per open buffer

It atomically writes `response.tsv`: completion label/detail, replacement range, signature, definition location,
diagnostic location/severity/message, reference path/start/length/old-name, reference-bearing source snapshots,
or an error message. Lines and columns are zero-based; ranges use UTF-8 bytes. Tabs/newlines in display text are
replaced with spaces. Callers must discard stale results and verify whole-source snapshots before applying a
rename. Rename validates new diagnostics and re-resolves the edited references to catch shadowing/capture even
when the resulting code compiles.

The daemon uses an authenticated loopback connection and a private per-user endpoint file. It stops after ten
idle minutes. Changed worker/adapter versions restart it automatically. Full source revisions update the
compiler incrementally; only edits to a member's completion prefix can reuse the previous declarations. A
changed project/dependency/source-file graph restarts the compiler. Parser generations and obsolete source
snapshots are retired after queries. Rename validation uses a separate compiler so hypothetical edits cannot
change the live workspace. No compiler-owned pointers cross the process boundary.

`--once` bypasses the daemon for validation and comparisons. Native `--serve` accepts one tab-separated
`manifest, operation, source, cursor, output` command per line and responds with `TALLOW_RESULT<TAB>status`.
Status 2 means the project graph changed and the adapter should restart the worker. Semantic support is
currently Linux and Windows. macOS is reported as unavailable.

Run `python3 tools/test_beef_language_service.py` to exercise the installed compiler against temporary sources:
unsaved type inference, completion prefixes, navigation, complete diagnostics, project graph changes, semantic
rename and collision/capture rejection. The tests preserve the compiler across queries to cover invalidation.
