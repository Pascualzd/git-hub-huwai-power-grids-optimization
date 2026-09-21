#!/usr/bin/env python3
"""
Set 9 -- prepare_hourly_demand.py

Build HOURLY demand at every bus, with a mix that changes hour by hour.

THE PROBLEM THIS SOLVES
Every earlier version of this project split the island total across buses by
one fixed vector -- population in Set 8, sector-weighted population and jobs
in `prepare_demand.py`. Either way the demand matrix was RANK ONE: 78,840
entries carrying only 8,760 pieces of information, because the nine numbers
could only grow and shrink together. The demand DIRECTION never moved, and
the paper's own central claim is that direction is what drives adequacy.

THE METHOD
Oahu's load is not one thing. It is offices downtown that peak at midday,
houses in the suburbs that peak in the evening, and industry that runs flat.
Those three have different spatial footprints AND different daily shapes, so
splitting them apart makes the island's demand vector rotate through the day.

    gross[s,t]  = sector s island load in hour t   (shape x annual energy,
                  then rescaled so the sectors sum to the real gross total)
    D[i,t]      = SUM_s a[i,s] * gross[s,t]  -  pv[i] * dgpv[t]

    a[i,res] = bus i share of resident population       (Census 2020)
    a[i,com] = bus i share of commercial jobs           (LODES 2021)
    a[i,ind] = bus i share of industrial jobs           (LODES 2021)
    pv[i]    = bus i share of rooftop PV                (assumed: population)

The island's measured hourly total is preserved EXACTLY. Only its
distribution across buses changes, and now it changes every hour.

SOURCES
  Sector energy shares  EIA Form 861, Sales to Ultimate Customers, 2021,
                        utility = "Hawaiian Electric Co Inc". That entity is
                        OAHU ONLY -- Maui Electric and Hawaii Electric Light
                        report separately. Its 6.17 TWh of retail sales against
                        6.52 TWh of measured net load is a ~5% gap, which is
                        what transmission and distribution losses look like.
  Building energy mix   EIA CBECS 2018 tables C22 and B1 -- electricity per worker
                        by principal building activity, used to weight the
                        commercial blend by estimated ENERGY, not headcount.
  Sector hourly shapes  OpenEI "Commercial and Residential Hourly Load Profiles
                        for all TMY3 Locations", Honolulu Intl AP station
                        911820. One residential profile and fifteen commercial
                        reference buildings, each a full 8,760 hours.
  Spatial keys          Census 2020 population; LEHD LODES8 2021 workplace jobs.
  Island load and DGPV  data/processed/oahu_load_components_2021.csv, from
                        Hawaiian Electric IGP Workbook 3.

LIMITATIONS
  1. The shapes are TYPICAL-YEAR reference buildings at Honolulu weather, not
     Oahu's metered sector loads. They carry the right diurnal character; they
     are not a measurement of what Oahu's offices actually did in 2021.
  2. Industrial is modelled FLAT. OpenEI has no industrial reference building,
     and EIA's "industrial" class on Oahu likely includes large federal and
     military accounts that behave more like big commercial customers.
  3. The split of each job category ACROSS building types (40/35/25 for offices,
     and so on in COM_BUILDINGS) is assumed -- no source gives it. TESTED: across
     300 random mixes the hour-of-day curve moves at most 0.062 of its own peak,
     and the peak hour never leaves 13:00, because every commercial building type
     shares a daytime-peaking profile. The real exposure is limitation 5.
  4. Rooftop PV is allocated by population. The right source is Hawaiian
     Electric's Locational Value Map, which is circuit-level but not available
     in bulk.
  5. LODES excludes uniformed military, so Wahiawa (Schofield) and Koolaupoko
     (Kaneohe) remain under-weighted. Unchanged from `prepare_demand.py`.

    python3 "Set 9/prepare_hourly_demand.py"
"""

import csv, gzip, io, math, pathlib, sys, urllib.request
from collections import defaultdict

