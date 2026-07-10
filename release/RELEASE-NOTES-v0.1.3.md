# AincradTogether v0.1.3

Co-op mod for Echoes of Aincrad — see the other player, explore Aincrad
together, engine-level netcode woken up via UE4SS.

## Install (the only two files you ever need)

Download the setup script for your OS from this release's **Assets**, then run
it. It always fetches the newest mod version by itself, checks what's already
installed (skips what isn't needed), and guides you through everything —
including host/guest setup and the UE4SS mod loader:

- **Windows**: `AincradTogether-Setup.ps1` — run with
  `powershell -ExecutionPolicy Bypass -File AincradTogether-Setup.ps1`
- **Linux / Steam Deck**: `aincrad-together-setup.sh` — run with
  `bash aincrad-together-setup.sh`

Re-run the same file any time to update to the latest version.

## What's new in v0.1.3

- **Fixed the once-per-second stutter (and likely crash) while hosting**: the
  mod no longer scans the engine's object array on a timer — caches are fed
  by object-construction events, with full scans only at session start, map
  change, and manual commands.
- **On-screen HUD works on more UE4SS builds**: when the Lua `FText`
  constructor is missing (as in the community UE4SS build for this game), the
  mod now builds FText through engine reflection instead of giving up.
- **HUD toggle auto-remaps off F10**: F10 opens the in-game console, so old
  configs binding the HUD there are remapped to F6 with a notice.
- **Installer overhaul**: no more silent downloads of the stock UE4SS (which
  cannot scan this game) — an existing UE4SS is kept as-is, and a missing one
  triggers a guided walk-through pointing at the community build.
- Replication for newly spawned NPCs is now event-driven with a 30s safety
  sweep (configurable/disable-able).

## Known state

- Hosting verified working on the Steam demo (Linux/Proton host).
- First full two-PC join session still pending — see
  `docs/TROUBLESHOOTING.md` if the guest times out (checklist: host IP not
  left at 127.0.0.1, host actually hosting, UDP 7777 reachable).
- Game facts: Unreal Engine 5.3.2 (custom `ROD` branch), Denuvo, no
  anti-cheat. Stock UE4SS cannot pattern-scan the binary; the Nexus community
  build can.
