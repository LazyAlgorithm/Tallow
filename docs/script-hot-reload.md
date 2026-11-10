# Automatic script library reload

Linux and Windows x86-64 Debug editors watch project `.bf` files, including additions, removals and graph-generated scripts.

**Project Settings > Scripting > Script Reload** offers:

- **Automatic (default):** On Linux, compatible method-only changes use the existing lightweight native dispatch patcher without refreshing the component and asset catalogs. A change to declarations, fields, or script types uses structural reload. If method patch validation fails, Tallow reuses the **already-compiled** library for structural activation without another BeefBuild or link. After any structural activation the method patcher is disabled until the editor restarts because it cannot reliably match class metadata replaced by structural migration. Windows currently uses structural reload for both kinds of edits.
- **Conservative:** Always use structural compilation and state migration, including method-only changes.
- **Manual:** Saving and external file changes do not activate script code. Use **File > Reload Scripts** (Ctrl+R) when ready. **Check Errors** compiles without activating. **Force Structural Script Reload** overrides Automatic or Manual without restarting the editor.

The selected mode is saved to `project.tallow` and defaults to Automatic for existing projects.

Automatic now keeps gameplay method-body changes pending while in Edit mode by default. Script
declarations (new components, fields, method signatures and inspector attributes) still trigger
structural reload in Edit mode, so newly added fields can be configured in the Inspector.
The **Reload Methods In Edit** project toggle restores method hot-reload on every save.
When Play is pressed with a reload in progress or pending, Tallow stays in Edit mode
while it compiles, and automatically enters Play when the reload succeeds. No second click
or setting is required. A failed compilation retains the previous live code and keeps Play blocked.
The top-of-editor status is cleared on successful Play entry and updated for compile failures.
The old `playAfterCompile` project setting is no longer used or saved.
Manual mode also defers compilation until explicit Reload Scripts or a Play attempt.

A cheap `--classify` invocation compares the saved source with the last successfully activated
script library (0 unchanged, 10 method-only, 11 structural, 3 incompatible resident code).
No script compiler or native linker is invoked for method-only saves while idle in Edit mode.
Whitespace-only saves now skip BeefBuild entirely on Linux and Windows when the
source token stream is unchanged. String/comment content stays significant; multiline
strings and preprocessor directives conservatively preserve raw source bytes. The
same check runs before Play, including when Manual mode has marked scripts dirty.
Explicit rebuild commands are not suppressed. Existing baseline snapshots without
a normalized-source fingerprint perform one ordinary build before using the shortcut.
The method-only path currently reduces activation and catalog-refresh overhead, but **it still invokes
BeefBuild for a new native script library**. It is not yet a persistent incremental compiler; compiler
time and module linking remain visible in the timing log.

To validate source formatting after changes, run
`python3 tools/format/format_code.py --check Editor/src/Project/Project.bf Editor/src/Project/ProjectSettings.bf Editor/src/Scripts/ScriptReloadEditor.bf Editor/src/Scripts/ScriptEditor.bf Editor/src/App/EditorBuild.bf Editor/src/App/EditorLayout.bf`.
The repository also includes `python3 tools/test_reload_scripts.py` for Python reload-mode and cache tests.

Linux and Windows x86-64 Debug editors watch project `.bf` files, including additions, removals and graph-generated scripts. Saving in the Scripts tab also queues a reload. Editor saves update the file monitor immediately so one save does not trigger a second identical compilation when the monitor polls. Changes debounce briefly (150 ms) before the compiler builds a versioned game library on a worker thread. Generated Beef workspace configuration files are rewritten only when their content changes to preserve incremental compiler caches. Engine/editor implementations and their state remain in the host. Beef still compiles changed code and metadata; no manual full-project rebuild is required for supported game-script edits.

