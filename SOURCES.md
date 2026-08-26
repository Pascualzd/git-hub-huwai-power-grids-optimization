# Source and provenance ledger

Accessed 2026-08-10. Raw downloads are immutable and gitignored; processed CSVs and all
transformation code are committed. SHA-256 values make the research snapshot independently
checkable even if a publisher later replaces a file at the same URL.

## Archived inputs

| Raw file | Publisher and vintage | Direct source | SHA-256 |
|---|---|---|---|
| `heco_20220331_final_oahu_inputs_workbook_3_revised.xlsx` | Hawaiian Electric, Final Oʻahu Inputs Workbook 3, filed 2022-03-31 | [XLSX](https://www.hawaiianelectric.com/documents/clean_energy_hawaii/integrated_grid_planning/20220331_final_oahu_inputs_workbook_3_revised.xlsx) | `fec85a2efd7bbe593424944a33e5fa93c7a7080cacba3fc8d404ced7ea1eb95b` |
| `heco_final_oahu_inputs_workbook_1_revised.xlsx` | Hawaiian Electric, Final Oʻahu Inputs Workbook 1, revised 2021-08-18 | [XLSX](https://www.hawaiianelectric.com/documents/clean_energy_hawaii/integrated_grid_planning/20210818_final_oahu_inputs_workbook_1_revised.xlsx) | `4fd27568f83f09351f32072bc360dd8fc6fce3b8cb98733f02ffba8d5014bae7` |
| `heco_20220519_final_oahu_inputs_workbook_4_revised.xlsx` | Hawaiian Electric, Final Oʻahu Inputs Workbook 4, revised 2022-05-19 | [XLSX](https://www.hawaiianelectric.com/documents/clean_energy_hawaii/integrated_grid_planning/20220519_final_oahu_inputs_workbook_4_revised.xlsx) | `1c0e7077de9ec37e4de972d6457e310cca4919f554deac2ba0e43e85d9d9e473` |
| `eia8602024.zip` | U.S. EIA Form 860, 2024 final | [ZIP](https://www.eia.gov/electricity/data/eia860/xls/eia8602024.zip) | `0aaae04812cd4ab87a3e346bdf93848a3cc15053fd4dc2a4cf82d2aeac95f12b` |
| `f923_2024.zip` | U.S. EIA Form 923, 2024 final | [ZIP](https://www.eia.gov/electricity/data/eia923/archive/xls/f923_2024.zip) | `272055f2d748f6486fc3076abd5a40ec736dbff45458bdb4c895761278c50f2b` |
| `heco_2014_psip_report.pdf` | Hawaiian Electric 2014 Power Supply Improvement Plan | [PDF](https://files.hawaii.gov/puc/3_Dkt%202011-0206%202014-08-26%20HECO%20PSIP%20Report.pdf) | `bf150f80762c42076fd6e6b01869158783b2ff20959ee4e9f61d9d490a3dee0f` |
| `tigerweb_census2020_honolulu_county_subdivisions.geojson` | U.S. Census 2020 P.L. 94-171 county subdivisions, Honolulu County, via TIGERweb | [ArcGIS query](https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/tigerWMS_Census2020/MapServer/20) | `9fa80ac39a3eb230707281ab02e790341ae1e5fbfd859a7c44fd8a1cc3bcca85` |
| `tigerweb_census2020_honolulu_tracts.json` | U.S. Census 2020 P.L. 94-171 census tracts, Honolulu County, via TIGERweb | [ArcGIS query](https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/tigerWMS_Census2020/MapServer/6) | `d1fad3077556ef221d92dc5e00b2d85d1758c2b91033f72b2e91a7688a912258` |

The authoritative filing index is the [Hawaiʻi PUC IGP docket 2018-0165](https://puc.hawaii.gov/energy/integrated-grid-planning-docket-for-hawaiian-electric-2018-0165/).
Hawaiian Electric's [current IGP document index](https://www.hawaiianelectric.com/clean-energy-hawaii/integrated-grid-planning/power-supply-improvement-plan)
lists the four final Oʻahu workbooks.

## Load transformation

`scripts/prepare_load.py` reads the year 2021 from ten hourly layers in Workbook 3:

- `gross_load_mw = Underlying_Load + Managed EV - Base Forecast + Future_eBus_Load`
- `net_load_mw = gross load + DGPV + four DBESS sectors + EE + non-DER/EV TOU`

Hawaiian Electric stores reductions such as DGPV and efficiency as negative values. The
script preserves those signs. It requires one value for each of 24 hourly-ending columns on
each of 365 days, validates exactly 8,760 observations, and writes a compact model file plus
a component-level audit file. `timestamp_hst` is fixed at UTC−10 because Hawaiʻi does not
observe daylight-saving time.

The base scenario uses the managed-EV layer. This is a filed planning profile, not metered
system load. Its peak is 1,054.257588 MW in hour 6,331 (2021-09-21 19:00 HST); annual mean
net load is 743.858974 MW.

## Fleet transformation

`scripts/prepare_generators.py` starts from EIA-860's `Operable` sheet, filters operational
Hawaiʻi units to the following utility/contracted firm Oʻahu plants, and uses summer capacity:

- Kahe (765), Waiau (766), H-POWER (10334), Kalaeloa (54646), Campbell Industrial Park
  (56329), and Schofield Generating Station (60328).
- Airport emergency generators and refinery self-generation are excluded from normal-grid
  economic dispatch.
- Solar, wind, and battery resources are excluded from the dispatchable thermal fleet because
  their effect is already represented in HECO net load.
- Kalaeloa CT1, CT2, and its steam component are aggregated as one 220 MW combined-cycle
  resource; dispatching the steam component independently would be physically misleading.

Implied heat rate is EIA-923 electric fuel consumption (MMBtu) divided by net generation
(MWh), aggregated at plant level except Waiau, where steam and combustion-turbine prime
movers are calculated separately. Variable cost is:

`heat rate × HECO 2024 base-forecast fuel price + technology VOM proxy`.

EIA-923 fuel-receipt costs are withheld or incomplete for most of this fleet, so they cannot
support a consistent plant-level delivered-price series. The HECO planning forecast is used
instead and is labeled as a forecast. VOM proxies are $5/MWh for steam, $4.50/MWh for simple
cycle, $4/MWh for combined cycle, $5/MWh for reciprocating engines, and $10/MWh for municipal
waste, informed by the [NREL 2024 ATB](https://atb.nrel.gov/electricity/2024b/data).
H-POWER assumes zero fuel cost plus the $10/MWh VOM proxy.

## Operating constraints and assumptions

Neither EIA-860 nor EIA-923 carries unit-level minimum stable output or ramp rate. Workbook 1
contains RESOLVE technology/resource structure and Workbook 4 contains alternative DER, EV,
EE, TOU, and fuel-price forecasts; neither exposes a current, directly traceable unit table
for these two parameters. The 2014 PSIP is retained as historical context, but its age and
unit-vintage ambiguity make it unsuitable for silently filling a 2024 fleet.

The baseline therefore applies visible technology assumptions:

| Technology | `P^min` | Hourly ramp |
|---|---:|---:|
| Oil steam | 40% of `P^max` | 30% of `P^max` |
| Combined cycle | 40% | 50% |
| Municipal-waste steam | 80% | 20% |
| Combustion turbine | 0% | 100% |
| Internal combustion | 0% | 100% |

Every fleet row repeats the assumption in `source` and `constraint_source`. Replacing these
values with a verified operational dataset is the highest-priority model improvement.

## Emissions

For fossil units, operational CO₂ intensity equals EIA-923 heat rate multiplied by the fuel
factor in Workbook 1 (`fuels` sheet): 0.083063247278 t/MMBtu for LSFO and 0.081806613878
t/MMBtu for diesel/ULSD. H-POWER uses the [EPA eGRID2023 HIOA](https://www.epa.gov/egrid/summary-data)
total-output rate of 1,489.548 lb CO₂/MWh (converted with 0.45359237 kg/lb) as a proxy. That
proxy is an Oʻahu subregion average, not a plant-specific H-POWER emissions factor.

## Network representation

`scripts/prepare_network.py` builds the stylized 9-bus Oʻahu network the DC-OPF study runs on.
It fetches the two TIGERweb responses above (caching them into `data/raw/` on first run, exactly
as `download_data.py` handles the EIA and HECO archives) and writes three processed files:
`oahu_network_buses.csv`, `oahu_network_branches.csv`, and `oahu_generator_bus_map.csv`.

**Buses.** The seven Oʻahu judicial districts, which the Census publishes as county subdivisions
(CCDs). Bus coordinates are population-weighted 2020 census-tract centroids rather than CCD
internal points, because the Honolulu CCD legally extends across the Northwestern Hawaiian
Islands and its geometric internal point falls about 500 miles from Oʻahu. The Ewa CCD is split
into three model buses (`Ewa-West`, `Ewa-Central`, `Kahe`): point-in-polygon on EIA-860
coordinates places all six modeled plants inside Ewa, which spans roughly twenty miles from
Kapolei to Mililani, so leaving it whole would collapse all island generation to one node and
erase the injection geography the study exists to examine. The split is at −158.075° W by tract;
Kahe is pulled out separately as the island's single largest injection. Point-in-polygon
assignment was cross-checked against the Census geocoder's own result for every plant.

**Loads.** Each bus is allocated a share of island net load equal to its resident-population
share, so total served load is identical to the copper-plate baseline and the models stay
comparable. This is a deliberate proxy — see the caveat in *Interpretation boundaries* below.

**Branches.** Ten 138 kV branches wired as the two-corridor ring (one north, one south) that
Hawaiian Electric describes in its [Power Delivery](https://www.hawaiianelectric.com/about-us/power-facts/power-delivery)
material. Nine buses and ten branches leave two independent loops, which is required: a radial
network makes DC-OPF and the transportation model identical. Every electrical parameter is a
labeled technology assumption, recorded in the CSV's `*_source` columns:

| Parameter | Assumption |
|---|---:|
| Length | great-circle bus separation × 1.25 routing factor |
| Reactance | 0.80 Ω/mi at 138 kV on a 100 MVA base |
| Resistance (transport-cost proxy only; DC-OPF is lossless) | 0.12 Ω/mi |
| Thermal limit | 200 MW per circuit; 1–3 circuits per branch by corridor |
| Transport cost | per-unit resistance × the copper-plate marginal cost (\$134.48/MWh) |

The urban import corridor (Ewa-Central→Honolulu) carries three circuits, reflecting that the
southern tie into town is the island's strongest path; the north corridor out of Kahe carries a
single circuit and is the constraint that binds at peak. Transport cost is a modeled loss/wheeling
proxy, not a Hawaiian Electric tariff.

## Interpretation boundaries

- This is continuous linear economic dispatch, not unit commitment. Positive `P^min` values
  act as always-on lower bounds within the selected fleet.
- The model omits startups, minimum up/down times, reserves, forced outages, fuel contracts,
  heat-rate curves, and storage state of charge.
- Costs are modeled marginal variable costs, not wholesale prices or customer rates.
- Emissions are operational proxies, not a regulatory inventory or lifecycle assessment.
- The AES-before/after case in the startup plan remains an explicitly optional extension and
  is not mixed into this 2024-fleet baseline.
- The network is a stylized 9-bus representation, not Hawaiian Electric's actual topology, and
  DC-OPF itself is lossless and omits reactive power, voltage limits, and N-1 security. Bus
  loads are allocated by resident population; Honolulu's commercial, hotel, and military load
  and the rooftop PV already embedded in net load both bias its true net import upward relative
  to that share, so the urban import result is conservative. Texas A&M's Hawaii40 synthetic
  case (real reactances and ratings, behind a one-time request form) is the intended
  higher-fidelity cross-check.

## Rebuild commands

```bash
bash scripts/python scripts/download_data.py
bash scripts/python scripts/prepare_load.py
bash scripts/python scripts/prepare_generators.py
bash scripts/python scripts/prepare_network.py
bash scripts/verify.sh
```
