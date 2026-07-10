# Modding guide — how this mod works, and how to go further

Written for the maintainer who wants to extend AincradTogether. It explains
the full stack from the ground up, where to learn each layer, and what the
realistic ceiling is for modding this game.

## The stack, bottom to top

```
Echoes of Aincrad  (Unreal Engine 5.3.2, shipping build, Denuvo, no anti-cheat)
        ▲ loads dwmapi.dll (Windows system DLL the game imports anyway)
UE4SS   (impersonates that DLL → runs inside the game process)
        ▲ finds engine internals via byte-pattern scans / signature files
UE4SS Lua runtime  (Lua 5.4 + a bridge into Unreal's reflection system)
        ▲ Mods/*/Scripts/main.lua
AincradTogether    (this repo's Lua)
```

Two ideas carry everything:

1. **Every packaged UE game still contains the whole engine** — including
   the client/server networking that single-player games never use. Mods
   don't add netcode; they *wake up* what's shipped. `open <map>?listen`
   turns the running game into a server; `open <ip>` turns one into a client.

2. **Unreal's reflection system is the modding API.** UE keeps runtime
   metadata for every class, property, and function marked for its own use
   (Blueprints, replication, serialization). UE4SS exposes that to Lua: you
   can find any live object, read/write any reflected property, and call any
   `BlueprintCallable` function — without the game's source code. That's how
   this mod calls `RestartPlayer`, flips `bReplicates`, reads ping from
   `PlayerState`, teleports pawns, and builds UMG widgets at runtime.

## The languages

| Layer | Language | Used for |
| --- | --- | --- |
| The mod | **Lua 5.4** | all runtime logic (`Mods/AincradTogether/Scripts/`) |
| Tooling | **Bash** / **PowerShell** | installers, diagnostics (`tools/`, `release/`) |
| Next tier | **C++** | UE4SS C++ mods: hook native functions, own sockets |
| Content tier | **Blueprint** (visual) | new actors/UI authored in Unreal Editor, loaded as paks |

Learning resources:

