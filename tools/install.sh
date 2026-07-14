#!/usr/bin/env bash
# ============================================================================
# AincradTogether installer for Linux (Steam + Proton)
#
# The game is Windows-only, so on Linux it runs through Proton — and UE4SS
# injects into it the same way it does on Windows. This script installs
# UE4SS + the mod into your Steam copy of Echoes of Aincrad (demo or full).
#
#   ./tools/install.sh                        # guided setup: finds the game,
#                                             # keeps an existing UE4SS or
#                                             # walks you through getting the
#                                             # community build, installs the
#                                             # mod, asks host/guest
#   ./tools/install.sh --experimental         # replace UE4SS with the stock
#                                             # experimental build
#   ./tools/install.sh --game-path <folder>   # point at the game manually
#   ./tools/install.sh --zip <file.zip>       # install a specific UE4SS
#                                             # package, e.g. the community
#                                             # "UE4SS" from the game's Nexus
#                                             # Mods page (recommended for
#                                             # this game - it ships working
#                                             # signatures)
#   ./tools/install.sh --skip-ue4ss           # only (re)install the mod
#   ./tools/install.sh --engine-version 5.3   # force the UE version instead
#                                             # of reading it from the exe
#                                             # (Echoes of Aincrad is 5.3)
#   ./tools/install.sh --role host|guest      # skip the role question
#   ./tools/install.sh --host-ip 100.1.2.3    # guest: save the host's IP
#                                             # into config.lua
#   ./tools/install.sh --no-prompt            # never ask questions
#
# The script also reads the game's Unreal Engine version out of the exe and
# writes it into UE4SS-settings.ini ([EngineVersionOverride]) so UE4SS does
# not depend on detecting it by memory scan. To write the override into an
# EXISTING install without reinstalling, use:
#   ./tools/diagnose.sh --set-engine-version auto
#
# After installing you MUST set the game's Steam launch options (the script
# prints the exact line) so Proton loads UE4SS.
# Requires: bash, curl, unzip. (python3 recommended.)
# ============================================================================

set -euo pipefail

GAME_PATH=""
UE4SS_ZIP=""
SKIP_UE4SS=0
EXPERIMENTAL=0
FORCED_ENGINE_VERSION=""
ROLE=""
HOST_IP=""
NO_PROMPT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-path) GAME_PATH="$2"; shift 2 ;;
        --zip)       UE4SS_ZIP="$2"; shift 2 ;;
        --skip-ue4ss) SKIP_UE4SS=1; shift ;;
        --experimental) EXPERIMENTAL=1; shift ;;
        --engine-version) FORCED_ENGINE_VERSION="$2"; shift 2 ;;
        --role)      ROLE="$2"; shift 2 ;;
        --host-ip)   HOST_IP="$2"; shift 2 ;;
        --no-prompt) NO_PROMPT=1; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

if [[ -n "$FORCED_ENGINE_VERSION" ]] && ! [[ "$FORCED_ENGINE_VERSION" =~ ^5\.[0-9]+$ ]]; then
    printf 'ERROR: --engine-version must look like "5.3" (major.minor, no patch digit)\n' >&2
    exit 1
fi
ROLE="$(printf '%s' "$ROLE" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$ROLE" && "$ROLE" != "host" && "$ROLE" != "guest" ]]; then
    printf 'ERROR: --role must be "host" or "guest"\n' >&2
    exit 1
fi
if [[ -n "$HOST_IP" ]] && ! [[ "$HOST_IP" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    printf 'ERROR: --host-ip does not look like an IP address or hostname: %s\n' "$HOST_IP" >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 0. Setup questions (asked up front so the rest runs unattended)
# ----------------------------------------------------------------------------
if [[ "$NO_PROMPT" -eq 0 && -z "$ROLE" && -t 0 ]]; then
    echo
    printf '\033[36mWho is this PC in your co-op session?\033[0m\n'
    echo "  [1] HOST  - the world you'll both play in runs on this PC"
    echo "  [2] GUEST - this PC joins the host's world"
    while true; do
        read -r -p "Enter 1 or 2: " answer
        case "$answer" in
            1) ROLE="host"; break ;;
            2) ROLE="guest"; break ;;
        esac
    done
fi

if [[ "$NO_PROMPT" -eq 0 && "$ROLE" == "guest" && -z "$HOST_IP" && -t 0 ]]; then
    echo
    printf "\033[36mThe GUEST needs the HOST's IP address. How the host finds it, on THEIR pc:\033[0m\n"
    echo "  - Same house / same Wi-Fi (host on Windows): press Win+R, type 'cmd',"
    echo "    press Enter, then run:  ipconfig"
    echo "    -> use the 'IPv4 Address' line (usually starts with 192.168.)"
    echo "  - Different houses via Tailscale: open the Tailscale app / tray icon"
    echo "    -> use the IP that starts with 100."
    echo "  - Host on Linux: run  hostname -I  in a terminal (first address)"
    echo "  (Leave empty to set it later - re-run this installer or edit config.lua.)"
    read -r -p "Host IP address: " HOST_IP
    HOST_IP="$(printf '%s' "$HOST_IP" | tr -d '[:space:]')"
    if [[ -n "$HOST_IP" ]] && ! [[ "$HOST_IP" =~ ^[A-Za-z0-9.:-]+$ ]]; then
        printf '\033[33m    That does not look like an IP; skipping. Re-run the installer to try again.\033[0m\n'
        HOST_IP=""
    fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD_SOURCE="$REPO_ROOT/Mods/AincradTogether"
MOD_NAME="AincradTogether"
UA='User-Agent: AincradTogether-installer'

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v unzip >/dev/null || die "unzip is required"
[[ -d "$MOD_SOURCE" ]] || die "Mod files not found at $MOD_SOURCE - run from a full clone of the repo."

# ----------------------------------------------------------------------------
# 1. Locate the game
# ----------------------------------------------------------------------------
step "Locating Echoes of Aincrad..."