HERE      = pathlib.Path(__file__).resolve().parent
PROCESSED = HERE.parent / "data" / "processed"
CACHE     = HERE / "data_cache"
OUT       = HERE / "data"
CACHE.mkdir(exist_ok=True, parents=True)
OUT.mkdir(exist_ok=True, parents=True)

YEAR          = 2021
EWA_SPLIT_LON = -158.075

# The OpenEI reference-building runs use a calendar whose 1 January is a SUNDAY;
# 2021's is a FRIDAY. Both years are non-leap, so the DATES line up -- but the
# WEEKDAYS are two days apart, and an earlier version of this script assumed they
# carried over. They do not. Left uncorrected, the simulated Saturday and Sunday
# get filed as Thursday and Friday, so offices read as busier at the weekend than
# midweek (weekend/weekday draw came out at 1.14x instead of 0.63x).
# Verified independently against three buildings with a real work-week signal --
# LargeOffice, PrimarySchool and Hospital all imply the same +2.
PROFILE_DOW_OFFSET = 2
OPENEI        = "https://openei.org/datasets/files/961/pub"
HNL           = "USA_HI_Honolulu.Intl.AP.911820_TMY3"

# Commercial reference buildings, and the LODES sector whose employment sets
# each one's weight in the composite commercial shape.
#   CNS07 retail          CNS08 transport/warehouse   CNS15 education
#   CNS16 health care     CNS18 accommodation+food
#   offices: CNS09-14 and CNS17, CNS19, CNS20
OFFICE = ["CNS09","CNS10","CNS11","CNS12","CNS13","CNS14","CNS17","CNS19","CNS20"]
COM_BUILDINGS = {
    "LargeOffice":            (OFFICE,   0.40),
    "MediumOffice":           (OFFICE,   0.35),
    "SmallOffice":            (OFFICE,   0.25),
    "Stand-aloneRetail":      (["CNS07"], 0.45),
    "StripMall":              (["CNS07"], 0.30),
    "SuperMarket":            (["CNS07"], 0.25),
    "LargeHotel":             (["CNS18"], 0.30),
    "SmallHotel":             (["CNS18"], 0.15),
    "FullServiceRestaurant":  (["CNS18"], 0.30),
    "QuickServiceRestaurant": (["CNS18"], 0.25),
    "Hospital":               (["CNS16"], 0.60),
    "OutPatient":             (["CNS16"], 0.40),
    "PrimarySchool":          (["CNS15"], 0.50),
    "SecondarySchool":        (["CNS15"], 0.50),
    "Warehouse":              (["CNS08"], 1.00),
}
# Jobs are a headcount, not a load. Weighting the building blend by headcount
# alone assumes an office worker and a hotel worker stand for the same kilowatts,
# and they do not -- by a factor of five. These convert headcount into estimated
# electricity: EIA CBECS 2018 table C22 (electricity by principal building
# activity) divided by table B1 (workers by the same activity). kWh/worker/year.
#   https://www.eia.gov/consumption/commercial/data/2018/ce/pdf/c22.pdf
#   https://www.eia.gov/consumption/commercial/data/2018/bc/html/b1.php
# NATIONAL figures -- CBECS publishes no state breakout at this detail.
CBECS_KWH_PER_WORKER = {
    "FoodSales":   58_888,   #  54 bn kWh /    917k workers
    "Lodging":     36_179,   # 100 bn kWh /  2,764k
    "FoodService": 21_151,   #  61 bn kWh /  2,884k
    "Mercantile":  20_266,   # 180 bn kWh /  8,882k
    "Inpatient":   18_071,   #  65 bn kWh /  3,597k
    "Warehouse":   13_416,   #  95 bn kWh /  7,081k
    "Education":   12_343,   # 128 bn kWh / 10,370k
    "Outpatient":  10_134,   #  31 bn kWh /  3,059k
    "Office":       6_912,   # 227 bn kWh / 32,843k  <- the least intense of all
}
BUILDING_TO_CBECS = {
    "LargeOffice": "Office", "MediumOffice": "Office", "SmallOffice": "Office",
    "Stand-aloneRetail": "Mercantile", "StripMall": "Mercantile",
    "SuperMarket": "FoodSales",
    "LargeHotel": "Lodging", "SmallHotel": "Lodging",
    "FullServiceRestaurant": "FoodService", "QuickServiceRestaurant": "FoodService",
    "Hospital": "Inpatient", "OutPatient": "Outpatient",
    "PrimarySchool": "Education", "SecondarySchool": "Education",
    "Warehouse": "Warehouse",
}

