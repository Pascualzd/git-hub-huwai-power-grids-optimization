#=
OPT part 5 -- one animation per model, plus the data export behind the viewer.

Parts 2, 3 and 4 each define a model. This file animates each of them, and then
animates itself: part 5 is the RENDERER, so its own piece is the generative
space the renderer spans over a single fixed solution.

  figures/anim_part2_3bus.gif
      Part 2's model. Load at bus 3 walks 0 -> 300 MW. The cheap generator at
      bus 1 serves everything until line 1-3 hits its 150 MW rating; from that
      moment the expensive generator at bus 2 is forced on and the single
      system price splits into three locational prices.

  figures/anim_part3_ieee14.gif
      Part 3's model. Demand climbs until the IEEE 14-bus network genuinely has
      no feasible dispatch left. The last frame is the LAST FEASIBLE STATE --
      found by bisection, not by a sweep that happened to stop.

  figures/anim_part4_day.gif
      Part 4's model. One ramp-constrained day; the slow cheap unit pinned
      against its ramp plate through the morning climb.

  figures/anim_part5_variations.gif
      Part 5 itself. One fixed solved state, rendered across the seed and
      parameter space of gridanim.jl. The physics never changes; only what the
      optimisation leaves undetermined does.

  viz/gridflow/network.json
      Every solved state above, for the browser viewer.

Run:  julia "OPT part 5 - animations.jl"
=#

using JuMP, HiGHS
using Plots
using DataFrames, CSV, Printf, JSON3
gr()

const HERE = @__DIR__
include(joinpath(HERE, "gridanim.jl"))
include(joinpath(HERE, "gridviz.jl"))       # for BUS3_COORDS / IEEE14_COORDS
mkpath(joinpath(HERE, "figures"))

# ---------------------------------------------------------------------------
# Shared model code (same formulations as Parts 2-4, local so this runs alone)
# ---------------------------------------------------------------------------
function prep!(gen, gencost, branch, bus)
    for f in (gen, gencost, branch, bus); rename!(f, lowercase.(names(f))); end
    gen.id = 1:nrow(gen); gencost.id = 1:nrow(gencost); branch.id = 1:nrow(branch)
    branch.sus = 1 ./ branch.x
    return gen, gencost, branch, bus
end

function dcopf(gen, branch, gencost, bus, baseMVA)
    m = Model(HiGHS.Optimizer); set_silent(m)
    G = gen.id; N = bus.bus_i; L = branch.id
    slack = bus[bus.type .== 3, :bus_i][1]
    @variable(m, gen[g, :pmin] <= GEN[g in G] <= gen[g, :pmax])
    @variable(m, THETA[N])
    @objective(m, Min, sum(gencost[g, :c1] * GEN[g] for g in G))
    @constraint(m, cSlack, THETA[slack] == 0)
    @expression(m, FLOW[l in L], baseMVA * branch[l, :sus] *
                (THETA[branch[l, :fbus]] - THETA[branch[l, :tbus]]))
    @constraint(m, cBal[i in N],
        sum(GEN[g] for g in gen[gen.bus .== i, :id]) - bus[bus.bus_i .== i, :pd][1] ==
        sum(FLOW[l] for l in branch[branch.fbus .== i, :id]) -
        sum(FLOW[l] for l in branch[branch.tbus .== i, :id]))
    @constraint(m, cLim[l in L], -branch[l, :ratea] <= FLOW[l] <= branch[l, :ratea])
    optimize!(m)
    termination_status(m) == MOI.OPTIMAL || return nothing
    fl = DataFrame(id = branch.id, fbus = branch.fbus, tbus = branch.tbus,
                   flow = value.(FLOW).data, ratea = branch.ratea)
    fl.util = [r.ratea >= 9000 ? 0.0 : abs(r.flow) / r.ratea for r in eachrow(fl)]
    return (generation = DataFrame(id = gen.id, node = gen.bus, gen = value.(GEN).data),
            flows = fl,
            angles = DataFrame(bus = bus.bus_i, theta = value.(THETA).data),
            prices = DataFrame(bus = bus.bus_i, lmp = [dual(cBal[i]) for i in N]),
            cost = objective_value(m))
end

"""
    feasibility_ceiling(solve_at, lo, hi; tol)

Largest scaling factor at which the network still has a feasible dispatch.

This exists because a sweep on a coarse grid does NOT find the ceiling -- it
finds the last grid point it happened to test, which is a different and weaker
claim. Bisection makes "one step further is infeasible" an honest statement.
"""
function feasibility_ceiling(solve_at, lo, hi; tol = 1e-4)
    solve_at(lo) === nothing && error("lower bound is already infeasible")
    solve_at(hi) === nothing || error("upper bound is still feasible; raise it")
    while hi - lo > tol
        mid = (lo + hi) / 2
        solve_at(mid) === nothing ? (hi = mid) : (lo = mid)
    end
    return lo
end

# ===========================================================================
# PART 2 -- the 3-bus DC-OPF, as its load grows
# ===========================================================================
println("\n[1/5] Part 2: 3-bus DC-OPF load walk")

g3, gc3, br3, bs3 = prep!(
    CSV.read(joinpath(HERE, "gen.csv"), DataFrame),
    CSV.read(joinpath(HERE, "gencost.csv"), DataFrame),
    CSV.read(joinpath(HERE, "branch.csv"), DataFrame),
    CSV.read(joinpath(HERE, "bus.csv"), DataFrame))
baseMVA = 100
PD3 = bs3[bs3.bus_i .== 3, :pd][1]          # 300 MW in the shipped data

states2 = NamedTuple[]
for d in 0.0:10.0:PD3
    b = deepcopy(bs3); b.pd = [i == 3 ? d : 0.0 for i in bs3.bus_i]
    s = dcopf(g3, br3, gc3, b, baseMVA)
    s === nothing && continue
    push!(states2, (load = d, bus = b, sol = s))
end
@printf("  %d feasible states, load 0 -> %.0f MW\n", length(states2), states2[end].load)
onset = findfirst(st -> any(st.sol.flows.util .>= 0.999), states2)
onset === nothing || @printf("  line 1-3 saturates at %.0f MW of load\n", states2[onset].load)
MAXF2 = maximum(maximum(abs.(s.sol.flows.flow)) for s in states2)

SUB2 = 3
shots2 = NamedTuple[]
for (k, st) in enumerate(states2), sub in 1:SUB2
    push!(shots2, (st = st, ph = (k - 1) * SUB2 + sub))
end
for h in 1:12
    push!(shots2, (st = states2[end], ph = length(states2) * SUB2 + h))
end

anim2 = @animate for fr in shots2
    st = fr.st
    lm = st.sol.prices.lmp
    nc = sum(st.sol.flows.util .>= 0.999)
    grid_frame(st.bus, br3, st.sol.generation, st.sol.flows, st.sol.angles, BUS3_COORDS;
               phase = fr.ph / 24, maxflow_ref = MAXF2, density = 34.0, seed = 7, jitter = 1.0,
               title = "PART 2  ·  3-BUS DC-OPF  ·  THE PRICE OF A FULL PIPE",
               hud = [("load at bus 3", @sprintf("%.0f MW", st.load)),
                      ("G1 cheap (10/MWh)", @sprintf("%.1f MW", st.sol.generation.gen[1])),
                      ("G2 dear (30/MWh)", @sprintf("%.1f MW", st.sol.generation.gen[2])),
                      ("cost", @sprintf("%.0f USD/h", st.sol.cost)),
                      ("prices  b1 / b2 / b3", @sprintf("%.0f / %.0f / %.0f", lm[1], lm[2], lm[3])),
                      ("line 1-3", nc == 0 ? "slack" : "AT ITS 150 MW LIMIT")])
end
save_gif(anim2, joinpath(HERE, "figures", "anim_part2_3bus.gif"); fps = 14)