find_steam_libraries() {
    local roots=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"  # Flatpak
        "$HOME/snap/steam/common/.local/share/Steam"                 # Snap
    )
    local root vdf
    for root in "${roots[@]}"; do
        [[ -d "$root/steamapps" ]] && echo "$root/steamapps"
        vdf="$root/steamapps/libraryfolders.vdf"
        if [[ -f "$vdf" ]]; then
            # Every "path" entry is another library location.
            grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" \
                | sed -E 's/"path"[[:space:]]+"([^"]+)"/\1/' \
                | while read -r lib; do
                      [[ -d "$lib/steamapps" ]] && echo "$lib/steamapps"
                  done
        fi
    done | sort -u
}

GAME_ROOT=""
if [[ -n "$GAME_PATH" ]]; then
    [[ -d "$GAME_PATH" ]] || die "The path you passed does not exist: $GAME_PATH"
    GAME_ROOT="$GAME_PATH"
else
    while IFS= read -r steamapps; do
        for candidate in "$steamapps"/common/*Aincrad*; do
            if [[ -d "$candidate" ]]; then
                GAME_ROOT="$candidate"
                break 2
            fi
        done
    done < <(find_steam_libraries)
    [[ -n "$GAME_ROOT" ]] || die "Could not auto-detect the game. Find it via Steam -> Manage -> Browse local files, then re-run with --game-path \"<that folder>\""
fi
ok "Game folder: $GAME_ROOT"

SHIPPING_EXE="$(find "$GAME_ROOT" -name '*-Win64-Shipping.exe' -type f 2>/dev/null | head -n 1)"
[[ -n "$SHIPPING_EXE" ]] || die "No *-Win64-Shipping.exe found under '$GAME_ROOT'. Is this really the game folder?"
WIN64_DIR="$(dirname "$SHIPPING_EXE")"
ok "Game executable: $(basename "$SHIPPING_EXE")"
ok "Install target:  $WIN64_DIR"

# ----------------------------------------------------------------------------
# 2. Detect the game's Unreal Engine version from the executable
#    (the version string is embedded in the binary; we scan for it in chunks)
# ----------------------------------------------------------------------------
# Known version for Echoes of Aincrad: UE 5.3.2 (UE4SS-RE/RE-UE4SS#1283).
# Used as the fallback when nothing better is available.
KNOWN_GAME_ENGINE_VERSION="5.3"

ENGINE_VERSION=""
if [[ -n "$FORCED_ENGINE_VERSION" ]]; then
    ENGINE_VERSION="$FORCED_ENGINE_VERSION"
    step "Using engine version from --engine-version: UE $ENGINE_VERSION"
elif command -v python3 >/dev/null; then
    step "Reading the game's Unreal Engine version from the exe..."
    ENGINE_VERSION="$(python3 - "$SHIPPING_EXE" <<'PYEOF' || true
import re
import sys

path = sys.argv[1]
CHUNK = 32 * 1024 * 1024
OVERLAP = 128
PATTERNS = [
    # "++UE5+Release-5.6" as ASCII and UTF-16LE
    re.compile(rb'\+\+UE5\+Release-(5\.[0-9]{1,2})'),
    re.compile(rb'\+\x00\+\x00U\x00E\x005\x00\+\x00R\x00e\x00l\x00e\x00a\x00s\x00e\x00-\x00(5\x00\.\x00[0-9]\x00(?:[0-9]\x00)?)'),
    # Full build version "5.6.1-12345678+++..." as ASCII
    re.compile(rb'(5\.[0-9]{1,2})\.[0-9]{1,2}-[0-9]{6,12}\+\+\+'),
]

found = set()
with open(path, 'rb') as handle:
    tail = b''
    while True:
        chunk = handle.read(CHUNK)
        if not chunk:
            break
        data = tail + chunk
        for pattern in PATTERNS:
            for match in pattern.finditer(data):
                version = match.group(1).replace(b'\x00', b'').decode('ascii', 'ignore')
                found.add(version)
        tail = data[-OVERLAP:]

# Highest minor wins if several strings are embedded.
def minor(v):
    try:
        return int(v.split('.')[1])
    except (IndexError, ValueError):
        return -1

candidates = sorted(found, key=minor)
print(candidates[-1] if candidates else '')
PYEOF
)"
    if [[ -n "$ENGINE_VERSION" ]]; then
        ok "Detected Unreal Engine $ENGINE_VERSION"
    else
        warn "Could not read a UE version string from the exe (DRM hides it in this game)."
    fi
else
    warn "python3 not found - skipping engine version detection."
fi

if [[ -z "$ENGINE_VERSION" ]]; then
    ENGINE_VERSION="$KNOWN_GAME_ENGINE_VERSION"
    ok "Falling back to the known version for this game: UE $ENGINE_VERSION"
    ok "(documented in UE4SS-RE/RE-UE4SS issue #1283; override with --engine-version)"
fi

# ----------------------------------------------------------------------------
# 3. Install UE4SS
# ----------------------------------------------------------------------------
# Extracts a UE4SS package into the game folder, tolerating community
# repacks that wrap the payload in one or two folders.
install_ue4ss_from_zip() {
    local Zip="$1"
    [[ -f "$Zip" ]] || die "UE4SS zip not found: $Zip"
    local Staging
    Staging="$(mktemp -d)"
    unzip -o -q "$Zip" -d "$Staging"
    local Payload=""
    local cand
    for cand in "$Staging" "$Staging"/*/ "$Staging"/*/*/; do
        [[ -d "$cand" ]] || continue
        if [[ -e "$cand/dwmapi.dll" || -e "$cand/xinput1_3.dll" || -d "$cand/ue4ss" || -e "$cand/UE4SS.dll" ]]; then
            Payload="$cand"
            break
        fi
    done
    [[ -n "$Payload" ]] || { rm -rf "$Staging"; die "That zip doesn't look like a UE4SS package (no dwmapi.dll / xinput1_3.dll / ue4ss folder inside)."; }
    cp -a "$Payload/." "$WIN64_DIR/"
    rm -rf "$Staging"
    ok "UE4SS installed next to the game executable."
}