IND_CNS = ["CNS01","CNS02","CNS03","CNS04","CNS05","CNS06"]
COM_CNS = [f"CNS{i:02d}" for i in range(7, 21)]


def get(url, name):
    p = CACHE / name
    if not p.exists():
        print(f"  downloading {name} ...", flush=True)
        urllib.request.urlretrieve(url, p)
    return p


# ---------------------------------------------------------------- shapes
def read_profile(path):
    """Return a (month, is_weekend, hour) -> mean kW lookup from an OpenEI file."""
    tot = defaultdict(float); cnt = defaultdict(int)
    with open(path, newline="") as f:
        rd = csv.reader(f); hdr = next(rd)
        col = next(i for i, c in enumerate(hdr) if c.startswith("Electricity:Facility")
                   and "Hourly" in c)
        for i, row in enumerate(rd):
            if len(row) <= col or not row[col]:
                continue
            stamp = row[0].strip()                    # "01/01  01:00:00"
            mm = int(stamp[:2]); dd = int(stamp[3:5]); hh = int(stamp.split()[1][:2])
            hh = 0 if hh == 24 else hh
            # Dates carry over from the non-leap reference calendar to 2021;
            # weekdays do NOT. See PROFILE_DOW_OFFSET at the top of this file.
            dow = (_dow(YEAR, mm, dd) + PROFILE_DOW_OFFSET) % 7
            k = (mm, 1 if dow >= 5 else 0, hh)
            tot[k] += float(row[col]); cnt[k] += 1
    return {k: tot[k] / cnt[k] for k in tot}


def _dow(y, m, d):
    return (__import__("datetime").date(y, m, d).weekday())


def commercial_shape(jobs_total):
    """
    Energy-weighted composite of the fifteen commercial reference buildings.

    Each weight is (assumed mix within the job category) x (FILED LODES job count)
    x (CBECS electricity per worker). That last factor is what stops a headcount
    standing in for a load: offices hold 39.5% of O'ahu's commercial jobs but only
    18.4% of its estimated commercial electricity.
    """
    parts, wts = [], []
    for b, (cns, w) in COM_BUILDINGS.items():
        p = get(f"{OPENEI}/COMMERCIAL_LOAD_DATA_E_PLUS_OUTPUT/{HNL}/"
                f"RefBldg{b}New2004_v1.3_7.1_1A_USA_FL_MIAMI.csv", f"com_{b}.csv")
        lk = read_profile(p)
        s = sum(lk.values()) or 1.0
        parts.append({k: v / s for k, v in lk.items()})            # unit-energy shape
        wts.append(w * sum(jobs_total[c] for c in cns)
                     * CBECS_KWH_PER_WORKER[BUILDING_TO_CBECS[b]])
    W = sum(wts) or 1.0
    keys = set().union(*[set(p) for p in parts])
    return {k: sum(p.get(k, 0.0) * w for p, w in zip(parts, wts)) / W for k in keys}


def residential_shape():
    p = get(f"{OPENEI}/RESIDENTIAL_LOAD_DATA_E_PLUS_OUTPUT/BASE/{HNL}_BASE.csv",
            "res_base.csv")
    lk = read_profile(p)
    s = sum(lk.values()) or 1.0
    return {k: v / s for k, v in lk.items()}


