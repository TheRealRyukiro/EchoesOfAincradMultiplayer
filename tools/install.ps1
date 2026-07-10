# ============================================================================
# AincradTogether installer
#
# Installs UE4SS + the AincradTogether mod into an Echoes of Aincrad install.
# Run this in PowerShell on EACH PC that will play (host and joiner):
#
#   powershell -ExecutionPolicy Bypass -File tools\install.ps1
#
# If the script cannot find your game automatically, point it at the folder:
#
#   powershell -ExecutionPolicy Bypass -File tools\install.ps1 -GamePath "D:\SteamLibrary\steamapps\common\Echoes of Aincrad"
#
# Already have UE4SS installed, or want to install it by hand? Use -SkipUE4SS.
# ============================================================================

param(
    # Game root folder OR any folder inside it. Auto-detected from Steam if omitted.
    [string]$GamePath,
    # Path to a locally downloaded UE4SS release zip (skips the download).
    [string]$UE4SSZip,
    # Don't touch UE4SS at all; only install/update the mod files.
    [switch]$SkipUE4SS,
    # Use the UE4SS experimental (pre-release) build. Needed while the game's
    # UE5 version is newer than what the stable UE4SS release supports
    # (symptom: UE4SS.log full of "[PS] Scan failed" / "PS scan timed out").
    [switch]$Experimental,
    # Force the game's Unreal Engine version (e.g. "5.3") instead of reading
    # it from the exe. Written to UE4SS-settings.ini [EngineVersionOverride].
    # Echoes of Aincrad is UE 5.3 (per UE4SS-RE/RE-UE4SS issue #1283).
    [string]$EngineVersion,
    # This PC's role in co-op: 'Host' (the world runs here) or 'Guest'
    # (joins the host). If omitted, the script asks interactively.
    [string]$Role,
    # For guests: the host's IP address (LAN 192.168.x.x or Tailscale
    # 100.x.y.z). Written into the mod's config.lua. If omitted and the role
    # is Guest, the script asks interactively.
    [string]$HostIP,
    # Skip all interactive questions (for unattended runs).
    [switch]$NoPrompt
)

if ($EngineVersion -and $EngineVersion -notmatch '^5\.\d+$') {
    throw "-EngineVersion must look like '5.3' (major.minor, no patch digit)"
}

if ($Role -and $Role -notmatch '^(?i)(host|guest)$') {
    throw "-Role must be 'Host' or 'Guest'"
}
if ($HostIP -and $HostIP -notmatch '^[A-Za-z0-9\.\:\-]+$') {
    throw "-HostIP doesn't look like an IP address or hostname: $HostIP"
}

# Known version for Echoes of Aincrad, used when nothing better is available.
$KnownGameEngineVersion = '5.3'

# ----------------------------------------------------------------------------
# 0. Setup questions (asked up front so the rest runs unattended)
# ----------------------------------------------------------------------------
if (-not $NoPrompt -and -not $Role) {
    Write-Host ""
    Write-Host "Who is this PC in your co-op session?" -ForegroundColor Cyan
    Write-Host "  [1] HOST  - the world you'll both play in runs on this PC"
    Write-Host "  [2] GUEST - this PC joins the host's world"
    do { $answer = Read-Host "Enter 1 or 2" } until ($answer -match '^[12]$')
    $Role = if ($answer -eq '1') { 'Host' } else { 'Guest' }
}

if (-not $NoPrompt -and $Role -match '^(?i)guest$' -and -not $HostIP) {
    Write-Host ""
    Write-Host "The GUEST needs the HOST's IP address. How the host finds it, on THEIR pc:" -ForegroundColor Cyan
    Write-Host "  - Same house / same Wi-Fi (host on Windows): press Win+R, type 'cmd',"
    Write-Host "    press Enter, then run:  ipconfig"
    Write-Host "    -> use the 'IPv4 Address' line (usually starts with 192.168.)"
    Write-Host "  - Different houses via Tailscale: open the Tailscale app / tray icon"
    Write-Host "    -> use the IP that starts with 100."
    Write-Host "  - Host on Linux: run  hostname -I  in a terminal (first address)"
    Write-Host "  (Leave empty to set it later - re-run this installer or edit config.lua.)"
    $HostIP = (Read-Host "Host IP address").Trim()
    if ($HostIP -and $HostIP -notmatch '^[A-Za-z0-9\.\:\-]+$') {
        Write-Host "    That doesn't look like an IP; skipping. Re-run the installer to try again." -ForegroundColor Yellow
        $HostIP = $null
    }
}

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModSource = Join-Path $RepoRoot 'Mods\AincradTogether'
$ModName = 'AincradTogether'

