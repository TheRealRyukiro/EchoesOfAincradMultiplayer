# Next Session Plan — AincradTogether (Echoes of Aincrad co-op mod)

## Context

This repo (`TheRealRyukiro/EchoesOfAincradMultiplayer`) is a co-op mod for
Echoes of Aincrad (UE 5.3.2, single-player, Denuvo, no anti-cheat) so Tommy
(Linux/CachyOS, Proton) can play with his girlfriend (Windows 11). The mod is
UE4SS Lua that turns the game into a listen server (host F7 / guest F8), with
spawn/replication fixers, ping HUD + version watermark, teleports, guided
installers, and one-file self-updating setup scripts.

**Where we are:** mod v0.1.5 on `main` @ `1f1bf1e`. Hosting is FIELD-VERIFIED
on the demo (Linux host). The first successful two-PC join has NOT happened
yet — her F8 previously timed out to the main menu (suspected `127.0.0.1`
default IP + host instability, both since addressed but unverified). The
v0.1.5 changes (stutter fix via event-driven caches, FText-reflection HUD,
watermark) are written but **untested in-game**.

**Goal of next session:** triage Tommy's test results, achieve the first
successful two-PC join, then scope v0.2 from what actually replicates.

## Step 0 — persist this plan

This container is ephemeral. First action after approval: copy this plan into
the repo as `docs/NEXT-SESSION.md`, commit to `main`, push (attribution rules
below). That makes it readable by any future session regardless of context.

## Step 1 — collect state from Tommy (session start checklist)

Ask for whichever of these he has; each unblocks a different work item:

1. **GitHub housekeeping done?** Has the `v0.1.5` release been drafted
   (body: `release/RELEASE-NOTES.md`; assets: the two `release/*` setup
   scripts)? OWNER DECISION (final): the leftover `v0.1.3` tag and the
   `claude/aincrad-multiplayer-mod-zpwoxt` branch STAY — do not delete or
   re-suggest deleting anything on GitHub for Claude-artifact reasons. Never
   reuse tag name `v0.1.3` (it pins pre-rewrite history); new releases start
   at `v0.1.5`. Commit rule for this repo: NO Claude attribution
   (no Co-Authored-By/Claude-Session trailers); commit as
   `Tommy <tomdunbar2000@gmail.com>`; the README disclaimer covers AI
   assistance.
2. **Host-side v0.1.5 test results:** does the once-per-second stutter
   persist? Any crash? Does the corner watermark render (proves the
   FText-reflection HUD path works on the community UE4SS build)? Artifacts:
   `ue4ss/UE4SS.log`, `coop_status` (F9) output, and if no watermark:
   `grep -iE "HUD (attempt|unavailable)" .../ue4ss/UE4SS.log`.
3. **Two-PC join attempt (same LAN):** she runs `coop_join <his-192.168.x>`
   from the in-game console (F10) while he hosts. Artifacts: BOTH UE4SS.logs,
   his `ss -uln | grep 7777` output while hosting, `coop_status` from both
   sides after the attempt.
4. **Her installer experience:** she should re-run the setup on Windows —
   first live run of the PS1 wizard + bundled-UE4SS path. Any errors verbatim.

## Step 2 — triage matrix (work items keyed to his answers)

| Result | Action |
| --- | --- |
| Stutter persists on v0.1.5 | Profile further: toggle `ForceReplication`/`ShowHud`/`KeepWorldRunning` one at a time; if it's none of ours, it's listen-server cost — investigate `net.MaxTickRate`-style console tweaks |
| Crash persists | Get game crash log from `compatdata/4148250/pfx/.../EchoesofAincrad/Saved/Logs/` + UE4SS.log tail; likely suspects: SetReplicates on protected actors (try `ForceReplication=false`), pause guard |
| No watermark, log shows HUD attempts failing | Read the exact error; likely fix inside `TryCreateHud()` in `Mods/AincradTogether/Scripts/main.lua` (e.g. widget class or WidgetTree differences on this build) |
| Join times out with correct IP + host listening | Verify her traffic arrives: `sudo tcpdump -ni any udp port 7777` on host during her F8; if packets arrive but no connection, investigate the game's NetDriver config (may need `-log` or engine ini overrides in the Proton prefix) |
| Join succeeds but she's invisible/no body | Spawn fixer logs on host (`RestartPlayer` failures) → pin `BP_RODGameMode_World_C` specifics; use `coop_fixspawns`, `coop_warp` |
| Join succeeds fully | Jump to Step 3 |

## Step 3 — first-join success protocol (what to catalog while they play)

Have them spend 15 minutes together and note: does she see him move
(replication baseline)? Does she see NPCs move? Animations or gliding?
What happens on his map travel? Combat visuals from each side? Save
integrity after `coop_stop`? Each answer feeds the v0.2 backlog already in
`docs/ROADMAP.md`: pin ROD classes in `main.lua`, spawn-at-host placement,
appearance carryover, map-travel handling, then the damage-relay hook
(`RegisterHook` on the game's damage BP function) as the first combat-sync
step.

## Step 4 — opportunistic items (only if time / relevant)

- Nameplates over heads (TextRenderActor attach) — teaches actor spawning,
  from `docs/MODDING-GUIDE.md` project list.
- `diagnose.ps1` for Windows-side self-service debugging (she has no
  equivalent of `tools/diagnose.sh`).
- Auto-reconnect option for the guest after connection drops.

## Key facts for a cold-start session

- Repo layout: mod at `Mods/AincradTogether/Scripts/{main,config}.lua`
  (v0.1.5, `MOD_VERSION` in main.lua is the version source of truth);
  installers `tools/install.{sh,ps1}` (guided, no params needed); health
  check `tools/diagnose.sh`; one-file bootstraps in `release/`; bundled
  loader `UE4SS_5_3_2.zip` at repo root (community build — stock UE4SS
  CANNOT scan this game, see UE4SS-RE/RE-UE4SS#1283).
- Game: UE `5.3.2-0+++ROD-App-ONE`, demo Steam appid `4148250`; classes:
  `BP_RODGameMode_World_C`, `BP_RODWorldHeroCharacter_C`,
  `BP_RODWorldPlayerController_C`; Town-of-Beginnings map
  `/Game/ROD/Maps/Main/WL01/TOB/PL_TOB`; menu map `PL_ROD`.
- His install: `~/.local/share/Steam/steamapps/common/Echoes of Aincrad
  Demo/EchoesofAincrad/Binaries/Win64/` (+ `ue4ss/` layout), launch option
  `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- Keys: F7 host, F8 join, F9 status, F6 HUD toggle, F10 = in-game console
  (where `coop_*` commands are typed).
- Git: work merges to `main`; NO Claude attribution in commits (explicit
  owner request — README disclaimer covers AI assistance); tag/ref deletion
  is blocked by the session git gateway (pushes are fine).

## Verification

- Step 0: `docs/NEXT-SESSION.md` visible on GitHub main.
- Steps 1–3 verify themselves: each is driven by real logs from both PCs and
  ends with an in-game observation (watermark visible, join succeeded,
  feature X replicates), re-checked via `tools/diagnose.sh` and `coop_status`.
- Any mod edit: `luac5.4 -p` syntax check + Ctrl+R hot-reload test
  instructions to Tommy; any installer edit: `bash -n` + fake-game-tree run
  (pattern used throughout: create `.../Binaries/Win64/Fake-Win64-Shipping.exe`
  in scratch, run installer with `--game-path`).