# ===========================================================================
# PART 3 -- IEEE 14-bus, driven to its genuine feasibility ceiling
# ===========================================================================
println("\n[2/5] Part 3: IEEE 14-bus to the true ceiling")

gen, gencost, branch, bus = prep!(
    CSV.read(joinpath(HERE, "ieee14", "gen.csv"), DataFrame),
    CSV.read(joinpath(HERE, "ieee14", "gencost.csv"), DataFrame),
    CSV.read(joinpath(HERE, "ieee14", "branch.csv"), DataFrame),
    CSV.read(joinpath(HERE, "ieee14", "bus.csv"), DataFrame))

base = dcopf(gen, branch, gencost, bus, baseMVA)
branchR = deepcopy(branch)
branchR.ratea = [max(25.0, ceil(1.5 * abs(f))) for f in base.flows.flow]

solve_growth(g) = (b = deepcopy(bus); b.pd = bus.pd .* g;
                   dcopf(gen, branchR, gencost, b, baseMVA))
CEILING = feasibility_ceiling(solve_growth, 1.0, 3.0)
@printf("  feasibility ceiling: growth %.4f -> %.2f MW (installed generation %.1f MW)\n",
        CEILING, sum(bus.pd) * CEILING, sum(gen.pmax))
@printf("  one step further (%.4f) is infeasible\n", CEILING + 1e-4)

grid = collect(1.00:0.02:floor(CEILING * 50) / 50)   # 2% steps up to the ceiling
push!(grid, CEILING)                                  # and the ceiling itself
states14 = NamedTuple[]
for g in grid
    b = deepcopy(bus); b.pd = bus.pd .* g
    s = dcopf(gen, branchR, gencost, b, baseMVA)
    s === nothing && continue
    push!(states14, (growth = g, bus = b, sol = s))
end
@printf("  %d feasible states exported\n", length(states14))
MAXF14 = maximum(maximum(abs.(s.sol.flows.flow)) for s in states14)

SUB = 3
shots14 = NamedTuple[]
for (k, st) in enumerate(states14), sub in 1:SUB
    push!(shots14, (st = st, ph = (k - 1) * SUB + sub, hold = false))
end
for h in 1:14
    push!(shots14, (st = states14[end], ph = length(states14) * SUB + h, hold = true))
end

anim3 = @animate for fr in shots14
    st = fr.st
    ncong = sum(st.sol.flows.util .>= 0.999)
    lmps = st.sol.prices.lmp
    grid_frame(st.bus, branchR, st.sol.generation, st.sol.flows, st.sol.angles,
               IEEE14_COORDS;
               phase = fr.ph / 22, maxflow_ref = MAXF14, seed = 7, jitter = 1.0,
               title = fr.hold ? "PART 3  ·  IEEE 14-BUS  ·  CEILING" :
                                 "PART 3  ·  IEEE 14-BUS DC-OPF",
               hud = fr.hold ?
                   [("system load", @sprintf("%.1f MW", sum(st.bus.pd))),
                    ("installed generation", @sprintf("%.1f MW", sum(gen.pmax))),
                    ("cost", @sprintf("%.0f USD/h", st.sol.cost)),
                    ("lines at limit", "$(ncong) of 20"),
                    ("any more demand", "NO FEASIBLE DISPATCH")] :
                   [("system load", @sprintf("%.1f MW", sum(st.bus.pd))),
                    ("demand growth", @sprintf("+%.1f%%", (st.growth - 1) * 100)),
                    ("cost", @sprintf("%.0f USD/h", st.sol.cost)),
                    ("price spread", @sprintf("%.0f - %.0f USD/MWh",
                                              minimum(lmps), maximum(lmps))),
                    ("lines at limit", ncong == 0 ? "none" : "$(ncong) of 20")])
end
save_gif(anim3, joinpath(HERE, "figures", "anim_part3_ieee14.gif"); fps = 14)

# ===========================================================================
# PART 4 -- the ramp-constrained day
# ===========================================================================
println("\n[3/5] Part 4: ramp-constrained day")