download_experimental_ue4ss() {
    ok "Downloading the UE4SS EXPERIMENTAL build from GitHub..."
    local ReleasesJson AssetUrl
    ReleasesJson="$(curl -fsSL -H "$UA" 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases?per_page=30')"
    if command -v python3 >/dev/null; then
        AssetUrl="$(printf '%s' "$ReleasesJson" | python3 -c '
import json
import sys

releases = json.load(sys.stdin)

def pick(rels):
    for release in rels:
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if name.startswith("UE4SS") and name.endswith(".zip") and "dev" not in name.lower():
                return asset["browser_download_url"]
    return ""

prereleases = [r for r in releases if r.get("prerelease")]
print(pick(prereleases) or pick(releases))
')"
    else
        # Fallback: experimental release tags contain "experimental" in the
        # download URL path.
        AssetUrl="$(printf '%s' "$ReleasesJson" \
            | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | cut -d'"' -f4 \
            | grep -i 'experimental' \
            | grep -E '/UE4SS[^/]*\.zip$' \
            | grep -viE 'dev' \
            | head -n 1)"
    fi
    [[ -n "$AssetUrl" ]] || die "Could not find a UE4SS zip on GitHub. Download one manually and re-run with --zip <file>"
    DOWNLOADED_ZIP="$(mktemp -d)/$(basename "$AssetUrl")"
    curl -fL -H "$UA" -o "$DOWNLOADED_ZIP" "$AssetUrl"
    ok "Downloaded $(basename "$DOWNLOADED_ZIP")"
}

# UE4SS is already in place when both a proxy DLL and the core DLL exist.
UE4SS_PRESENT=0
if [[ -f "$WIN64_DIR/dwmapi.dll" || -f "$WIN64_DIR/xinput1_3.dll" ]] \
        && [[ -f "$WIN64_DIR/UE4SS.dll" || -f "$WIN64_DIR/ue4ss/UE4SS.dll" ]]; then
    UE4SS_PRESENT=1
fi

if [[ "$SKIP_UE4SS" -eq 1 ]]; then
    step "Skipping UE4SS install (as requested)."
elif [[ -n "$UE4SS_ZIP" ]]; then
    step "Installing UE4SS from $UE4SS_ZIP ..."
    install_ue4ss_from_zip "$UE4SS_ZIP"
elif [[ "$EXPERIMENTAL" -eq 1 ]]; then
    step "Installing UE4SS (EXPERIMENTAL build)..."
    download_experimental_ue4ss
    install_ue4ss_from_zip "$DOWNLOADED_ZIP"
elif [[ "$UE4SS_PRESENT" -eq 1 ]]; then
    step "UE4SS is already installed - keeping it."
    ok "(replace it explicitly with --zip <file> or --experimental if ever needed)"
else
    step "UE4SS (the mod loader) is not installed yet."
    # A game-ready UE4SS build ships with this repo/download, so the normal
    # path needs no extra downloads and no questions.
    BUNDLED_ZIP=""
    for cand in "$REPO_ROOT/UE4SS_5_3_2.zip" "$REPO_ROOT"/UE4SS*.zip; do
        if [[ -f "$cand" ]]; then BUNDLED_ZIP="$cand"; break; fi
    done
    if [[ -n "$BUNDLED_ZIP" ]]; then
        ok "Installing the UE4SS build bundled with this download: $(basename "$BUNDLED_ZIP")"
        ok "(community build prepared for this game - stock UE4SS cannot scan it)"
        install_ue4ss_from_zip "$BUNDLED_ZIP"
    elif [[ "$NO_PROMPT" -eq 0 && -t 0 ]]; then
        echo "    No bundled UE4SS found. Get the community build from the game's"
        echo "    Nexus Mods page (free account required):"
        echo "        https://www.nexusmods.com/echoesofaincrad   (search: UE4SS)"
        echo "    Download it now, then come back here."
        read -r -p "Paste the full path to the downloaded zip (Enter to abort): " ZIP_INPUT
        # Strip surrounding quotes that file managers love to add.
        ZIP_INPUT="${ZIP_INPUT%\"}"; ZIP_INPUT="${ZIP_INPUT#\"}"
        ZIP_INPUT="${ZIP_INPUT%\'}"; ZIP_INPUT="${ZIP_INPUT#\'}"
        [[ -n "$ZIP_INPUT" ]] || die "Aborted. Re-run this installer once you have the zip."
        install_ue4ss_from_zip "$ZIP_INPUT"
    else
        die "No bundled UE4SS found. Re-run with --zip <file> (community build from nexusmods.com/echoesofaincrad) or --experimental."
    fi
