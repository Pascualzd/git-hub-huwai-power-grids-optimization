# Hawaii Economic Dispatch — Project Startup Plan

## Context

The goal is a research presentation that reproduces the structure of Cornell BEE 4750/5750
Lecture 12, "Economic Dispatch" (Vivek Srikrishnan), but driven by **real data from Hawaiʻi's
island grids** instead of the lecture's five-generator toy fleet.

Source lecture: https://envsys.viveks.me/fall2022/assets/lecture-notes/12-economic-dispatch/index.html

The lecture builds up in three steps: (1) single-period economic dispatch — minimize
`Σ VarCost_g · y_g` subject to a load balance and `P^min_g ≤ y_g ≤ P^max_g`; (2) multi-period
dispatch adding ramp constraints `|y_{g,t+1} − y_{g,t}| ≤ R_g`; (3) a merit-order /
dispatch-stack discussion closing on the CAISO duck curve. It is implemented in Julia with
JuMP + HiGHS.

Oʻahu is the target system: ~1,100 MW peak and roughly a dozen dispatchable units — small
enough to fit the parameter table on one slide, real enough to be a genuine study. It also
carries a strong narrative: the AES coal plant retired in September 2022 and Kapolei Energy
Storage came online shortly after, giving a concrete before/after dispatch comparison.

The intended outcome is a reproducible Quarto revealjs deck where every figure is generated
from source data by committed code, plus a documented, citable dataset that outlives the
presentation.

**The decisive constraint:** Hawaiʻi is excluded from EIA Form 930, so the Hourly Electric
Grid Monitor has no Hawaiʻi demand series. Hourly load must come from Hawaiian Electric's
Integrated Grid Planning (IGP) filings. Getting that file is the critical path — start there.

**Toolchain (decided):** Julia + JuMP + HiGHS for the model; Quarto revealjs for the deck.

---

## Step 1 — Scaffold the repo and toolchain

Create:

```
data/raw/          # untouched downloads — never edited, gitignored if large
data/processed/    # tidy CSVs the model reads — committed, these are small
src/               # Julia model code
scripts/           # Python data-prep scripts
slides/            # Quarto .qmd + generated figures
figures/
```

Toolchain setup:

- Julia 1.12.6. Create a project environment and add: `JuMP`, `HiGHS`, `DataFrames`, `CSV`,
  `Plots`, `Measures`. This mirrors the lecture's imports exactly.
- Python 3.12 with `pandas`, `numpy`, `matplotlib`, `requests`. Data prep only — the
  optimization stays in Julia.