At a frame boundary, the editor loads the library, maps its type metadata onto stable resident identities, refreshes the component registry, replaces project component instances and restores compatible fields/references. The editor window, scene objects, physics world and Play state remain alive. The activation scene is passed explicitly, including in Edit mode. Activated symbols are recorded so newly added types work through later generations.

In a network session, what changes on the other machines, and how `[Sync]` fields and native ECS systems behave when only one machine reloads, is in [Unified ECS networking](unified-ecs-networking.md#editing-while-playing).

Supported changes include method edits, new component scripts, adding/removing/retyping supported instance fields, and inspector attributes. Same-name/type fields retain their values; newly added or retyped fields use their new initializers. Supported private runtime fields are also preserved unless marked NonSerialized. Awake/Start state is preserved and those callbacks are not repeated; OnValidate runs after restoring values. Constructors and field initializers run for replacement instances.

The project `build/script-reload.log` includes timing information for source scanning, the BeefBuild invocation,
and the full native reload build. Linux also separates object inspection, ELF object preparation, and linking.
The Linux reload worker caches ELF objects whose bytes and actually affected host definitions have
not changed, avoiding repeated symbol rewriting on ordinary method saves.
Linux now links gameplay objects and reflection metadata explicitly and, without mold or lld (see
[Compile speed](#compile-speed-on-linux-install-mold-or-lld)), puts existing engine/editor
dependency objects into a cached static archive. The linker extracts dependency implementations
only when necessary. New script declarations can still cause BeefBuild to rewrite
many engine/editor object outputs. To avoid spending extra time repacking
thousands of prepared dependency objects, Linux builds an indexed **thin** static
archive that references those objects in place. The archive index is refreshed
when prepared objects change, and GNU/LLVM linkers extract needed implementations
normally. An archiver without thin-archive support falls back to the original
full archive; a link error retries the previous full-object linker for compatibility.
Thin archives optimize Tallow's archive construction stage, not BeefBuild's
compilation, symbol rewriting of truly changed objects, or linker resolution.
Prepared ELF objects are now cached by **source object path**, not by the
object's position in BeefBuild's `ObjectArgs.txt` linker list. Adding or removing
a component can reorder that list without changing the object itself, so using
position as the cache key falsely invalidated many existing entries. Existing
index-keyed cache records are migrated in place and retain their prepared
object paths. Reordered but byte-identical objects will no longer require
ELF symbol rewriting. Truly changed objects still require rewriting; a changed
dependency archive still requires rebuilding. This does **not** prevent BeefBuild
from rewriting dependency output files when its own reflection/type graph changes.
Both Linux and Windows keep their temporary Beef workspaces across editor launches so that
incremental compiler caches can survive closing and reopening the editor. Windows already uses
indexed dependency .lib archives, with on-demand extraction.
Linux logs game/dependency object counts, archive reuse and full-link fallback.
Set `TALLOW_RELOAD_FLAT_LINK=1` before launching Tallow to use the old Linux full-object link
for diagnosis. Compilation of scripts and type metadata still takes time: this changes link
inputs, not the underlying Beef compiler. Validate with the measured reload log before
assuming a given game has improved. Adding unrelated exported
functions to the host no longer invalidates every dependency object. Missing objects, changed object
bytes and changed relevant host definitions still trigger a fresh rewrite. The log reports all three
miss categories. The first reload in a new editor session will have a cold cache.
Source/ABI checks still run on every reload.
This helps distinguish compiler latency from Tallow's own reload overhead without guessing.

Reloads now log **BeefBuild outputs** separately for gameplay, dependency archives/objects,
and reflection metadata. These are file timestamp changes (rewritten or newly created), not
proof of semantic recompilation. If dependency outputs remain untouched but BeefBuild still
takes several seconds, that latency is outside Tallow's native link step.

To measure the no-change BeefBuild baseline, **close the editor after a successful reload**
and run `python3 tools/profile_reload_compiler.py /path/to/GameProject --runs 2` from
the Tallow source checkout. The script reuses the exact temporary workspace and invokes
the compiler twice with diagnostic verbosity, prints output-file activity and timings,
and saves `beef-profile-1.log` and `beef-profile-2.log` in the workspace.
Do not run it concurrently with the editor or another build. No source files or
build configurations are changed. This diagnostic supports Linux and Windows.

To see BeefBuild's own detailed rebuild activity, set `TALLOW_RELOAD_TRACE_COMPILER=1` in the
environment **before launching Tallow**, then save a script and inspect `build/script-reload.log`.
This enables compiler diagnostics rather than changing the build's optimization settings.

## Compile speed on Linux: install mold or lld

Every compile ends with a link, and GNU ld (Linux's default) is slow at it. When `ld.mold` or `ld.lld` is on
PATH (`sudo dnf install mold`, or `lld`; `apt install mold`), the editor links games with it (the project's
BeefProj.toml gets `-fuse-ld=mold` or `-fuse-ld=lld`), and script reloads link the library with it, reading
the engine's objects as a lazy `--start-lib` group, so no dependency archive is made or kept. A project's own
`link` setting comes after, so it can choose another linker.

Measured on a 512-script project (TallowCompileBench, Ryzen 9 7900X, Debug):

| | GNU ld | lld |
|---|---|---|
| Game build (error check, Full Rebuild): any edit | 3.7 s | 2.9 s |
| Game build: a script added or removed | 5.1 s | 4.3 s |
| Script reload: method body or field edit | 4.4 s | 3.7 s |
| Script reload: a script added or removed | 8.5 s | 5.3 s |

Most of what is left is BeefBuild itself: about 1.9 s of every compile is its frontend checking the whole
engine, editor and game again (each BeefBuild starts with nothing loaded), however small the edit. Adding or
removing a type also makes it regenerate most of the engine's object files (it does so in a workspace of a few
classes too), which is the extra 1.4 s of those rows. Script reloads no longer pay either: see below.

## Compile speed on Linux: the compile server

Script reloads compile with the Beef compiler kept loaded between builds, as the Beef IDE keeps it, instead of a
new BeefBuild each time. `tools/BeefCompileServer/Serve.bf` is BeefBuild's own code (BuildApp) with a loop around
it; `tools/beef_compile_server.py` builds it from the Beef install's BeefBuild and IDE sources (a Linux install of
Beef is built from them, so nothing more is installed: it takes about 5 s, once per Beef install, into
`~/.cache/tallow/beef-compile-server`), and `reload_scripts.py` uses it:

- `--snapshot` (the editor opening a project) starts a server for the project's reload workspace, which builds
  once. The server leaves when the editor does, or after an hour without a build.
- Each reload asks it to build (`.tallow-reload/workspace-linux64/.compile-server`: a `request` file in, a `done`
  file out, its output in `server.log`). It looks at time stamps, recompiles only the sources that changed or
  were added or removed, and keeps everything else it parsed and built.
- It leaves out the archive BeefBuild makes of a dynamic library's 5,000 objects (78 MB, up to 2 s): reload links
  its own module from the objects.
- When it cannot be used (another platform, a Beef install without its sources, still being built, it crashed),
  the reload runs BeefBuild as before and says which compiled it on the `Reload timings` line.
  `TALLOW_COMPILE_SERVER=0` turns it off; `TALLOW_RELOAD_TRACE_COMPILER=1` uses BeefBuild with full output.

Every reload also runs `reload_scripts.py` three times (classify, build, commit). What each run works out per file
is cached by size and time stamp (`.tallow-reload/source-cache.json`, and the game objects' and reflection
object's symbols beside the aliased objects), so only what an edit changed is read again.

The same project, whole reloads as the editor runs them (classify, build and commit), lld:

| | BeefBuild | Compile server |
|---|---|---|
| Method body edit | 4.1 s | 1.1-1.2 s (compile 0.23 s) |
| New field | 4.1 s | 1.6 s (compile 0.65 s) |
| A script added or removed | 5.7 s | 1.6 s (compile 0.65 s) |

**Keep the engine and editor free of compiler warnings.** Beef records a type that produced a warning as failed,
so that the warning is shown again, and recompiles it and everything depending on it on every build. Thirteen
warnings made the server regenerate EditorApp, NetworkManager and others each time (about 1.5 s); a game's own
warnings cost the same for its types.

## Inspector attributes

```beef
[ShowInInspector] private float speed = 3;
[HideInInspector] public int32 internalCounter;
[ShowInInspector, Range(0, 10)] private float volume = 1;
```

ShowInInspector exposes and saves supported non-public fields. HideInInspector hides public fields while keeping them serialized. NonSerialized excludes fields from saving/reload migration. Ordinary private fields remain hidden. The shared inspector/scene/reload field set includes float/double; signed and unsigned 8/16/32/64-bit and platform int/uint; bool; char8/16/32; String; Vector2/3/4; Int3; Quaternion; Color; Matrix4; integer-backed enums and scene/component references. Enums use reflected names when available and a numeric field otherwise. Integer storage retains its actual width, and double serialization preserves precision. Arrays, collections and arbitrary structs do not yet have general inspector drawers. The code editor highlights ShowInInspector and HideInInspector and includes them in identifier autocomplete. SerializeField and DontShowInInspector are not defined.

Adding/removing HideInInspector refreshes visibility during automatic library reload. It needs fresh compiled metadata, but does not require a manual rebuild or restart.

## Boundaries

Engine/editor/native code, project build configuration and resident dependency changes still require Full Rebuild & Restart. After installing changes to the reload engine itself, restart once to load that engine implementation; subsequent supported script edits reload in place.

This implementation targets Linux and Windows x86-64 Debug and depends on the Beef/native toolchain's reflection ABI and on being able to link new code against the running program (see below for how each system does that). Existing static fields share host storage; incompatible static layout changes require a full rebuild. Unsupported private containers, arbitrary object graphs, coroutines/tasks, native delegates and custom registration lifecycles do not have general state migration. Old modules and retired components remain allocated for the development session so outstanding old pointers do not refer to unloaded memory. References outside the supported component field set are not automatically retargeted.

Compile failures retain the previous running version. Metadata/layout validation rejects incompatible resident changes. Deleted scripts disappear from Add Component on folder refresh; existing instances of deleted types are retained until removed rather than silently discarding scene data.

Validation: the compiler integration fixture reloads six generations in one host process. It covers compile failure, method changes, added scripts, added/removed/retyped fields, ShowInInspector with Range, adding/removing HideInInspector on an existing field, field values, component references, static state, input, Play state and the same physics world.

## How the library reaches the running program

The new code has to call into the engine that is already running, and use its data, rather than bring a second copy.

**Linux.** The editor is linked with `-rdynamic`, which makes every symbol in it visible to libraries loaded later. The script library is an ordinary shared library in which everything the editor already has is left undefined, so the system's loader binds it to the editor.

**Windows.** A Windows program shares nothing with a library unless each symbol is exported, and an export table has no room for a whole engine. So Windows' own loader is not used. The debug editor is linked with `/MAP`, which writes down where everything in it is. When it starts, the editor reserves a stretch of address space just below itself and notes where (`.tallow-reload/session-*.host`). `tools/reload_scripts.py` then links the script library with Beef's own linker (`lld-link`, in `bin/llvm/bin` beside BeefBuild) at an exact address in that space, against a stand-in object that places every symbol of the editor, and of the libraries loaded before, at its real address. Every reference to the engine is resolved by the linker like any other, and the editor copies the library's sections into place itself. Libraries fill the reserved space from the top down; each is a megabyte or two, and the space is some hundreds of megabytes.

What that means in practice on Windows: