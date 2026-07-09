#!/usr/bin/env bash
# ============================================================================
# AincradTogether doctor for Linux (Steam + Proton)
#
# Read-only: checks every link in the chain that gets the mod from disk into
# the running game, and prints a PASS/FAIL report with a verdict at the end.
# Run it after launching the game at least once, and paste the whole output
# when asking for help.
#
#   ./tools/diagnose.sh
#   ./tools/diagnose.sh --game-path "<game folder>"
# ============================================================================

set -uo pipefail   # no -e on purpose: keep going and report everything

GAME_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-path) GAME_PATH="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

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
    pass "UE4SS-settings.ini present"
    for key in ConsoleEnabled GuiConsoleEnabled GuiConsoleVisible GraphicsAPI; do
        line="$(grep -E "^${key}[[:space:]]*=" "$SETTINGS_INI" | head -n 1 | tr -d '\r')"
        info "  settings: ${line:-$key not found in ini}"
    done
else
    fail "UE4SS-settings.ini not found in $UE4SS_DIR"
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