function Write-Step($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

if (-not (Test-Path $ModSource)) {
    throw "Cannot find mod files at '$ModSource'. Run this script from a full clone of the repository."
}

# ----------------------------------------------------------------------------
# 1. Locate the game
# ----------------------------------------------------------------------------
Write-Step "Locating Echoes of Aincrad..."

function Get-SteamLibraryFolders {
    $folders = @()
    $steamPath = $null
    try {
        $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch { }
    if ($steamPath) {
        $steamPath = $steamPath -replace '/', '\'
        $folders += (Join-Path $steamPath 'steamapps')
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            # Every "path" entry in libraryfolders.vdf is another library.
            foreach ($line in Get-Content $vdf) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $lib = $Matches[1] -replace '\\\\', '\'
                    $folders += (Join-Path $lib 'steamapps')
                }
            }
        }
    }
    return $folders | Select-Object -Unique | Where-Object { Test-Path $_ }
}

$gameRoot = $null
if ($GamePath) {
    if (-not (Test-Path $GamePath)) { throw "The path you passed does not exist: $GamePath" }
    $gameRoot = $GamePath
} else {
    foreach ($steamapps in Get-SteamLibraryFolders) {
        $common = Join-Path $steamapps 'common'
        if (-not (Test-Path $common)) { continue }
        $candidate = Get-ChildItem -Path $common -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Aincrad*' } | Select-Object -First 1
        if ($candidate) { $gameRoot = $candidate.FullName; break }
    }
    if (-not $gameRoot) {
        throw @"
Could not auto-detect the game in your Steam libraries.
Find it yourself: Steam -> right-click Echoes of Aincrad -> Manage -> Browse local files.
Then re-run with:  -GamePath "<that folder>"
"@
    }
}
Write-Ok "Game folder: $gameRoot"

# The mod goes next to the *shipping* executable: <Project>\Binaries\Win64\
$shippingExe = Get-ChildItem -Path $gameRoot -Recurse -Filter '*-Win64-Shipping.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $shippingExe) {
    throw "No *-Win64-Shipping.exe found under '$gameRoot'. Is this really the game folder?"
}
$win64Dir = $shippingExe.DirectoryName
Write-Ok "Game executable: $($shippingExe.Name)"
Write-Ok "Install target:  $win64Dir"

# ----------------------------------------------------------------------------
# 1b. Detect the game's Unreal Engine version from the executable
#     (version string is embedded in the binary; scan it in chunks)
# ----------------------------------------------------------------------------
function Get-EngineVersion($exePath) {
    $patterns = @(
        '\+\+UE5\+Release-(5\.\d{1,2})',
        '(5\.\d{1,2})\.\d{1,2}-\d{6,12}\+\+\+'
    )
    $found = @{}
    $stream = [IO.File]::OpenRead($exePath)
    try {
        $chunkSize = 32MB
        $overlap = 128
        $buffer = New-Object byte[] $chunkSize
        $tail = [byte[]]@()
        while (($read = $stream.Read($buffer, 0, $chunkSize)) -gt 0) {
            $bytes = if ($read -eq $chunkSize) { $buffer } else { $buffer[0..($read - 1)] }
            $data = [byte[]]($tail + $bytes)
            foreach ($enc in @([Text.Encoding]::ASCII, [Text.Encoding]::Unicode)) {
                $text = $enc.GetString($data)
                foreach ($pat in $patterns) {
                    foreach ($m in [regex]::Matches($text, $pat)) {
                        $found[$m.Groups[1].Value] = $true
                    }
                }
            }
            if ($data.Length -gt $overlap) {
                $tail = $data[($data.Length - $overlap)..($data.Length - 1)]
            }
        }
    } finally { $stream.Close() }
    return ($found.Keys | Sort-Object { [double]$_ } | Select-Object -Last 1)
}

if ($EngineVersion) {
    Write-Step "Using engine version from -EngineVersion: UE $EngineVersion"
} else {
    Write-Step "Reading the game's Unreal Engine version from the exe..."
    try { $EngineVersion = Get-EngineVersion $shippingExe.FullName } catch { }
    if ($EngineVersion) {
        Write-Ok "Detected Unreal Engine $EngineVersion"
    } else {
        Write-Warn2 "Could not read a UE version string from the exe (DRM hides it in this game)."
        $EngineVersion = $KnownGameEngineVersion
        Write-Ok "Falling back to the known version for this game: UE $EngineVersion"
        Write-Ok "(documented in UE4SS-RE/RE-UE4SS issue #1283; override with -EngineVersion)"
    }
}