fi

# UE4SS 3.x experimental keeps its files in a "ue4ss" subfolder; 3.0.x and
# older put everything directly next to the exe. Support both layouts.
UE4SS_DIR="$WIN64_DIR/ue4ss"
[[ -d "$UE4SS_DIR" ]] || UE4SS_DIR="$WIN64_DIR"

# If we just upgraded from the flat layout to the ue4ss/ layout, retire the
# old core DLL so nothing can load stale code, and remember the old mod
# config so user settings survive the move.
OLD_FLAT_CONFIG=""
if [[ "$UE4SS_DIR" != "$WIN64_DIR" ]]; then
    if [[ -f "$WIN64_DIR/UE4SS.dll" ]]; then
        mv -f "$WIN64_DIR/UE4SS.dll" "$WIN64_DIR/UE4SS.dll.old-flat-layout"
        warn "Old flat-layout UE4SS.dll renamed to UE4SS.dll.old-flat-layout (new layout uses ue4ss/)."
    fi
    if [[ -f "$WIN64_DIR/UE4SS-settings.ini" ]]; then
        mv -f "$WIN64_DIR/UE4SS-settings.ini" "$WIN64_DIR/UE4SS-settings.ini.old-flat-layout"
        warn "Old flat-layout UE4SS-settings.ini renamed - the live settings file is ue4ss/UE4SS-settings.ini."
    fi
    if [[ -f "$WIN64_DIR/UE4SS.log" ]]; then
        mv -f "$WIN64_DIR/UE4SS.log" "$WIN64_DIR/UE4SS.log.old-flat-layout"
        warn "Old flat-layout UE4SS.log renamed - the LIVE log is ue4ss/UE4SS.log (don't paste the stale one)."
    fi
    if [[ -f "$WIN64_DIR/Mods/$MOD_NAME/Scripts/config.lua" ]]; then
        OLD_FLAT_CONFIG="$WIN64_DIR/Mods/$MOD_NAME/Scripts/config.lua"
    fi
fi

MODS_DIR="$UE4SS_DIR/Mods"
if [[ ! -d "$MODS_DIR" ]]; then
    [[ "$SKIP_UE4SS" -eq 1 ]] && die "No UE4SS 'Mods' folder found in '$WIN64_DIR'. Install UE4SS first."
    mkdir -p "$MODS_DIR"
fi

# ----------------------------------------------------------------------------
# 4. Install / update the mod (never clobber an edited config.lua)
# ----------------------------------------------------------------------------
step "Installing the $MOD_NAME mod..."
MOD_TARGET="$MODS_DIR/$MOD_NAME"
SAVED_CONFIG=""
if [[ -f "$MOD_TARGET/Scripts/config.lua" ]]; then
    SAVED_CONFIG="$(mktemp)"
    cp "$MOD_TARGET/Scripts/config.lua" "$SAVED_CONFIG"
    ok "Existing config.lua found - your settings will be kept."
elif [[ -n "$OLD_FLAT_CONFIG" ]]; then
    SAVED_CONFIG="$(mktemp)"
    cp "$OLD_FLAT_CONFIG" "$SAVED_CONFIG"
    ok "Migrating your config.lua from the old mod location."
fi
mkdir -p "$MOD_TARGET"
cp -r "$MOD_SOURCE/." "$MOD_TARGET/"
if [[ -n "$SAVED_CONFIG" ]]; then
    cp "$SAVED_CONFIG" "$MOD_TARGET/Scripts/config.lua"
    rm -f "$SAVED_CONFIG"
fi
ok "Mod files copied to $MOD_TARGET"

# Apply the guest's host IP straight into the mod config so nobody has to
# edit Lua by hand. (HOST_IP is pre-validated: letters/digits/.:-only.)
MOD_CONFIG="$MOD_TARGET/Scripts/config.lua"
if [[ -n "$HOST_IP" && -f "$MOD_CONFIG" ]]; then
    if grep -qE '^Config\.HostAddress' "$MOD_CONFIG"; then
        sed -i -E "s/^Config\.HostAddress[[:space:]]*=.*/Config.HostAddress = \"$HOST_IP\"/" "$MOD_CONFIG"
    else
        sed -i -E "s/^return Config/Config.HostAddress = \"$HOST_IP\"\n\nreturn Config/" "$MOD_CONFIG"
    fi
    ok "config.lua updated: pressing Join (F8) will connect to $HOST_IP"
