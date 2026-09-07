#=
cases.jl -- turn the two datasets into one common shape.

Q2 runs on IEEE-14, a textbook network. Q3 runs on the 9-bus Oʻahu model built
from Hawaiian Electric and EIA filings. They arrive in different file layouts,
different column names and different units, and the whole point of Set 8 is to
ask IDENTICAL questions of both. So both are loaded into the same `GridCase`
struct and from then on the Monte Carlo cannot tell them apart.

THE CALIBRATION DECISION
------------------------
The assignment says the exponential's mean should "come from the real power
network". For Oʻahu that is literal: bus i's mean is its population share of
the real 8,760-hour average. For IEEE-14 it needs a translation, because a
textbook network has no Hawaii in it.

The translation used here is CAPACITY UTILISATION. Oʻahu carries a mean net
load of 743.86 MW against 1,508.1 MW of installed firm capacity -- it runs, on
average, at 49.3% of what it owns. Applying that same ratio to IEEE-14's
772.4 MW of capacity gives a target mean of about 381 MW, which is then split
across the eleven load buses in the proportions of the published case14 load
vector.

Why this and not the raw 259 MW textbook load: the three questions Set 8 asks
are all questions about HEADROOM. "How often does the expensive unit run" and
"how often do we shed" are almost entirely determined by the ratio of mean
demand to installed capacity, so comparing a toy at 33.5% utilisation with a
real island at 49.3% would be comparing the calibration, not the networks.
Fixing utilisation makes the comparison about topology and fleet structure,
which is what we actually want to see.

The native 259 MW case is still run, as a labelled reference point.
=#

using CSV, DataFrames, Statistics, Printf

include(joinpath(@__DIR__, "montecarlo.jl"))

const REPO = dirname(@__DIR__)
const PROCESSED = joinpath(REPO, "data", "processed")
const IEEE14_DIR = joinpath(REPO, "OPT simple case", "ieee14")


# ===========================================================================
# IEEE-14
# ===========================================================================
"""
    ieee14_case(; mean_total = nothing)

Load MATPOWER case14 as a `GridCase`.

`mean_total` sets the SYSTEM mean demand in MW; the published per-bus load
vector is rescaled to hit it while keeping each bus's share of the island
unchanged. Pass `nothing` to keep the textbook 259 MW.

Two data notes inherited from Part 3, repeated here because they change the
answers:

  * case14 publishes rateA = 0 on every branch, which in MATPOWER means "no
    thermal limit". A literal 0 would clamp every flow to zero. Part 3 stored
    9900 as the sentinel. For a CONGESTION study an unlimited network is
    useless -- no line can ever bind -- so ratings are assigned the same way
    Part 3's Scenario B assigns them: 1.5x the flow each line carries in the
    base case, floored at 25 MW. Those are the ratings a planner would build
    if they sized the network for today's duty and no more.

  * branches 4-7, 4-9 and 5-6 are off-nominal-tap transformers. The DC
    approximation ignores the tap and uses b = 1/x, as in Parts 2-5.
"""
function ieee14_case(; mean_total = nothing, headroom = 1.5, floor_mw = 25.0,
                       rate_override = nothing)
    gen     = CSV.read(joinpath(IEEE14_DIR, "gen.csv"),     DataFrame)
    gencost = CSV.read(joinpath(IEEE14_DIR, "gencost.csv"), DataFrame)
    branch  = CSV.read(joinpath(IEEE14_DIR, "branch.csv"),  DataFrame)
    bus     = CSV.read(joinpath(IEEE14_DIR, "bus.csv"),     DataFrame)
    for f in (gen, gencost, branch, bus); rename!(f, lowercase.(names(f))); end

    nbus    = nrow(bus)
    baseMVA = 100.0
    slack   = findfirst(==(3), bus.type)

    # buses are numbered 1..14 in order, so index == bus_i, but map explicitly
    idx = Dict(b => i for (i, b) in enumerate(bus.bus_i))

    mu = Float64.(bus.pd)
    if mean_total !== nothing
        base = sum(mu)
        base > 0 || error("case14 has no load to rescale")
        mu .*= (mean_total / base)
    end

    sus = 1 ./ Float64.(branch.x)
    fb  = [idx[b] for b in branch.fbus]
    tb  = [idx[b] for b in branch.tbus]

    # --- assign ratings from a base-case solve -----------------------------
    # Build a throwaway case with effectively infinite ratings, solve it at the
    # DESIGN MEAN, and size every line at `headroom` times the flow it carries.
    #
    # `rate_override` EXISTS FOR THE STRESS SWEEP, and it fixes a real bug.
    # Sizing lines from the base case means that changing `mean_total` also
    # changes the NETWORK -- total ratings run from 927 MW at half load to
    # 1,823 MW at 1.6x, and at the extremes the rating vector reshapes entirely
    # because the base dispatch itself moves. A sweep built that way is not
    # measuring "risk as a function of headroom" at all; it is measuring a
    # different grid at every point, and it comes out far too flat.
    #
    # So the sweep builds the network ONCE at lambda = 1 and passes those
    # ratings in here for every other lambda.
    if rate_override !== nothing
        length(rate_override) == nrow(branch) ||
            error("rate_override must have one entry per branch")
        return GridCase("IEEE 14-bus", nbus,
                        [idx[b] for b in gen.bus],
                        Float64.(gen.pmax), Float64.(gencost.c1),
                        ["G$(i) @ bus $(gen.bus[i])" for i in 1:nrow(gen)],
                        fb, tb, sus, Float64.(collect(rate_override)), mu,
                        slack, baseMVA,
                        ["bus $(b)" for b in bus.bus_i],
                        Dict(i => IEEE14_XY[bus.bus_i[i]] for i in 1:nbus))
    end

    tmp = GridCase("ieee14-sizing", nbus, [idx[b] for b in gen.bus],
                   Float64.(gen.pmax), Float64.(gencost.c1),
                   ["G$(i)@bus$(gen.bus[i])" for i in 1:nrow(gen)],
                   fb, tb, sus, fill(1e6, nrow(branch)), mu, slack, baseMVA,
                   ["bus $(b)" for b in bus.bus_i],
                   Dict(i => IEEE14_XY[bus.bus_i[i]] for i in 1:nbus))
    m0 = build_model(tmp); set_demand!(m0, tmp, mu); optimize!(m0.model)
    termination_status(m0.model) == MOI.OPTIMAL ||
        error("IEEE-14 base case failed to solve while sizing lines")
    base_flow = collect(value.(m0.F).data)
    rate = [max(floor_mw, ceil(headroom * abs(f))) for f in base_flow]

    return GridCase("IEEE 14-bus", nbus,
                    [idx[b] for b in gen.bus],
                    Float64.(gen.pmax),
                    Float64.(gencost.c1),
                    ["G$(i) @ bus $(gen.bus[i])" for i in 1:nrow(gen)],
                    fb, tb, sus, rate, mu, slack, baseMVA,
                    ["bus $(b)" for b in bus.bus_i],
                    Dict(i => IEEE14_XY[bus.bus_i[i]] for i in 1:nbus))
