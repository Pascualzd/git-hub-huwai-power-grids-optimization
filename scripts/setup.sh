#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bash scripts/install_quarto.sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

