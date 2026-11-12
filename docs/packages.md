# Asset packages

A package is a set of assets in one `.tpackage` file, to be put into another project: models, textures, materials,
prefabs, scenes, sounds, UI, behaviour trees, and the scripts that go with them. It is Tallow's version of a Unity
package.

## Exporting

Right-click an asset or folder in the Project window and pick **Export Package...** (or File > Export Package... for
the selected one).

- **Include dependencies** adds what the picked assets need: what they name (a prefab's model and material, the
  material's textures, a scene's prefabs and sequences...), followed as far as it goes, and the scripts of the
  components their scenes and prefabs use. Each line says why a file is there. Untick anything to leave it out.
- A graph brings its generated script, and a shader graph its generated shader.
- Name, version, author and description go into the package. It is written to `Packages/Exports/<Name>-<version>.tpackage`
  unless you change the file.

Each asset goes with its `.tmeta`, so it keeps its ID (`docs/asset-ids.md`) in every project it goes into. Its
`.import` (model import settings) and `.bonemap` go too.

## Importing

Drop a `.tpackage` on the editor, use File > Import Package..., or pick one in the Package Manager. The Import Package
window lists every file and what will happen to it:

| | |
| --- | --- |
| **New** | Not in the project: added. |
| **Changed** | The project has it (the same ID), different: replaced with the package's, where it is now. |
| **Same** | Already as in the package: left alone. |
| **Conflict** | Its name is taken by something else. An asset goes beside it under a free name (`crate 1.glb`); a script only replaces the project's if you tick it. |

- **Into folder** puts the package's new files under a folder of yours (`ThirdParty/Forest`). Paths inside the
  package's own files (a prefab naming its model) are changed to where those files went.
- Assets the project already has are found by ID wherever they are now, even if they were moved or renamed after an
  earlier import, and updated in place. Importing a newer version of a package is an update.
- Scripts are known by their file name: a script the project already has, the same, is left alone rather than added
  a second time.
- Imported scripts are compiled straight away; their components can then be used like the project's own.

## The Package Manager

Window > Package Manager.

- **In this project**: the packages imported, with their version and how many of their files were changed since.
  **Remove** deletes a package's files that are as they were imported (files you changed are kept and listed in the
  Console), and folders left empty. **Import Again** opens the package file it came from.
- **Package files**: `.tpackage` files in the project's `Packages` folder and your `Downloads` folder, or any path.
- **Catalogs**: addresses of package catalogs, one per line (kept in `Packages/sources.txt`, so a team shares them).
  A project starts with the Tallow website's catalog, `https://tallowengine.com/packages/catalog.txt`: the community
  packages at https://tallowengine.com/packages/, each checked by a moderator. **Add the Tallow website's packages**
  puts it back if it was taken out; **Browse Packages Online** opens the site.
  **Fetch Catalogs** lists their packages; **Download and Import...** downloads one into `Packages/Downloads` and
  opens it, or **Update...** when the project has an older version.

## Catalogs

A catalog is a text file on a web server (or a shared drive):

```
tallowcatalog 1
package "Forest Props" version "1.2.0" url "Forest_Props-1.2.0.tpackage" sha256 "77cf915e..." author "Me" description "Trees, rocks and logs"
package "Forest Props" version "1.1.0" url "https://example.com/old/Forest_Props-1.1.0.tpackage"
```

- `url` is an `https://` or `http://` address, a file path, or a name relative to the catalog itself.
- When `sha256` is given, the download must match it or it is deleted and not opened.
- When a package is listed more than once, the newest version is shown.

## In the project

| | |
| --- | --- |
| `Packages/packages.txt` | What each imported package put in (path and checksum of each file). Commit it. |
| `Packages/sources.txt` | Catalog addresses. Commit it. |
| `Packages/Exports/`, `Packages/Downloads/` | Packages made and downloaded here. Left out of git by new projects' `.gitignore`. |

## The file

A `.tpackage` is a pack file (the format of a built game's `game.tpak`, `native/tallow_pack.c`). It holds
`package.txt`:

```
tallowpackage 1
name "Forest Props"
version "1.2.0"
author "Me"
description "Trees, rocks and logs"
engine "v0.2.5-beta"
file "Models/tree.glb" id 3f2a9c51e07b4d6a8e1f20c4b9d73a55 crc 2829648212 size 48120
file "Models/tree.glb.tmeta" crc 621421125 size 36
file "Scripts/Sway.bf" crc 3436966438 size 912
```

and every file under `assets/<its path>`. Paths that would leave the Assets folder are refused when it is read.

## Licences

A package carries whatever is put in it. Do not export assets you have no right to give away (bought asset packs
usually allow use in your games but not passing the files on).

## Tests and switches

- `--packages-test`: export with dependencies, import into another folder, update after a move, remove, catalogs;
  logs `PACKAGES-TEST PASS` or what failed.
- `--export-package <asset or folder>` opens Export Package; with `--export-package-to <file>` it exports at once.
- `--import-package <file>` opens Import Package; `--import-into <folder>`, and `--import-package-now` to import at once.
- `--package-manager [files|catalogs]` opens the Package Manager on that page.
- `--package-download <catalog>` fetches a catalog and downloads its first package (with `--import-package-now`, imports it).
