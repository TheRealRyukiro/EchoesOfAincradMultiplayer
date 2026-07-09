# Roadmap

## v0.1 — scaffold (this release)

Host/join over UE's listen-server networking, automatic pawn spawning for the
joiner, runtime replication for NPCs, diagnostics (`coop_status`), installer,
docs. Written against engine-level classes only; needs its first contact with
the retail build.

## v0.2 — tuned to the game

The first play-testing sessions will tell us the game's real class names
(`coop_status` prints them). Then:

- Pin the game's pawn/GameMode/PlayerController classes in `main.lua` instead
  of relying on generic `RestartPlayer` behavior; spawn the joiner next to the
  host instead of at a PlayerStart.
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
