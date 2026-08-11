# Data source map

Links rechecked 2026-08-10. See [SOURCES.md](SOURCES.md) for exact filenames, transformations,
checksums, exclusions, and limitations.

| Model field | Primary source | Implementation |
|---|---|---|
| Hourly gross/net load | [Hawaiian Electric final Oʻahu IGP inputs](https://www.hawaiianelectric.com/clean-energy-hawaii/integrated-grid-planning/power-supply-improvement-plan), Workbook 3 | Reconstruct 2021 base scenario from underlying load, managed EV/e-bus, DGPV, customer battery, EE, and TOU layers. |
| Unit list and `P^max` | [EIA Form 860, 2024 final](https://www.eia.gov/electricity/data/eia860/) | Filter operational Honolulu County utility/contracted firm resources; use summer capacity. |
| Heat rate | [EIA Form 923, 2024 final](https://www.eia.gov/electricity/data/eia923/) | Electric fuel consumption MMBtu ÷ net generation MWh, at plant/prime-mover level. |
| Fuel price | Hawaiian Electric IGP Workbook 3 | 2024 base-forecast LSFO, diesel, CIP ULSD, and Schofield ULSD prices. Schedule 2 costs are withheld or incomplete for most modeled plants. |
| VOM | [NREL Annual Technology Baseline 2024](https://atb.nrel.gov/electricity/2024b/data) | Technology-level proxy; explicitly labeled in fleet provenance. |
| `P^min`, ramp rate | Technology defaults, cross-checked against [HECO 2014 PSIP](https://files.hawaii.gov/puc/3_Dkt%202011-0206%202014-08-26%20HECO%20PSIP%20Report.pdf) and current IGP workbooks | Assumed for every resource because current public inputs do not provide unit-level values in a directly traceable table. |
| CO₂ intensity | HECO IGP Workbook 1; [EPA eGRID2023](https://www.epa.gov/egrid/summary-data) | Fuel factor × heat rate for fossil units; HIOA output-rate proxy for H-POWER. |

Hawaiʻi is excluded from EIA Form 930's Lower-48 balancing-authority series, so no Form 930
load data is used. NSRDB, NOW-23, PUDL, and the Texas A&M Hawaii40 synthetic network remain
possible extensions but are not inputs to this baseline.