fi

MODS_TXT="$MODS_DIR/mods.txt"
if [[ -f "$MODS_TXT" ]] && ! grep -q "$MOD_NAME" "$MODS_TXT"; then
    printf '%s : 1\n' "$MOD_NAME" >> "$MODS_TXT"
    ok "Enabled $MOD_NAME in mods.txt"
fi

# ----------------------------------------------------------------------------
# 5. Settings: console on, OpenGL GUI (Proton), engine version override
# ----------------------------------------------------------------------------
SETTINGS_INI="$UE4SS_DIR/UE4SS-settings.ini"
if [[ -f "$SETTINGS_INI" ]]; then
    step "Configuring UE4SS-settings.ini..."
    sed -i -E 's/^ConsoleEnabled[[:space:]]*=.*/ConsoleEnabled = 1/' "$SETTINGS_INI"
    sed -i -E 's/^GuiConsoleEnabled[[:space:]]*=.*/GuiConsoleEnabled = 1/' "$SETTINGS_INI"
    sed -i -E 's/^GuiConsoleVisible[[:space:]]*=.*/GuiConsoleVisible = 1/' "$SETTINGS_INI"
    sed -i -E 's/^GraphicsAPI[[:space:]]*=.*/GraphicsAPI = opengl/' "$SETTINGS_INI"
    ok "Console enabled, GUI set to OpenGL (Proton-friendly)."

    if [[ -n "$ENGINE_VERSION" ]]; then
        MINOR="${ENGINE_VERSION#5.}"
        if grep -qE '^MajorVersion' "$SETTINGS_INI"; then
            sed -i -E 's/^MajorVersion[[:space:]]*=.*/MajorVersion = 5/' "$SETTINGS_INI"
            sed -i -E "s/^MinorVersion[[:space:]]*=.*/MinorVersion = $MINOR/" "$SETTINGS_INI"
        else
            printf '\n[EngineVersionOverride]\nMajorVersion = 5\nMinorVersion = %s\n' "$MINOR" >> "$SETTINGS_INI"
        fi
        ok "Engine version override written: UE 5.$MINOR"
    fi
else
    warn "UE4SS-settings.ini not found in '$UE4SS_DIR' - if the mod does not load, see docs/TROUBLESHOOTING.md."
fi

