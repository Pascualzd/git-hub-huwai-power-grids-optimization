#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

julia --project=. -e 'using Pkg; Pkg.instantiate()'
bash scripts/python scripts/validate_data.py
julia --project=. test/opf_reference_test.jl
bash scripts/render_slides.sh
bash scripts/python scripts/export_viz_data.py
