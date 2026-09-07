# Set 8 — Monte Carlo dispatch risk

Presented 8 September 2026.

One network, held completely fixed. Ten thousand random demand columns. The
output is not a dispatch — it is a **distribution of dispatches**, and three
probabilities read off it.

---

## The assignment

| | Question |
|---|---|
| **Q1** | Do we have usage statistics for a real power network? (Hawaii) |
| **Q2** | Fix IEEE-14, put random demand in, solve 10,000 times. How often do we spin up the most expensive generator? How often is the solution infeasible (load shedding)? How often do network elements get overloaded? Sample from an exponential Exp(1) at each demand node, with the mean coming from the real network. |
| **Q3** | Ask the same questions of the real network from Q1. |

---

## Headline answers

**Q1 — yes.** 8,760 filed hourly load observations for Oʻahu, a 24-unit
dispatchable fleet with sourced marginal costs, and a 9-bus network. Mean net
load 743.86 MW, peak 1,054.26 MW, installed capacity 1,508.1 MW.

And one number that reshapes the rest of the set: real Oʻahu load has a
**coefficient of variation of 0.168**. Exp(1) has a CV of **1.000**.

**Q2 — IEEE-14 under Exp(1)**, calibrated to Oʻahu's 49.3% capacity utilisation:

| question | answer | 95% CI |
|---|---:|---|
| most expensive generator runs | **59.63%** | 58.66–60.59% |
| load shedding (infeasible) | **41.58%** | 40.62–42.55% |
| at least one line at its limit | **60.95%** | — |

Demand exceeds total *nameplate* capacity in only 2.87% of draws, yet shedding
happens in 41.58%. The gap is the **network** failing to deliver power the fleet
could generate.

**Which led to the result I did not expect.** Nameplate is the wrong yardstick —
a megawatt that cannot cross a line is not capacity. Solving for the largest
load the network can actually deliver:

| network | nameplate | deliverable | stranded |
|---|---:|---:|---:|
| IEEE-14 | 772.4 MW | **575.1 MW** | 197.3 MW (25.5%) |
| Oʻahu | 1,508.1 MW | **1,082.0 MW** | 426.1 MW (28.3%) |

Oʻahu's annual peak is 1,054.3 MW. Against nameplate that is a 43% reserve
margin. **Against what the network can deliver it is 27.7 MW — 2.6%.**

**Q3 — Oʻahu.** Same three questions, three demand models, one unchanged grid:

| demand model | CV | P(costliest unit) | P(shedding) | P(line at limit) |
|---|---:|---:|---:|---:|
| A · independent Exp(1) | 0.532 | 5.48% | 19.77% | 58.40% |
| B · common island-wide shock, weight 0.7 | 0.708 | 5.20% | 19.53% | 51.05% |
| **C · real 8,760-hour bootstrap** | **0.168** | **0.00%** | **0.00%** | **92.51%** |

**The exponential does not simply exaggerate risk — it misdirects it.**

- It *invents* an adequacy crisis Oʻahu does not have. Real demand never leaves
  the 473–1,054 MW band the fleet was built for; load is served in all 10,000
  resampled hours.
- It *hides* the congestion Oʻahu does have. Real load sits persistently in
  exactly the band that saturates the Ewa-West → Ewa-Central corridor, which
  runs at **97.7% of its rating on average** and is pinned at the limit 68.8%
  of the time. In this model that single corridor — not generation capacity —
  is the island's binding constraint.

---

## Files

| file | what it does |
|---|---|
| `montecarlo.jl` | The engine. DC-OPF with load shedding, built once and re-parameterised per scenario; the samplers; the statistics and reporting. |
| `cases.jl` | Loads IEEE-14 and the 9-bus Oʻahu model into one common `GridCase` shape, and documents the calibration decision. |
| `theme.jl` | Shared chart styling and a CVD-validated palette. |
| `Q1 - hawaii data.jl` | Audits the real dataset; produces the load-distribution and merit-order figures. |
| `Q2 - ieee14 montecarlo.jl` | 10,000 IEEE-14 draws, convergence check, stress sweep over mean demand. |
| `Q3 - oahu montecarlo.jl` | 10,000 Oʻahu draws under all three demand models, plus the Q2-vs-Q3 comparison. |
| `anim_set8.jl` | The two-act animation on the real Oʻahu map. |
| `slides/` | Quarto reveal.js deck. |
| `figures/`, `results/` | Generated output — every file regenerates from the scripts. |

## Running it

```bash
cd "Set 8"
julia "Q1 - hawaii data.jl"
julia "Q2 - ieee14 montecarlo.jl"
julia "Q3 - oahu montecarlo.jl"
julia anim_set8.jl

cd slides && quarto render      # deck -> slides/_site/
```

Requires the packages already in the repo `Project.toml` (JuMP, HiGHS,
DataFrames, CSV, Plots, PrettyTables) and `ffmpeg` for clean GIF encoding.
Runtime is about 30 seconds for Q2, a minute for Q3, and a few minutes for the
animation. Seed is `20260908` throughout, so every number reproduces exactly.

