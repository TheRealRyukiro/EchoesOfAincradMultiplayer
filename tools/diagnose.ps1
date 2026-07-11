# ============================================================================
# AincradTogether doctor for Windows
#
# Checks every link in the chain that gets the mod from disk into the running
# game, and prints a PASS/FAIL report with a verdict at the end. Run it after
# launching the game at least once, and paste the whole output when asking
# for help:
#
#   powershell -ExecutionPolicy Bypass -File tools\diagnose.ps1
#   powershell -ExecutionPolicy Bypass -File tools\diagnose.ps1 -GamePath "D:\...\Echoes of Aincrad Demo"
#
# Read-only by default. The one exception is an explicit repair flag that
# writes the engine version into UE4SS-settings.ini on an existing install:
#
#   ... diagnose.ps1 -SetEngineVersion auto    # version read from the exe
#   ... diagnose.ps1 -SetEngineVersion 5.3     # version you provide
#
# NOTE: first live run of this script happens in the field; if it errors,
# paste the error verbatim along with your UE4SS.log.
# ============================================================================

param(
    # Game root folder OR any folder inside it. Auto-detected from Steam if omitted.
    [string]$GamePath,
    # 'auto' (read from the exe) or an explicit version like '5.3'.
    [string]$SetEngineVersion
)

$ErrorActionPreference = 'Continue'   # keep going and report everything

if ($SetEngineVersion -and $SetEngineVersion -ne 'auto' -and $SetEngineVersion -notmatch '^5\.\d+$') {
    Write-Host "ERROR: -SetEngineVersion takes 'auto' or a version like '5.3' (major.minor, no patch digit)" -ForegroundColor Red
    exit 1
}

$script:PassCount = 0
$script:FailCount = 0
$script:Verdict = ''

