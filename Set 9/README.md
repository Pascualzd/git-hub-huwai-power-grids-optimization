# Set 9 — Chronological dispatch under generator operating constraints

Set 8 asked whether the assumed demand distribution decides the computed
risk. It does. Set 9 asks the obvious follow-up: **does that finding survive
when the generators are modelled as real machines instead of dials?**

## What changed from Set 8

Set 8's dispatch model constrained generators with one line:

```julia
0 <= P[g] <= pmax[g]
```

A 128 MW steam unit could idle at 3 MW, jump to full output in an hour, and
start and stop every hour at no cost. Set 9 adds what real machines do:

| Constraint | Meaning | Source |
|---|---|---|
| Minimum stable generation | a committed unit must produce at least `p_min` | `oahu_generators.csv`, column `p_min_mw` |
| Ramp limits | output moves at most `ramp` MW between hours | `oahu_generators.csv`, column `ramp_mw_per_hr` |
| Minimum up / down time | once started it must run a while; once stopped it must stay down | **assumed here** — `fleet.jl` |
| Start-up cost | starting a cold unit costs money | **assumed here** — `fleet.jl` |

**The first two were already in the repository.** `oahu_generators.csv` has
carried `p_min_mw` and `ramp_mw_per_hr` since the data was assembled; Set 8's
`cases.jl` simply read only `p_max_mw` and `varcost_usd_per_mwh`. No new data
was collected for Set 9 — we stopped discarding two columns.

## Why this required rebuilding the experiment, not patching it

Ramp limits couple hour *t* to hour *t−1*. Minimum up/down times couple a
decision to the hours after it. Set 8 sampled hours **independently, with
replacement** — hour 5,000 could follow hour 12 — so there was no "previous
hour" for a ramp constraint to attach to.

Set 9 therefore walks sequences **in order**, solving 24-hour blocks and
carrying commitment state across the boundary. That is a different
experimental design, which is why Set 9 generates all of its own numbers and
does not reuse any of Set 8's.

## The design

Two demand worlds, each an 8,760-hour sequence, crossed with a four-rung
constraint ladder. Every cell is solved fresh.

**Worlds**

| | Magnitude | Direction | Provenance |
|---|---|---|---|
| `REAL` | filed 2021 planning profile | **frozen** sector-weighted shares (v2) | island total is filed; the split is reconstructed — see `DATA_REBUILD.md` |
| `EXPO` | `Exp(1)` per bus per hour | moves freely | scaled so the island mean **equals the real record's mean** |

Same mean by construction. The only thing being compared is shape.

**Ladder**

| Rung | Adds |
|---|---|
| `:lp` | nothing — Set 8's constraint set, as a control |
| `:pmin` | binary commitment + minimum stable generation |
| `:ramp` | hour-to-hour ramp limits |
| `:full` | minimum up/down times + start-up costs |

Each rung changes exactly one thing, so every movement in the results is
attributable. This is the same discipline Set 8's own finding argues for.

## Files

| File | Role |
|---|---|
| `fleet.jl` | the case loader, reading the two columns Set 8 ignored; all assumed parameters are declared here and nowhere else |
| `commitment.jl` | the MILP — commitment, `p_min`, ramping, min up/down, DC network |
| `run_set9.jl` | the 2 × 4 experiment grid, and the reporting |
| `prepare_demand.py` | v2 — the static per-bus rebuild, self-downloading |
| `prepare_hourly_demand.py` | v3 — the hourly per-bus rebuild, self-downloading |
| `compare_shares.jl` | the ladder under v1 vs v2, everything else held fixed |
| `run_hourly.jl` | the ladder under v1 vs v2 vs v3 |
| `DATA_REBUILD.md` | what the rebuild did, with sources and limitations |
| `data/` | the rebuilt shares and the 9 × 8,760 demand matrix |
| `results/` | generated CSVs |
| `slides/index.html` | the deck |

## Running it

```bash
julia --project=. "Set 9/run_set9.jl"        # full year
julia --project=. "Set 9/run_set9.jl" 20     # first 20 days, quick
julia --project=. "Set 9/run_set9.jl" 365 7  # full year, seed 7
```

## Two modelling notes worth knowing before reading the results

**Start-up ramping is handled separately, and has to be.** On this fleet every
steam unit has `p_min` = 40% of capacity but a ramp rate of 30% per hour. A
naive `|P[t] − P[t−1]| ≤ ramp` makes those units *permanently unstartable* —
coming online means jumping from 0 to `p_min` in one hour, which exceeds the
ramp. The first version of this model did exactly that and produced 95%
shedding on real load, which is an artefact of the formulation and not a fact
about the grid. `commitment.jl` uses the standard separate start-up ramp.

**Solves are capped at 1% optimality gap and 20 seconds per block.** Under
`EXPO` the fleet is asked to follow swings it physically cannot, so shedding
at VOLL is the only escape and proving optimality becomes very expensive. Every
block that hits the cap is counted and reported in the results table.

## The demand rebuild — the limitation Set 8 inherited, and what Set 9 did about it

Set 8 split island demand across the nine buses by **2020 resident population**,
frozen in every hour. That makes the demand matrix **rank one**: the nine bus
loads can only grow and shrink together, so the demand *direction* never moves —
and direction is the quantity this whole line of work is about.

Set 9 rebuilt it in two steps. `DATA_REBUILD.md` carries the sources and numbers.

| Version | What it is | Rank | Built by |
|---|---|---|---|
| `v1` | 2020 resident population, frozen | 1 | Set 8's assumption, kept so it reproduces |
| `v2` | EIA-861 sector weights on population + LODES workplace jobs, frozen | 1 | `prepare_demand.py` |
| `v3` | residential / commercial / industrial separated, each with its own spatial footprint **and** its own hourly shape | **2** | `prepare_hourly_demand.py` |

`oahu_set9()` returns **v2**; `oahu_hourly_demand(case)` returns **v3**.
`run_set9.jl` runs the 2 × 4 grid on v2, so its `REAL` world still has a frozen
direction. `run_hourly.jl` runs the ladder on all three, which is what isolates
the allocation from everything else.

Oʻahu is a commuter island: Honolulu holds **71.0% of jobs against 39.9% of
residents**. Under v3 its share swings from about **52% at midnight to 85% at
midday** — a pattern nobody imposed; it falls out of the sector shapes.

## What is still assumed

The island **total** is filed and is preserved exactly in all three versions —
only its distribution across buses is reconstructed, and that reconstruction
rests on:

- typical-year **reference-building** load shapes, not Oʻahu's metered sector loads;
- **flat industrial** demand, because no industrial reference building exists;
- **rooftop PV allocated by population**, where the right key is Hawaiian
  Electric's circuit-level Locational Value Map;
- LODES employment counts that **exclude uniformed military**, which
  under-weights Wahiawa (Schofield) and Kōolaupoko (Kāneʻohe) — and note that
  Schofield Generating Station exists precisely to serve that load.

Read `DATA_REBUILD.md` before quoting any per-bus number.