g3.ru = [30.0, 250.0]; g3.rd = [30.0, 250.0]; g3.p0 = [100.0, 50.0]
const T = 24
resi = [0.46,0.44,0.43,0.44,0.48,0.56,0.68,0.80,0.86,0.88,0.87,0.86,
        0.85,0.84,0.85,0.88,0.94,1.00,0.98,0.92,0.83,0.72,0.60,0.51]
comm = [0.22,0.20,0.20,0.20,0.24,0.35,0.55,0.78,0.92,0.98,1.00,1.00,
        0.96,0.98,1.00,0.98,0.92,0.80,0.62,0.48,0.38,0.32,0.28,0.24]
PEAK = Dict(1 => 0.0, 2 => 80.0, 3 => 300.0)
SHAPE = Dict(1 => zeros(T), 2 => comm, 3 => resi)
D = Dict((i, t) => PEAK[i] * SHAPE[i][t] for i in bs3.bus_i, t in 1:T)
const VOLL = 5000.0

m4 = Model(HiGHS.Optimizer); set_silent(m4)
let G = g3.id, N = bs3.bus_i, L = br3.id
    global P4, F4, cBal4
    @variable(m4, 0 <= P[g in G, t in 1:T] <= g3[g, :pmax])
    @variable(m4, F[l in L, t in 1:T])
    @variable(m4, 0 <= S[i in N, t in 1:T] <= max(D[(i, t)], 0.0))
    @objective(m4, Min, sum(gc3[g, :c1] * P[g, t] for g in G, t in 1:T) +
                        sum(VOLL * S[i, t] for i in N, t in 1:T))
    @constraint(m4, cBal[i in N, t in 1:T],
        sum(P[g, t] for g in g3[g3.bus .== i, :id]) - (D[(i, t)] - S[i, t]) ==
        sum(F[l, t] for l in br3[br3.fbus .== i, :id]) -
        sum(F[l, t] for l in br3[br3.tbus .== i, :id]))
    @constraint(m4, [l in L, t in 1:T], -br3[l, :ratea] <= F[l, t] <= br3[l, :ratea])
    @constraint(m4, [g in G, t in 2:T], P[g, t] - P[g, t-1] <= g3[g, :ru])
    @constraint(m4, [g in G, t in 2:T], P[g, t-1] - P[g, t] <= g3[g, :rd])
    @constraint(m4, [g in G], P[g, 1] - g3[g, :p0] <= g3[g, :ru])
    @constraint(m4, [g in G], g3[g, :p0] - P[g, 1] <= g3[g, :rd])
    optimize!(m4)
    P4 = P; F4 = F; cBal4 = cBal
end
@printf("  daily cost %.0f USD\n", objective_value(m4))

day_states = NamedTuple[]
for t in 1:T
    b = deepcopy(bs3); b.pd = [D[(i, t)] for i in bs3.bus_i]
    fl = DataFrame(id = br3.id, fbus = br3.fbus, tbus = br3.tbus,
                   flow = [value(F4[l, t]) for l in br3.id], ratea = br3.ratea)
    fl.util = abs.(fl.flow) ./ fl.ratea
    push!(day_states, (
        hour = t, bus = b,
        generation = DataFrame(id = g3.id, node = g3.bus,
                               gen = [value(P4[g, t]) for g in g3.id]),
        flows = fl,
        field = DataFrame(bus = bs3.bus_i, theta = [dual(cBal4[i, t]) for i in bs3.bus_i]),
        prices = [dual(cBal4[i, t]) for i in bs3.bus_i]))
end
MAXF3 = maximum(maximum(abs.(s.flows.flow)) for s in day_states)
g1series = [value(P4[1, t]) for t in 1:T]
Δg1 = vcat(g1series[1] - g3[1, :p0], diff(g1series))

