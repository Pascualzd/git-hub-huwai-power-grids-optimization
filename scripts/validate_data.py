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
    print(
        "Validated 8,760 load hours and "
        f"{len(generators)} resources ({generators.p_max_mw.sum():.1f} MW)."
    )


if __name__ == "__main__":
    main()
