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

> **Status: v0.1.2 — hosting verified on the Steam demo.** The mod loads and
> F7 confirmed brings up a real listen server in-game (via the community
> UE4SS build — see the install note below). The join half awaits its first
> two-PC session. Game facts learned along the way: Unreal Engine **5.3.2**
> (custom `ROD` branch), Denuvo but no anti-cheat, and stock UE4SS cannot
> pattern-scan this binary — [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
> has the full fix ladder.

## What works / what doesn't

| Feature | Status |
| --- | --- |
| Hosting your world as a co-op session | ✅ verified in-game on the demo |
| Seeing each other move around Aincrad in real time | ✅ engine-level, needs first two-PC test |
| Second player gets a body spawned automatically | ✅ automatic fixer + `coop_fixspawns`, spawns next to the host |
| On-screen session HUD with live ping (ms) | 🟡 falls back to the UE4SS console on this game (fix in progress); `coop_ping`/`coop_status` always work |
| Teleport to each other | ✅ `coop_warp` / `coop_goto` (host runs them) |
| Host's menus don't freeze the partner's world | ✅ pause guard while a partner is connected |
| NPCs/enemies visible and moving for the joining player | 🟡 forced at runtime, host-authoritative |
| Combat damage/health synced between players | ❌ not yet — see [docs/ROADMAP.md](docs/ROADMAP.md) |
| Quest progress, inventory, cutscenes, menus | ❌ stay local to each player |
| Joining player keeps their own character appearance | ❌ spawns as the default character for now |

Treat v0.1.x as "play tourist in each other's Aincrad": the host plays the
game, the partner is physically present in the same world. Deeper sync is the
roadmap.

## Quick start

Both PCs need their own copy of the game (Steam demo or full release — but
**both must run the same version**: demo joins demo, full joins full).

> **Works on the free demo today.** The demo is the same packaged UE5 build,
> so you can install the mod and test co-op before the full game releases.

1. **Install** — grab the one setup file for your OS from the
   [Releases page](https://github.com/TheRealRyukiro/EchoesOfAincradMultiplayer/releases)
   and run it. It fetches the newest mod version by itself, keeps what's
   already installed, and guides you through everything — including the
   UE4SS mod loader (this game needs the community build from
   [Nexus Mods](https://www.nexusmods.com/echoesofaincrad); the script tells
   you exactly when and how) and the host/guest questions. Re-run the same
   file any time to update.

   Windows:

   ```powershell
   powershell -ExecutionPolicy Bypass -File AincradTogether-Setup.ps1
   ```

   Linux (game runs through Proton; the script prints the one required
   `WINEDLLOVERRIDES` Steam launch option):

   ```bash
   bash aincrad-together-setup.sh
   ```

   Working from a clone instead? `tools/install.ps1` / `tools/install.sh`
   are the same guided installer. Manual steps in
   [docs/INSTALL.md](docs/INSTALL.md). Mixed Windows/Linux couples are fine —
   the network protocol is identical because it's the same game binary on
   both sides.

2. **Connect your PCs** — same Wi-Fi/LAN works out of the box. Over the
   internet, install [Tailscale](https://tailscale.com) on both PCs (free, no
   port forwarding). Details in [docs/CONNECTING.md](docs/CONNECTING.md).

3. **Play** —
   - **Host**: launch the game, load into the world, press **F7** (the map
     reloads once — that's the server starting).
   - **Guest**: launch, load into the world, wait for the host's go, press
     **F8**. (Or open the in-game console with **F10** and type
     `coop_join <ip>`.)

## Keys and commands

| Key | Console command | What it does |
| --- | --- | --- |
| F7 | `coop_host` | Re-open your current map as a co-op session (host) |
| F8 | `coop_join <ip>` | Join a host (refuses on the machine that's hosting) |
| F9 | `coop_status` | Print a diagnostic report to the UE4SS console |
| F6 | `coop_hud` | Show/hide the on-screen HUD (players, ping, session time) |
| — | `coop_ping` | Print everyone's ping to the console |
| — | `coop_warp` | Teleport your partner to you (run on the host) |
| — | `coop_goto` | Teleport yourself to your partner (run on the host) |
| — | `coop_fixspawns` | Force-spawn a body for any player stuck invisible |
| — | `coop_stop` | Leave the session |

**F10** (or `~`) opens the in-game console — that's where the `coop_*`
commands are typed. Keys are configurable in
`Mods/AincradTogether/Scripts/config.lua`.

## Repository layout

```
Mods/AincradTogether/Scripts/main.lua    the mod
Mods/AincradTogether/Scripts/config.lua  user settings (IP, keys, fixer toggles)
tools/install.ps1                        guided installer (Windows)
tools/install.sh                         guided installer (Linux/Proton)
tools/diagnose.sh                        install health check + repair (Linux)
ue4ss-config/                            game-specific UE4SS fixes & signature
                                         templates (see its README)
docs/                                    install, connecting, troubleshooting,
                                         how it works, roadmap
```

## Fair-play & legal notes

- Each player needs their own legitimately purchased/installed copy.
- This repo contains **no game assets or code** — only original Lua, shell
  scripts, and documentation (GPL-3.0, see [LICENSE](LICENSE)).
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
