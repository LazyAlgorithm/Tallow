# Automatic script library reload

Linux and Windows x86-64 Debug editors watch project `.bf` files, including additions, removals and graph-generated scripts.

**Project Settings > Scripting > Script Reload** offers:

- **Automatic (default):** On Linux, compatible method-only changes use the existing lightweight native dispatch patcher without refreshing the component and asset catalogs. A change to declarations, fields, or script types uses structural reload. If method patch validation fails, Tallow retries the structural path without discarding the last working code. Windows currently uses structural reload for both kinds of edits.
- **Conservative:** Always use structural compilation and state migration, including method-only changes.
- **Manual:** Saving and external file changes do not activate script code. Use **File > Reload Scripts** (Ctrl+R) when ready. **Check Errors** compiles without activating. **Force Structural Script Reload** overrides Automatic or Manual without restarting the editor.

The selected mode is saved to `project.tallow` and defaults to Automatic for existing projects.
The method-only path currently reduces activation and catalog-refresh overhead, but **it still invokes
BeefBuild for a new native script library**. It is not yet a persistent incremental compiler; compiler
time and module linking remain visible in the timing log.

To validate source formatting after changes, run
`python3 tools/format/format_code.py --check Editor/src/Project/Project.bf Editor/src/Project/ProjectSettings.bf Editor/src/Scripts/ScriptReloadEditor.bf Editor/src/Scripts/ScriptEditor.bf Editor/src/App/EditorBuild.bf Editor/src/App/EditorLayout.bf`.
The repository also includes `python3 tools/test_reload_scripts.py` for Python reload-mode and cache tests.

Linux and Windows x86-64 Debug editors watch project `.bf` files, including additions, removals and graph-generated scripts. Saving in the Scripts tab also queues a reload. Editor saves update the file monitor immediately so one save does not trigger a second identical compilation when the monitor polls. Changes debounce briefly (150 ms) before the compiler builds a versioned game library on a worker thread. Generated Beef workspace configuration files are rewritten only when their content changes to preserve incremental compiler caches. Engine/editor implementations and their state remain in the host. Beef still compiles changed code and metadata; no manual full-project rebuild is required for supported game-script edits.

At a frame boundary, the editor loads the library, maps its type metadata onto stable resident identities, refreshes the component registry, replaces project component instances and restores compatible fields/references. The editor window, scene objects, physics world and Play state remain alive. The activation scene is passed explicitly, including in Edit mode. Activated symbols are recorded so newly added types work through later generations.

Supported changes include method edits, new component scripts, adding/removing/retyping supported instance fields, and inspector attributes. Same-name/type fields retain their values; newly added or retyped fields use their new initializers. Supported private runtime fields are also preserved unless marked NonSerialized. Awake/Start state is preserved and those callbacks are not repeated; OnValidate runs after restoring values. Constructors and field initializers run for replacement instances.

The project `build/script-reload.log` includes timing information for source scanning, the BeefBuild invocation,
and the full native reload build. Linux also separates object inspection, ELF object preparation, and linking.
The Linux reload worker caches ELF objects whose bytes and actually affected host definitions have
not changed, avoiding repeated symbol rewriting on ordinary method saves. Adding unrelated exported
functions to the host no longer invalidates every dependency object. Missing objects, changed object
bytes and changed relevant host definitions still trigger a fresh rewrite. The log reports all three
miss categories. The first reload in a new editor session will have a cold cache.
Source/ABI checks still run on every reload.
This helps distinguish compiler latency from Tallow's own reload overhead without guessing.

To see BeefBuild's own detailed rebuild activity, set `TALLOW_RELOAD_TRACE_COMPILER=1` in the
environment **before launching Tallow**, then save a script and inspect `build/script-reload.log`.
This enables compiler diagnostics rather than changing the build's optimization settings.

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