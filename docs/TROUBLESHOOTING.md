# Troubleshooting

**On Linux, start here:** launch the game once, quit, then run

```bash
./tools/diagnose.sh
```

It checks the whole chain (UE4SS files → launch options → `UE4SS.log` → mod
banner) and prints a verdict telling you which link is broken. Paste its full
output when asking for help.

Otherwise work top to bottom — each section assumes the previous ones pass.
When you're stuck, the two artifacts that diagnose almost everything are the
output of `coop_status` (F9) and the file `UE4SS.log` (next to
`UE4SS-settings.ini`).

## Back up your saves

Before hosting for the first time: press `Win+R`, run `%LOCALAPPDATA%`, and
look for a folder named after the game (it contains `Saved\SaveGames`). Copy
`SaveGames` somewhere safe. Hosting reloads the map through a code path the
game never uses in single-player; nobody has reported save corruption, but a
30-second backup beats regret.

## The UE4SS console window never appears

- **Linux/Proton**: the #1 cause is a missing launch option. Steam →
  Properties → Launch Options must contain
  `WINEDLLOVERRIDES="dwmapi=n,b" %command%` (use `xinput1_3` instead of
  `dwmapi` if that's the proxy DLL your UE4SS version shipped). Without it,
  Wine loads its own built-in DLL and UE4SS never starts.
- UE4SS must sit next to `*-Win64-Shipping.exe` (in `...\Binaries\Win64\`),
  **not** next to the small launcher exe at the top of the install folder.
- Check `UE4SS-settings.ini`: `GuiConsoleEnabled = 1` and
  `GuiConsoleVisible = 1`.
- **Linux/Proton**: if the game runs but the console window crashes or never
  draws, set `GraphicsAPI = opengl` in `UE4SS-settings.ini` (the install
  script does this for you; the DX11 debug window is flaky under Wine). Even
  with no window, check `UE4SS.log` — the mod may be loading fine anyway.
- Very new game builds sometimes outpace the stable UE4SS release. Grab the
  latest **experimental** build from the
  [UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases) and
  extract it over the old one.
- If the game crashes on startup with UE4SS installed, that's an
  engine-version mismatch — again, try the experimental build, and check the
  UE4SS GitHub issues for the game's UE5 minor version.

## Console appears, but the log shows `[PS] Scan failed` / `Fatal Error: PS scan timed out`

UE4SS injected fine, but its pattern scanner can't fingerprint this game's
engine build — the stable UE4SS release is older than the game's UE5 version,
so it can't find `GUObjectArray`/`EngineVersion` and gives up before running
any mods. This is expected on brand-new games. Fix:

```bash
./tools/install.sh --experimental        # Linux
```
```powershell
powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Experimental
```

This upgrades to the UE4SS **experimental** build (its signatures track the
newest UE5 versions) and writes the game's engine version — read directly out
of the exe — into `UE4SS-settings.ini` under `[EngineVersionOverride]`, so
UE4SS no longer depends on detecting it by memory scan. Your mod settings and
`config.lua` are preserved across the upgrade (including the move to the new
`ue4ss/` folder layout).

If the experimental build *still* logs `Failed to find GUObjectArray`, the
game needs a hand-made signature file (`UE4SS_Signatures/GUObjectArray.lua`).
Check the game's Nexus Mods page / UE4SS Discord — for a popular release,
someone usually publishes one within days — and open an issue here with your
log so we can bundle it.

## A popup says "Unable to load library steamclient64.dll" (Linux/Proton)

Seen occasionally when UE4SS is loaded under Proton. It's about Steam's own
client library, not UE4SS or the mod, and if the game still starts you can
dismiss and ignore it. If the game does *not* start:

- Make sure you launch through the Steam client (Denuvo requires it), not by
  running the exe directly.
- Try a different Proton version: game Properties → Compatibility → e.g.
  Proton Experimental or the latest numbered Proton.

## Console appears, but no `[AincradTogether] ... loaded.` line

- The mod folder must be at `Mods\AincradTogether\Scripts\main.lua` (watch for
  a doubled folder like `AincradTogether\AincradTogether\...` after unzipping).
- `enabled.txt` must exist in `Mods\AincradTogether\`.
- Look for red Lua error lines mentioning `AincradTogether` in the console or
  `UE4SS.log` — a config.lua typo shows up here.

## Pressing F7/F8 does nothing

- The keybinds only fire while the game (or the UE4SS console) has focus.
- Some games eat function keys; use the console instead: `coop_host`,
  `coop_join <ip>`. If the UE console (`~`) doesn't open, type commands into
  the UE4SS GUI console window.
- "Cannot host: no map loaded yet" — you pressed Host while still in the main
  menu. Load into the world first.

## Host works, joiner times out ("Connection to host failed/timed out")

Network problem, not a mod problem:

- Host must already be hosting (F7) *before* the joiner presses F8.
- Wrong IP is the #1 cause — re-read [CONNECTING.md](CONNECTING.md). On
  Tailscale, use the `100.x.y.z` address, not the LAN one.
- Firewall on the host: on Windows, allow the game (the *Shipping* exe)
  through Windows Firewall or open inbound **UDP 7777**; on Linux,
  `sudo ufw allow 7777/udp` if you run a firewall.
- Both PCs must run the **same game version** (and demo↔demo or full↔full,
  never mixed). Steam updates one PC before the other surprisingly often.

## Joiner connects but is invisible / a floating camera

This is the "no pawn" state the spawn fixer exists for:

- Wait a few seconds — the fixer retries every 2 s.
- Host runs `coop_fixspawns`, then both check `coop_status` (F9): the REMOTE
  controller should flip from `NO BODY` to `has body`.
- If `RestartPlayer failed` appears in the host's console, the game's
  GameMode vetoes default spawning. Run `coop_status` on the host and open a
  GitHub issue with the output plus `UE4SS.log` — pinning the game's real
  pawn/GameMode class names is exactly the per-game tuning
  [ROADMAP.md](ROADMAP.md) describes.

## Joiner sees an empty world (no NPCs/enemies)

- Confirm `Config.ForceReplication = true` on the **host** and give it ~5 s.
- Host-side console line `Enabled replication on N NPC(s)` confirms the fixer
  is finding them. If it never appears, the game's NPCs may not be Pawn-based;
  report it with `coop_status` output.
- NPCs standing frozen on the joiner's screen but moving on the host's means
  their movement component doesn't replicate — known limitation, roadmap item.

## No HUD appears on screen / where's the ping display?

- The HUD only shows **while in a session** (hosting or joined) — it hides
  itself in single-player. Press F10 (`coop_hud`) in case it was toggled off.
- Ping is measured by the engine itself (PlayerState) and replicates to both
  sides: the joiner sees their round-trip to the host; the host sees the
  joiner's. The host's own ping reading ~0 is correct, not a bug.
- The HUD is built from engine UMG widgets at runtime; on some engine
  versions that construction can fail. The mod then says
  `On-screen HUD unavailable...` once and mirrors the same info to the UE4SS
  console instead — `coop_ping` always works there. If you hit this, include
  the logged error when reporting; it's fixable per-game.
- Ping showing `...` for a player means the engine hasn't measured it yet
  (a few seconds after joining) or the session isn't actually connected —
  check `coop_status`.

## Partner spawned somewhere else entirely / fell through the floor

- `Config.SpawnAtHost = true` (default) teleports them to the host right
  after their body spawns. If they still end up elsewhere, the host can run
  `coop_warp` (bring partner here) or `coop_goto` (go to partner) any time.
- Falling through the floor after a teleport usually means the offset placed
  them outside geometry — nudge `Config.WarpOffset` down (e.g. 100) and try
  again.

## Menus misbehave on the host / partner freezes when host opens a menu

- While a partner is connected, the mod cancels the game's attempts to pause
  (single-player games pause for menus; that would freeze the partner too).
  If a menu acts strangely on the host because of this, set
  `Config.KeepWorldRunning = false` — the trade-off is the partner's world
  freezing whenever the host opens a menu.

## The game gets weird while hosting (AI stuck, scripted events double-fire)

- Turn off `Config.ForceReplication` and re-test; some actors react badly to
  being made network-relevant mid-life.
- Story missions and cutscenes are the most fragile places. Host in the open
  world / town first to establish a baseline.

## Both games crash at the same point

Note what you were doing (map transition? cutscene? boss?), grab both
`UE4SS.log` files, and open an issue. Map-travel crashes on the joiner are
usually the game demanding a loading flow (`seamless travel`) the mod doesn't
drive yet.

## Reporting an issue

Include: game version (Steam → game → Properties → Updates shows the build),
demo or full, UE4SS version, `coop_status` output from both PCs if possible,
both `UE4SS.log` files, and what you pressed in what order. That turns a
"doesn't work" into a fixable bug.
