#!/usr/bin/env bash
# Exports a debug build and pushes it to GorackLaptop for testing over the
# real network instead of running the project live off the Samba share
# (see memory: that was the whole "everything is slow" mystery). Debug
# export on purpose - keeps console prints/warnings visible for debugging.
#
# If the laptop's IP ever changes (DHCP), update LAPTOP_HOST below - find
# the new one on the laptop with `hostname -I`.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_HOST="dave@192.168.1.110"
LAPTOP_DIR="~/Sledge_2_build"
EXPORT_PRESET="Linux"

cd "$PROJECT_DIR"
mkdir -p binaries

echo "==> Exporting debug build..."
godot --headless --export-debug "$EXPORT_PRESET" "binaries/Sledge 2.x86_64"

echo "==> Pushing to $LAPTOP_HOST..."
rsync -av "binaries/" "$LAPTOP_HOST:$LAPTOP_DIR/"

echo "==> Setting executable permissions..."
# ~ has to stay OUTSIDE the quoted part here - quoting the whole path (as an
# earlier version of this script did) sends the ~ to the remote shell
# inside quotes, where it's treated as a literal character instead of
# expanding to the home directory, and chmod fails with "No such file".
ssh "$LAPTOP_HOST" "chmod +x $LAPTOP_DIR/'Sledge 2.x86_64' $LAPTOP_DIR/'Sledge 2.sh'"

echo "==> Done. On the laptop, run: $LAPTOP_DIR/\"Sledge 2.x86_64\""
