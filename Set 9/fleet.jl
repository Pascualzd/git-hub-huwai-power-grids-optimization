# =====================================================================
# Set 9 -- fleet.jl
#
# The Oʻahu case, loaded WITH the two generator columns Set 8 ignored.
#
# This is the whole premise of Set 9. `oahu_generators.csv` has carried
# `p_min_mw` and `ramp_mw_per_hr` since the data was assembled; Set 8's
# `cases.jl` reads only `p_max_mw` and `varcost_usd_per_mwh`. Nothing new
# was collected here -- we simply stopped discarding two columns.
#
# PROVENANCE, restated so nobody has to go digging:
#
#   p_max_mw              REAL   EIA-860 2024 summer capacity
#   varcost_usd_per_mwh   REAL   EIA-923 2024 heat rate, HECO IGP 2022
#                                fuel forecast, NREL ATB VOM proxy
#   p_min_mw              ASSUMED  by technology class (see the CSV's
#   ramp_mw_per_hr        ASSUMED  own `constraint_source` column)
#   min up/down, start-up cost   ASSUMED here, in this file, below
#
# DEMAND -- this is the one place Set 9 went past Set 8, and it exists in
# three versions:
#
#   v1  `load_share * island_total`, population shares frozen. Set 8's
#       assumption, kept so it can still be reproduced exactly.
#   v2  the same frozen product, but with sector-weighted shares built from
#       EIA-861 sales and LODES workplace jobs (`prepare_demand.py`).
#       This is the DEFAULT for `oahu_set9`.
#   v3  `oahu_hourly_demand` below -- a full 9 x 8,760 matrix whose mix
#       changes every hour (`prepare_hourly_demand.py`). Rank 2, not rank
#       1: the demand direction finally moves.
#
# The island TOTAL is identical in all three and is not reconstructed: it is
# the 2021 base scenario from Hawaiian Electric's IGP O'ahu Inputs Workbook
# 3. That is a FILED PLANNING PROFILE, not metered system load. Only the
# split across buses is reconstructed -- see `DATA_REBUILD.md`.
# =====================================================================

using CSV, DataFrames

const PROCESSED = joinpath(@__DIR__, "..", "data", "processed")

const VOLL      = 10_000.0   # $/MWh, matching Set 8
const BASE_MVA  = 100.0
const TIEBREAK  = 1e-6       # keeps dispatch unique between equal-cost units

"""
Minimum up/down times in hours, by technology.

ASSUMED. These are not in any data file. They are conventional values for
each technology class and they are the single biggest judgement call in
Set 9, because they are what makes commitment actually bite: a unit needed
for the evening peak that cannot shut off for four hours must idle through
the midday solar trough at its minimum output.
"""
const MIN_UP = Dict(
    "municipal_waste"     => 24,   # H-Power burns refuse continuously; effectively must-run
    "combined_cycle"      => 6,
    "steam"               => 8,
    "combustion_turbine"  => 1,
    "internal_combustion" => 1,
)
const MIN_DOWN = Dict(
    "municipal_waste"     => 24,
    "combined_cycle"      => 4,
    "steam"               => 8,
    "combustion_turbine"  => 1,
    "internal_combustion" => 1,
)

"""Start-up cost in USD per MW of capacity. ASSUMED, conventional by class."""
const STARTUP_PER_MW = Dict(
    "municipal_waste"     => 100.0,
    "combined_cycle"      => 55.0,
    "steam"               => 75.0,
    "combustion_turbine"  => 20.0,
    "internal_combustion" => 20.0,
)

struct Set9Case
    name      :: String
    nbus      :: Int
    # generators
    gen_bus   :: Vector{Int}
    pmin      :: Vector{Float64}
    pmax      :: Vector{Float64}
    cost      :: Vector{Float64}
    ramp      :: Vector{Float64}
    minup     :: Vector{Int}
    mindown   :: Vector{Int}
    startup   :: Vector{Float64}
    gen_name  :: Vector{String}
    gen_tech  :: Vector{String}
    # network
    fbus      :: Vector{Int}
    tbus      :: Vector{Int}
    sus       :: Vector{Float64}
    rate      :: Vector{Float64}
    # demand
    share     :: Vector{Float64}
    slack     :: Int
    bus_name  :: Vector{String}
end

