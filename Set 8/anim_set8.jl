#=
anim_set8.jl -- the Monte Carlo, watched.

Q2 and Q3 answer the assignment in tables. A table of probabilities is the
right ANSWER but the wrong INSTRUMENT for seeing what is happening, because it
has already averaged away the thing being averaged.

This animation puts the 10,000 draws back in motion on the real map of Oʻahu.
Every frame is one sampled demand vector, solved. Nothing is illustrative:
the bus sizes, the flow directions, the colours and the numbers are all values
the LP returned for that draw.

THE TWO ACTS
------------
Act 1  ASSUMED DEMAND -- D_i = mu_i * Exp(1), the assignment's baseline.
       Demand lurches between a quarter and three times the island's average.
       Buses swell and collapse; the fleet climbs into its diesel peakers; and
       roughly one frame in five goes into load shedding, which the readout
       calls a blackout because that is what unserved load is.

Act 2  REAL DEMAND -- an hour resampled from the actual 8,760-hour record.
       The island stops lurching. Demand breathes inside a narrow band and the
       shedding stops completely. But watch the Ewa-West -> Ewa-Central
       corridor: under real load it is pinned at its limit almost permanently,
       far more often than the exponential ever suggested.

Put side by side, the two acts are the argument of Set 8 in one picture: the
assumed distribution does not merely exaggerate risk, it points at the wrong
risk.

GEOGRAPHY
---------
Bus positions are the real population-weighted centroids of the seven Oʻahu
judicial districts, projected equirectangularly (longitude scaled by cos(lat))
so the picture is an actual map of the island rather than an abstract graph.

Produces: figures/anim_set8_montecarlo.gif

Run:  julia anim_set8.jl
=#

using JuMP, HiGHS
using Plots, DataFrames, CSV, Printf, Random, Statistics
gr()

const HERE = @__DIR__
include(joinpath(HERE, "cases.jl"))
include(joinpath(HERE, "..", "OPT simple case", "gridanim.jl"))
mkpath(joinpath(HERE, "figures"))

"""Thousands separators, so a six-figure hourly cost is readable at a glance."""
function format_thousands(x::Real)
    s = @sprintf("%.0f", x)
    neg = startswith(s, "-"); neg && (s = s[2:end])
    out = ""
    for (i, ch) in enumerate(reverse(s))
        i > 1 && (i - 1) % 3 == 0 && (out = "," * out)
        out = string(ch) * out
    end
    return (neg ? "-" : "") * out
end

# ---------------------------------------------------------------------------
# 1. Adapt a GridCase into the tables gridanim.jl expects
# ---------------------------------------------------------------------------
"""
    anim_tables(case)

gridanim.jl was written for the MATPOWER-shaped DataFrames used in Parts 2-5.
This converts a `GridCase` into that shape once, so the renderer built for the
earlier work can be reused unchanged.
"""
function anim_tables(case::GridCase)
    busdf = DataFrame(
        bus_i = collect(1:case.nbus),
        type  = [i == case.slack ? 3 : 1 for i in 1:case.nbus],
        pd    = copy(case.mu))
    brdf = DataFrame(
        id    = collect(1:nbranch(case)),
        fbus  = case.fbus,
        tbus  = case.tbus,
        ratea = case.rate)
    return busdf, brdf
end

"""
    map_coords(case)

Equirectangular projection of the real lat/lon centroids: longitude is scaled
by cos(mean latitude) so a degree east and a degree north cover the same
distance on the page. Without this Oʻahu comes out stretched ~7% too wide.
"""
function map_coords(case::GridCase)
    lats = [case.coords[i][2] for i in 1:case.nbus]
    lat0 = mean(lats)
    k = cos(lat0 * pi / 180)
    return Dict(i => ((case.coords[i][1]) * k, case.coords[i][2])
                for i in 1:case.nbus)
end

# ---------------------------------------------------------------------------
# 2. Solve one scenario and capture everything the renderer needs
# ---------------------------------------------------------------------------
"""
    solve_state(mdl, case, D)

Solve one demand draw and return the full picture: dispatch, flows, voltage
angles (the terrain), prices, shedding, and how many lines ended up pinned.
"""
function solve_state(mdl, case::GridCase, D::Vector{Float64})
    set_demand!(mdl, case, D)
    optimize!(mdl.model)
    termination_status(mdl.model) == MOI.OPTIMAL || error("scenario failed to solve")

    Pv = collect(value.(mdl.P).data)
    Sv = collect(value.(mdl.S).data)
    Fv = collect(value.(mdl.F).data)
    Tv = collect(value.(mdl.THETA).data)

    flows = DataFrame(id = 1:nbranch(case), fbus = case.fbus, tbus = case.tbus,
                      flow = Fv, ratea = case.rate)
    flows.util = abs.(flows.flow) ./ case.rate

    return (generation = DataFrame(id = 1:ngen(case), node = case.gen_bus, gen = Pv),
            flows = flows,
            angles = DataFrame(bus = 1:case.nbus, theta = Tv),
            shed = sum(Sv),
            cost = sum(case.cost[g] * Pv[g] for g in 1:ngen(case)),
            n_at_limit = count(>=(0.999), flows.util),
            expensive_on = any(g -> Pv[g] > 1e-4 && case.cost[g] >= maximum(case.cost) - 1e-9,
                               1:ngen(case)),
            demand = sum(D))