- **Quarto** (`brew install --cask quarto`), plus a Julia execution engine for it
  (`QuartoNotebookRunner` for Quarto's native Julia engine, or `IJulia` for the Jupyter path).

Commit the scaffold plus a `.gitignore` for large raw archives before pulling any data, so
the first data commit is reviewable.

## Step 2 — Get the hourly load profile (critical path, do this first)

Everything downstream keys off this, and it is the only piece that may require a human
request rather than a download. Pursue in this order and stop at the first success:

1. **Hawaiian Electric IGP key stakeholder documents** —
   https://www.hawaiianelectric.com/clean-energy-hawaii/integrated-grid-planning/stakeholder-engagement/key-stakeholder-documents
   Filter to the "Inputs and Assumptions" category. HECO's 8760 corporate load forecast is
   reported to live in **Workbook 3**. The forecast is layered — underlying load, DER/rooftop
   PV, EVs, energy efficiency — which is exactly what you need to plot gross vs. net load and
   derive Oʻahu's own duck curve from source data rather than asserting it.
2. **PUC Docket 2018-0165** — https://puc.hawaii.gov/energy/integrated-grid-planning-docket-for-hawaiian-electric-2018-0165/
   The full filing set (~721 MB of Excel). Slower to navigate but authoritative.
3. **IGP Report Appendix B** — https://hawaiipowered.com/igpreport/05_IGP-AppendixB_ForecastsandAssumptions.pdf
   Forecasts and assumptions in PDF; use as a cross-check on whatever workbook you find, and
   as the citation in the deck.
4. **Fallback if no 8760 is publicly downloadable:** email `igp@hawaiianelectric.com`, and in
   parallel synthesize a defensible profile — scale a published normalized island load shape
   (NREL Oʻahu wind/solar integration studies) to annual retail sales from **EIA Form 861**
   and the reported system peak. Label it clearly as synthesized in the deck.

Deliverable: `data/processed/oahu_load_8760.csv` with columns `hour, gross_load_mw,
net_load_mw`, plus a `SOURCES.md` note recording exactly which file and vintage it came from.

## Step 3 — Build the Oʻahu generator fleet table

This produces the direct analogue of the lecture's parameter table. Four parameters, three
different sources — no single dataset has all of them.

**`P^max` and the unit list — EIA Form 860 (2024 final):**
https://www.eia.gov/electricity/data/eia860/xls/eia8602024.zip

Filter to state `HI`, Oʻahu plants. Gives nameplate and summer capacity, prime mover, energy
source, operating and retirement dates. Use summer capacity as `P^max` — Hawaiʻi is
temperature-derated year-round and it is the honest number for a dispatch study. This step
also confirms the AES retirement date and the Kapolei Energy Storage in-service date from
primary data rather than from press coverage.

**`VarCost` — EIA Form 923 (2024 final):**
https://www.eia.gov/electricity/data/eia923/archive/xls/f923_2024.zip

Compute implied heat rate per plant as net generation (MWh) ÷ fuel consumed (MMBtu). Get
delivered fuel price ($/MMBtu) from **Schedule 2** (fuel receipts and costs), which HECO
reports as a regulated utility. Then:

```
VarCost [$/MWh] = heat_rate [MMBtu/MWh] × fuel_price [$/MMBtu] + VOM [$/MWh]
```

VOM from the NREL ATB (https://atb.nrel.gov/) by technology.

**Optional accelerator:** PUDL ships EIA-860/861/923 pre-cleaned and cross-linked, which
removes the pain of EIA's spreadsheet layout drifting between vintages. SQLite:
https://s3.us-west-2.amazonaws.com/pudl.catalyst.coop/nightly/pudl.sqlite.zip ; browsable at
https://data.catalyst.coop . Prefer tables with the `out_` prefix. Worth it if the raw
spreadsheet wrangling exceeds an afternoon; otherwise the raw ZIPs are fine at this scale.

**`P^min` and `R` (ramp rate) — regulatory filings, not EIA.** These two parameters are what
the lecture's multi-period model actually turns on, and no EIA form carries them:

- HECO 2014 PSIP: https://files.hawaii.gov/puc/3_Dkt%202011-0206%202014-08-26%20HECO%20PSIP%20Report.pdf
  and its appendices: http://www.solari.net/portfolio/Solari-Hawaiian-Electric-2014-PSIP-Appendices.pdf
  Older vintage, but contains unit-level min load / ramp rate / heat rate curve tables.
- Current IGP Inputs and Assumptions workbooks (same source as Step 2) for present-day values.

Where a unit is genuinely undocumented, fall back to technology defaults (oil steam min stable
level ≈ 40–50% of `P^max`) and **mark every such cell as an assumption in the table** — a
column named `source` with values like `PSIP-2014` / `assumed` costs nothing and is the
difference between a defensible study and a plausible-looking one.

Deliverable: `data/processed/oahu_generators.csv` — one row per unit, columns `name, fuel,
p_min_mw, p_max_mw, varcost_usd_per_mwh, ramp_mw_per_hr, source`.

## Step 4 — Port the lecture's two models to the Hawaiʻi data

In `src/`, write the models to read the two CSVs from Step 3 and Step 2. Keep the lecture's
formulation and variable naming (`y[g]`, `y[g,t]`) so the deck can show the math and the code
side by side, as the lecture does.

1. **Single-period ED** at a chosen hour (use the annual peak hour — it is the most
   interesting and the easiest to sanity-check). Report dispatch by unit and identify the
   marginal generator.
2. **Multi-period ED** over a 24-hour window with ramp constraints, reproducing the lecture's
   two plots: line plot of generation by unit, and stacked area plot with demand overlaid as a
   dashed red line.

Sanity checks before trusting any output: total dispatch equals demand every hour; no unit
exceeds `P^max` or violates its ramp limit; the merit order matches a hand-sorted `VarCost`
ranking; and infeasibility at any hour means the fleet or the load series is wrong, not the
solver.

## Step 5 — The analysis that makes it a research project rather than a homework replication

Two extensions, both of which fall out of data already collected:

- **Flat merit order.** Oʻahu is overwhelmingly oil-fired, so unlike the lecture's
  nuclear-to-gas cost spread, the dispatch stack will be compressed and ordered by heat rate
  and fuel grade (LSFO vs. diesel vs. biodiesel) rather than by fuel type. Plot Oʻahu's merit
  order next to the lecture's and explain why island grids are expensive, and why that makes
  ramping and storage — not fuel-cost ranking — dominate the economics.
- **Emissions.** Add CO₂ per unit and either report emissions alongside cost or add an
  emissions constraint. EPA eGRID splits Hawaiʻi into subregions `HIOA` (Oʻahu) and `HIMS`
  (other islands), so the factors are available at exactly the right granularity. This is the
  natural fit for a course framed as *Environmental* Systems Analysis.

Optional if time allows: re-run dispatch with the AES coal unit present vs. retired, using the
EIA-860 retirement date to define the two fleets.

## Step 6 — Build the deck

Quarto revealjs in `slides/`, with figures generated by the Step 4/5 code at render time so
nothing is hand-pasted. Suggested arc, mirroring the lecture:

1. Why island grids are a distinct problem — isolated, no interties, oil-dependent
2. The Oʻahu fleet (the parameter table, with assumption provenance visible)
3. Single-period dispatch and the marginal generator
4. Merit order — Oʻahu vs. the textbook case
5. Multi-period dispatch with ramping
6. Oʻahu's duck curve, from HECO's own gross/net load layers
7. Emissions and what this implies for the transition

## Verification

- `julia --project=. -e 'using Pkg; Pkg.instantiate()'` resolves cleanly.
- Both models solve to optimality; the sanity checks in Step 4 pass.
- `quarto render slides/` produces the deck end to end from a clean checkout with no manual
  steps — this is the real test that the project is reproducible.
- Every number in the deck traces to a row in `data/processed/` and a citation in
  `SOURCES.md`; every assumed parameter is visibly labeled as assumed.

## Risks

- **Step 2 is the schedule risk.** If the 8760 is not publicly downloadable, the fallback in
  Step 2.4 is viable but changes the framing of the results — decide early, not late.
- HECO PUC filing URLs get reorganized periodically. Archive the raw files into `data/raw/`
  on first download rather than re-fetching later.
- The 2014 PSIP is old. Where its ramp rates conflict with current IGP workbooks, prefer the
  IGP values and note the discrepancy.
