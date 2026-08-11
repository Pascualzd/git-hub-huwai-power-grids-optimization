#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. src/run_analysis.jl
bash scripts/render_slides.sh

