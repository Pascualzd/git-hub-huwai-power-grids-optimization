#!/usr/bin/env python3
"""
Set 9 -- prepare_demand.py

Rebuild the per-bus load allocation from public filings instead of resident
population alone.

WHY
Set 8 and the first Set 9 run split island demand across buses by 2020
resident population. `SOURCES.md` already flagged the problem:

    "Honolulu's commercial, hotel, and military load and the rooftop PV
     already embedded in net load both bias its true net import upward
     relative to that share, so the urban import result is conservative."

This script replaces the guess with measurement. On Oahu, 71% of jobs sit in
the Honolulu judicial district against 40% of residents -- so an allocation
by residents alone moves a large block of commercial load out of town.

THE METHOD
    share[bus] = f_res * pop[bus]         / pop_total
               + f_com * com_jobs[bus]    / com_jobs_total
               + f_ind * ind_jobs[bus]    / ind_jobs_total

with the sector weights f taken from filed retail sales and the spatial keys
from filed employment and the decennial census.

SOURCES (all public, all downloaded by this script)
    Sector weights   EIA Form 861, "Sales to Ultimate Customers" 2021, the
                     utility "Hawaiian Electric Co Inc" -- the O'ahu entity,
                     not the statewide total. See `sector_weights()` below.
                     https://www.eia.gov/electricity/data/eia861/
    Jobs by block    Census LEHD LODES8 Workplace Area Characteristics,
                     Hawaii, 2021, NAICS sector columns CNS01-CNS20.
                     https://lehd.ces.census.gov/data/lodes/LODES8/hi/wac/
    Block -> district  LODES8 geography crosswalk, `ctycsubname`.
    Tract centroids  Census 2020 Gazetteer, used only to split the Ewa
                     district at -158.075 W -- the same meridian and the same
                     by-tract method the existing bus file documents.
    Population       data/processed/oahu_network_buses.csv (Census 2020 P.L.
                     94-171 via TIGERweb), unchanged.

KNOWN LIMITATIONS -- read these before quoting any number downstream
  1. FIXED. The EIA sector weights were originally STATEWIDE Hawaii. They now
     come from "Hawaiian Electric Co Inc" alone, which is the O'ahu operating
     entity -- Maui Electric and Hawaii Electric Light file their own returns.
     `sector_weights()` documents the check that this is the right one.
  2. LODES EXCLUDES UNIFORMED MILITARY. Oahu hosts Pearl Harbor-Hickam,
     Schofield Barracks and Kaneohe MCB, whose loads are large and are not in
     this employment count. Wahiawa (Schofield) and Koolaupoko (Kaneohe) are
     therefore likely UNDER-weighted by this method -- note that Schofield has
     its own generating station in the fleet, so this matters.
  3. Jobs are a proxy for commercial load, not a measurement of it. A data
     centre employs few people and draws heavily; a call centre is the reverse.
  4. The allocation produced HERE is STATIC -- each bus keeps a fixed share in
     every hour, so the demand direction does not move. That is what
     `prepare_hourly_demand.py` (v3) fixes. O'ahu's metered sector loads are
     not published, so v3 substitutes OpenEI TMY3 reference-building shapes at
     Honolulu weather: the right diurnal character, not a measurement.

    julia/python: python3 "Set 9/prepare_demand.py"
"""

import csv, gzip, io, json, pathlib, sys, urllib.request

HERE      = pathlib.Path(__file__).resolve().parent
PROCESSED = HERE.parent / "data" / "processed"
CACHE     = HERE / "data_cache"
OUT       = HERE / "data"
CACHE.mkdir(exist_ok=True, parents=True)
OUT.mkdir(exist_ok=True, parents=True)

YEAR           = 2021          # matches the load year of oahu_load_8760.csv
EWA_SPLIT_LON  = -158.075      # the meridian the existing bus file splits Ewa on

URLS = {
    "wac":   f"https://lehd.ces.census.gov/data/lodes/LODES8/hi/wac/hi_wac_S000_JT00_{YEAR}.csv.gz",
    "xwalk":  "https://lehd.ces.census.gov/data/lodes/LODES8/hi/hi_xwalk.csv.gz",
    "gaz":    "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2020_Gazetteer/2020_gaz_tracts_15.txt",
    "eia861": f"https://www.eia.gov/electricity/data/eia861/archive/zip/f861{YEAR}.zip",
}

# NAICS groupings. CNS01-06 are goods-producing and utilities; the rest are
# services, which includes accommodation/food (CNS18) and public
# administration (CNS20).
IND = [f"CNS{i:02d}" for i in range(1, 7)]
COM = [f"CNS{i:02d}" for i in range(7, 21)]


def fetch(key: str) -> pathlib.Path:
    dest = CACHE / URLS[key].rsplit("/", 1)[-1]
    if not dest.exists():
        print(f"  downloading {dest.name} ...", flush=True)
        urllib.request.urlretrieve(URLS[key], dest)
    return dest


