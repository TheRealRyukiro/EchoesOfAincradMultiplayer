#!/usr/bin/env bash
# ============================================================================
# AincradTogether doctor for Linux (Steam + Proton)
#
# Checks every link in the chain that gets the mod from disk into the
# running game, and prints a PASS/FAIL report with a verdict at the end.
# Run it after launching the game at least once, and paste the whole output
# when asking for help.
#
#   ./tools/diagnose.sh
#   ./tools/diagnose.sh --game-path "<game folder>"
#
# Read-only by default. The one exception is an explicit repair flag that
# writes the engine version into UE4SS-settings.ini ([EngineVersionOverride])
# on an EXISTING install, without reinstalling anything:
#
#   ./tools/diagnose.sh --set-engine-version auto   # version read from the exe
#   ./tools/diagnose.sh --set-engine-version 5.6    # version you provide
# ============================================================================

set -uo pipefail   # no -e on purpose: keep going and report everything

GAME_PATH=""
SET_ENGINE_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-path) GAME_PATH="$2"; shift 2 ;;
        --set-engine-version) SET_ENGINE_VERSION="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

if [[ -n "$SET_ENGINE_VERSION" && "$SET_ENGINE_VERSION" != "auto" ]] \
        && ! [[ "$SET_ENGINE_VERSION" =~ ^5\.[0-9]+$ ]]; then
    echo "ERROR: --set-engine-version takes 'auto' or a version like '5.6' (major.minor, no patch digit)"
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
VERDICT=""