# ----------------------------------------------------------------------------
# 2. Install UE4SS
# ----------------------------------------------------------------------------
# Never silently downgrade: if a ue4ss\-layout install (experimental or a
# community package) is already present, a plain run would stomp it with the
# older stable release.
if (-not $SkipUE4SS -and -not $Experimental -and -not $UE4SSZip -and (Test-Path (Join-Path $win64Dir 'ue4ss'))) {
    throw @"
A ue4ss\-layout UE4SS (experimental or community build) is already installed.
Refusing to replace it with the older stable release. Pick one:
  -Experimental     update to the latest experimental build
  -UE4SSZip <file>  install a specific package (e.g. the game's Nexus UE4SS)
  -SkipUE4SS        keep the current UE4SS; only update the mod and settings
"@
}

if (-not $SkipUE4SS) {
    Write-Step "Installing UE4SS (the mod loader)..."
    $zipToExtract = $null

    if ($UE4SSZip) {
        if (-not (Test-Path $UE4SSZip)) { throw "UE4SS zip not found: $UE4SSZip" }
        $zipToExtract = $UE4SSZip
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'AincradTogether-installer' }
        $asset = $null
        if ($Experimental) {
            Write-Ok "Downloading the UE4SS EXPERIMENTAL build from GitHub (newest engine support)..."
            $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases?per_page=30' -Headers $headers
            foreach ($rel in (@($releases | Where-Object { $_.prerelease }) + @($releases))) {
                $asset = $rel.assets |
                    Where-Object { $_.name -match '^UE4SS.*\.zip$' -and $_.name -notmatch 'DEV|Dev' } |
                    Select-Object -First 1
                if ($asset) { break }
            }
        } else {
            Write-Ok "Downloading the latest UE4SS release from GitHub..."
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest' -Headers $headers
            # Prefer the standard (non-dev) zip, e.g. "UE4SS_v3.0.1.zip".
            $asset = $release.assets |
                Where-Object { $_.name -match '^UE4SS_v.*\.zip$' -and $_.name -notmatch 'DEV|Dev' } |
                Select-Object -First 1
            if (-not $asset) {
                $asset = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
            }
        }
        if (-not $asset) { throw "Could not find a UE4SS zip on GitHub. Install UE4SS manually (see docs/INSTALL.md) and re-run with -SkipUE4SS." }
        $zipToExtract = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipToExtract `
            -Headers @{ 'User-Agent' = 'AincradTogether-installer' }
        Write-Ok "Downloaded $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
    }

    # Extract to a staging dir first and locate the real payload: community
    # repacks often wrap everything in one or two folders.
    $tmpExtract = Join-Path $env:TEMP ("ue4ss_extract_" + [IO.Path]::GetRandomFileName())
    Expand-Archive -Path $zipToExtract -DestinationPath $tmpExtract -Force
    $payloadRoot = @($tmpExtract) + @(Get-ChildItem -Path $tmpExtract -Directory -Recurse -Depth 2 | ForEach-Object { $_.FullName }) |
        Where-Object {
            (Test-Path (Join-Path $_ 'dwmapi.dll')) -or
            (Test-Path (Join-Path $_ 'xinput1_3.dll')) -or
            (Test-Path (Join-Path $_ 'ue4ss')) -or
            (Test-Path (Join-Path $_ 'UE4SS.dll'))
        } | Select-Object -First 1
    if (-not $payloadRoot) {
        Remove-Item -Path $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
        throw "That zip doesn't look like a UE4SS package (no dwmapi.dll / xinput1_3.dll / ue4ss folder inside)."
    }
    Copy-Item -Path (Join-Path $payloadRoot '*') -Destination $win64Dir -Recurse -Force
    Remove-Item -Path $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "UE4SS extracted next to the game executable."
} else {
    Write-Step "Skipping UE4SS install (as requested)."
}

# UE4SS 3.x experimental keeps its files in a "ue4ss" subfolder; 3.0.x and
# older put everything directly next to the exe. Support both layouts.
$ue4ssDir = Join-Path $win64Dir 'ue4ss'
if (-not (Test-Path $ue4ssDir)) { $ue4ssDir = $win64Dir }

# If we just upgraded from the flat layout to the ue4ss\ layout, retire the
# old core DLL so nothing can load stale code, and remember the old mod
# config so user settings survive the move.
$oldFlatConfig = $null
if ($ue4ssDir -ne $win64Dir) {
    $oldDll = Join-Path $win64Dir 'UE4SS.dll'
    if (Test-Path $oldDll) {
        Move-Item -Path $oldDll -Destination "$oldDll.old-flat-layout" -Force
        Write-Warn2 "Old flat-layout UE4SS.dll renamed to UE4SS.dll.old-flat-layout (new layout uses ue4ss\)."
    }
    $oldIni = Join-Path $win64Dir 'UE4SS-settings.ini'
    if (Test-Path $oldIni) {
        Move-Item -Path $oldIni -Destination "$oldIni.old-flat-layout" -Force
        Write-Warn2 "Old flat-layout UE4SS-settings.ini renamed - the live settings file is ue4ss\UE4SS-settings.ini."
    }
    $oldCfg = Join-Path $win64Dir "Mods\$ModName\Scripts\config.lua"
    if (Test-Path $oldCfg) { $oldFlatConfig = $oldCfg }
}

$modsDir = Join-Path $ue4ssDir 'Mods'
if (-not (Test-Path $modsDir)) {
    if ($SkipUE4SS) {
        throw "No UE4SS 'Mods' folder found in '$win64Dir'. Install UE4SS first (see docs/INSTALL.md)."
    }
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
}

# ----------------------------------------------------------------------------
# 3. Install / update the mod
# ----------------------------------------------------------------------------
Write-Step "Installing the $ModName mod..."
$modTarget = Join-Path $modsDir $ModName

# Never clobber the player's edited config.lua on update.
$existingConfig = Join-Path $modTarget 'Scripts\config.lua'
$savedConfig = $null
if (Test-Path $existingConfig) {
    $savedConfig = Get-Content $existingConfig -Raw
    Write-Ok "Existing config.lua found - your settings will be kept."
} elseif ($oldFlatConfig) {
    $savedConfig = Get-Content $oldFlatConfig -Raw
    Write-Ok "Migrating your config.lua from the old mod location."
}

Copy-Item -Path $ModSource -Destination $modsDir -Recurse -Force
if ($savedConfig) { Set-Content -Path $existingConfig -Value $savedConfig -NoNewline }
Write-Ok "Mod files copied to $modTarget"

# Apply the guest's host IP straight into the mod config so nobody has to
# edit Lua by hand.
if ($HostIP) {
    $configPath = Join-Path $modTarget 'Scripts\config.lua'
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw
        if ($cfg -match '(?m)^Config\.HostAddress') {
            $cfg = $cfg -replace '(?m)^Config\.HostAddress\s*=\s*"[^"]*"', "Config.HostAddress = `"$HostIP`""
        } else {
            $cfg = $cfg -replace '(?m)^return Config', "Config.HostAddress = `"$HostIP`"`r`n`r`nreturn Config"
        }
        Set-Content -Path $configPath -Value $cfg -NoNewline
        Write-Ok "config.lua updated: pressing Join (F8) will connect to $HostIP"
    }
}

# Register in mods.txt as well (enabled.txt inside the mod folder also works,
# but having both makes it visible/toggleable alongside the built-in mods).
$modsTxt = Join-Path $modsDir 'mods.txt'
if (Test-Path $modsTxt) {
    $content = Get-Content $modsTxt -Raw
    if ($content -notmatch [regex]::Escape($ModName)) {
        Add-Content -Path $modsTxt -Value "$ModName : 1"
        Write-Ok "Enabled $ModName in mods.txt"
    }
}

# ----------------------------------------------------------------------------
# 4. Make sure the UE4SS console is available (our best friend for debugging)
# ----------------------------------------------------------------------------
$settingsIni = Join-Path $ue4ssDir 'UE4SS-settings.ini'
if (Test-Path $settingsIni) {
    Write-Step "Configuring UE4SS-settings.ini..."
    $ini = Get-Content $settingsIni -Raw
    $ini = $ini -replace '(?m)^ConsoleEnabled\s*=.*$', 'ConsoleEnabled = 1'
    $ini = $ini -replace '(?m)^GuiConsoleEnabled\s*=.*$', 'GuiConsoleEnabled = 1'
    $ini = $ini -replace '(?m)^GuiConsoleVisible\s*=.*$', 'GuiConsoleVisible = 1'
    if ($EngineVersion) {
        $minor = $EngineVersion.Split('.')[1]
        if ($ini -match '(?m)^MajorVersion\s*=') {
            $ini = $ini -replace '(?m)^MajorVersion\s*=.*$', 'MajorVersion = 5'
            $ini = $ini -replace '(?m)^MinorVersion\s*=.*$', "MinorVersion = $minor"
        } else {
            $ini += "`r`n[EngineVersionOverride]`r`nMajorVersion = 5`r`nMinorVersion = $minor`r`n"
        }
        Write-Ok "Engine version override written: UE 5.$minor"
    }
    Set-Content -Path $settingsIni -Value $ini -NoNewline
    Write-Ok "Console enabled."
} else {
    Write-Warn2 "UE4SS-settings.ini not found (looked in '$ue4ssDir'). If the mod does not load, see docs/TROUBLESHOOTING.md."
}

# Deploy custom engine signatures, if this repo ships any (see ue4ss-config/).
$sigSource = Join-Path $RepoRoot 'ue4ss-config\UE4SS_Signatures'
if ((Test-Path $sigSource) -and (Get-ChildItem -Path $sigSource -Filter '*.lua' -ErrorAction SilentlyContinue)) {
    $sigTarget = Join-Path $ue4ssDir 'UE4SS_Signatures'
    New-Item -ItemType Directory -Path $sigTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $sigSource '*.lua') -Destination $sigTarget -Force
    Write-Ok "Custom engine signatures deployed to $sigTarget"
}

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Role-specific finish
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "Install complete!" -ForegroundColor Green
Write-Host ""

if ($Role -match '^(?i)host$') {
    Write-Host "This PC is the HOST. Your play steps:" -ForegroundColor Cyan
    Write-Host "  1. Launch the game through Steam; wait for the UE4SS console window"
    Write-Host "     to print '[AincradTogether] ... loaded.'"
    Write-Host "  2. Load into the world, then press F7. The map reloads once - normal."
    Write-Host "  3. Tell your partner you're ready; they press F8 on their PC."
    Write-Host ""
    Write-Host "Give your partner ONE of these addresses (the 100.x one if you use Tailscale):"
    $ips = @()
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object { $_.IPAddress }
    } catch { }
    if ($ips) {
        foreach ($ip in $ips) {
            $kind = if ($ip -like '100.*') { ' (Tailscale - use this across the internet)' }
                    elseif ($ip -like '192.168.*' -or $ip -like '10.*') { ' (LAN - same house/Wi-Fi)' }
                    else { '' }
            Write-Host "      $ip$kind"
        }
    } else {
        Write-Host "      (couldn't list IPs - run 'ipconfig' and read the IPv4 Address line)"
    }
    Write-Host ""
    $existingRule = $null
    try { $existingRule = Get-NetFirewallRule -DisplayName 'AincradTogether UDP 7777' -ErrorAction SilentlyContinue } catch { }
    if ($existingRule) {
        Write-Ok "Windows Firewall already allows UDP 7777."
    } elseif (-not $NoPrompt) {
        $fw = Read-Host "Open UDP 7777 in Windows Firewall so your partner can connect? (y/N)"
        if ($fw -match '^(?i)y') {
            try {
                New-NetFirewallRule -DisplayName 'AincradTogether UDP 7777' -Direction Inbound `
                    -Protocol UDP -LocalPort 7777 -Action Allow -Profile Any | Out-Null
                Write-Ok "Firewall rule added."
            } catch {
                Write-Warn2 "Couldn't add the rule (needs an Administrator PowerShell). Alternative:"
                Write-Warn2 "just click 'Allow' when Windows asks the first time you host."
            }
        }
    }
} elseif ($Role -match '^(?i)guest$') {
    Write-Host "This PC is the GUEST. Your play steps:" -ForegroundColor Cyan
    Write-Host "  1. Launch the game through Steam; wait for the UE4SS console window"
    Write-Host "     to print '[AincradTogether] ... loaded.'"
    Write-Host "  2. Load into the game world."
    Write-Host "  3. WAIT until the host says they've pressed F7, then press F8."
    if ($HostIP) {
        Write-Host "     You'll connect to: $HostIP (already saved in config.lua)"
    } else {
        Write-Host "     No host IP saved yet - re-run this installer when you have it, or"
        Write-Host "     type it in-game in the console (F10):  coop_join <the-hosts-ip>"
    }
} else {
    Write-Host "Next steps:"
    Write-Host "  1. Launch the game through Steam. A UE4SS console window should appear"
    Write-Host "     alongside the game and print '[AincradTogether] ... loaded.'"
    Write-Host "  2. HOST: load into the world, then press F7."
    Write-Host "  3. GUEST: put the host's IP in Scripts\config.lua (HostAddress),"
    Write-Host "     start the game, then press F8."
}
Write-Host ""
Write-Host "Playing over the internet? Read docs/CONNECTING.md (Tailscale is the easy way)."