# ---------------------------------------------------------------- spatial
def spatial_keys():
    tlon = {}
    with open(get("https://www2.census.gov/geo/docs/maps-data/data/gazetteer/"
                  "2020_Gazetteer/2020_gaz_tracts_15.txt", "gaz_tracts_15.txt"),
              encoding="utf-8") as f:
        for ln in f:
            p = ln.split("\t")
            if p[0] != "USPS":
                tlon[p[1].strip()] = float(p[-1])

    sub = {}
    with gzip.open(get("https://lehd.ces.census.gov/data/lodes/LODES8/hi/hi_xwalk.csv.gz",
                       "hi_xwalk.csv.gz"), "rt") as f:
        for r in csv.DictReader(f):
            sub[r["tabblk2020"]] = (r["cty"], r["ctycsubname"])

    per_bus = defaultdict(lambda: defaultdict(int)); island = defaultdict(int)
    with gzip.open(get(f"https://lehd.ces.census.gov/data/lodes/LODES8/hi/wac/"
                       f"hi_wac_S000_JT00_{YEAR}.csv.gz",
                       f"hi_wac_{YEAR}.csv.gz"), "rt") as f:
        for r in csv.DictReader(f):
            g = sub.get(r["w_geocode"])
            if not g or g[0] != "15003":
                continue
            d = g[1].split(" CCD")[0]
            if d == "Ewa":
                lon = tlon.get(r["w_geocode"][:11])
                d = "Ewa-West" if (lon is not None and lon < EWA_SPLIT_LON) else "Ewa-Central"
            for c in COM_CNS + IND_CNS:
                v = int(r[c]); per_bus[d][c] += v; island[c] += v
    return per_bus, island


# ---------------------------------------------------------------- sector energy
def sector_energy():
    """O'ahu-only sector shares: EIA-861, utility 'Hawaiian Electric Co Inc'."""
    try:
        import pandas as pd, zipfile
    except ImportError:
        sys.exit("pandas + openpyxl required")
    z = zipfile.ZipFile(get("https://www.eia.gov/electricity/data/eia861/archive/zip/"
                            f"f861{YEAR}.zip", f"f861{YEAR}.zip"))
    d = pd.read_excel(z.open(f"Sales_Ult_Cust_{YEAR}.xlsx"), header=None, skiprows=3).iloc[:, :24]
    d.columns = ["year","unum","uname","part","svc","dtype","state","own","ba",
                 "res_rev","res_mwh","res_cust","com_rev","com_mwh","com_cust",
                 "ind_rev","ind_mwh","ind_cust","tra_rev","tra_mwh","tra_cust",
                 "tot_rev","tot_mwh","tot_cust"]
    h = d[d.uname.astype(str).str.strip() == "Hawaiian Electric Co Inc"]
    g = {k: float(pd.to_numeric(h[k], errors="coerce").fillna(0).sum())
         for k in ("res_mwh", "com_mwh", "ind_mwh")}
    t = sum(g.values())
    return g["res_mwh"] / t, g["com_mwh"] / t, g["ind_mwh"] / t


