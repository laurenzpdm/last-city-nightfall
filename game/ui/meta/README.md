# [P24] meta — save/load, settings, accessibility, Steam

The layer around the game: the first screen a player sees, the menu they press
Escape for, the file their city lives in, and the switches that make the build
usable by someone who does not see the way the art director does.

Everything here installs itself from `game/content/meta/meta_bootstrap.tres`
(scanned by `Registry`), sits on canvas layer 80 (`LcnLayers.MODAL`), and is
absent from a headless run.

## The files

| file | what it is |
|---|---|
| `save_file.gd` | the on-disk format: seekable header, thumbnail, binary world payload, sha256 |
| `save_manager.gd` | slots, headers, thumbnails, and the ORDER a load must happen in |
| `autosave.gd` | one save at dawn, three files rotating |
| `meta_root.gd` | the modal stack, the input path, pause/resume, quick save/load |
| `meta_screen.gd` / `meta_list.gd` / `meta_style.gd` | the screen base, the one widget, the look |
| `main_menu.gd` `pause_menu.gd` `settings_index.gd` `display_settings.gd` `audio_settings.gd` `controls_settings.gd` `access_settings.gd` `save_browser.gd` `confirm_dialog.gd` | the screens |
| `steam_seam.gd` | the Steamworks seam — no binary dependency |
| `export_build.gd` | produces the Linux and Windows builds and refuses to certify an empty one |
| `restart_probe.tscn` | a cold second process that prints what the config file says |

## Three things worth knowing before changing anything here

**The world payload is binary, not JSON.** `Rng.snapshot()` reports each stream
as a full 64-bit integer and JSON numbers are doubles, so the JSON version wrote
`-4710635756903808991` and read back `-4710635756903809024`. The city reloaded
looking perfect and rolled a different night. `tests/meta/test_save_roundtrip.gd`
fails within a second if anyone puts JSON back.

**The load order is not arbitrary.** `create_world()` → set `SimClock.tick` →
systems deserialize in sorted name order → `Rng.restore()`. Several systems stamp
the current tick into what they rebuild, and `create_world` reseeds every stream,
so any other order loses something quietly.

**A rebind asks `LcnLayers.key_is_reserved()`, not the InputMap.** The router
takes 1/2/3 and 4/5/6 before any panel sees them, and the InputMap does not know
that. Captured events are also normalised to their physical keycode: a real
keypress carries both a physical and a virtual code, the defaults carry only the
physical one, and `Keybinds.conflicts()` compares the whole event — so without
normalisation "already bound" never fired for any key a player actually pressed.

## Accessibility

`Settings.accessibility` is read by [P17]'s HUD, [P19]'s lenses, [P15]'s timing
and these menus. The tokens this screen writes are the SHORT forms —
`off / protan / deutan / tritan / mono` — because they are the ones every
consumer understands: [P19] also accepts `protanopia` and friends, but [P17]
matches `tritan` exactly, so writing the long name would silently give a tritan
player the red-green remap instead of theirs.

`tests/meta/test_settings_reach_the_game.gd` asserts that for every token, and
reads the consumer rather than the setting.

Known gap, not ours to fix: `LcnHudStyle._cb()` has no `mono` branch, so a
monochrome player gets the red-green remap in the HUD while the lenses correctly
go to pure luminance. One `if` in `game/ui/hud/hud_style.gd` — [P17]'s.

## Steam: the path from here to a store page

There is **no Steamworks binary in this repository, deliberately.** A
GDExtension would be loaded by every one of the ~40 headless Godot invocations
in `tools/check.sh`, each printing a load error when `steam_api` is not present,
and the gate counts engine errors. It lands when someone can attach a real app
id. Until then `steam_seam.gd` is the shape it lands in, and it is the only file
in the build that will ever mention Steam.

1. **Build.** `godot --headless --path . --script game/ui/meta/export_build.gd -- --all`
   writes `dist/linux/` and `dist/windows/`, then runs the Linux binary and
   refuses to call it a build if it loads zero content items.
2. **App id.** Set `LcnSteamSeam.APP_ID` (480 is Valve's public test id). Add
   `steam_appid.txt` next to the binary for LOCAL testing only — shipping it
   lets the client trust whatever app id the file says.
3. **Extension.** Drop `godotsteam` under `addons/` with its per-platform
   binaries. `LcnSteamSeam.available()` starts returning true on its own.
4. **Fill the four calls.** `init_if_present` → `Steam.steamInit`; `unlock` →
   `setAchievement` + `storeStats`; add `Steam.runCallbacks()` from `_process`
   on one node. Nothing else in the build calls Steam, so this is the whole
   integration.
5. **Achievements.** `LcnSteamSeam.ACHIEVEMENTS` is the list to enter on the
   partner page; each row names the fact the build already measures, and
   `tests/meta/test_steam_seam.gd` checks that system exists.
6. **Cloud.** Point Steam auto-cloud at `LcnSteamSeam.save_directory_for_cloud()`
   — the folder saves are already written to. No code changes.

### Still needed for a store page, and not [P24]'s to do

* `project.godot` is integrator-owned. `config/version` is `0.1.0` and
  `config/icon` is the stock `icon.svg`; both want a real value and a real icon
  before a store page.
* A Windows `.ico` and the version block need `rcedit`, which is a separate
  download; the preset leaves `application/modify_resources=false` so the export
  succeeds without it and produces an .exe wearing the engine's icon.
* macOS is not in the preset file: it needs signing and notarisation
  credentials, which are not a build-agent decision.
