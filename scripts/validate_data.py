#!/usr/bin/env python3
"""Fail fast on malformed or internally inconsistent processed inputs."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
PROCESSED = ROOT / "data" / "processed"


def main() -> None:
    load = pd.read_csv(PROCESSED / "oahu_load_8760.csv")
    generators = pd.read_csv(PROCESSED / "oahu_generators.csv")

    expected_load = ["hour", "gross_load_mw", "net_load_mw"]
    required_generators = [
        "name",
        "fuel",
        "p_min_mw",
        "p_max_mw",
        "varcost_usd_per_mwh",
        "ramp_mw_per_hr",
        "source",
    ]
    assert list(load.columns) == expected_load, f"load columns must be {expected_load}"
    assert len(load) == 8760, "load profile must contain exactly 8,760 hours"
    assert load.hour.tolist() == list(range(1, 8761)), "hour must be contiguous and 1-based"
    assert not load.isna().any().any(), "load profile contains missing values"
    assert (load[["gross_load_mw", "net_load_mw"]] >= 0).all().all(), "negative load"
    assert set(required_generators).issubset(generators.columns), "generator columns missing"
    assert len(generators) == 24, "expected the documented 24-resource Oʻahu fleet"
    assert generators.name.is_unique, "generator names must be unique"
    assert not generators[required_generators].isna().any().any(), "generator values missing"
    assert (generators.p_min_mw >= 0).all(), "negative minimum output"
    assert (generators.p_max_mw > 0).all(), "non-positive maximum output"
    assert (generators.p_min_mw <= generators.p_max_mw).all(), "Pmin exceeds Pmax"
    assert (generators.ramp_mw_per_hr > 0).all(), "non-positive ramp rate"
    assert generators.source.str.contains("assumed operating constraints").all(), (
        "assumed constraint provenance must remain visible"
    )
    assert generators.p_max_mw.sum() >= load.net_load_mw.max(), "fleet cannot meet peak load"
    peak_index = int(load.net_load_mw.idxmax())
    peak_day_start = (peak_index // 24) * 24
    peak_day_minimum = load.net_load_mw.iloc[peak_day_start : peak_day_start + 24].min()
    assert generators.p_min_mw.sum() <= peak_day_minimum, (
        "minimum output exceeds load in the modeled 24-hour peak window"
    )
    assert np.isfinite(generators.varcost_usd_per_mwh).all(), "non-finite variable cost"

    validate_network(generators)

    print(
        "Validated 8,760 load hours and "
        f"{len(generators)} resources ({generators.p_max_mw.sum():.1f} MW)."
    )


def validate_network(generators: pd.DataFrame) -> None:
    buses = pd.read_csv(PROCESSED / "oahu_network_buses.csv")
    branches = pd.read_csv(PROCESSED / "oahu_network_branches.csv")
    generator_bus = pd.read_csv(PROCESSED / "oahu_generator_bus_map.csv")

    bus_names = set(buses.bus)
    assert buses.bus.is_unique, "bus names must be unique"
    assert np.isclose(buses.load_share.sum(), 1.0), "bus load shares must sum to one"
    assert (buses.load_share >= 0).all(), "negative load share"
    assert (buses.latitude.between(21.2, 21.8)).all(), "a bus is outside Oʻahu's latitude band"
    assert (buses.longitude.between(-158.4, -157.6)).all(), "a bus is outside Oʻahu's longitude band"

    assert branches.branch.is_unique, "branch ids must be unique"
    assert set(branches.from_bus) <= bus_names, "a branch starts at an unknown bus"
    assert set(branches.to_bus) <= bus_names, "a branch ends at an unknown bus"
    assert (branches.x_pu > 0).all(), "non-positive branch reactance"
    assert (branches.limit_mw > 0).all(), "non-positive branch thermal limit"
    assert (branches.transport_cost_usd_per_mwh >= 0).all(), "negative transport cost"

    # DC-OPF only differs from the transportation model on a meshed network, so the loop
    # count is a hard requirement, not a nicety.
    connected = set(branches.from_bus) | set(branches.to_bus)
    assert connected == bus_names, "some bus is disconnected from every branch"
    loops = len(branches) - len(buses) + 1
    assert loops >= 1, "network is radial; DC-OPF would collapse to the transportation model"

    assert set(generator_bus.name) == set(generators.name), "generator/bus map is out of sync with the fleet"
    assert set(generator_bus.bus) <= bus_names, "a generator is mapped to an unknown bus"
    assert (generator_bus.p_max_mw.sum() - generators.p_max_mw.sum()) < 1e-6, "fleet capacity drifted in the bus map"

    print(
        f"Validated {len(buses)}-bus network with {len(branches)} branches "
        f"({loops} independent loops)."
    )


if __name__ == "__main__":
    main()
