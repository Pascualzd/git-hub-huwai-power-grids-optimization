#!/usr/bin/env python3
"""Bundle the processed network results into a single JSON for the interactive viewer.

The TypeScript app in `viz/` consumes exactly one file, `viz/src/network.json`, so it never
has to parse CSVs or worry about fetch paths. Everything the explorer shows — per-plant
capacities and costs, per-bus loads and prices, per-line flows, and the three-model cost
comparison — is merged here from the committed `data/processed/` CSVs.
"""

from __future__ import annotations

import json
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
PROCESSED = ROOT / "data" / "processed"
OUTPUT = ROOT / "viz" / "src" / "network.json"


def read(name: str) -> pd.DataFrame:
    return pd.read_csv(PROCESSED / f"{name}.csv")


def summary_lookup() -> dict[str, str]:
    frame = read("analysis_summary")
    return dict(zip(frame.metric, frame.value))


def main() -> None:
    buses = read("oahu_network_buses")
    branches = read("oahu_network_branches")
    generators = read("oahu_generators")
    genmap = read("oahu_generator_bus_map")[["name", "bus"]]
    lmps = read("network_lmps")
    flows = read("network_flows_single")
    dispatch = read("network_dispatch_single")[["name", "dispatch_mw", "emissions_kg_co2"]]
    costs = read("network_cost_comparison")
    summary = summary_lookup()

    # Per-generator record: static fleet parameters joined to the peak-hour DC-OPF result.
    fleet = generators.merge(genmap, on="name", how="left").merge(dispatch, on="name", how="left")
    generator_records = [
        {
            "name": row["name"],
            "bus": row["bus"],
            "fuel": row["fuel"],
            "technology": row["technology"],
            "plantCode": int(row["plant_code"]),
            "pMinMw": round(float(row["p_min_mw"]), 2),
            "pMaxMw": round(float(row["p_max_mw"]), 2),
            "varCostUsdPerMwh": round(float(row["varcost_usd_per_mwh"]), 2),
            "rampMwPerHr": round(float(row["ramp_mw_per_hr"]), 2),
            "heatRateMmbtuPerMwh": round(float(row["heat_rate_mmbtu_per_mwh"]), 3),
            "co2KgPerMwh": round(float(row["co2_kg_per_mwh"]), 1),
            "dispatchMw": round(float(row["dispatch_mw"]), 2),
            "emissionsKgCo2": round(float(row["emissions_kg_co2"]), 1),
            "capacitySource": row["capacity_source"],
            "varCostSource": row["varcost_source"],
            "constraintSource": row["constraint_source"],
        }
        for _, row in fleet.iterrows()
    ]

    capacity_by_bus = fleet.groupby("bus").p_max_mw.sum()
    dispatch_by_bus = fleet.groupby("bus").dispatch_mw.sum()
    emissions_by_bus = fleet.groupby("bus").emissions_kg_co2.sum()
    price = lmps.set_index("bus")

    bus_records = [
        {
            "id": row["bus"],
            "district": row["district"],
            "latitude": float(row["latitude"]),
            "longitude": float(row["longitude"]),
            "population2020": int(row["population_2020"]),
            "loadShare": round(float(row["load_share"]), 4),
            "demandMw": round(float(price.loc[row["bus"], "demand_mw"]), 2),
            "lmpUsdPerMwh": round(float(price.loc[row["bus"], "lmp_usd_per_mwh"]), 2),
            "unservedMw": round(float(price.loc[row["bus"], "unserved_mw"]), 3),
            "generationCapacityMw": round(float(capacity_by_bus.get(row["bus"], 0.0)), 2),
            "dispatchMw": round(float(dispatch_by_bus.get(row["bus"], 0.0)), 2),
            "emissionsKgCo2": round(float(emissions_by_bus.get(row["bus"], 0.0)), 1),
            "generatorCount": int((fleet.bus == row["bus"]).sum()),
        }
        for _, row in buses.iterrows()
    ]

    flow = flows.set_index("branch")
    branch_records = [
        {
            "id": int(row["branch"]),
            "from": row["from_bus"],
            "to": row["to_bus"],
            "corridor": row["corridor"],
            "circuits": int(row["circuits"]),
            "lengthMi": round(float(row["length_mi"]), 2),
            "reactancePu": round(float(row["x_pu"]), 4),
            "limitMw": round(float(row["limit_mw"]), 1),
            "flowMw": round(float(flow.loc[row["branch"], "flow_mw"]), 2),
            "loading": round(float(flow.loc[row["branch"], "loading"]), 4),
        }
        for _, row in branches.iterrows()
    ]

    cost_records = {
        row["mode"]: {
            "totalCostUsd": round(float(row["total_cost_usd"]), 2),
            "generationCostUsd": round(float(row["generation_cost_usd"]), 2),
            "transportCostUsd": round(float(row["transport_cost_usd"]), 2),
            "unservedMwh": round(float(row["unserved_mwh"]), 4),
        }
        for _, row in costs.iterrows()
    }

    payload = {
        "meta": {
            "peakHour": int(summary["annual_net_peak_hour"]),
            "peakDemandMw": float(summary["annual_net_peak_mw"]),
            "islandLmpUsdPerMwh": float(summary["peak_hour_marginal_cost_usd_per_mwh"]),
            "congestionCostUsdPerHr": float(summary["network_congestion_cost_usd_per_hr"]),
            "loopflowCostUsdPerHr": float(summary["network_loopflow_cost_usd_per_hr"]),
            "bindingBranch": summary["network_binding_branch_peak"],
            "highestLmpBus": summary["network_highest_lmp_bus"],
            "lmpSpanUsdPerMwh": summary["network_lmp_span_usd_per_mwh"],
        },
        "buses": bus_records,
        "branches": branch_records,
        "generators": generator_records,
        "costs": cost_records,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, indent=2))
    print(
        f"Wrote {OUTPUT.relative_to(ROOT)}: {len(bus_records)} buses, "
        f"{len(branch_records)} branches, {len(generator_records)} generators."
    )


if __name__ == "__main__":
    main()