def sector_weights() -> tuple:
    """
    Residential / commercial / industrial shares of retail sales, O'AHU ONLY.

    EIA-861 reports each utility separately, and "Hawaiian Electric Co Inc" is
    the O'ahu entity -- Maui Electric and Hawaii Electric Light file their own
    returns. An earlier version of this script used the STATEWIDE totals, which
    mixed in islands this study does not model. The check that this is the right
    entity: its 6.17 TWh of 2021 retail sales against 6.52 TWh of measured O'ahu
    net load leaves a ~5% gap, which is what T&D losses look like.
    """
    try:
        import pandas as pd, zipfile
    except ImportError:
        sys.exit("pandas is required to read the EIA workbook: pip install pandas openpyxl")
    z = zipfile.ZipFile(fetch("eia861"))
    d = pd.read_excel(z.open(f"Sales_Ult_Cust_{YEAR}.xlsx"),
                      header=None, skiprows=3).iloc[:, :24]
    d.columns = ["year", "unum", "uname", "part", "svc", "dtype", "state", "own", "ba",
                 "res_rev", "res_mwh", "res_cust", "com_rev", "com_mwh", "com_cust",
                 "ind_rev", "ind_mwh", "ind_cust", "tra_rev", "tra_mwh", "tra_cust",
                 "tot_rev", "tot_mwh", "tot_cust"]
    h = d[d.uname.astype(str).str.strip() == "Hawaiian Electric Co Inc"]
    g = {k: float(pd.to_numeric(h[k], errors="coerce").fillna(0).sum())
         for k in ("res_mwh", "com_mwh", "ind_mwh")}
    t = sum(g.values())
    return g["res_mwh"] / t, g["com_mwh"] / t, g["ind_mwh"] / t


def jobs_by_district() -> dict:
    """Workplace jobs per Oahu judicial district, split into industrial and commercial."""
    tlon = {}
    with open(fetch("gaz"), encoding="utf-8") as f:
        for line in f:
            p = line.split("\t")
            if p[0] == "USPS":
                continue
            tlon[p[1].strip()] = float(p[-1])

    sub = {}
    with gzip.open(fetch("xwalk"), "rt") as f:
        for r in csv.DictReader(f):
            sub[r["tabblk2020"]] = (r["cty"], r["ctycsubname"])

    out = {}
    with gzip.open(fetch("wac"), "rt") as f:
        for r in csv.DictReader(f):
            g = sub.get(r["w_geocode"])
            if not g or g[0] != "15003":        # Honolulu County == Oahu
                continue
            d = g[1].split(" CCD")[0]
            if d == "Ewa":                       # split exactly as the bus file does
                lon = tlon.get(r["w_geocode"][:11])
                d = "Ewa-West" if (lon is not None and lon < EWA_SPLIT_LON) else "Ewa-Central"
            e = out.setdefault(d, {"ind": 0, "com": 0})
            e["ind"] += sum(int(r[c]) for c in IND)
            e["com"] += sum(int(r[c]) for c in COM)
    return out


def main() -> None:
    print("Set 9 -- rebuilding the per-bus load allocation\n")
    f_res, f_com, f_ind = sector_weights()
    print(f"  EIA-861 Hawaii {YEAR} sector shares of retail sales:")
    print(f"    residential {f_res:6.2%}   commercial {f_com:6.2%}   industrial {f_ind:6.2%}\n")

    jobs  = jobs_by_district()
    buses = list(csv.DictReader(open(PROCESSED / "oahu_network_buses.csv")))
    pop   = {b["bus"]: float(b["population_2020"]) for b in buses}
    old   = {b["bus"]: float(b["load_share"])      for b in buses}

    # Kahe is a pure generation node and carries no load in this network.
    for b in buses:
        jobs.setdefault(b["bus"], {"ind": 0, "com": 0})
    jobs["Kahe"] = {"ind": 0, "com": 0}

    tp = sum(pop.values())
    ti = sum(j["ind"] for j in jobs.values())
    tc = sum(j["com"] for j in jobs.values())

    raw = {b["bus"]: (f_res * pop[b["bus"]] / tp
                      + f_com * jobs[b["bus"]]["com"] / tc
                      + f_ind * jobs[b["bus"]]["ind"] / ti) for b in buses}
    tot = sum(raw.values())
    new = {k: v / tot for k, v in raw.items()}

    print("  %-14s %9s %9s %9s" % ("bus", "old", "new", "change"))
    print("  " + "-" * 44)
    for n in sorted(new, key=lambda k: -new[k]):
        print("  %-14s %8.2f%% %8.2f%% %+8.2fpp" % (n, 100 * old[n], 100 * new[n],
                                                    100 * (new[n] - old[n])))

    path = OUT / "oahu_bus_load_shares_v2.csv"
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["bus", "load_share_v2", "load_share_v1_population",
                    "population_2020", "jobs_commercial", "jobs_industrial",
                    "f_res", "f_com", "f_ind", "source"])
        src = (f"v2: EIA-861 {YEAR} HI sector sales weights applied to Census 2020 population "
               f"(residential) and LEHD LODES8 {YEAR} WAC workplace jobs (commercial, industrial); "
               f"Ewa split by tract centroid at {EWA_SPLIT_LON} W. Excludes uniformed military.")
        for n in new:
            w.writerow([n, f"{new[n]:.6f}", f"{old[n]:.6f}", int(pop[n]),
                        jobs[n]["com"], jobs[n]["ind"],
                        f"{f_res:.4f}", f"{f_com:.4f}", f"{f_ind:.4f}", src])
    print(f"\n  wrote {path}")
    json.dump(new, open(OUT / "oahu_bus_load_shares_v2.json", "w"), indent=1)


if __name__ == "__main__":
    main()