end

# Standard IEEE-14 single-line-diagram layout, reused from gridviz.jl so every
# picture in the project places the same bus in the same spot.
const IEEE14_XY = Dict(
    1 => (0.00, 0.00),   2 => (1.30, 0.55),   3 => (2.75, 0.35),
    4 => (2.05, 1.55),   5 => (0.95, 1.50),   6 => (0.35, 2.55),
    7 => (2.55, 2.30),   8 => (3.45, 2.35),   9 => (2.25, 2.95),
   10 => (1.65, 3.35),  11 => (0.85, 3.15),  12 => (0.15, 3.45),
   13 => (0.75, 3.85),  14 => (1.85, 4.05))


# ===========================================================================
# OʻAHU
# ===========================================================================
"""
    oahu_case(; mean_total = nothing)

Load the 9-bus Oʻahu model as a `GridCase`.

Provenance is documented in the repository's `SOURCES.md`; in brief:
  buses      Census 2020 judicial districts, Ewa split to expose generation
  loads      island net load allocated by resident population share
  branches   138 kV two-corridor ring, 200 MW per circuit
  fleet      EIA-860 summer capacity, EIA-923 heat rates, HECO fuel forecast

`mean_total` defaults to the real annual mean net load, 743.86 MW.

The slack bus is Honolulu: it is the largest load centre and the electrical
centre of the southern corridor, which makes it the natural angle reference.
"""
function oahu_case(; mean_total = nothing)
    busdf = CSV.read(joinpath(PROCESSED, "oahu_network_buses.csv"), DataFrame)
    brdf  = CSV.read(joinpath(PROCESSED, "oahu_network_branches.csv"), DataFrame)
    gendf = CSV.read(joinpath(PROCESSED, "oahu_generators.csv"), DataFrame)
    mapdf = CSV.read(joinpath(PROCESSED, "oahu_generator_bus_map.csv"), DataFrame)
    load  = CSV.read(joinpath(PROCESSED, "oahu_load_8760.csv"), DataFrame)

    nbus = nrow(busdf)
    idx  = Dict(String(b) => i for (i, b) in enumerate(busdf.bus))

    mean_net = mean(load.net_load_mw)
    target   = mean_total === nothing ? mean_net : mean_total
    mu       = Float64.(busdf.load_share) .* target

    fb = [idx[String(b)] for b in brdf.from_bus]
    tb = [idx[String(b)] for b in brdf.to_bus]
    sus = 1 ./ Float64.(brdf.x_pu)

    genbus = Dict(String(r.name) => String(r.bus) for r in eachrow(mapdf))
    gbus = [idx[genbus[String(n)]] for n in gendf.name]

    # Geographic layout: longitude east, latitude north, so the picture is a
    # real map of Oʻahu rather than an abstract graph.
    coords = Dict(i => (Float64(busdf.longitude[i]), Float64(busdf.latitude[i]))
                  for i in 1:nbus)

    return GridCase("Oʻahu 9-bus", nbus, gbus,
                    Float64.(gendf.p_max_mw),
                    Float64.(gendf.varcost_usd_per_mwh),
                    String.(gendf.name),
                    fb, tb, sus, Float64.(brdf.limit_mw), mu,
                    idx["Honolulu"], 100.0,
                    String.(busdf.bus), coords)
end

"""Real hourly net load, MW -- the 8,760-point empirical record."""
oahu_hourly_net_load() =
    Float64.(CSV.read(joinpath(PROCESSED, "oahu_load_8760.csv"), DataFrame).net_load_mw)

"""Per-bus population load shares, aligned to `oahu_case()` bus order."""
oahu_load_shares() =
    Float64.(CSV.read(joinpath(PROCESSED, "oahu_network_buses.csv"), DataFrame).load_share)
