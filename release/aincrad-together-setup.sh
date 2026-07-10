#!/usr/bin/env bash
# ============================================================================
# AincradTogether one-file setup (Linux / Steam Deck)
#
# Download this file ONCE. Every time you run it, it checks GitHub for the
# newest AincradTogether version, downloads it, and walks you through the
# whole install - game detection, the UE4SS mod loader, host/guest setup.
# Nothing else to download, no options to remember:
#
#     bash aincrad-together-setup.sh
#
# Requires: curl, tar, unzip (all standard on desktop Linux).
# ============================================================================

set -euo pipefail

REPO="TheRealRyukiro/EchoesOfAincradMultiplayer"
UA='User-Agent: AincradTogether-setup'

command -v curl >/dev/null || { echo "ERROR: curl is required"; exit 1; }
command -v tar  >/dev/null || { echo "ERROR: tar is required"; exit 1; }

printf '\033[36m==> Checking the latest AincradTogether version...\033[0m\n'
TAG="$(curl -fsSL -H "$UA" "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4 || true)"

if [[ -n "$TAG" ]]; then
    URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
    printf '    Latest release: %s\n' "$TAG"
else
    URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
    printf '    No tagged release found - using the latest development version.\n'
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '\033[36m==> Downloading...\033[0m\n'
curl -fL -H "$UA" "$URL" | tar -xz -C "$TMP"

INSTALLER="$(find "$TMP" -maxdepth 3 -path '*/tools/install.sh' -type f | head -n 1)"
[[ -n "$INSTALLER" ]] || { echo "ERROR: download looks broken (no tools/install.sh inside)"; exit 1; }

printf '\033[36m==> Starting the guided installer...\033[0m\n'
echo
bash "$INSTALLER"