SUB4 = 4
anim4 = @animate for (k, st) in enumerate(day_states), sub in 1:SUB4
    pinned = abs(abs(Δg1[st.hour]) - g3[1, :ru]) < 1e-6
    grid_frame(st.bus, br3, st.generation, st.flows, st.field, BUS3_COORDS;
               phase = ((k - 1) * SUB4 + sub) / 26, maxflow_ref = MAXF3,
               density = 34.0, seed = 7, jitter = 1.0,
               title = @sprintf("PART 4  ·  RAMP-CONSTRAINED DISPATCH  ·  %02d:00", st.hour),
               hud = [("system load", @sprintf("%.1f MW", sum(st.bus.pd))),
                      ("G1 cheap+slow", @sprintf("%.1f MW  (%+.0f MW/h)",
                                                 st.generation.gen[1], Δg1[st.hour])),
                      ("G2 dear+fast", @sprintf("%.1f MW", st.generation.gen[2])),
                      ("price @ bus 3", @sprintf("%.0f USD/MWh", st.prices[3])),
                      ("ramp plate", pinned ? "G1 PINNED AT LIMIT" : "slack")])
end
save_gif(anim4, joinpath(HERE, "figures", "anim_part4_day.gif"); fps = 15)

# ===========================================================================
# PART 5 -- the renderer's own space
# ===========================================================================
# Part 5 has no model of its own; it is the instrument. So its animation holds
# ONE solved state completely fixed -- the IEEE 14-bus ceiling, every flow,
# angle and price frozen -- and moves only the parameters the optimisation
# does not determine: the seed, the carrier density, the contour band count,
# the palette. Everything that changes on screen is representation. Nothing
# that changes on screen is physics.
println("\n[4/5] Part 5: the renderer's parameter space")

fixed = states14[end]
palettes = [
    (name = "ember",   cool = RGB(0.35,0.72,0.85), warm = RGB(0.98,0.72,0.25), hot = RGB(0.95,0.28,0.22)),
    (name = "cyan",    cool = RGB(0.30,0.85,0.80), warm = RGB(0.45,0.65,0.95), hot = RGB(0.85,0.35,0.95)),
    (name = "sodium",  cool = RGB(0.55,0.80,0.55), warm = RGB(0.95,0.85,0.35), hot = RGB(0.98,0.45,0.15)),
    (name = "arctic",  cool = RGB(0.60,0.78,0.92), warm = RGB(0.85,0.88,0.95), hot = RGB(0.98,0.55,0.62)),
]
NV = 72
anim5 = @animate for i in 1:NV
    u = (i - 1) / NV
    pal = palettes[1 + (div(i - 1, 18) % length(palettes))]
    sd = 1 + div(i - 1, 6)
    dens = 12 + 34 * (0.5 + 0.5 * sin(2pi * u * 2))
    bnd = round(Int, 4 + 26 * (0.5 + 0.5 * sin(2pi * u * 1.5 + 1.0)))
    grid_frame(fixed.bus, branchR, fixed.sol.generation, fixed.sol.flows,
               fixed.sol.angles, IEEE14_COORDS;
               phase = i / 20, maxflow_ref = MAXF14,
               seed = sd, jitter = 1.6, density = dens, bands = bnd,
               cool = pal.cool, warm = pal.warm, hot = pal.hot,
               title = "PART 5  ·  ONE SOLUTION, RE-RENDERED",
               hud = [("solved state", "IEEE 14-bus at its ceiling (FIXED)"),
                      ("cost", @sprintf("%.0f USD/h  (never changes)", fixed.sol.cost)),
                      ("seed", @sprintf("%d", sd)),
                      ("carrier density", @sprintf("%.0f", dens)),
                      ("terrain bands", @sprintf("%d", bnd)),
                      ("palette", pal.name)])
end
save_gif(anim5, joinpath(HERE, "figures", "anim_part5_variations.gif"); fps = 12)

# ===========================================================================
# EXPORT
# ===========================================================================
println("\n[5/5] Exporting solved states to JSON")

