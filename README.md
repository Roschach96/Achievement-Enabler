# Achievement Enabler

A merge of the old separate "Goldberg / ColdClient semi-auto setup" and
"Uplay R2 semi-auto setup" batch toolkits into one project, built so
other emulators can be added easily in the future.

## Layout

```
_Achievement_Enabler.bat          <- the only script you run
dummy_account.txt.example         <- rename it to dummy_account.txt and fill in your "throwaway account" details
core/
  common/
    select_adapter.ps1            <- scans adapters/*/adapter.json, picks one
    download_helpers.bat          <- shared GitHub asset / GBE Fork / GSE Tools fetch
    shared_find_appid.ps1         <- Steam Store AppID lookup by folder name
    shared_parse_launch_args.ps1  <- Checks if the game needs any launch arguments to make achievemens work
    update_top_owners.py          <- Tries to create a list of profiles with newest games so achievement info can be collected
    check_update.py               <- self-update notifier (see note below)
adapters/
  steam_coldclient/               <- Steam ColdClient (Structure was created for Goldberg Steam emulator fork by Detanup01)
    adapter.json
    find_paths.ps1
    write_config.ps1
    modify_joker_json.ps1
    generate_achievement_percentages.ps1
    make_shortcut.ps1
    GameSample.json
    steamstub_x32.dll             <- Not part of the GitHub project, you provide this, search the forum
    steamstub_x64.dll             <- Not part of the GitHub project, you provide this, search the forum
    UserData_symbolic_link_for_D_tokens.ps1
  uplay_r2/                       <- Uplay R2 (Structure was created for Goldberg R2 Ubisoft emulator version by demde)
    adapter.json
    find_paths.ps1
    write_config.ps1
    patch_ini.ps1
    generate_achievements_schema_v3.ps1
    modify_joker_json.ps1
    generate_achievement_percentages.ps1
    make_shortcut.ps1
    GameSample.json
    GoldbergUplayR2-*/       <- you provide this asset pack (7 files, see below, search the forum)
  uplay_r1/                  <- Uplay R1 (Structure was created for Goldberg R2 Ubisoft emulator version by demde, same structure as Uplay R2)
    ...same file list as uplay_r2, adapted for r1 naming...
    UplayR1-*/               <- you provide this asset pack (6 files, see below, search the forum)
```

## How it works

`AchievementEnabler.bat` does everything that used to be duplicated between
the old scripts exactly once: downloads GBE Fork + GSE Tools, auto-detects
which adapter applies, runs automatic crack-state pre-flight checks, finds/
confirms the Steam AppID, fetches the SteamCMD manifest, parses launch args,
runs `generate_emu_config` to produce achievement data, exports to
Achievement Watcher and the Jokerverse Achievements app, creates the desktop
shortcut, and cleans up.

Everything that's actually different between emulators is delegated to
whichever **adapter** gets selected, through five fixed hooks called in this
order:

1. `find_paths.ps1` — locate the game's exe and the relevant loader DLL.
   Writes `_ae_vars.cmd` (`EXE_REL`, `DLL_REL`, `DLL_FOLDER_REL`,
   `ExePathRelative`, and for Steam ColdClient also `LOADER_EXE`).