# ---------------------------------------------------------------- main
def main():
    print("Set 9 -- building hourly per-bus demand\n")

    f_res, f_com, f_ind = sector_energy()
    print(f"  O'ahu-only sector shares (EIA-861, Hawaiian Electric Co Inc):")
    print(f"    residential {f_res:.2%}   commercial {f_com:.2%}   industrial {f_ind:.2%}\n")

    per_bus, island_jobs = spatial_keys()
    print("  building sector hourly shapes from Honolulu TMY3 profiles ...")
    sh_res = residential_shape()
    sh_com = commercial_shape(island_jobs)
    print("  shapes ready\n")

    # The components file carries an explicit HST timestamp; the 8,760 file does
    # not, so the timestamp is reconstructed from the hour index. Hour 1 is
    # 2021-01-01T01:00:00-10:00 in the components file, which fixes the offset.
    comp = PROCESSED / "oahu_load_components_2021.csv"
    rows = list(csv.DictReader(open(comp if comp.exists()
                                    else PROCESSED / "oahu_load_8760.csv")))
    if "timestamp_hst" not in rows[0]:
        import datetime as _dt
        base = _dt.datetime(YEAR, 1, 1, 0, 0)
        for r in rows:
            r["timestamp_hst"] = (base + _dt.timedelta(hours=int(r["hour"]))).isoformat()
    buses = list(csv.DictReader(open(PROCESSED / "oahu_network_buses.csv")))
    names = [b["bus"] for b in buses]
    pop   = {b["bus"]: float(b["population_2020"]) for b in buses}
    tp    = sum(pop.values())

    ci = sum(island_jobs[c] for c in COM_CNS) or 1
    ii = sum(island_jobs[c] for c in IND_CNS) or 1
    a_res = {n: pop[n] / tp for n in names}
    a_com = {n: sum(per_bus[n][c] for c in COM_CNS) / ci for n in names}
    a_ind = {n: sum(per_bus[n][c] for c in IND_CNS) / ii for n in names}
    for k in (a_res, a_com, a_ind):
        k["Kahe"] = 0.0
    # renormalise after zeroing the pure generation node
    for k in (a_res, a_com, a_ind):
        s = sum(k.values()) or 1.0
        for n in k: k[n] /= s
    a_pv = dict(a_res)                      # rooftop PV follows people (assumed)

    import datetime
    out = []
    for r in rows:
        ts    = datetime.datetime.fromisoformat(r["timestamp_hst"])
        gross = float(r["gross_load_mw"]); net = float(r["net_load_mw"])
        dgpv  = gross - net                 # everything netted out of gross
        key   = (ts.month, 1 if ts.weekday() >= 5 else 0, ts.hour)

        w_res = f_res * sh_res.get(key, 0.0)
        w_com = f_com * sh_com.get(key, 0.0)
        w_ind = f_ind * (1.0 / 8760.0)      # flat -- see limitation 2
        W = w_res + w_com + w_ind
        if W <= 0:
            w_res, w_com, w_ind, W = f_res, f_com, f_ind, 1.0
        g_res, g_com, g_ind = (w_res / W) * gross, (w_com / W) * gross, (w_ind / W) * gross

        d = {n: a_res[n]*g_res + a_com[n]*g_com + a_ind[n]*g_ind - a_pv[n]*dgpv
             for n in names}
        # DGPV can exceed a bus's gross draw at midday; the network model has no
        # negative load, so clip and give the surplus back proportionally.
        neg = sum(-v for v in d.values() if v < 0)
        if neg > 0:
            d = {n: max(v, 0.0) for n, v in d.items()}
            pos = sum(d.values()) or 1.0
            d = {n: v * (1 - neg / pos) if pos > neg else v for n, v in d.items()}
        s = sum(d.values()) or 1.0
        d = {n: v * net / s for n, v in d.items()}     # preserve the measured total exactly
        out.append((int(r["hour"]), r["timestamp_hst"], net, g_res, g_com, g_ind, dgpv, d))

    path = OUT / "oahu_bus_hourly_demand.csv"
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["hour", "timestamp_hst", "net_load_mw",
                    "gross_residential_mw", "gross_commercial_mw", "gross_industrial_mw",
                    "dgpv_mw"] + [f"load_{n}_mw" for n in names])
        for h, ts, net, gr, gc, gi, pv, d in out:
            w.writerow([h, ts, f"{net:.4f}", f"{gr:.4f}", f"{gc:.4f}", f"{gi:.4f}",
                        f"{pv:.4f}"] + [f"{d[n]:.4f}" for n in names])
    print(f"  wrote {path}  ({len(out)} hours x {len(names)} buses)")

    # ---- does the direction actually move now? ----
    shares = [[d[n] / max(sum(d.values()), 1e-9) for n in names] for *_, d in out]
    print("\n  BUS SHARE OF ISLAND LOAD -- min / mean / max across the year")
    print("  %-14s %8s %8s %8s %9s" % ("bus", "min", "mean", "max", "swing"))
    print("  " + "-" * 52)
    for j, n in enumerate(names):
        col = [s[j] for s in shares]
        lo, hi = min(col), max(col)
        print("  %-14s %7.2f%% %7.2f%% %7.2f%% %8.2fpp"
              % (n, 100*lo, 100*sum(col)/len(col), 100*hi, 100*(hi-lo)))


if __name__ == "__main__":
    main()
