#!/usr/bin/env bash
# wt をインストールする。既定で ~/.local/bin/wt に配置する。
# 配置先を変えるには PREFIX を渡す: PREFIX=~/bin ./install.sh
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt"

mkdir -p "$PREFIX"
install -m 755 "$src" "$PREFIX/wt"
echo "[install] $PREFIX/wt に配置した"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "[install] 注意: $PREFIX が PATH に無い。シェルの設定に追加してください" ;;
esac