end

# ---------------------------------------------------------------------------
# 3. Draw the scenarios for both acts
# ---------------------------------------------------------------------------
case   = oahu_case()
hourly = oahu_hourly_net_load()
shares = oahu_load_shares()
busdf, brdf = anim_tables(case)
COORDS = map_coords(case)
# Real district names under each node. Kahe carries no load -- it is the
# island's largest generation site -- so it is labelled as such.
BUS_LABELS = Dict(i => (case.bus_name[i] == "Kahe" ? "Kahe (gen)" : case.bus_name[i])
                  for i in 1:case.nbus)
mdl = build_model(case)

const N_ACT   = 90     # scenarios shown per act
const SUB     = 3      # sub-frames per scenario (carrier motion)
const HOLD    = 12     # frames held at the end of each act

println("Sampling and solving $(2 * N_ACT) scenarios...")

"""Collect N solved states from a sampler, plus the running probabilities."""
function collect_act(sampler, n; seed)
    rng = MersenneTwister(seed)
    states = NamedTuple[]
    nshed = 0; nexp = 0; ncong = 0
    for k in 1:n
        D = sampler(rng, case)
        st = solve_state(mdl, case, D)
        nshed += st.shed > 1e-4; nexp += st.expensive_on; ncong += st.n_at_limit > 0
        push!(states, (st = st, bus_pd = D, k = k,
                       p_shed = nshed / k, p_exp = nexp / k, p_cong = ncong / k))
    end
    return states
end

actA = collect_act(exponential_sampler, N_ACT; seed = 20260908)
actC = collect_act(bootstrap_sampler(hourly, shares), N_ACT; seed = 20260908)

@printf("  Act 1 (Exp(1))   : P(shed) %.1f%%  P(expensive) %.1f%%  P(congested) %.1f%%\n",
        100actA[end].p_shed, 100actA[end].p_exp, 100actA[end].p_cong)
@printf("  Act 2 (real)     : P(shed) %.1f%%  P(expensive) %.1f%%  P(congested) %.1f%%\n",
        100actC[end].p_shed, 100actC[end].p_exp, 100actC[end].p_cong)

# One flow scale for BOTH acts, so a thick stream in Act 1 means the same
# number of megawatts as a thick stream in Act 2. Rescaling per act would make
# the two halves silently incomparable.
MAXF = maximum(maximum(abs.(s.st.flows.flow)) for s in vcat(actA, actC))
@printf("  shared flow scale: %.1f MW\n", MAXF)

# ---------------------------------------------------------------------------
# 4. Render
# ---------------------------------------------------------------------------
println("Rendering frames...")

"""Build the frame list for one act: each state repeated SUB times, then a hold."""
function act_shots(states, label, tag)
    shots = NamedTuple[]
    for (i, s) in enumerate(states), sub in 1:SUB
        push!(shots, (s = s, ph = (i - 1) * SUB + sub, label = label, tag = tag))
    end
    for h in 1:HOLD
        push!(shots, (s = states[end], ph = length(states) * SUB + h,
                      label = label, tag = tag))
    end
    return shots
end

shots = vcat(act_shots(actA, "ACT 1  ·  ASSUMED DEMAND   D = μ · Exp(1)", :exp),
             act_shots(actC, "ACT 2  ·  REAL DEMAND   resampled from 8,760 recorded hours", :real))

anim = @animate for (n, fr) in enumerate(shots)
    s  = fr.s; st = s.st
    b  = copy(busdf); b.pd = s.bus_pd

    blackout = st.shed > 1e-4
    hud = [("scenario",        @sprintf("%d of %d", s.k, N_ACT)),
           ("island demand",   @sprintf("%.0f MW", st.demand)),
           ("hourly cost",     @sprintf("\$%s", format_thousands(st.cost))),
           ("unserved load",   blackout ? @sprintf("%.0f MW   ← BLACKOUT", st.shed) : "0 MW   all served"),
           ("lines at limit",  @sprintf("%d of %d", st.n_at_limit, nbranch(case))),
           ("costliest unit",  st.expensive_on ? "RUNNING  (\$238/MWh)" : "off"),
           ("running P(shed)",      @sprintf("%.1f%%", 100s.p_shed)),
           ("running P(congested)", @sprintf("%.1f%%", 100s.p_cong))]

    grid_frame(b, brdf, st.generation, st.flows, st.angles, COORDS;
               phase = fr.ph / 26, maxflow_ref = MAXF,
               density = 30.0, seed = 11, jitter = 1.0,
               show_flow_labels = true,
               bus_labels = BUS_LABELS,
               size = (1180, 1000),
               title = fr.label,
               hud = hud)
    n % 30 == 0 && println("  frame $n / $(length(shots))")
end

outpath = joinpath(HERE, "figures", "anim_set8_montecarlo.gif")
save_gif(anim, outpath; fps = 11)
println("\nDone: $outpath")