- **Lua** — small language, a weekend to learn:
  - [Programming in Lua](https://www.lua.org/pil/contents.html) (the book, free online for 5.0; buy the 5.4 edition or use it with the manual)
  - [Lua 5.4 Reference Manual](https://www.lua.org/manual/5.4/) (the syntax truth)
  - [Learn Lua in Y Minutes](https://learnxinyminutes.com/docs/lua/) (one-page crash course)
- **UE4SS** — the bridge you're scripting against:
  - [UE4SS docs](https://docs.ue4ss.com/) — Lua API reference (every global like `FindAllOf`, `RegisterHook`, `NotifyOnNewObject` we use), C++ API, custom game support (`UE4SS_Signatures`)
  - [UE4SS GitHub](https://github.com/UE4SS-RE/RE-UE4SS) — source, issues (search your game/engine version when something breaks)
- **Unreal Engine concepts** — you're manipulating UE objects, so UE docs apply directly:
  - [Gameplay Framework](https://dev.epicgames.com/documentation/en-us/unreal-engine/gameplay-framework-in-unreal-engine) — GameMode, PlayerController, Pawn, PlayerState: the exact classes this mod touches
  - [Networking & Replication](https://dev.epicgames.com/documentation/en-us/unreal-engine/networking-overview-for-unreal-engine) — why movement syncs for free and HP doesn't
  - [UMG UI](https://dev.epicgames.com/documentation/en-us/unreal-engine/umg-ui-designer-for-unreal-engine) — what our HUD builds through reflection
- **UE modding community knowledge** (game-agnostic techniques):
  - [Dmgvol's UE Modding guides](https://github.com/Dmgvol/UE_Modding) — the community's collected handbook (pak mods, Blueprint mods, common tools)
  - The game's [Nexus Mods page](https://www.nexusmods.com/echoesofaincrad) and its community — game-specific discoveries land there first (the UE4SS build we bundle came from there)

## The capability ceiling for this game

Your Bethesda-vs-texture-swap question: UE games without official mod support
sit **upper-middle** on that spectrum, and this game is a normal member of
that class. What each tier looks like here:

1. **Asset swaps** (textures, models, sounds, text) — ✅ standard UE pak
   modding: browse assets with [FModel](https://fmodel.app/), repackage with
   repak-style tools, load via the `~mods` pak folder convention.
2. **Data edits** (DataTables: damage numbers, drop rates, prices) — ✅
   uasset editing (UAssetGUI etc.), same pak pipeline.
3. **Runtime logic** (what this mod does) — ✅ via UE4SS Lua: read/modify any
   live object, call reflected functions, spawn actors, hook Blueprint
   function calls (`RegisterHook`), build UI. This is already "change how the
   game behaves" territory, live, every frame if you want.
4. **New content** — ✅ mostly: the bundled UE4SS ships `BPModLoaderMod`,
   which loads *new Blueprint classes you author yourself* in a matching
   Unreal Editor project (UE 5.3, cooked into a pak). Custom UI screens, new
   actors with their own logic, new interactables. This is the closest thing
   to "Creation Kit" modding UE offers without developer support.
5. **Native-level changes** (new netcode, hooking C++ functions that never
   pass through reflection) — ⚠️ possible via UE4SS **C++ mods**, the
   documented next tier; this is where full combat sync lives.
6. **Hard limits** — engine-core rewrites, editing the shipped C++ logic
   itself, anything requiring the game's source. Denuvo adds one rule:
   never patch the exe on disk (everything we do is in-memory at runtime,
   which it tolerates). And there's no official editor project, so tier-4
   content is built "blind" in a lookalike UE 5.3 project.

So: you can't rebuild the game, but you can add systems, UI, content, and
behavior — a co-op mod is proof, since "multiplayer" is about as invasive as
mods get.

## Walkthrough of this mod (read alongside `Mods/AincradTogether/Scripts/main.lua`)

- **Hosting/joining** — `HostSession`/`JoinSession` execute console commands
  through `UKismetSystemLibrary:ExecuteConsoleCommand`. The map path comes
  from the live `UWorld` object's full name.
- **The spawn fixer** — single-player GameModes never spawn player 2.
  `FixMissingPawns` finds controllers without pawns and calls the engine's
  own `RestartPlayer` on the GameMode — generic, so game patches don't break
  it. Remote vs local controllers are distinguished by whether
  `Controller.Player` is a `ULocalPlayer` or a `UNetConnection`.
- **The replication fixer** — actors only replicate if `bReplicates` is set;
  we flip it (plus `SetReplicateMovement`) on pawns so the guest sees NPCs.
- **Ping** — the engine measures it per player in `APlayerState`
  (`GetPingInMilliseconds`, with `CompressedPing`/`ExactPing` fallbacks);
  we only display it.
- **The HUD/watermark** — shipping builds strip debug printing, so the HUD
  is a real UMG widget built through reflection: `WidgetBlueprintLibrary:
  Create` an empty `UserWidget`, construct a `TextBlock` with
  `StaticConstructObject`, make it the root, `AddToViewport`. FText comes
  from the Lua `FText()` constructor or, when a build lacks it, from
  `KismetTextLibrary:Conv_StringToText` — same reflection trick.
- **Performance discipline** — `FindAllOf` walks every object in the engine;
  doing that on a timer caused visible stutter. The mod is event-driven:
  `NotifyOnNewObject` feeds caches; full scans happen only at session
  start/map change/manual commands. If you add features, follow this rule.
- **Defensiveness** — everything touches the game through `pcall` +
  `IsValid()`; a game patch that renames something produces a log line, not
  a crash. Timer callbacks marshal to the game thread with
  `ExecuteInGameThread` (UObjects are not thread-safe).
- **The scaffolding** — `tools/install.*` (guided installers),
  `tools/diagnose.sh` (health checks + UE4SS.log analysis),
  `ue4ss-config/` (signature files story), `release/` (self-updating
  bootstrap scripts). The bundled `UE4SS_5_3_2.zip` exists because this
  game's binary defeats stock UE4SS's pattern scan
  ([UE4SS-RE/RE-UE4SS#1283](https://github.com/UE4SS-RE/RE-UE4SS/issues/1283));
  the community build carries a hand-made `UE4SS_Signatures/GUObjectArray.lua`.

## How to explore the game (your actual superpowers)

- **In-game console** (F10): `coop_status` shows the live class names — this
  is how we learned `BP_RODGameMode_World_C`, `BP_RODWorldHeroCharacter_C`.
- **UE4SS GUI console** → *Live View* tab: browse every live object and its
  properties in real time. This is the single best learning tool you have.
- **Object dumps**: UE4SS can dump all objects and generate headers/`.usmap`
  mappings (see the Dumpers section of its docs) — that plus **FModel**
  pointed at the game's `Paks` folder shows you every Blueprint, widget, and
  DataTable the game contains, by name.
- **Hot reload**: UE4SS reloads Lua mods with Ctrl+R in its console — edit
  `main.lua`, reload, test, without restarting the game.
- **Hooks**: `RegisterHook("/Game/.../BP_Something:SomeFunction", pre, post)`
  lets your Lua run whenever the game calls one of its own Blueprint
  functions — the key to reacting to game events (damage, pickups, dialogs).

## Suggested projects, easiest first

1. Change a keybind or the warp offset in `config.lua` (zero code).
2. Add a `coop_time` console command that prints the session clock
   (~10 lines: copy the `coop_ping` pattern).
3. Show the partner's name over their head (spawn a `TextRenderActor` and
   attach it to their pawn — teaches actor spawning + attachment).
4. Carry the guest's character appearance onto their pawn (read their save's
   customization, apply to the spawned pawn's mesh components — teaches
   game-specific reverse engineering with Live View).
5. Damage relay: `RegisterHook` the game's damage-dealing Blueprint function
   on the host, re-apply the guest's hits authoritatively — the first real
   step toward combat sync.
6. A Blueprint mod via `BPModLoaderMod` (custom party UI widget) — teaches
   the content pipeline (UE 5.3 editor project → cook → pak).
7. The C++ mod (full bidirectional combat sync) — the endgame; see the
   UE4SS C++ API docs.
