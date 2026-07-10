# Roadmap

## v0.1.x — scaffold + field-testing (current)

Host/join over UE's listen-server networking, automatic pawn spawning for the
joiner, runtime replication for NPCs, diagnostics (`coop_status`), installer
(Windows + Linux/Proton), docs. Written against engine-level classes only;
needs its first contact with the retail build.

v0.1.1 quality-of-life additions: on-screen HUD with live ping/session timer
(UMG-built, console fallback), `coop_ping`, teleport helpers
(`coop_warp`/`coop_goto`), spawn-at-host, pause guard so the host's menus
don't freeze the partner, and a map-change watcher with recovery hints.

v0.1.2 field-test fixes (hosting confirmed working on the Steam demo):
self-join guard, join announcements verified against real network
connections, and a shared once-per-second object cache replacing the
per-loop scans that caused hosting lag.

v0.1.3: fully event-driven caches (no periodic object scans at all — fixes
the once-per-second hosting stutter), FText via reflection so the HUD can
work on the community UE4SS build, F10→F6 HUD keybind auto-remap, installer
overhaul (guided UE4SS handling, no stock downloads), and one-file setup
scripts for GitHub Releases.

## v0.2 — tuned to the game

Field testing already revealed the game's real classes: GameMode
`BP_RODGameMode_World_C`, player pawn `BP_RODWorldHeroCharacter_C`,
controller `BP_RODWorldPlayerController_C`, engine branch
`5.3.2-0+++ROD-App-ONE`. Next:

- Pin those classes in `main.lua` instead of relying on generic
  `RestartPlayer` behavior.
- Fix the on-screen HUD on this game (currently console fallback).
- Carry the joiner's character-creator appearance onto their spawned pawn
  (read their save's customization data, apply to the pawn's mesh components).
- Handle map travel: when the host changes floors, bring the joiner along
  cleanly (hook the travel, re-issue `open` on the client if needed).
- Blocklist maps/sequences that break under a listen server (some cutscenes
  will), with a friendly console message instead of a crash.
- Nameplates over each player's head.

## v0.3 — combat presence

- Replicate NPC animation state, not just movement, where possible
  (`SetReplicates` on mesh components / forcing dormancy flushes).
- Host-relayed damage: hook the game's damage-dealing function with UE4SS,
  apply the joiner's hits on the host's authoritative world so both players
  can actually fight the same monster.
- Basic health mirroring for the two players.

## v1.0 — the real thing (C++ mod)

Lua + reflection tops out below full co-op. A UE4SS C++ mod can hook arbitrary
native functions and run its own socket, which unlocks:

- Proper bidirectional combat sync (damage, deaths, aggro).
- Shared loot/interaction events (doors, chests, NPC dialogue triggers).
- Session browser/invite flow instead of raw IPs (Steam relay via SteamNetworkingSockets, so no VPN needed).
- Party UI.

## Non-goals

- More than ~4 players. This is a couch-scale co-op mod, not an MMO revival.
- Anything that touches other people's game sessions — the game has none.
- Redistributing game content of any kind.
