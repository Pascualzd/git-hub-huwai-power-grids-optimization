# Oʻahu Economic Dispatch

A reproducible economic-dispatch study of Hawaiʻi's largest island grid. It ports the
single-period, multi-period, merit-order, and duck-curve structure of Cornell BEE 4750/5750
to an auditable Oʻahu dataset built from Hawaiian Electric, EIA, EPA, and NREL sources.

The current baseline models 24 dispatchable resources (1,508.1 MW summer capacity) against
Hawaiian Electric's 8,760-hour 2021 base-scenario net-load profile. At the modeled 1,054.3 MW
annual peak, Waiau W8 is marginal at $134.48/MWh. These are research results, not a production
unit-commitment, reliability, or emissions-inventory study.

## Reproduce the project

From the repository root:

```bash
bash scripts/setup.sh
bash scripts/verify.sh
```

`setup.sh` installs a pinned, repository-local Quarto 1.10.18 and instantiates the Julia
environment. `verify.sh` validates the committed processed inputs, solves both models with
JuMP + HiGHS, regenerates every figure, and renders `slides/_site/index.html`.

To rebuild the processed data from the large public raw files:

```bash
bash scripts/python scripts/download_data.py
bash scripts/python scripts/prepare_load.py
bash scripts/python scripts/prepare_generators.py
bash scripts/verify.sh
```

The raw downloads are intentionally gitignored. Their exact URLs, vintages, hashes,
transformations, and limitations are recorded in [SOURCES.md](SOURCES.md).

## Repository map

- `data/processed/` — committed model inputs and outputs
- `scripts/` — repeatable acquisition, preparation, validation, rendering, and setup
- `src/EconomicDispatch.jl` — the two optimization formulations and sanity checks
- `src/run_analysis.jl` — scenario runner and all generated figures
- `slides/` — Quarto revealjs source and rendered deck
- `figures/` — code-generated analysis graphics
- `DATA_SOURCES.md` — source-to-parameter map
- `SOURCES.md` — exact provenance ledger and modeling boundaries

## Scope boundaries

- Renewables and customer batteries are represented through HECO's filed net-load layers;
  they are not separately dispatched.
- The fleet excludes airport emergency units and refinery self-generation.
- Kalaeloa's two combustion turbines and steam component are one combined-cycle resource.
- Public current workbooks do not expose unit-level minimum stable output or hourly ramp
  rates. Every such input is marked as an assumption in `oahu_generators.csv`.
- The LP has no binary commitment, start cost, minimum up/down time, reserve, outage, network,
  or storage state-of-charge constraints.

The original implementation brief remains in [PROJECT_PLAN.md](PROJECT_PLAN.md); the
[current course lecture](https://envsys.viveks.me/fall2025/slides/lecture10-2-economic-dispatch.html)
provides the textbook comparison used in the deck.
