# Troubleshooting

Work top to bottom — each section assumes the previous ones pass. When you're
stuck, the two artifacts that diagnose almost everything are the output of
`coop_status` (F9) and the file `UE4SS.log` (next to `UE4SS-settings.ini`).

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
