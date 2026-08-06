# Data Sources

Which dataset supplies which economic dispatch parameter. No single source has all of them.

Links verified 2026-08-06.

## Model parameters → sources

| Parameter | Source | Notes |
|---|---|---|
| Unit list, `P^max` | [EIA Form 860](https://www.eia.gov/electricity/data/eia860/) — [2024 final ZIP](https://www.eia.gov/electricity/data/eia860/xls/eia8602024.zip) | Filter state `HI`. Use **summer capacity**, not nameplate. Also gives prime mover, fuel, operating/retirement dates. |
| `VarCost` | [EIA Form 923](https://www.eia.gov/electricity/data/eia923/) — [2024 final ZIP](https://www.eia.gov/electricity/data/eia923/archive/xls/f923_2024.zip) | Heat rate = net generation (MWh) ÷ fuel consumed (MMBtu). Delivered fuel price from **Schedule 2** (fuel receipts and costs). |
| VOM adder | [NREL ATB](https://atb.nrel.gov/) | By technology. |
| `P^min`, ramp rate `R` | [HECO 2014 PSIP](https://files.hawaii.gov/puc/3_Dkt%202011-0206%202014-08-26%20HECO%20PSIP%20Report.pdf) + [appendices](http://www.solari.net/portfolio/Solari-Hawaiian-Electric-2014-PSIP-Appendices.pdf); current IGP Inputs & Assumptions workbooks | **Not available in any EIA form.** Unit-level min load / ramp / heat rate curve tables. |
| Hourly demand (8760) | [HECO IGP key stakeholder documents](https://www.hawaiianelectric.com/clean-energy-hawaii/integrated-grid-planning/stakeholder-engagement/key-stakeholder-documents) — "Inputs and Assumptions" category | 8760 corporate load forecast reported to be in **Workbook 3**. Layered into underlying load / DER rooftop PV / EVs / efficiency — use the layers for gross vs. net load. |
| Solar profiles | [NSRDB](https://nsrdb.nrel.gov/) | Covers Hawaiʻi. |
| Wind profiles | [NOW-23 Hawaii](https://developer.nrel.gov/docs/wind/wind-toolkit/offshore-hawaii-download/) | 21-year offshore dataset; replaced the 2013 WIND Toolkit Hawaii data. |
| Emissions factors | [EPA eGRID](https://www.epa.gov/egrid) | Splits Hawaiʻi into subregions `HIOA` (Oʻahu) and `HIMS` (other islands). |

## Two gaps to know about before you start

**Hawaiʻi is excluded from EIA Form 930.** The [Hourly Electric Grid Monitor](https://www.eia.gov/todayinenergy/detail.php?id=40993)
collects from the 65 balancing authorities in the **Lower 48** only. There is no `HECO`
balancing authority in that dataset and no Hawaiʻi hourly demand series. This is the single
most common wrong turn on this project.

**`P^min` and ramp rates are regulatory-filing data, not federal survey data.** They exist
only in HECO's PUC filings. Where a unit is genuinely undocumented, use technology defaults
(oil steam min stable level ≈ 40–50% of `P^max`) and record `assumed` in the `source` column
of the fleet table.

## Supporting references

- [PUC Docket 2018-0165](https://puc.hawaii.gov/energy/integrated-grid-planning-docket-for-hawaiian-electric-2018-0165/) — the full IGP filing set (~721 MB of Excel).
- [IGP Report Appendix B — Forecasts and Assumptions](https://hawaiipowered.com/igpreport/05_IGP-AppendixB_ForecastsandAssumptions.pdf) — PDF cross-check and citation source.
- Companion PSIPs: [Maui Electric](https://files.hawaii.gov/puc/1_Dkt%202011-0092%202014-08-26%20MECO%20PSIP%20Report.pdf), [Hawaii Electric Light](https://files.hawaii.gov/puc/2_Dkt%202012-0212%202014-08-26%20HELCO%20PSIP%20Report.pdf) — if the study is extended beyond Oʻahu.
- [PUDL](https://catalyst.coop/pudl/) — EIA-860/861/923 pre-cleaned and cross-linked. [SQLite](https://s3.us-west-2.amazonaws.com/pudl.catalyst.coop/nightly/pudl.sqlite.zip), [browsable](https://data.catalyst.coop). Prefer `out_`-prefixed tables. Optional accelerator, not required.
- [Texas A&M Hawaii40](https://electricgrids.engr.tamu.edu/hawaii40/) — 37-bus synthetic case on Oʻahu's footprint, 1,100 MW peak, MATPOWER/PSS-E/PowerWorld formats. **Synthetic — does not represent the actual grid, and carries no generator cost data.** Useful only if network constraints get added (which the source lecture skips).

## Rules for this repo

- Archive every raw download into `data/raw/` on first fetch. HECO and PUC URLs get
  reorganized; do not plan on re-fetching later.
- Every row in `data/processed/oahu_generators.csv` carries a `source` column. Filed values
  and assumed values must be distinguishable at a glance.
- Where the 2014 PSIP conflicts with current IGP workbooks, prefer the IGP values and note
  the discrepancy.