pack(name, note, field, coords, busdf, branchdf, maxflow, states) = Dict(
    "name" => name, "note" => note, "field" => field,
    "coords" => Dict(string(i) => collect(coords[i]) for i in busdf.bus_i),
    "buses" => [Dict("id" => r.bus_i, "type" => r.type) for r in eachrow(busdf)],
    "branches" => [Dict("id" => r.id, "from" => r.fbus, "to" => r.tbus,
                        "rateA" => r.ratea) for r in eachrow(branchdf)],
    "maxflow" => maxflow, "states" => states)

pack2 = pack("3-bus, load walk",
             "field = voltage phase angle (radians); DC-OPF, Part 2",
             "theta", BUS3_COORDS, bs3, br3, MAXF2,
    [Dict("key" => st.load, "label" => @sprintf("%.0f MW at bus 3", st.load),
          "load" => sum(st.bus.pd), "cost" => st.sol.cost,
          "pd" => Dict(string(r.bus_i) => r.pd for r in eachrow(st.bus)),
          "gen" => Dict(string(i) => sum(st.sol.generation[st.sol.generation.node .== i, :gen]; init = 0.0)
                        for i in bs3.bus_i),
          "flow" => st.sol.flows.flow,
          "field" => Dict(string(r.bus) => r.theta for r in eachrow(st.sol.angles)),
          "lmp" => Dict(string(r.bus) => r.lmp for r in eachrow(st.sol.prices)),
          "congested" => sum(st.sol.flows.util .>= 0.999)) for st in states2])

pack14 = pack("IEEE 14-bus",
              "field = voltage phase angle (radians); DC-OPF, Part 3",
              "theta", IEEE14_COORDS, bus, branchR, MAXF14,
    [Dict("key" => st.growth,          # full precision: the ceiling state is
                                       # 1.52012..., and rounding it to 1.5201
                                       # would make the exported numbers fail to
                                       # reproduce from their own key
          "label" => @sprintf("+%.2f%% demand", (st.growth - 1) * 100),
          "load" => sum(st.bus.pd), "cost" => st.sol.cost,
          "pd" => Dict(string(r.bus_i) => r.pd for r in eachrow(st.bus)),
          "gen" => Dict(string(i) => sum(st.sol.generation[st.sol.generation.node .== i, :gen]; init = 0.0)
                        for i in bus.bus_i),
          "flow" => st.sol.flows.flow,
          "field" => Dict(string(r.bus) => r.theta for r in eachrow(st.sol.angles)),
          "lmp" => Dict(string(r.bus) => r.lmp for r in eachrow(st.sol.prices)),
          "congested" => sum(st.sol.flows.util .>= 0.999)) for st in states14])
pack14["ceiling"] = CEILING

pack3 = pack("3-bus, one day",
             "field = locational marginal price (USD/MWh); transport model with ramping, Part 4",
             "lmp", BUS3_COORDS, bs3, br3, MAXF3,
    [Dict("key" => st.hour, "label" => @sprintf("%02d:00", st.hour),
          "load" => sum(st.bus.pd),
          "cost" => sum(gc3[g, :c1] * st.generation.gen[g] for g in g3.id),
          "pd" => Dict(string(r.bus_i) => r.pd for r in eachrow(st.bus)),
          "gen" => Dict(string(i) => sum(st.generation[st.generation.node .== i, :gen]; init = 0.0)
                        for i in bs3.bus_i),
          "flow" => st.flows.flow,
          "field" => Dict(string(r.bus) => r.theta for r in eachrow(st.field)),
          "lmp" => Dict(string(bs3.bus_i[j]) => st.prices[j] for j in 1:nrow(bs3)),
          "congested" => sum(st.flows.util .>= 0.999),
          "ramp" => Δg1[st.hour], "rampLimit" => g3[1, :ru]) for st in day_states])

outdir = joinpath(dirname(HERE), "viz", "gridflow")
mkpath(outdir)
open(joinpath(outdir, "network.json"), "w") do io
    JSON3.pretty(io, Dict("bus3" => pack2, "ieee14" => pack14, "day3" => pack3))
end
@printf("  wrote %s\n", joinpath(outdir, "network.json"))
println("\nDone: 4 animations in figures/, data in viz/gridflow/network.json")
