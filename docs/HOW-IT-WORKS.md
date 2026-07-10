# How the mod works

For the curious, and for anyone who wants to contribute.

## The big idea: the multiplayer code is already in there

Unreal Engine's client/server networking (NetDriver, actor replication,
client prediction for character movement) is part of the engine runtime, and
single-player games don't strip it out — it ships in every packaged build,
dormant. Two console commands wake it up:

- `open <map>?listen` — reload the current map as a **listen server**: the
  host's game becomes both server and player 1.
- `open <ip>:<port>` — connect as a **client**: the engine downloads nothing,
  it simply loads its local copy of whatever map the server says it's running
  and starts replicating actors.

`ACharacter` (the class virtually every UE game's player is built on) has
networked movement built in — position, rotation, velocity, and the animation
that derives from them replicate with client-side prediction, for free. That
one engine feature is why "walk around together" works in games that were
never designed for it.

UE4SS gets our Lua code into the shipping game without touching any file on
disk: it's a DLL that the game loads at startup (proxy DLL technique), which
then runs `Mods/*/Scripts/main.lua`. Denuvo anti-tamper protects the exe from
modification but doesn't interfere with this — the exe is never modified.

## What the Lua mod actually does

`main.lua` does eight things:

1. **Host** (`coop_host` / F7): reads the current world's package path (e.g.
   `/Game/Maps/L_Floor01`) from the `UWorld` object and executes
   `open <path>?listen` via `UKismetSystemLibrary::ExecuteConsoleCommand`.
2. **Join** (`coop_join` / F8): executes `open <ip>:<port>`.
3. **Spawn fixer** (host, every 2 s): the game's `GameMode` was written
   assuming exactly one player, so it typically never gives player 2 a pawn —
   they join as an invisible spectator. The fixer walks all
   `APlayerController`s, identifies remote ones (their `.Player` is a
   `UNetConnection`, a local player's is a `ULocalPlayer`), and calls the
   engine-standard `AGameModeBase::RestartPlayer()` on any that lack a pawn.
   `RestartPlayer` runs the game's own spawn logic (default pawn class,
   PlayerStart selection), so whatever the game considers "a player body" is
   what appears.
4. **Replication fixer** (host, every 5 s): actors only replicate if
   `bReplicates` is set, and a single-player game has no reason to set it on
   its NPCs — so without help, the joiner sees an empty world. The fixer calls
   `SetReplicates(true)` + `SetReplicateMovement(true)` on every `APawn` that
   doesn't have it yet. Host-authoritative: NPCs think and move on the host,
   the joiner sees mirrored transforms.
5. **Pause guard** (host, every 300 ms): single-player games pause the world
   for menus; on a listen server that freezes the partner too. While a
   partner is connected, `IsGamePaused` → `SetGamePaused(false)` vetoes it.
6. **HUD + ping** (every second): the engine already measures each player's
   round-trip time in `APlayerState` (`GetPingInMilliseconds`, with the
   replicated `CompressedPing`/`ExactPing` properties as fallbacks across
   engine versions), so ping needs no custom netcode at all. Displaying it
   is the hard part: shipping builds compile out `PrintString` and `stat`
   overlays, so the mod hand-builds the smallest possible UMG widget through
   reflection — an empty `UserWidget` whose root is one `TextBlock` — and
   rewrites its text each second. If widget construction fails on some game
   build, the HUD demotes itself to console output, deduplicated so it
   doesn't flood.
7. **Teleport helpers** (`coop_warp`, `coop_goto`, and spawn-at-host): the
   host owns the world, so `K2_TeleportTo` on any pawn is authoritative and
   replicates to the client for free.
8. **Diagnostics** (`coop_status` / F9): dumps mode, map, every controller
   (local/remote, has-pawn, pawn class), per-player ping and GameMode
   presence — the exact facts needed to debug a broken session remotely.

Everything runs through `pcall` with validity checks, because game updates
can rename or restructure classes; a failed call logs and moves on instead of
crashing the game. UObject work triggered from timers is marshalled to the
game thread with `ExecuteInGameThread` (UE objects are not thread-safe). And
because scanning the engine's object array is expensive in a big open world,
a once-per-second master tick refreshes a shared controller/PlayerState
cache that every other loop reads instead of scanning on its own.

## Why some things don't sync

Replication in Unreal is opt-in **per property and per function**. Character
movement syncs because Epic wrote that code. The game's own state — HP,
inventory, quest flags, skill cooldowns — lives in properties that were never
marked `Replicated` and functions never marked as RPCs, and those annotations
are baked at compile time. A Lua script can't add them at runtime.

Practical consequences in v0.1:

- Each player's damage only exists in their own world-view. The host's hits
  are "real" (host is the authority); the joiner is closer to a ghost who can
  sightsee but not meaningfully fight.
- UI, menus, dialogue and cutscenes are local. If the host pauses (opening a
  menu may pause a single-player game), the world freezes for both.
- Saves stay per-player. The joiner's own story progress doesn't advance.

The path past these limits is a UE4SS **C++ mod** that hooks the game's
damage/interaction functions on both sides and forwards them over its own
socket — the technique behind mature co-op mods for other games. That is the
[ROADMAP.md](ROADMAP.md) headline item.

## Contributing / porting notes

The mod deliberately references only engine classes (`PlayerController`,
`Pawn`, `GameModeBase`, `GameplayStatics`, `KismetSystemLibrary`) so it
survives game patches and would even work on other single-player UE5 games.
Game-specific tuning (pinning the real pawn class, carrying the joiner's
character appearance, blocking problem maps) belongs in clearly marked
sections of `main.lua` with class names discovered via `coop_status` and
UE4SS's UHT dumper.