# ----------------------------------------------------------------------------
# 6. Deploy custom engine signatures, if this repo ships any
#    (UE4SS_Signatures/*.lua teach UE4SS where this game's internals live
#    when its built-in fingerprints miss; see ue4ss-config/README.md)
# ----------------------------------------------------------------------------
SIG_SOURCE="$REPO_ROOT/ue4ss-config/UE4SS_Signatures"
if [[ -d "$SIG_SOURCE" ]] && compgen -G "$SIG_SOURCE/*.lua" > /dev/null; then
    mkdir -p "$UE4SS_DIR/UE4SS_Signatures"
    cp "$SIG_SOURCE"/*.lua "$UE4SS_DIR/UE4SS_Signatures/"
    ok "Custom engine signatures deployed to $UE4SS_DIR/UE4SS_Signatures/"
fi

# ----------------------------------------------------------------------------
# Done — Proton needs a launch option to load UE4SS's proxy DLL
# ----------------------------------------------------------------------------
PROXY_DLL="dwmapi"
if [[ ! -e "$WIN64_DIR/dwmapi.dll" && -e "$WIN64_DIR/xinput1_3.dll" ]]; then
    PROXY_DLL="xinput1_3"
fi

echo
printf '\033[32mInstall complete!\033[0m\n'
echo
echo "ONE REQUIRED MANUAL STEP - tell Steam to load UE4SS:"
echo "  Steam -> right-click Echoes of Aincrad -> Properties -> Launch Options:"
echo
printf '      WINEDLLOVERRIDES="%s=n,b" %%command%%\n' "$PROXY_DLL"
echo
if [[ "$ROLE" == "host" ]]; then
    printf '\033[36mThis PC is the HOST. Your play steps:\033[0m\n'
    echo "  1. Launch the game; wait for the UE4SS console window to print"
    echo "     '[AincradTogether] ... loaded.'"
    echo "  2. Load into the world, then press F7. The map reloads once - normal."
    echo "  3. Tell your partner you're ready; they press F8 on their PC."
    echo
    echo "Give your partner ONE of these addresses (the 100.x one if you use Tailscale):"
    if command -v hostname >/dev/null && hostname -I >/dev/null 2>&1; then
        for ip in $(hostname -I); do
            case "$ip" in
                100.*)              echo "      $ip (Tailscale - use this across the internet)" ;;
                192.168.*|10.*)     echo "      $ip (LAN - same house/Wi-Fi)" ;;
                *)                  echo "      $ip" ;;
            esac
        done
    else
        echo "      (couldn't list IPs - run 'ip addr' and look for 192.168.x.x / 100.x.y.z)"
    fi
    echo
    printf '\033[36mHOST checklist:\033[0m\n'
    echo "  [1] Same network: give your partner the LAN address above (192.168.x / 10.x)."
    echo "      Different networks: use the Tailscale 100.x address instead."
    printf '  [2] Inbound UDP 7777 on this PC: '
    if command -v ufw >/dev/null 2>&1; then
        UFW_OUT="$(ufw status 2>/dev/null || true)"
        if printf '%s' "$UFW_OUT" | grep -qi 'inactive'; then
            echo "OK (ufw is inactive - nothing blocks)"
        elif printf '%s' "$UFW_OUT" | grep -q '7777'; then
            echo "OK (ufw rule found)"
        elif [[ -z "$UFW_OUT" ]]; then
            echo "unknown (reading ufw needs sudo)"
            echo "      If ufw is enabled, allow the port:  sudo ufw allow 7777/udp"
        else
            echo "MISSING - run:  sudo ufw allow 7777/udp"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q '7777/udp'; then
            echo "OK (firewalld rule found)"
        else
            echo "check firewalld - run:  sudo firewall-cmd --add-port=7777/udp"
        fi
    else
        echo "OK (no ufw/firewalld detected - likely nothing blocks)"
    fi
    echo "  [3] After pressing F7 in-game, confirm the server is actually listening:"
    echo "        ss -uln | grep 7777"
    echo "  [4] Your partner (the guest) needs NO firewall changes on their side -"
    echo "      outbound connections and their replies are allowed automatically."
elif [[ "$ROLE" == "guest" ]]; then
    printf '\033[36mThis PC is the GUEST. Your play steps:\033[0m\n'
    echo "  1. Launch the game; wait for the UE4SS console window to print"
    echo "     '[AincradTogether] ... loaded.'"
    echo "  2. Load into the game world."
    echo "  3. WAIT until the host says they've pressed F7, then press F8."
    if [[ -n "$HOST_IP" ]]; then
        echo "     You'll connect to: $HOST_IP (already saved in config.lua)"
    else
        echo "     No host IP saved yet - re-run this installer when you have it, or"
        echo "     type it in-game in the console (F10):  coop_join <the-hosts-ip>"
    fi
    echo "  No firewall changes are needed on this PC - guests connect outbound,"
    echo "  which is allowed automatically. Only the HOST opens a port."
else
    echo "Then:"
    echo "  1. Launch the game. A UE4SS console window should appear and print"
    echo "     '[AincradTogether] ... loaded.'"
    echo "  2. HOST: load into the world, then press F7."
    echo "     (Hosting on Linux? Open UDP 7777 if you use a firewall, e.g."
    echo "      sudo ufw allow 7777/udp)"
    echo "  3. GUEST: put the host's IP in Scripts/config.lua (HostAddress),"
    echo "     start the game, then press F8."
fi
echo
echo "Playing over the internet? Read docs/CONNECTING.md (Tailscale is the easy way)."
echo "Something not working? Launch the game once, then run: ./tools/diagnose.sh"