---

## Modelling decisions worth knowing about

These change the answers, so they are stated rather than buried.

**Shedding instead of solver failure.** Every bus carries a load-shedding
variable priced at VOLL = \$10,000/MWh, far above the costliest real unit
(\$237.97/MWh). The LP is therefore always feasible and "infeasible" becomes a
measured megawatt quantity rather than a boolean. This is how reliability
studies actually measure adequacy.

**Generator Pmin is set to zero.** Oʻahu's fleet carries 531 MW of nameplate
minimum stable output. Enforcing it in a continuous LP without unit commitment
would make every *low*-demand draw infeasible for a reason that has nothing to
do with adequacy — you cannot switch a unit off. Set 8 asks whether the network
can meet demand, so the fleet is allowed to shut down freely.

**IEEE-14 is calibrated to Oʻahu's utilisation, not its megawatts.** Oʻahu runs
at 49.3% of installed capacity on average; IEEE-14 is given the same ratio
(380.98 MW of its 772.4 MW), split across load buses in the published case14
proportions. All three questions are questions about headroom, so comparing a
toy at 33.5% utilisation against an island at 49.3% would compare the
calibration rather than the networks. The native 259 MW case is reported too.

**IEEE-14 line ratings are assigned, not published.** case14 lists no thermal
limits, and an unlimited network can never be congested. Ratings are 1.5× the
flow each line carries at the design mean, floored at 25 MW — the network a
planner would build for today's duty plus a margin.

**"Overloaded" means saturated.** In a hard-constrained DC-OPF a flow can never
exceed its rating; the constraint binds instead. So the primary statistic is
P(line at its limit). Each scenario is *also* solved a second time with limits
removed, which measures how far over the rating the flow would have gone — the
`p_overload_unconstrained` column.

**Only the linear cost term is used.** `gencost.csv` is MATPOWER cost model 2,
carrying a quadratic `c2` as well as a linear `c1`. Like Parts 2–5 of this
project, Set 8 minimises `sum(c1*P)` alone, keeping the problem an LP with
constant marginal costs and genuine LMP duals. Consequence worth stating: under
`c1` alone, G1 and G2 both cost \$20/MWh and buses 3/6/8 all cost \$40/MWh, so
"the most expensive generator" is really the most expensive **tier**. Under the
full quadratic cost the units would rank differently.

**Ties between equal-cost units are broken explicitly.** Because G1 and G2 tie
at \$20/MWh, the LP has infinitely many optima — the total is pinned, the split
is not — and which one a solver reports is decided by its pivot rule. Probing
the optimal face shows G1's output free to move by up to 140 MW at identical
cost. A `1e-6` per-index cost increment makes the choice reproducible. Totals,
shedding, and whether the expensive tier runs were already unique and are
unaffected; **where units tie, read the tier, not the individual unit.**

**The stress sweep freezes the network.** Line ratings are derived from a
base-case solve, so changing mean demand would also change the grid (total
ratings would run 927 → 1,823 MW across the sweep). The λ = 1 ratings are
therefore frozen and reused at every point — without this the risk curve comes
out far too flat (3.9% vs 15.5% shedding at λ = 0.5).

**Model B's parameter is a mixing weight, not a correlation.** `D_i = mu_i *
(w*E_common + (1-w)*E_i)` with `w = 0.7` induces pairwise correlation **0.845**
and per-node CV **0.762** — verified by simulation. So B changes correlation
*and* dispersion together; it is a sensitivity, not a clean isolation of
correlation, and its effect shows up in the depth of shedding (expected unserved
57 → 85 MW) rather than its frequency.

**Seed robustness.** The reported seed is `20260908`, fixed in advance as the
presentation date. Re-running on four independent streams gives P(shedding)
41.58 / 42.32 / 42.73 / 43.10% — a 1.52 pp spread against a 0.97 pp Wilson
half-width, i.e. the size binomial error predicts. The reported seed sits at the
**low** end, so the headline is mildly conservative rather than flattering.
`results/q2_seed_robustness.csv`.

**The network is stylised.** Nine buses on a two-corridor 138 kV ring, loads
allocated by resident population, 200 MW per circuit as a labelled technology
assumption. The *ranking* of corridors is the finding; the exact percentages
inherit those assumptions. See `SOURCES.md`.

---

## Sources

- Hawaiian Electric, Final Oʻahu Inputs Workbook 3 (filed 2022-03-31) — hourly load
- U.S. EIA Form 860 (2024 final) — unit list and summer capacity
- U.S. EIA Form 923 (2024 final) — implied heat rates
- U.S. Census 2020 P.L. 94-171 via TIGERweb — bus geography and load allocation
- Hawaiian Electric *Power Delivery* — two-corridor 138 kV ring topology
- MATPOWER `case14` — the IEEE 14-bus test system

Full provenance, checksums, and interpretation boundaries live in the repository
root: [`SOURCES.md`](../SOURCES.md) and [`DATA_SOURCES.md`](../DATA_SOURCES.md).
