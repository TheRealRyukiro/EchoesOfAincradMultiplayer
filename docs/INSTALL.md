# Installing AincradTogether

Do this on **both PCs** (the host and the joiner). The automated way takes
about two minutes; the manual way is below it in case the script can't find
your game or you prefer to see every step.

## Requirements

- Echoes of Aincrad installed via Steam (demo or full game — **both PCs must
  run the same version**; demo cannot join full game or vice versa).
- Windows 10/11.
- This repository downloaded somewhere (green "Code" button → Download ZIP is
  fine; unzip it).

## Automated install

Open PowerShell (Start menu → type "powershell"), then:

```powershell
cd <where-you-unzipped-this-repo>
powershell -ExecutionPolicy Bypass -File tools\install.ps1
```

The script:

1. finds your Steam install of the game (pass
   `-GamePath "D:\...\Echoes of Aincrad"` if it can't),
2. downloads the latest [UE4SS release](https://github.com/UE4SS-RE/RE-UE4SS/releases)
   and unpacks it next to the game's real executable
   (`...\Binaries\Win64\*-Win64-Shipping.exe`),
3. copies `Mods\AincradTogether` into UE4SS's `Mods` folder and enables it,
4. turns on the UE4SS console so you can see the mod's messages.

Re-running the script later **updates the mod without overwriting your
`config.lua` settings**.

## Manual install

1. **Find the real game executable.** Steam → right-click the game → Manage →
   Browse local files. Inside, find the folder that looks like
   `<ProjectName>\Binaries\Win64\` and contains
   `<ProjectName>-Win64-Shipping.exe`. (The exe in the top folder is just a
   launcher — UE4SS must sit next to the *Shipping* exe.)
2. **Install UE4SS.** Download the latest `UE4SS_v*.zip` (not the zDEV one)
   from the [UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases)
   and extract it into that `Win64` folder. If the game is on a very new UE5
   version and UE4SS fails to start, try the latest *experimental* release
   instead — it tracks new engine versions faster.
3. **Install the mod.** Copy this repo's `Mods\AincradTogether` folder into
   the UE4SS mods folder:
   - UE4SS 3.x layout: `Win64\ue4ss\Mods\`
   - older layout: `Win64\Mods\`
   The `enabled.txt` inside the mod folder activates it. Optionally also add
   the line `AincradTogether : 1` to `Mods\mods.txt`.
4. **Enable the console.** In `UE4SS-settings.ini` (same folder as the `Mods`
   folder), set:

   ```ini
   ConsoleEnabled = 1
   GuiConsoleEnabled = 1
   GuiConsoleVisible = 1
   ```

## Verify it works

Launch the game through Steam. A separate "UE4SS" console window should appear
and, among its startup text, print:

```
[AincradTogether] AincradTogether v0.1.0 loaded.
[AincradTogether] Keys: F7=Host  F8=Join  F9=Status
```

If the window doesn't appear or the message is missing, head to
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Configure the joiner

On the PC that will **join** (not host), edit
`...\Mods\AincradTogether\Scripts\config.lua` and set:

```lua
Config.HostAddress = "the.host.ip.here"
```

Which IP to use — LAN vs internet — is explained in
[CONNECTING.md](CONNECTING.md).

## Uninstall

Delete the `AincradTogether` folder from `Mods\`. To remove UE4SS entirely,
delete the files the UE4SS zip added next to the Shipping exe (`dwmapi.dll`,
the `ue4ss` folder / `UE4SS.dll`, `UE4SS-settings.ini`, `Mods\`). Steam →
"Verify integrity of game files" restores a pristine install if in doubt.
