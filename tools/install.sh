#!/usr/bin/env bash
# ============================================================================
# AincradTogether installer for Linux (Steam + Proton)
#
# The game is Windows-only, so on Linux it runs through Proton — and UE4SS
# injects into it the same way it does on Windows. This script installs
# UE4SS + the mod into your Steam copy of Echoes of Aincrad (demo or full).
#
#   ./tools/install.sh                        # auto-detect the game
#   ./tools/install.sh --experimental         # use UE4SS experimental build
#                                             # (needed while the game's UE5
#                                             # version is newer than the
#                                             # stable UE4SS release)
#   ./tools/install.sh --game-path <folder>   # point at the game manually
#   ./tools/install.sh --zip <UE4SS_vX.zip>   # use a pre-downloaded UE4SS
#   ./tools/install.sh --skip-ue4ss           # only (re)install the mod
#   ./tools/install.sh --engine-version 5.6   # force the UE version instead
#                                             # of reading it from the exe
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-path) GAME_PATH="$2"; shift 2 ;;
        --zip)       UE4SS_ZIP="$2"; shift 2 ;;
        --skip-ue4ss) SKIP_UE4SS=1; shift ;;
        --experimental) EXPERIMENTAL=1; shift ;;
        --engine-version) FORCED_ENGINE_VERSION="$2"; shift 2 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

if [[ -n "$FORCED_ENGINE_VERSION" ]] && ! [[ "$FORCED_ENGINE_VERSION" =~ ^5\.[0-9]+$ ]]; then
    printf 'ERROR: --engine-version must look like "5.6" (major.minor, no patch digit)\n' >&2
    exit 1
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
        warn "Could not find a UE version string in the exe (this can happen with DRM)."
        warn "Re-run with an explicit version once you know it, e.g.: --engine-version 5.6"
        warn "(Find it on the game's PCGamingWiki/SteamDB page, or ask in the modding community.)"
    fi
else
    warn "python3 not found - skipping engine version detection."
    warn "You can pass the version yourself instead: --engine-version 5.6"
fi

# ----------------------------------------------------------------------------
# 3. Install UE4SS
# ----------------------------------------------------------------------------
if [[ "$SKIP_UE4SS" -eq 0 ]]; then
    if [[ "$EXPERIMENTAL" -eq 1 ]]; then
        step "Installing UE4SS (EXPERIMENTAL build - newest engine support)..."
    else
        step "Installing UE4SS (the mod loader)..."
    fi
    ZIP_TO_EXTRACT="$UE4SS_ZIP"
    if [[ -z "$ZIP_TO_EXTRACT" ]]; then
        ok "Downloading UE4SS from GitHub..."
        ASSET_URL=""
        if [[ "$EXPERIMENTAL" -eq 1 ]]; then
            RELEASES_JSON="$(curl -fsSL -H "$UA" 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases?per_page=30')"
            if command -v python3 >/dev/null; then
                ASSET_URL="$(printf '%s' "$RELEASES_JSON" | python3 -c '
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
                # Fallback: experimental release tags contain "experimental"
                # in the download URL path.
                ASSET_URL="$(printf '%s' "$RELEASES_JSON" \
                    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
                    | cut -d'"' -f4 \
                    | grep -i 'experimental' \
                    | grep -E '/UE4SS[^/]*\.zip$' \
                    | grep -viE 'dev' \
                    | head -n 1)"
            fi
        else
            API_JSON="$(curl -fsSL -H "$UA" \
                https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest)"
            ASSET_URL="$(printf '%s' "$API_JSON" \
                | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | cut -d'"' -f4 \
                | grep -E '/UE4SS_v[^/]*\.zip$' \
                | grep -viE 'dev' \
                | head -n 1)"
        fi
        [[ -n "$ASSET_URL" ]] || die "Could not find a UE4SS zip on GitHub. Download one manually from https://github.com/UE4SS-RE/RE-UE4SS/releases and re-run with --zip <file>"
        ZIP_TO_EXTRACT="$(mktemp -d)/$(basename "$ASSET_URL")"
        curl -fL -H "$UA" -o "$ZIP_TO_EXTRACT" "$ASSET_URL"
        ok "Downloaded $(basename "$ZIP_TO_EXTRACT")"
    fi
    [[ -f "$ZIP_TO_EXTRACT" ]] || die "UE4SS zip not found: $ZIP_TO_EXTRACT"
    unzip -o -q "$ZIP_TO_EXTRACT" -d "$WIN64_DIR"
    ok "UE4SS extracted next to the game executable."
else
    step "Skipping UE4SS install (as requested)."
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
[[ -n "$SAVED_CONFIG" ]] && cp "$SAVED_CONFIG" "$MOD_TARGET/Scripts/config.lua"
ok "Mod files copied to $MOD_TARGET"

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
echo "Then:"
echo "  1. Launch the game. A UE4SS console window should appear and print"
echo "     '[AincradTogether] ... loaded.'"
echo "  2. HOST: load into the world, then press F7."
echo "     (Hosting on Linux? Open UDP 7777 if you use a firewall, e.g."
echo "      sudo ufw allow 7777/udp)"
echo "  3. JOINER: put the host's IP in Scripts/config.lua (HostAddress),"
echo "     start the game, then press F8."
echo
echo "Playing over the internet? Read docs/CONNECTING.md (Tailscale is the easy way)."
echo "Something not working? Launch the game once, then run: ./tools/diagnose.sh"