"""
    oahu_set9(; shares = :v2)

The same 9-bus network Set 8 used -- identical buses, identical branches,
identical line ratings -- with the generator operating constraints attached.

`shares` selects how island demand is split across buses:

  `:v1`  2020 resident population alone. What Set 8 and the first Set 9
         run used.
  `:v2`  EIA-861 sector weights applied to Census population (residential)
         and LEHD LODES workplace jobs (commercial, industrial). Built by
         `prepare_demand.py`; see that file for sources and limitations.

Both are FROZEN: one share vector reused in all 8,760 hours, so the demand
direction cannot move. For demand whose mix changes hour to hour, use
`oahu_hourly_demand(case)` below -- that is v3.

Both are provided so the effect of the allocation can be isolated from the
effect of everything else -- the same one-change-at-a-time discipline the
constraint ladder uses.
"""
function oahu_set9(; shares::Symbol = :v2)
    busdf = CSV.read(joinpath(PROCESSED, "oahu_network_buses.csv"), DataFrame)
    brdf  = CSV.read(joinpath(PROCESSED, "oahu_network_branches.csv"), DataFrame)
    gendf = CSV.read(joinpath(PROCESSED, "oahu_generators.csv"), DataFrame)
    mapdf = CSV.read(joinpath(PROCESSED, "oahu_generator_bus_map.csv"), DataFrame)

    idx = Dict(String(b) => i for (i, b) in enumerate(busdf.bus))

    share = if shares === :v1
        Float64.(busdf.load_share)
    elseif shares === :v2
        p = joinpath(@__DIR__, "data", "oahu_bus_load_shares_v2.csv")
        isfile(p) || error("missing $p -- run: python3 \"Set 9/prepare_demand.py\"")
        v2 = CSV.read(p, DataFrame)
        m  = Dict(String(r.bus) => Float64(r.load_share_v2) for r in eachrow(v2))
        [m[String(b)] for b in busdf.bus]
    else
        error("shares must be :v1 or :v2, got $shares")
    end

    genbus = Dict(String(r.name) => String(r.bus) for r in eachrow(mapdf))
    gbus   = [idx[genbus[String(n)]] for n in gendf.name]
    tech   = String.(gendf.technology)

    Set9Case(
        "Oʻahu 9-bus, Set 9 constraints",
        nrow(busdf),
        gbus,
        Float64.(gendf.p_min_mw),
        Float64.(gendf.p_max_mw),
        Float64.(gendf.varcost_usd_per_mwh),
        Float64.(gendf.ramp_mw_per_hr),
        [MIN_UP[t]   for t in tech],
        [MIN_DOWN[t] for t in tech],
        [STARTUP_PER_MW[t] * p for (t, p) in zip(tech, Float64.(gendf.p_max_mw))],
        String.(gendf.name),
        tech,
        [idx[String(b)] for b in brdf.from_bus],
        [idx[String(b)] for b in brdf.to_bus],
        1 ./ Float64.(brdf.x_pu),
        Float64.(brdf.limit_mw),
        share,
        idx["Honolulu"],
        String.(busdf.bus),
    )
end

"""
    oahu_hourly_demand(case)

The bus-by-hour demand matrix built by `prepare_hourly_demand.py` -- 9 buses
by 8,760 hours, with a mix that CHANGES every hour.

This is the only demand source in the project that is not rank one. v1 and v2
both scale a single fixed share vector, so their 78,840 entries carry 8,760
pieces of information and the demand direction can never move. Here offices,
houses and industry are separated, given their own daily shapes and their own
spatial footprints, and recombined -- so the island's demand vector rotates
through the day. Honolulu's share runs from about 52% at midnight to 85% at
midday.

The measured island total is preserved exactly; only its distribution moves.
"""
function oahu_hourly_demand(case)
    p = joinpath(@__DIR__, "data", "oahu_bus_hourly_demand.csv")
    isfile(p) || error("missing $p -- run: python3 \"Set 9/prepare_hourly_demand.py\"")
    df = CSV.read(p, DataFrame)
    D  = Matrix{Float64}(undef, case.nbus, nrow(df))
    for (i, b) in enumerate(case.bus_name)
        D[i, :] = Float64.(df[!, Symbol("load_$(b)_mw")])
    end
    return D
end

"""
The island's 8,760-hour load series for 2021: the base scenario of Hawaiian
Electric's IGP O'ahu Inputs Workbook 3. A FILED PLANNING PROFILE, not metered
system load -- the distinction matters when quoting it. Net load is gross
minus the behind-the-meter layers (DGPV, storage, efficiency, TOU shifting).
Annual mean 743.86 MW; peak 1,054.26 MW in hour 6,331 (2021-09-21 19:00 HST).
"""
oahu_net_load() =
    Float64.(CSV.read(joinpath(PROCESSED, "oahu_load_8760.csv"), DataFrame).net_load_mw)

"""Gross load from the same filed profile, before the behind-the-meter layers."""
oahu_gross_load() =
    Float64.(CSV.read(joinpath(PROCESSED, "oahu_load_8760.csv"), DataFrame).gross_load_mw)
