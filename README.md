# AincradTogether — co-op mod for Echoes of Aincrad

Echoes of Aincrad is strictly single-player. This mod exists because the whole
point of Sword Art Online is being trapped in the death game *with someone* —
so this turns the game into a two-player (or more) co-op experience you can
play with your partner.

It works by waking up the multiplayer machinery that ships inside every
Unreal Engine 5 game: one player **hosts** their world as a listen server, the
other **joins** over the network, and Unreal's built-in character replication
does the heavy lifting. The mod is a Lua script loaded by
[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — nothing on disk is modified,
no game files are redistributed, and there is no anti-cheat in this game to
trip (Denuvo anti-tamper does not object to runtime mods like UE4SS).

> **Status: v0.1 — experimental.** The game released on 2026-07-10 and this
> scaffold has not yet been tuned against the retail build. The host/join
> plumbing is the proven technique used by co-op mods for many single-player
> UE games; the game-specific fixes will need iteration. `coop_status` and the
> UE4SS log exist precisely to make that iteration fast — see
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## What works / what doesn't (v0.1 expectations)

| Feature | Status |
| --- | --- |
| Seeing each other move around Aincrad in real time | ✅ core feature |
| Exploring towns, fields and dungeons together | ✅ |
| Second player gets a body spawned automatically | ✅ (automatic fixer + `coop_fixspawns`) |
| NPCs/enemies visible and moving for the joining player | 🟡 forced at runtime, host-authoritative |
| Combat damage/health synced between players | ❌ not yet — see [docs/ROADMAP.md](docs/ROADMAP.md) |
| Quest progress, inventory, cutscenes, menus | ❌ stay local to each player |
| Joining player keeps their own character appearance | ❌ spawns as the default character for now |

Treat v0.1 as "play tourist in each other's Aincrad": the host plays the game,
the partner is physically present in the same world. Deeper sync is the roadmap.

## Quick start

Both PCs need their own copy of the game (Steam demo or full release — but
**both must run the same version**: demo joins demo, full joins full).

> **Works on the free demo today.** The demo is the same packaged UE5 build,
> so you can install the mod and test co-op before the full game releases.

1. **Install** — on each PC, clone/download this repo and run the installer:

   Windows:

   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\install.ps1
   ```

   Linux (game runs through Proton; UE4SS injects fine under it):

   ```bash
   ./tools/install.sh
   ```

   The Linux script prints one required follow-up: a `WINEDLLOVERRIDES`
   Steam launch option so Proton loads the mod loader.

   Either script downloads UE4SS, installs it next to the game's executable,
   and copies the mod in. Manual steps in [docs/INSTALL.md](docs/INSTALL.md).
   Mixed Windows/Linux couples are fine — the network protocol is identical
   because it's the same game binary on both sides.

2. **Connect your PCs** — same Wi-Fi/LAN works out of the box. Over the
   internet, install [Tailscale](https://tailscale.com) on both PCs (free, no
   port forwarding). Details in [docs/CONNECTING.md](docs/CONNECTING.md).

3. **Play** —
   - **Host**: launch the game, load into the world, press **F7**.
   - **Joiner**: put the host's IP into
     `Mods/AincradTogether/Scripts/config.lua` (`HostAddress`), launch the
     game, press **F8**. (Or open the console and type `coop_join <ip>`.)

## Keys and commands

| Key | Console command | What it does |
| --- | --- | --- |
| F7 | `coop_host` | Re-open your current map as a co-op session (host) |
| F8 | `coop_join <ip>` | Join a host |
| F9 | `coop_status` | Print a diagnostic report to the UE4SS console |
| — | `coop_fixspawns` | Force-spawn a body for any player stuck invisible |
| — | `coop_stop` | Leave the session |

Keys are configurable in `Mods/AincradTogether/Scripts/config.lua`.

## Repository layout

```
Mods/AincradTogether/Scripts/main.lua    the mod
Mods/AincradTogether/Scripts/config.lua  user settings (IP, keys, fixer toggles)
tools/install.ps1                        one-shot installer (Windows)
tools/install.sh                         one-shot installer (Linux/Proton)
docs/                                    install, connecting, troubleshooting,
                                         how it works, roadmap
```

## Fair-play & legal notes

- Each player needs their own legitimately purchased/installed copy.
- This repo contains **no game assets or code** — only original Lua/PowerShell
  and documentation (GPL-3.0, see [LICENSE](LICENSE)).
- The game has no online mode and no anti-cheat, so there is nobody to cheat
  against; this is purely for private co-op between consenting players.
- Mods are "use at your own risk" per the usual EULA boilerplate. **Back up
  your saves** before hosting for the first time (see
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#back-up-your-saves)).

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — the injectable UE4/UE5
  scripting system that makes runtime mods like this possible.
- The lineage of single-player-to-co-op UE mods that proved the listen-server
  technique works.
