# Oʻahu Economic Dispatch

A reproducible economic-dispatch study of Hawaiʻi's largest island grid. It ports the
single-period, multi-period, merit-order, and duck-curve structure of Cornell BEE 4750/5750
to an auditable Oʻahu dataset built from Hawaiian Electric, EIA, EPA, and NREL sources.

The current baseline models 24 dispatchable resources (1,508.1 MW summer capacity) against
Hawaiian Electric's 8,760-hour 2021 base-scenario net-load profile. At the modeled 1,054.3 MW
annual peak, Waiau W8 is marginal at $134.48/MWh. A second track adds **network structure** — a
stylized 9-bus, two-corridor Oʻahu grid solved three ways (copper plate, transportation, and
DC optimal power flow); at peak, network congestion and loop flow add $5,839/h and $7,938/h
respectively, and the single island price splits into locational prices from $126 to $456/MWh.
The math is written up in [docs/DC_OPF_FORMULATION.md](docs/DC_OPF_FORMULATION.md), following the
assigned [Power Systems Optimization course manual](https://github.com/Power-Systems-Optimization-Course/power-systems-optimization/blob/master/Notebooks/06-Optimal-Power-Flow.ipynb)
and validated against its 3-bus example in `test/opf_reference_test.jl`. These are research
results, not a production unit-commitment, reliability, or emissions-inventory study.

## Optimal power flow, animated

A second teaching track in `OPT simple case/` builds the DC-OPF up from a 3-bus triangle to the
IEEE 14-bus test system, then to a ramp-constrained 24-hour dispatch. **Each model gets its own
animation**, and every frame is a HiGHS solution — nothing is hand-drawn or illustrative.

The visual grammar is the same throughout: the **background is the scalar potential** (voltage
phase angle, or price) interpolated into contour bands, because power does not choose a route —
it runs downhill. On top, **discrete carriers** are advected along each conductor, their spacing
set by `|flow|` and their speed by `|flow| / rateA`, so a corridor at its thermal limit visibly
runs hot and fast. The aesthetic is written up in
[docs/GRIDFLOW_PHILOSOPHY.md](docs/GRIDFLOW_PHILOSOPHY.md).

### Part 2 — the price of a full pipe (3-bus DC-OPF)

<p align="center">
  <img src="OPT%20simple%20case/figures/anim_part2_3bus.gif" alt="3-bus DC-OPF as load at bus 3 grows from 0 to 300 MW" width="440">
</p>

Load at bus 3 walks 0 → 300 MW. The cheap \$10/MWh generator at bus 1 serves everything until
**line 1-3 saturates at 230 MW of load**; from that moment the \$30/MWh generator at bus 2 is
forced on and the single system price splits into three locational prices. At full load the
answer is \$6,000/h with prices of **\$10 / \$30 / \$50 per MWh** — the load bus prices *above*
the most expensive running unit, which is the whole point of the exercise.

### Part 3 — the feasibility ceiling (IEEE 14-bus)

<p align="center">
  <img src="OPT%20simple%20case/figures/anim_part3_ieee14.gif" alt="IEEE 14-bus DC-OPF driven to its feasibility ceiling" width="420">
</p>

Demand climbs in 2% steps until the network genuinely runs out. The last frame is the **last
feasible state, located by bisection** rather than by a sweep that happened to stop: growth
**+52.01% → 393.7 MW at \$8,503/h**; one further increment of 0.01% has no feasible dispatch at
all. Installed generation is **772.4 MW**, so the copper gives out at roughly half the capacity
of the turbines.

Four corridors are binding at the ceiling — 2→5, 4→9, 6→13 and 7→9 — and the price consequence
is violent. Watch the spread sit pinned at a flat \$20/MWh while nothing binds, then tear apart
to **\$20 – \$382/MWh** as each corridor ignites in turn. That is congestion rent, not fuel
cost: the most expensive generator in the case runs at \$40/MWh.

### Part 4 — one ramp-constrained day

<p align="center">
  <img src="OPT%20simple%20case/figures/anim_part4_day.gif" alt="24-hour ramp-constrained dispatch on the 3-bus system" width="480">
</p>

Two generators, two demand shapes (a commercial bus and a residential bus), 24 hours solved as
one welded program. The cheap slow unit (\$10/MWh, 30 MW/h ramp) is pinned against its ramp
plate through the morning climb while the fast expensive unit (\$30/MWh) covers the difference.
Ignoring ramp limits understates the daily bill by **\$1,256 (1.43%)** and produces a dispatch
that violates the plate by 1.9×.

### Part 5 — the instrument itself

<p align="center">
  <img src="OPT%20simple%20case/figures/anim_part5_variations.gif" alt="One fixed DC-OPF solution re-rendered across the seed and parameter space" width="400">
</p>

Part 5 has no model of its own — it is the renderer. So its animation holds **one solved state
completely fixed** (the IEEE 14-bus ceiling: every flow, angle and price frozen, cost stuck at
\$8,503/h) and moves only what the optimisation leaves undetermined: the seed, carrier density,
contour band count, palette. Everything that changes on screen is representation; nothing that
changes on screen is physics.

### Interactive explorer

`viz/gridflow/index.html` is a self-contained p5.js instrument over the same solved states —
switch between all three networks, scrub demand or the hour of day, retune carrier density,
trail persistence, terrain relief and the palette, and step through seeds. Open the file
directly in a browser; no build step and no server required.

### Run it yourself

```bash
cd "OPT simple case"
julia "OPT part 2.jl"                    # 3-bus DC-OPF + static network graph
julia "OPT part 3 - IEEE 14 bus.jl"      # IEEE 14-bus, demand sweep, verification
julia "OPT part 4 - dynamic ramping.jl"  # multi-period dispatch with ramp limits
julia "OPT part 5 - animations.jl"       # all four GIFs + viz/gridflow/network.json
julia audit_animation_data.jl            # independent re-solve of every exported state
```

Parts 3 and 4 print their own verification block (energy balance, line limits, slack angle,
generator bounds, and a from-scratch Kirchhoff check at every bus). `audit_animation_data.jl`
goes further: it ignores the animation pipeline entirely, re-solves all 83 exported states from
the raw CSVs, and checks each one against a fresh solve **and** against physics that must hold
regardless of what any solver said — 744 assertions covering dispatch, flows, angles, prices,
cost identities, nodal balance recomputed from the exported numbers alone, thermal limits,
generator bounds, the DC flow identity `flow = baseMVA · sus · Δθ`, ramp limits, and the
feasibility-ceiling claim from both sides. Part 5 additionally needs `ffmpeg` on `PATH` for
clean GIF palettes; without it, it falls back to Julia's encoder.

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
bash scripts/python scripts/prepare_network.py
bash scripts/verify.sh
```

The raw downloads are intentionally gitignored. Their exact URLs, vintages, hashes,
transformations, and limitations are recorded in [SOURCES.md](SOURCES.md).

## Repository map

- `data/processed/` — committed model inputs and outputs
- `scripts/` — repeatable acquisition, preparation, validation, rendering, and setup
- `src/EconomicDispatch.jl` — the copper-plate single- and multi-period formulations and sanity checks
- `src/NetworkDispatch.jl` — the copper-plate, transportation, and DC-OPF network formulations
- `src/run_analysis.jl` — scenario runner and all generated figures
- `slides/` — Quarto revealjs source and rendered deck
- `figures/` — code-generated analysis graphics
- `viz/` — interactive, zoomable TypeScript/Cytoscape.js network explorer (see `viz/README.md`)
- `viz/gridflow/` — self-contained p5.js optimal-power-flow instrument (`index.html`) over the
  solved states exported to `network.json`
- `OPT simple case/` — the DC-OPF teaching track: 3-bus, IEEE 14-bus, and the ramp-constrained
  day, plus `gridviz.jl` (static network graphs), `gridanim.jl` (the animated renderer), and
  `audit_animation_data.jl` (independent re-solve of every exported state)
- `OPT simple case/ieee14/` — MATPOWER `case14` transcribed into this project's four-table schema
- `docs/DC_OPF_FORMULATION.md` — the network optimization problem stated mathematically
- `docs/DYNAMIC_DISPATCH_FORMULATION.md` — the multi-period problem with ramp limits and
  time-varying nodal demand, stated mathematically
- `docs/GRIDFLOW_PHILOSOPHY.md` — the generative-visualization aesthetic behind the animations
- `test/opf_reference_test.jl` — reproduces the course manual's 3-bus example to validate the solver
- `DATA_SOURCES.md` — source-to-parameter map
- `SOURCES.md` — exact provenance ledger and modeling boundaries

## Scope boundaries

- Renewables and customer batteries are represented through HECO's filed net-load layers;
  they are not separately dispatched.
- The fleet excludes airport emergency units and refinery self-generation.
- Kalaeloa's two combustion turbines and steam component are one combined-cycle resource.
- Public current workbooks do not expose unit-level minimum stable output or hourly ramp
  rates. Every such input is marked as an assumption in `oahu_generators.csv`.
- The LP has no binary commitment, start cost, minimum up/down time, reserve, outage, or
  storage state-of-charge constraints.
- The network is a stylized 9-bus, two-corridor model (`docs/DC_OPF_FORMULATION.md`), not
  Hawaiian Electric's real topology; DC-OPF is lossless and omits reactive power, voltage
  limits, and N-1 security. Every line parameter is a labeled assumption.

The original implementation brief remains in [PROJECT_PLAN.md](PROJECT_PLAN.md); the
[current course lecture](https://envsys.viveks.me/fall2025/slides/lecture10-2-economic-dispatch.html)
provides the textbook comparison used in the deck.
