# AincradTogether v0.1.4

Co-op mod for Echoes of Aincrad — see the other player, explore Aincrad
together, engine-level netcode woken up via UE4SS.

## Install (the only two files you ever need)

Download the setup script for your OS from this release's **Assets**, then run
it. It always fetches the newest mod version by itself, checks what's already
installed (skips what isn't needed), and guides you through everything — the
UE4SS mod loader is **bundled** and installed automatically, and the script
asks the host/guest questions and configures the mod for you. No parameters,
nothing else to download:

- **Windows**: `AincradTogether-Setup.ps1` — run with
  `powershell -ExecutionPolicy Bypass -File AincradTogether-Setup.ps1`
- **Linux / Steam Deck**: `aincrad-together-setup.sh` — run with
  `bash aincrad-together-setup.sh`

Re-run the same file any time to update.

## What's new in v0.1.4

- **Zero-download UE4SS**: the game-ready community UE4SS build
  (`UE4SS_5_3_2.zip`) is bundled in the repo; when UE4SS is missing, the
  installers unpack it automatically — no Nexus detour, no flags.
- **Host checklist**: selecting HOST now ends with a live-checked list —
  which IP to give your partner (LAN vs Tailscale), whether inbound UDP 7777
  is actually allowed (reads ufw/firewalld on Linux, Windows Firewall rules
  on Windows, with a one-keystroke fix), how to confirm the server is
  listening after F7 (`ss -uln | grep 7777` / `netstat -an | findstr 7777`).
- **Guests need nothing**: both installers and the docs now state it
  explicitly — only the host opens a port; guest connections are outbound
  and allowed automatically.

## Since v0.1.3

- Fixed the once-per-second stutter (and likely crash) while hosting: no
  more timer-driven object-array scans — caches are event-fed.
- On-screen HUD works on UE4SS builds without the Lua `FText` constructor
  (builds FText via engine reflection instead).
- HUD toggle auto-remaps off F10 (the in-game console key) to F6.
- Installer overhaul: existing UE4SS kept as-is, guided flow when missing,
  one-file bootstrap setup scripts.

## Known state

- Hosting verified working on the Steam demo (Linux/Proton host).
- First full two-PC join session pending — if the guest times out, see
  `docs/TROUBLESHOOTING.md` (checklist: host IP not left at 127.0.0.1, host
  actually hosting and stable, host checklist above all green).
- Game facts: Unreal Engine 5.3.2 (custom `ROD` branch), Denuvo, no
  anti-cheat. Stock UE4SS cannot pattern-scan the binary; the bundled
  community build can.
