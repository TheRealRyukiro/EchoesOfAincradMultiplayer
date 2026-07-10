# ue4ss-config — game-specific UE4SS fixes

Echoes of Aincrad (UE 5.3.2 + Denuvo) is a known-difficult binary for UE4SS's
pattern scanner: even current builds fail to find some engine internals
(`GUObjectArray`, `FUObjectHashTables::Get()`, `GNatives` — tracked upstream
in [UE4SS-RE/RE-UE4SS#1283](https://github.com/UE4SS-RE/RE-UE4SS/issues/1283)).
Without them UE4SS aborts before running any mods
(`Fatal Error: PS scan timed out`).

## The two ways out

1. **Community UE4SS package (preferred — bundled).** The game's modding
   community publishes an adapted UE4SS on the game's Nexus Mods page
   (<https://www.nexusmods.com/echoesofaincrad> → search "UE4SS"); a copy is
   committed at the repo root as `UE4SS_5_3_2.zip` and the installers deploy
   it automatically whenever UE4SS is missing. To force-replace an existing
   install with it:

   ```bash
   ./tools/install.sh --zip UE4SS_5_3_2.zip
   ```

   The installer finds the payload inside the zip regardless of folder
   nesting, then re-applies our settings and the mod on top.

2. **Custom signature files.** UE4SS reads `UE4SS_Signatures/*.lua` next to
   `UE4SS-settings.ini` and uses them instead of its built-in fingerprints.
   Any real `*.lua` files placed in `ue4ss-config/UE4SS_Signatures/` in this
   repo are deployed automatically by `tools/install.sh`. The `*.lua.example`
   templates in there document the format; producing working byte patterns
   requires disassembling the game binary (x64dbg/IDA/Ghidra) — if you get
   working ones, please contribute them back via a pull request.

## Signature file format

Each file defines two functions. `Register` returns an AOB (array-of-bytes)
pattern — space-separated hex, `??` for wildcards. `OnMatchFound` receives the
address where the pattern matched and must return the final address of the
thing UE4SS wants (often by resolving a RIP-relative operand of the matched
instruction). See the UE4SS docs: "Custom Game Support" / UE4SS_Signatures.