function Write-Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green;  $script:PassCount++ }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red;    $script:FailCount++ }
function Write-Info($msg) { Write-Host "[info] $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "       $msg" }

Write-Host "=== AincradTogether diagnostics (Windows) ==="
Write-Host ""

# ----------------------------------------------------------------------------
# 1. Find the game (same search as install.ps1)
# ----------------------------------------------------------------------------
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
    if (Test-Path $GamePath) { $gameRoot = $GamePath }
} else {
    foreach ($steamapps in Get-SteamLibraryFolders) {
        $common = Join-Path $steamapps 'common'
        if (-not (Test-Path $common)) { continue }
        $candidate = Get-ChildItem -Path $common -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*Aincrad*' } | Select-Object -First 1
        if ($candidate) { $gameRoot = $candidate.FullName; break }
    }
}
if (-not $gameRoot) {
    Write-Fail "Could not find the game folder. Re-run with -GamePath `"<folder>`""
    exit 1
}
Write-Pass "Game folder: $gameRoot"

$shippingExe = Get-ChildItem -Path $gameRoot -Recurse -Filter '*-Win64-Shipping.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $shippingExe) {
    Write-Fail "No *-Win64-Shipping.exe under the game folder."
    exit 1
}
$win64Dir = $shippingExe.DirectoryName
Write-Pass "Shipping exe: $($shippingExe.FullName)"

# Engine version straight from the binary (chunked scan; DRM may hide it).
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

$engineVersion = $null
try { $engineVersion = Get-EngineVersion $shippingExe.FullName } catch { }
if ($engineVersion) {
    Write-Info "Game's Unreal Engine version (from exe): $engineVersion"
} else {
    Write-Info "Could not read a UE version string from the exe (DRM hides it; the game is UE 5.3)."
}

# ----------------------------------------------------------------------------
# 2. UE4SS files on disk
# ----------------------------------------------------------------------------
$ue4ssDir = Join-Path $win64Dir 'ue4ss'
if (-not (Test-Path $ue4ssDir)) { $ue4ssDir = $win64Dir }

$proxyDll = $null
if (Test-Path (Join-Path $win64Dir 'dwmapi.dll')) {
    $proxyDll = 'dwmapi'
    Write-Pass "UE4SS proxy DLL present: dwmapi.dll"
} elseif (Test-Path (Join-Path $win64Dir 'xinput1_3.dll')) {
    $proxyDll = 'xinput1_3'
    Write-Pass "UE4SS proxy DLL present: xinput1_3.dll"
} else {
    Write-Fail "No UE4SS proxy DLL (dwmapi.dll / xinput1_3.dll) next to the shipping exe."
    Write-Note "Re-run the installer (tools\install.ps1) - it uses the bundled UE4SS_5_3_2.zip."
}

if ((Test-Path (Join-Path $ue4ssDir 'UE4SS.dll')) -or (Test-Path (Join-Path $win64Dir 'UE4SS.dll'))) {
    Write-Pass "UE4SS.dll present"
} else {
    Write-Fail "UE4SS.dll missing - re-run the installer (tools\install.ps1)."
}

$settingsIni = Join-Path $ue4ssDir 'UE4SS-settings.ini'
if (Test-Path $settingsIni) {
    Write-Pass "Settings file: $settingsIni"
    foreach ($key in @('ConsoleEnabled', 'GuiConsoleEnabled', 'GuiConsoleVisible', 'GraphicsAPI')) {
        $line = (Select-String -Path $settingsIni -Pattern "^$key\s*=" | Select-Object -First 1)
        if ($line) { Write-Info "  settings: $($line.Line.Trim())" }
        else { Write-Info "  settings: $key not found in ini" }
    }
    $majorLine = (Select-String -Path $settingsIni -Pattern '^MajorVersion\s*=' | Select-Object -First 1)
    $minorLine = (Select-String -Path $settingsIni -Pattern '^MinorVersion\s*=' | Select-Object -First 1)
    if ($majorLine -or $minorLine) {
        $mj = if ($majorLine) { $majorLine.Line.Trim() } else { 'MajorVersion unset' }
        $mn = if ($minorLine) { $minorLine.Line.Trim() } else { 'MinorVersion unset' }
        Write-Info "  [EngineVersionOverride]: $mj | $mn"
    } else {
        Write-Info "  [EngineVersionOverride]: section not present"
    }

    if ($SetEngineVersion) {
        $target = $SetEngineVersion
        if ($target -eq 'auto') {
            $target = $engineVersion
            if (-not $target) {
                Write-Fail "-SetEngineVersion auto: could not read a version from the exe."
                Write-Note "Pass it explicitly - for Echoes of Aincrad: -SetEngineVersion 5.3"
                exit 1
            }
        }
        $minor = $target.Split('.')[1]
        $ini = Get-Content $settingsIni -Raw
        if ($ini -match '(?m)^MajorVersion\s*=') {
            $ini = $ini -replace '(?m)^MajorVersion\s*=.*$', 'MajorVersion = 5'
            $ini = $ini -replace '(?m)^MinorVersion\s*=.*$', "MinorVersion = $minor"
        } else {
            $ini += "`r`n[EngineVersionOverride]`r`nMajorVersion = 5`r`nMinorVersion = $minor`r`n"
        }
        Set-Content -Path $settingsIni -Value $ini -NoNewline
        Write-Pass "WROTE engine override: UE 5.$minor -> $settingsIni"
        Write-Note "Launch the game again; UE4SS will use this instead of scanning for the version."
    }
} else {
    Write-Fail "UE4SS-settings.ini not found in $ue4ssDir"
}

# ----------------------------------------------------------------------------
# 3. Mod files + the guest's most common mistake
# ----------------------------------------------------------------------------
$modsDir = Join-Path $ue4ssDir 'Mods'
$modDir = Join-Path $modsDir 'AincradTogether'
if (Test-Path (Join-Path $modDir 'Scripts\main.lua')) {
    Write-Pass "Mod script present: $(Join-Path $modDir 'Scripts\main.lua')"
} else {
    Write-Fail "Mod script missing at $modDir\Scripts\main.lua - re-run the installer."
}
if (Test-Path (Join-Path $modDir 'enabled.txt')) {
    Write-Pass "enabled.txt present"
} else {
    Write-Fail "enabled.txt missing in $modDir"
}
$modsTxt = Join-Path $modsDir 'mods.txt'
if ((Test-Path $modsTxt) -and (Select-String -Path $modsTxt -Pattern 'AincradTogether' -Quiet)) {
    Write-Pass "Registered in mods.txt"
} else {
    Write-Info "Not listed in mods.txt (fine - enabled.txt is enough)"
}

$configLua = Join-Path $modDir 'Scripts\config.lua'
if (Test-Path $configLua) {
    $hostLine = (Select-String -Path $configLua -Pattern '^Config\.HostAddress\s*=\s*"([^"]*)"' | Select-Object -First 1)
    if ($hostLine) {
        $addr = $hostLine.Matches[0].Groups[1].Value
        Write-Info "config.lua HostAddress = $addr"
        if ($addr -eq '127.0.0.1') {
            Write-Note "That is the localhost default. Fine on the HOST PC, but a GUEST"
            Write-Note "pressing F8 with this value connects to itself and hangs on a load"
            Write-Note "screen. Guests: re-run the installer, or in-game console (F10):"
            Write-Note "    coop_join <the-hosts-ip>"
        }
    }
}

# ----------------------------------------------------------------------------
# 4. Windows Firewall (matters on the HOST only)
# ----------------------------------------------------------------------------
try {
    $profilesOn = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $_.Enabled })
    if ($profilesOn.Count -eq 0) {
        Write-Info "Windows Firewall: off (nothing blocks; only relevant when this PC HOSTS)"
    } elseif (Get-NetFirewallRule -DisplayName 'AincradTogether UDP 7777' -ErrorAction SilentlyContinue) {
        Write-Info "Windows Firewall: on, inbound UDP 7777 rule present (ready to host)"
    } else {
        Write-Info "Windows Firewall: on, no UDP 7777 rule - only matters if this PC HOSTS."
        Write-Note "Hosts: click 'Allow' when Windows asks, or add the rule from an admin"
        Write-Note "PowerShell: New-NetFirewallRule -DisplayName 'AincradTogether UDP 7777' -Direction Inbound -Protocol UDP -LocalPort 7777 -Action Allow"
    }
} catch {
    Write-Info "Windows Firewall: couldn't read state - click 'Allow' if Windows asks when hosting."
}

# ----------------------------------------------------------------------------
# 5. The source of truth: UE4SS.log
# ----------------------------------------------------------------------------
$ue4ssLog = $null
foreach ($cand in @((Join-Path $ue4ssDir 'UE4SS.log'), (Join-Path $win64Dir 'UE4SS.log'))) {
    if (Test-Path $cand) { $ue4ssLog = $cand; break }
}

Write-Host ""
if (-not $ue4ssLog) {
    Write-Fail "No UE4SS.log found. UE4SS has NEVER run inside the game."
    $script:Verdict = @"
UE4SS is not being injected. On Windows no launch options are needed - the
usual causes are: (1) UE4SS files not next to the *Shipping* exe (must be in
...\Binaries\Win64\, not the top-level game folder); (2) antivirus/Windows
Defender quarantined dwmapi.dll - check protection history and restore/allow
it; (3) the game wasn't launched since installing. Launch the game once via
Steam and re-run this script.
"@
} else {
    Write-Pass "UE4SS.log exists: $ue4ssLog"
    Write-Info "log modified: $((Get-Item $ue4ssLog).LastWriteTime)"

    $logRaw = Get-Content $ue4ssLog -Raw
    if ($logRaw -match 'AincradTogether') {
        Write-Pass "Mod banner found in the log - AincradTogether IS loading."
        Write-Host ""
        Write-Info "AincradTogether lines from the log (last 20):"
        Select-String -Path $ue4ssLog -Pattern 'AincradTogether' | Select-Object -Last 20 | ForEach-Object { Write-Note $_.Line }
        $script:Verdict = @"
UE4SS and the mod are loading. If F8/F7 seem to do nothing: (1) the game
window must have focus; (2) you must be loaded INTO the world, not the main
menu; (3) bypass keybinds via the in-game console (F10 or ~) and type:
coop_join <the-hosts-ip>   (guests)  /  coop_host   (hosts)
"@
    } elseif ($logRaw -match 'PS scan timed out|\[PS\] Scan failed|Failed to find ') {
        Write-Fail "UE4SS runs, but its pattern scan cannot fingerprint this game's engine build."
        Write-Host ""
        Write-Info "Signatures the scan could not find:"
        [regex]::Matches($logRaw, 'Failed to find [A-Za-z_:()]+') | ForEach-Object { $_.Value } |
            Sort-Object -Unique | ForEach-Object { Write-Note ("- " + ($_ -replace '^Failed to find ', '') -replace ':+$', '') }
        $script:Verdict = @"
This UE4SS build cannot scan the game. Fix: re-run the installer and let it
deploy the bundled community build (UE4SS_5_3_2.zip):
    powershell -ExecutionPolicy Bypass -File tools\install.ps1 -UE4SSZip "UE4SS_5_3_2.zip"
Then make sure the engine override says 5.3:
    powershell -ExecutionPolicy Bypass -File tools\diagnose.ps1 -SetEngineVersion 5.3
"@
    } else {
        Write-Fail "UE4SS runs, but the mod banner is NOT in the log."
        $script:Verdict = @"
UE4SS injects fine but is not loading the mod. Check for a doubled folder
(Mods\AincradTogether\AincradTogether), confirm Scripts\main.lua exists, and
look for Lua error lines in the log. Paste this whole output when asking for
help.
"@
    }
    Write-Host ""
    Write-Info "Last 10 lines of UE4SS.log:"
    Get-Content $ue4ssLog -Tail 10 | ForEach-Object { Write-Note $_ }
}

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Result: $script:PassCount passed, $script:FailCount failed ==="
Write-Host ""
Write-Host $script:Verdict