2. `write_config.ps1` — write whatever config files that emulator needs:
   - **Steam ColdClient**: rebuilds `_ColdClient` from the GBE Fork template,
     copies in `steamstub_x32/64.dll`, copies in and runs
     `UserData_symbolic_link_for_D_tokens.ps1` (creates the `userdata`
     junction, then deletes itself), copies in achievement data + injects
     global unlock percentages, writes `version.txt` (GBE Fork tag) directly
     into `_ColdClient\`, patches `ColdClientLoader.ini`, and best-effort
     writes `configs.user.ini` from a local Denuvo token if one exists. The
     Denuvo lookup is wrapped in its own function so "no token found" only
     skips that step instead of ending the whole script early (it used to,
     which silently broke every step after it).
   - **Uplay R2 / Uplay R1**: validates its asset pack is complete (fails
     with a clear "redownload the emulator files" error if not), detects the
     achievement key prefix, generates `achievements_schema.json`, backs up
     and copies in the matching `upc_r*.ini`/`uplay_r*.ini` + loader DLL, and
     patches the INI.
   May write `_ae_final_exe.cmd` (`AE_FINAL_EXECUTABLE`) if the thing that
   actually launches the game isn't the game's own exe (Steam ColdClient
   points this at the ColdClient loader).
3. `modify_joker_json.ps1` — fill in the per-game JSON for the Jokerverse
   Achievements app, if it's installed.
4. `generate_achievement_percentages.ps1` — same call signature for every
   adapter: `-AppId -AchievementsJsonPath -OutputRoot`. Writes global unlock
   percentages for the Jokerverse export. (Steam ColdClient's copy also
   supports an `-InjectInPlace` switch it uses internally to bake
   percentages into its own achievements.json.)
5. `make_shortcut.ps1` — create the desktop shortcut.

The orchestrator sets a superset of `AE_*` environment variables before each
hook and never branches on which adapter is active — each script just reads
the subset of variables it needs. The one deliberate exception is
`generate_interfaces` (writes `steam_interfaces.txt`), which is gated on
`AE_ADAPTER_ID`==`steam_coldclient` directly in the orchestrator and searches
recursively under `release\` for `generate_interfaces_x64.exe` rather than
assuming a fixed subpath (GBE Fork's internal layout has moved before, and a
hardcoded path failed silently). It's run directly from `cmd`, never from
inside a PowerShell adapter script — spawning it via PowerShell
`Start-Process` is known to crash it (0xC0000409).

## Crack-state handling

There's no upfront prompt before the adapter is known. Right after an
adapter is selected, the orchestrator runs automatic checks (search excludes
`core\` and `adapters\`, so the project's own shipped template files never
cause a false positive):

- **`uplay_r2` / `uplay_r1` selected** — searches the game folder for
  `uplay_r*.ini` or `upc_r*.ini`. Found → assumed already cracked, proceeds
  silently, no prompt. Not found → stops and tells the user to apply the
  crack files first, then rerun.
- **`steam_coldclient` selected** — first searches the game folder for
  `voices38.dll`. Found → stops unconditionally and tells the user to
  reinstall the game, then rerun (a `voices38.dll` already sitting in the
  folder means the install is in a state this script can't safely work
  with). Not found → shows a prompt:
  ```
  Do you want to use the script for a Clean Steam Files game or for a voices38 release game?
    1 - Clean Steam Files
    2 - voices38 release
  ```
  Option 1 runs fully automatically. Option 2 sets `VOICES38=1`, and near
  the end of the run (after the shortcut is created) the script renames the
  loader DLL aside, pauses for the user to (re)apply the crack files, then
  removes the crack's leftover files and restores the loader DLL from
  backup.

## How adapter auto-detection works

Each `adapter.json` has a `detect` block:

```json
"detect": {
  "loader_dll_names": ["upc_r2_loader.dll", "upc_r2_loader64.dll", "uplay_r2_loader.dll", "uplay_r2_loader64.dll"],
  "is_default": false
}
```

`core/common/select_adapter.ps1` searches the **game folder** (recursively)
for any file named in `loader_dll_names`, and auto-selects the adapter that
matches. The search excludes the script's own `core\` and `adapters\`
folders wholesale — which also covers each adapter's own asset pack (e.g.
`adapters\uplay_r2\GoldbergUplayR2-*\`), since that lives *inside*
`adapters\`, not next to the script or in the game folder.

Exactly one adapter should have `"is_default": true` with an empty
`loader_dll_names` list (`steam_coldclient` today) — that's the fallback
used when no other adapter's DLLs are found anywhere in the game folder.

`assets_folder_glob` is unrelated to detection. It only tells `write_config.ps1`
where to find that adapter's ini/DLL template pack, and is resolved **inside
the adapter's own folder** (`adapters\<id>\<glob>`).

## Adding a third (or fourth) emulator

1. `mkdir adapters/<new_id>`
2. Add `adapter.json`:
   ```json
   {
     "id": "<new_id>",
     "name": "Human-readable name",
     "priority": 30,
     "detect": { "loader_dll_names": ["whatever_loader.dll"], "is_default": false },
     "assets_folder_glob": "SomeAssets-*"
   }
   ```
3. Implement the five hook scripts using the `AE_*` contract documented
   above (copy `uplay_r2` or `uplay_r1` as a starting point if the new
   emulator is ini/DLL-based like those two — it's the more reusable
   pattern; `steam_coldclient` has more one-off logic).
4. Add a `GameSample.json` template with whatever `executable` value makes
   sense for that emulator.
5. If it needs its own asset pack (ini/DLL templates), ship it inside
   `adapters/<new_id>/` and give `write_config.ps1` a failsafe check for the
   required files, matching the `uplay_r2`/`uplay_r1` pattern.
6. If the new emulator is ini/DLL-based and has its own "already cracked"
   marker files, add a check for it alongside the `uplay_r2`/`uplay_r1`
   blocks in the orchestrator's crack-state pre-flight step.

Nothing else in `AchievementEnabler.bat` needs to change.
