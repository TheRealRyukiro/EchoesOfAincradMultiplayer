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

UE4SS injected fine, but its pattern scanner can't fingerprint some of this
game's engine internals, so it gives up before running any mods. **For Echoes
of Aincrad specifically this is a known issue**
([UE4SS-RE/RE-UE4SS#1283](https://github.com/UE4SS-RE/RE-UE4SS/issues/1283)):
the game is **UE 5.3.2** with Denuvo, and its binary defeats the generic
fingerprints for `GUObjectArray`, `FUObjectHashTables::Get()` and `GNatives`
even on current UE4SS builds. Fixes, in order of preference:

1. **Make sure the engine override says 5.3** — the version cannot be read
   from the exe (DRM), so don't guess:

   ```bash
   ./tools/diagnose.sh --set-engine-version 5.3
   ```

   (Both installers also default to 5.3 for this game now.)

2. **Use the community UE4SS package adapted for this game.** The game's
   [Nexus Mods page](https://www.nexusmods.com/echoesofaincrad) hosts a
   "UE4SS" package prepared for this exact binary (free Nexus account needed
   to download). Then deploy it — the installer finds the payload no matter
   how the zip is nested, and re-applies the mod and settings on top:

   ```bash
   ./tools/install.sh --zip ~/Downloads/<that-package>.zip
   ```
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\install.ps1 -UE4SSZip "<that-package>.zip"
   ```

3. **Custom signature files** as a last resort — see
   [`ue4ss-config/README.md`](../ue4ss-config/README.md). Working signatures
   dropped into `ue4ss-config/UE4SS_Signatures/*.lua` are deployed
   automatically by the installers; please contribute them back.

Note: the installers refuse to downgrade a `ue4ss/`-layout install
(experimental or community) back to the stable release — use
`--experimental`, `--zip`, or `--skip-ue4ss` explicitly.

## Where is `UE4SS-settings.ini`, and what goes in `[EngineVersionOverride]`?

**Where:** next to the UE4SS loader itself, which depends on the UE4SS layout:

- stable v3.0.x (flat layout):
  `<game>\EchoesofAincrad\Binaries\Win64\UE4SS-settings.ini`
- experimental builds (subfolder layout):
  `<game>\EchoesofAincrad\Binaries\Win64\ue4ss\UE4SS-settings.ini`

You never have to hunt for it: `./tools/diagnose.sh` prints the exact path on
your machine (the `Settings file:` line) along with the current override
values.

**What goes in it:** the override tells UE4SS which Unreal Engine version the
game uses when its own detection fails. It's two whole numbers — major and
minor, **no patch digit** (this game's engine "5.3.2" means `3`):

```ini
[EngineVersionOverride]
MajorVersion = 5
MinorVersion = 3
```

If the section doesn't exist, add it anywhere in the file (stable 3.0.x ships
it with blank values — fill them in).

**You normally never edit this by hand.** All three tools write it for you:

| Command | What it does |
| --- | --- |
| `./tools/install.sh` / `install.ps1` | reads the version out of the game exe, writes the override during install |
| `./tools/install.sh --engine-version 5.3` (Windows: `-EngineVersion 5.3`) | forces a version you provide, for when the exe can't be read |
| `./tools/diagnose.sh --set-engine-version auto` (or an explicit `5.3`) | writes the override into an **existing** install — no reinstall, no download |

## Isn't there an injector that already supports the newest UE5?

UE4SS *is* the standard scripting injector for UE4/UE5 — there's no
alternative to switch to, and the experimental build is precisely its
"newest UE5" edition. The underlying reason no tool can "just work" forever:
a shipping game has no source code or debug symbols, so anything that scripts
the engine must locate internals by scanning for byte patterns, and Epic
rearranges those internals every engine release. New engine version →
fingerprints lag for a while → hence the experimental builds and the
`[EngineVersionOverride]` escape hatch. (Other UE "mod loaders" you may find
only load pak/asset mods — no scripting — so they can't power a mod like
this one.)

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
- Some games eat function keys; bypass them with the in-game console
  (**F10** or `~`): type `coop_host`, `coop_join <ip>`, etc. Note the
  separate UE4SS log window only *displays* output — commands are typed in
  the in-game console.
- "Cannot host: no map loaded yet" — you pressed Host while still in the main
  menu. Load into the world first.

## Host works, joiner times out ("Connection to host failed/timed out")

Network problem, not a mod problem:

- Host must already be hosting (F7) *before* the joiner presses F8 — and
  must stay running; a host that stutters out or crashes takes the join down
  with it.
- Wrong IP is the #1 cause — especially `HostAddress` still at its default
  `127.0.0.1` (= "connect to myself", which loads forever and lands on the
  main menu). Check the guest's `config.lua`, or bypass it entirely from the
  in-game console (F10): `coop_join <the-hosts-ip>`. On Tailscale, use the
  `100.x.y.z` address, not the LAN one.
- Firewall on the host: on Windows, allow the game (the *Shipping* exe)
  through Windows Firewall or open inbound **UDP 7777**; on Linux,
  `sudo ufw allow 7777/udp` if you run a firewall.
- Both PCs must run the **same game version** (and demo↔demo or full↔full,
  never mixed). Steam updates one PC before the other surprisingly often.

## I pressed Join on the same PC that's hosting (solo testing)

One game instance cannot be host and client at once — pressing F8 on the
hosting machine used to connect the game *to itself*, ending the session and
leaving an endless "connecting" load that eventually dumps you at the menu.
The mod now refuses with a message instead. What solo testing CAN verify:
host with F7, then check `coop_status` shows `HOSTING` and the map reloaded —
everything past that genuinely needs the second PC (Steam won't run two
copies of the game from one account, so there's no single-PC join test).

## The game stutters (once a second) or crashes while hosting

- Mod versions up to 0.1.2 rescanned the engine's object array on a timer —
  once per second while hosting — which hitches (and can destabilize) a big
  open world. **v0.1.3 removed all periodic scanning** (caches are fed by
  object-construction events); update by re-running the setup script, then
  confirm the banner says v0.1.3+.
- A listen server genuinely costs something beyond that: the game simulates
  networking authority it never does in single-player. To isolate a
  remaining problem, toggle these off one at a time in `config.lua`:
  `ForceReplication`, `ShowHud`, `KeepWorldRunning`, then re-test.
- Still crashing? Grab the game's own crash log from
  `compatdata/<appid>/pfx/drive_c/users/steamuser/AppData/Local/EchoesofAincrad/Saved/Logs/`
  (Linux) or `%LOCALAPPDATA%\EchoesofAincrad\Saved\Logs\` (Windows) along
  with `UE4SS.log`.

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
  itself in single-player. Press F6 (`coop_hud`) in case it was toggled off.
- Ping is measured by the engine itself (PlayerState) and replicates to both
  sides: the joiner sees their round-trip to the host; the host sees the
  joiner's. The host's own ping reading ~0 is correct, not a bug.
- The HUD is built from engine UMG widgets at runtime; on some engine
  versions that construction can fail. The mod then logs
  `On-screen HUD attempt N failed (...)`, retries a few times, and falls back
  to the UE4SS console until the next map change — `coop_ping` always works.
  If you hit this, grab the exact reason and include it when reporting:

  ```bash
  grep -m3 "HUD attempt" "<Win64>/ue4ss/UE4SS.log"
  ```
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
