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
    [switch]$SkipUE4SS
)

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
# 2. Install UE4SS
# ----------------------------------------------------------------------------
if (-not $SkipUE4SS) {
    Write-Step "Installing UE4SS (the mod loader)..."
    $zipToExtract = $null

    if ($UE4SSZip) {
        if (-not (Test-Path $UE4SSZip)) { throw "UE4SS zip not found: $UE4SSZip" }
        $zipToExtract = $UE4SSZip
    } else {
        Write-Ok "Downloading the latest UE4SS release from GitHub..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest' `
            -Headers @{ 'User-Agent' = 'AincradTogether-installer' }
        # Prefer the standard (non-dev) zip, e.g. "UE4SS_v3.0.1.zip".
        $asset = $release.assets |
            Where-Object { $_.name -match '^UE4SS_v.*\.zip$' -and $_.name -notmatch 'DEV|Dev' } |
            Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
        }
        if (-not $asset) { throw "Could not find a UE4SS zip in the latest release. Install UE4SS manually (see docs/INSTALL.md) and re-run with -SkipUE4SS." }
        $zipToExtract = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipToExtract `
            -Headers @{ 'User-Agent' = 'AincradTogether-installer' }
        Write-Ok "Downloaded $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
    }

    Expand-Archive -Path $zipToExtract -DestinationPath $win64Dir -Force
    Write-Ok "UE4SS extracted next to the game executable."
} else {
    Write-Step "Skipping UE4SS install (as requested)."
}

# UE4SS 3.x keeps its files in a "ue4ss" subfolder; older versions put
# everything directly next to the exe. Support both layouts.
$ue4ssDir = Join-Path $win64Dir 'ue4ss'
if (-not (Test-Path $ue4ssDir)) { $ue4ssDir = $win64Dir }
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
}

Copy-Item -Path $ModSource -Destination $modsDir -Recurse -Force
if ($savedConfig) { Set-Content -Path $existingConfig -Value $savedConfig -NoNewline }
Write-Ok "Mod files copied to $modTarget"

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
    Write-Step "Enabling the UE4SS console in UE4SS-settings.ini..."
    $ini = Get-Content $settingsIni -Raw
    $ini = $ini -replace '(?m)^ConsoleEnabled\s*=.*$', 'ConsoleEnabled = 1'
    $ini = $ini -replace '(?m)^GuiConsoleEnabled\s*=.*$', 'GuiConsoleEnabled = 1'
    $ini = $ini -replace '(?m)^GuiConsoleVisible\s*=.*$', 'GuiConsoleVisible = 1'
    Set-Content -Path $settingsIni -Value $ini -NoNewline
    Write-Ok "Console enabled."
} else {
    Write-Warn2 "UE4SS-settings.ini not found (looked in '$ue4ssDir'). If the mod does not load, see docs/TROUBLESHOOTING.md."
}

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "Install complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Launch the game through Steam. A UE4SS console window should appear"
Write-Host "     alongside the game and print '[AincradTogether] ... loaded.'"
Write-Host "  2. HOST: load into the world, then press F7."
Write-Host "  3. JOINER: put the host's IP in Scripts\config.lua (HostAddress),"
Write-Host "     start the game, then press F8."
Write-Host ""
Write-Host "Playing over the internet? Read docs/CONNECTING.md (Tailscale is the easy way)."