pass() { printf '\033[32m[PASS]\033[0m %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { printf '\033[36m[info]\033[0m %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }

echo "=== AincradTogether diagnostics ==="
echo

# ----------------------------------------------------------------------------
# 1. Find the game (same search as install.sh)
# ----------------------------------------------------------------------------
find_steam_libraries() {
    local roots=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "$HOME/snap/steam/common/.local/share/Steam"
    )
    local root vdf
    for root in "${roots[@]}"; do
        [[ -d "$root/steamapps" ]] && echo "$root/steamapps"
        vdf="$root/steamapps/libraryfolders.vdf"
        if [[ -f "$vdf" ]]; then
            grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" \
                | sed -E 's/"path"[[:space:]]+"([^"]+)"/\1/' \
                | while read -r lib; do
                      [[ -d "$lib/steamapps" ]] && echo "$lib/steamapps"
                  done
        fi
    done | sort -u
}

GAME_ROOT=""
STEAMAPPS_DIR=""
if [[ -n "$GAME_PATH" ]]; then
    GAME_ROOT="$GAME_PATH"
else
    while IFS= read -r steamapps; do
        for candidate in "$steamapps"/common/*Aincrad*; do
            if [[ -d "$candidate" ]]; then
                GAME_ROOT="$candidate"
                STEAMAPPS_DIR="$steamapps"
                break 2
            fi
        done
    done < <(find_steam_libraries)
fi

if [[ -z "$GAME_ROOT" || ! -d "$GAME_ROOT" ]]; then
    fail "Could not find the game folder. Re-run with --game-path \"<folder>\""
    exit 1
fi
pass "Game folder: $GAME_ROOT"

SHIPPING_EXE="$(find "$GAME_ROOT" -name '*-Win64-Shipping.exe' -type f 2>/dev/null | head -n 1)"
if [[ -z "$SHIPPING_EXE" ]]; then
    fail "No *-Win64-Shipping.exe under the game folder."
    exit 1
fi
WIN64_DIR="$(dirname "$SHIPPING_EXE")"
pass "Shipping exe: $SHIPPING_EXE"

# Engine version straight from the binary - the key fact when UE4SS's own
# detection fails.
if command -v python3 >/dev/null; then
    ENGINE_VERSION="$(python3 - "$SHIPPING_EXE" <<'PYEOF' 2>/dev/null || true
import re
import sys

path = sys.argv[1]
CHUNK = 32 * 1024 * 1024
OVERLAP = 128
PATTERNS = [
    re.compile(rb'\+\+UE5\+Release-(5\.[0-9]{1,2})'),
    re.compile(rb'\+\x00\+\x00U\x00E\x005\x00\+\x00R\x00e\x00l\x00e\x00a\x00s\x00e\x00-\x00(5\x00\.\x00[0-9]\x00(?:[0-9]\x00)?)'),
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
                found.add(match.group(1).replace(b'\x00', b'').decode('ascii', 'ignore'))
        tail = data[-OVERLAP:]

def minor(v):
    try:
        return int(v.split('.')[1])
    except (IndexError, ValueError):
        return -1

candidates = sorted(found, key=minor)
print(candidates[-1] if candidates else '')
PYEOF
)"
    if [[ -n "${ENGINE_VERSION:-}" ]]; then
        info "Game's Unreal Engine version (from exe): $ENGINE_VERSION"
    else
        info "Could not read a UE version string from the exe."
    fi
fi

# ----------------------------------------------------------------------------
# 2. UE4SS files on disk
# ----------------------------------------------------------------------------
UE4SS_DIR="$WIN64_DIR/ue4ss"
[[ -d "$UE4SS_DIR" ]] || UE4SS_DIR="$WIN64_DIR"

PROXY_DLL=""
if [[ -f "$WIN64_DIR/dwmapi.dll" ]]; then
    PROXY_DLL="dwmapi"
    pass "UE4SS proxy DLL present: dwmapi.dll"
elif [[ -f "$WIN64_DIR/xinput1_3.dll" ]]; then
    PROXY_DLL="xinput1_3"
    pass "UE4SS proxy DLL present: xinput1_3.dll"
else
    fail "No UE4SS proxy DLL (dwmapi.dll / xinput1_3.dll) next to the shipping exe."
    note "Re-run tools/install.sh."
fi

if [[ -f "$UE4SS_DIR/UE4SS.dll" || -f "$WIN64_DIR/UE4SS.dll" ]]; then
    pass "UE4SS.dll present"
else
    fail "UE4SS.dll missing - the UE4SS zip did not extract correctly. Re-run tools/install.sh."
fi

SETTINGS_INI="$UE4SS_DIR/UE4SS-settings.ini"
if [[ -f "$SETTINGS_INI" ]]; then
    pass "Settings file: $SETTINGS_INI"
    for key in ConsoleEnabled GuiConsoleEnabled GuiConsoleVisible GraphicsAPI; do
        line="$(grep -E "^${key}[[:space:]]*=" "$SETTINGS_INI" | head -n 1 | tr -d '\r')"
        info "  settings: ${line:-$key not found in ini}"
    done

    # Current engine override - the thing UE4SS falls back on when it cannot
    # detect the engine version itself.
    MAJOR_LINE="$(grep -E '^MajorVersion[[:space:]]*=' "$SETTINGS_INI" | head -n 1 | tr -d '\r')"
    MINOR_LINE="$(grep -E '^MinorVersion[[:space:]]*=' "$SETTINGS_INI" | head -n 1 | tr -d '\r')"
    if [[ -n "$MAJOR_LINE" || -n "$MINOR_LINE" ]]; then
        info "  [EngineVersionOverride]: ${MAJOR_LINE:-MajorVersion unset} | ${MINOR_LINE:-MinorVersion unset}"
    else
        info "  [EngineVersionOverride]: section not present"
    fi

    # Explicit repair mode: write the override in place.
    if [[ -n "$SET_ENGINE_VERSION" ]]; then
        TARGET_VERSION="$SET_ENGINE_VERSION"
        if [[ "$TARGET_VERSION" == "auto" ]]; then
            TARGET_VERSION="${ENGINE_VERSION:-}"
            if [[ -z "$TARGET_VERSION" ]]; then
                fail "--set-engine-version auto: could not read a version from the exe."
                note "Pass it explicitly instead, e.g.: --set-engine-version 5.6"
                exit 1
            fi
        fi
        MINOR="${TARGET_VERSION#5.}"
        if grep -qE '^MajorVersion' "$SETTINGS_INI"; then
            sed -i -E 's/^MajorVersion[[:space:]]*=.*/MajorVersion = 5/' "$SETTINGS_INI"
            sed -i -E "s/^MinorVersion[[:space:]]*=.*/MinorVersion = $MINOR/" "$SETTINGS_INI"
        else
            printf '\n[EngineVersionOverride]\nMajorVersion = 5\nMinorVersion = %s\n' "$MINOR" >> "$SETTINGS_INI"
        fi
        pass "WROTE engine override: UE 5.$MINOR -> $SETTINGS_INI"
        note "Launch the game again; UE4SS will use this instead of scanning for the version."
    fi
else
    fail "UE4SS-settings.ini not found in $UE4SS_DIR"
    if [[ -n "$SET_ENGINE_VERSION" ]]; then
        note "--set-engine-version needs an existing UE4SS install; run tools/install.sh first."
    fi
fi

# ----------------------------------------------------------------------------
# 3. Mod files
# ----------------------------------------------------------------------------
MODS_DIR="$UE4SS_DIR/Mods"
MOD_DIR="$MODS_DIR/AincradTogether"
if [[ -f "$MOD_DIR/Scripts/main.lua" ]]; then
    pass "Mod script present: $MOD_DIR/Scripts/main.lua"
else
    fail "Mod script missing at $MOD_DIR/Scripts/main.lua - re-run tools/install.sh."
fi
if [[ -f "$MOD_DIR/enabled.txt" ]]; then
    pass "enabled.txt present"
else
    fail "enabled.txt missing in $MOD_DIR"
fi
if [[ -f "$MODS_DIR/mods.txt" ]] && grep -q 'AincradTogether' "$MODS_DIR/mods.txt"; then
    pass "Registered in mods.txt"
else
    info "Not listed in mods.txt (fine - enabled.txt is enough on UE4SS 3.x)"
fi

# ----------------------------------------------------------------------------
# 4. Steam launch options (best effort - VDF parsing from bash is fuzzy)
# ----------------------------------------------------------------------------
APPID=""
if [[ -n "$STEAMAPPS_DIR" ]]; then
    INSTALL_DIR_NAME="$(basename "$GAME_ROOT")"
    for manifest in "$STEAMAPPS_DIR"/appmanifest_*.acf; do
        [[ -f "$manifest" ]] || continue
        if grep -q "\"installdir\"[[:space:]]*\"$INSTALL_DIR_NAME\"" "$manifest"; then
            APPID="$(basename "$manifest" | sed -E 's/appmanifest_([0-9]+)\.acf/\1/')"
            break
        fi
    done
fi

LAUNCH_OPTS=""
if [[ -n "$APPID" ]]; then
    info "Steam AppID: $APPID"
    for lc in "$HOME/.local/share/Steam/userdata"/*/config/localconfig.vdf \
              "$HOME/.steam/steam/userdata"/*/config/localconfig.vdf \
              "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata"/*/config/localconfig.vdf; do
        [[ -f "$lc" ]] || continue
        # The app's block in localconfig.vdf is small; look a bit below the appid.
        found="$(grep -A40 "\"$APPID\"" "$lc" | grep -m1 '"LaunchOptions"' || true)"
        if [[ -n "$found" ]]; then LAUNCH_OPTS="$found"; break; fi
    done
fi

if [[ -n "$LAUNCH_OPTS" ]] && printf '%s' "$LAUNCH_OPTS" | grep -q 'WINEDLLOVERRIDES'; then
    if [[ -n "$PROXY_DLL" ]] && printf '%s' "$LAUNCH_OPTS" | grep -q "$PROXY_DLL"; then
        pass "Steam launch options contain WINEDLLOVERRIDES for $PROXY_DLL"
    else
        fail "Launch options have WINEDLLOVERRIDES but not for '$PROXY_DLL' - it must match the proxy DLL."
        note "found: $LAUNCH_OPTS"
    fi
elif [[ -n "$LAUNCH_OPTS" ]]; then
    fail "Steam launch options found, but no WINEDLLOVERRIDES in them."
    note "found: $LAUNCH_OPTS"
    note "Set:   WINEDLLOVERRIDES=\"$PROXY_DLL=n,b\" %command%"
else
    info "Could not read launch options from Steam's config (this check is best-effort)."
    note "Verify by hand: Steam -> right-click the game -> Properties -> Launch Options must be:"
    note "  WINEDLLOVERRIDES=\"${PROXY_DLL:-dwmapi}=n,b\" %command%"
fi

# ----------------------------------------------------------------------------
# 5. The source of truth: UE4SS.log (written every time UE4SS actually runs)
# ----------------------------------------------------------------------------
UE4SS_LOG=""
for cand in "$UE4SS_DIR/UE4SS.log" "$WIN64_DIR/UE4SS.log"; do
    [[ -f "$cand" ]] && UE4SS_LOG="$cand" && break
done

echo
if [[ -z "$UE4SS_LOG" ]]; then
    fail "No UE4SS.log found. UE4SS has NEVER run inside the game."
    VERDICT="UE4SS is not being injected. 99% cause: the WINEDLLOVERRIDES launch option is
missing or misspelled (check exact quoting, and that the DLL name matches
'${PROXY_DLL:-dwmapi}'). Set it, launch the game once, and re-run this script -
this FAIL should turn into a log file."
else
    pass "UE4SS.log exists: $UE4SS_LOG"
    info "log modified: $(date -r "$UE4SS_LOG" 2>/dev/null || echo unknown)"

    if grep -qi 'AincradTogether' "$UE4SS_LOG"; then
        pass "Mod banner found in the log - AincradTogether IS loading."
        echo
        info "AincradTogether lines from the log:"
        grep -i 'AincradTogether' "$UE4SS_LOG" | tail -n 20 | sed 's/^/       /'
        VERDICT="UE4SS and the mod are loading. If F7 does nothing: (1) the game window must
have focus when you press it; (2) you must be loaded INTO the world, not the
main menu; (3) bypass keybinds entirely by opening the UE4SS console window's
Lua tab or the in-game console (~ or F10 area keys) and running: coop_host
If the UE4SS console window never appears but the log exists, the GUI can't
draw under this Proton setup - the mod still works; check the log for its
messages after pressing F7."
    elif grep -qE 'PS scan timed out|\[PS\] Scan failed|Failed to find GUObjectArray|Failed to find EngineVersion' "$UE4SS_LOG"; then
        fail "UE4SS runs, but its pattern scan cannot fingerprint this game's engine build."
        note "(log shows 'Scan failed' / 'PS scan timed out' - UE4SS gives up before running any mods)"
        VERDICT="This UE4SS build is older than the game's Unreal Engine version, so it cannot
find the engine internals it needs (GUObjectArray/EngineVersion). Fix:

    ./tools/install.sh --experimental

That installs the UE4SS experimental build (signatures for the newest UE5
versions) and writes the game's engine version - read out of the exe - into
UE4SS-settings.ini as an override. Then launch again and re-run this script.

To ONLY write the version override into the current install (no reinstall):

    ./tools/diagnose.sh --set-engine-version auto

If the experimental build still logs 'Failed to find GUObjectArray', the game
needs a custom signature (UE4SS_Signatures/GUObjectArray.lua) - paste this
output when asking for help and check the game's modding community, which
usually publishes one within days of release."
    else
        fail "UE4SS runs, but the mod banner is NOT in the log."
        echo
        info "Lua-related errors in the log (if any):"
        grep -iE 'lua|mod' "$UE4SS_LOG" | grep -iE 'error|fail|exception|no such' | tail -n 15 | sed 's/^/       /'
        VERDICT="UE4SS injects fine but is not loading the mod. Check for a doubled folder
(Mods/AincradTogether/AincradTogether), confirm Scripts/main.lua exists, and
look at the error lines above - a config.lua typo or an old UE4SS that lacks
some API will show there. Paste this whole output when asking for help."
    fi
    echo
    info "Last 10 lines of UE4SS.log:"
    tail -n 10 "$UE4SS_LOG" | sed 's/^/       /'
fi

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
echo
echo "=== Result: $PASS_COUNT passed, $FAIL_COUNT failed ==="
echo
printf '%s\n' "$VERDICT"
