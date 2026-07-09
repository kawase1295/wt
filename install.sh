#!/usr/bin/env bash
# Install wt. Defaults to ~/.local/bin/wt.
# To change the location: PREFIX=~/bin ./install.sh
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt"

mkdir -p "$PREFIX"
install -m 755 "$src" "$PREFIX/wt"
echo "[install] installed to $PREFIX/wt"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "[install] warning: $PREFIX is not in PATH. Add it to your shell config." ;;
esac
