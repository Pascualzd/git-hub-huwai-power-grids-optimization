#!/usr/bin/env bash
set -euo pipefail

QUARTO_VERSION="1.10.18"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUARTO_ROOT="$REPO_ROOT/.tools/quarto-$QUARTO_VERSION"
QUARTO_LINK="$REPO_ROOT/.tools/quarto"
ARCHIVE="$REPO_ROOT/.tools/quarto-$QUARTO_VERSION-macos.tar.gz"

if [[ -x "$QUARTO_LINK/bin/quarto" ]]; then
  exit 0
fi

mkdir -p "$REPO_ROOT/.tools"
curl --fail --location --retry 3 \
  "https://github.com/quarto-dev/quarto-cli/releases/download/v$QUARTO_VERSION/quarto-$QUARTO_VERSION-macos.tar.gz" \
  --output "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$REPO_ROOT/.tools"
ln -sfn "$QUARTO_ROOT" "$QUARTO_LINK"
rm "$ARCHIVE"

