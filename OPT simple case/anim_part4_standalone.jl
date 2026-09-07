#=
Standalone animation for Part 4 -- 24-hour ramp-constrained dispatch.

Produces: figures/anim_part4_day.gif

Shows the 3-bus triangle network evolving hour by hour through one day.
Two generators serve time-varying demand:
  G1 @ bus 1 : $10/MWh  -- CHEAP but SLOW  (30 MW/h ramp limit)
  G2 @ bus 2 : $30/MWh  -- DEAR but FAST   (250 MW/h ramp limit)

The animation makes visible:
  - Carrier particles flowing along each line (speed ~ utilisation)
  - MW flow labels on each line
  - HUD tracking hour, demand, each generator's output and ramp, cost
  - "RAMP-LIMITED" flag when G1 is pinned against its 30 MW/h plate
=#

using JuMP, HiGHS
using Plots
using DataFrames, CSV, Printf
gr()

const HERE = @__DIR__
include(joinpath(HERE, "gridanim.jl"))
include(joinpath(HERE, "gridviz.jl"))       # for BUS3_COORDS
mkpath(joinpath(HERE, "figures"))

# ---------------------------------------------------------------------------
# 1. Load the 3-bus data
# ---------------------------------------------------------------------------
function prep!(gen, gencost, branch, bus)
    for f in (gen, gencost, branch, bus); rename!(f, lowercase.(names(f))); end
    gen.id = 1:nrow(gen); gencost.id = 1:nrow(gencost); branch.id = 1:nrow(branch)
    branch.sus = 1 ./ branch.x
    return gen, gencost, branch, bus
end

g3, gc3, br3, bs3 = prep!(
    CSV.read(joinpath(HERE, "gen.csv"), DataFrame),
    CSV.read(joinpath(HERE, "gencost.csv"), DataFrame),
    CSV.read(joinpath(HERE, "branch.csv"), DataFrame),
    CSV.read(joinpath(HERE, "bus.csv"), DataFrame))

baseMVA = 100

# ---------------------------------------------------------------------------
# 2. Ramp data and demand curves
# ---------------------------------------------------------------------------
g3.ru = [30.0, 250.0]; g3.rd = [30.0, 250.0]; g3.p0 = [100.0, 50.0]
const T = 24

resi = [0.46,0.44,0.43,0.44,0.48,0.56,0.68,0.80,0.86,0.88,0.87,0.86,
        0.85,0.84,0.85,0.88,0.94,1.00,0.98,0.92,0.83,0.72,0.60,0.51]
comm = [0.22,0.20,0.20,0.20,0.24,0.35,0.55,0.78,0.92,0.98,1.00,1.00,
        0.96,0.98,1.00,0.98,0.92,0.80,0.62,0.48,0.38,0.32,0.28,0.24]

PEAK  = Dict(1 => 0.0, 2 => 80.0, 3 => 300.0)
SHAPE = Dict(1 => zeros(T), 2 => comm, 3 => resi)
D = Dict((i, t) => PEAK[i] * SHAPE[i][t] for i in bs3.bus_i, t in 1:T)
const VOLL = 5000.0

# ---------------------------------------------------------------------------
# 3. Solve: ramp-constrained 24-hour dispatch
# ---------------------------------------------------------------------------
println("Solving ramp-constrained 24-hour dispatch...")
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
    # THE WELD: ramp constraints linking consecutive hours
    @constraint(m4, [g in G, t in 2:T], P[g, t] - P[g, t-1] <= g3[g, :ru])
    @constraint(m4, [g in G, t in 2:T], P[g, t-1] - P[g, t] <= g3[g, :rd])
    @constraint(m4, [g in G], P[g, 1] - g3[g, :p0] <= g3[g, :ru])
    @constraint(m4, [g in G], g3[g, :p0] - P[g, 1] <= g3[g, :rd])
    optimize!(m4)
    P4 = P; F4 = F; cBal4 = cBal
end
@printf("  daily cost: \$%.0f\n", objective_value(m4))

# ---------------------------------------------------------------------------
# 4. Build per-hour state snapshots
# ---------------------------------------------------------------------------
day_states = NamedTuple[]
for t in 1:T
    b = deepcopy(bs3); b.pd = [D[(i, t)] for i in bs3.bus_i]
    fl = DataFrame(id = br3.id, fbus = br3.fbus, tbus = br3.tbus,
                   flow = [value(F4[l, t]) for l in br3.id], ratea = br3.ratea)
    fl.util = abs.(fl.flow) ./ fl.ratea
    # Use LMP as the "field" for terrain colouring -- in a transport model
    # there are no voltage angles, but the dual prices create a meaningful
    # landscape: valleys where power is cheap, ridges where it is dear.
    push!(day_states, (
        hour = t, bus = b,
        generation = DataFrame(id = g3.id, node = g3.bus,
                               gen = [value(P4[g, t]) for g in g3.id]),
        flows = fl,
        field = DataFrame(bus = bs3.bus_i,
                          theta = [dual(cBal4[i, t]) for i in bs3.bus_i]),
        prices = [dual(cBal4[i, t]) for i in bs3.bus_i]))
end

MAXF = maximum(maximum(abs.(s.flows.flow)) for s in day_states)
g1series = [value(P4[1, t]) for t in 1:T]
Δg1 = vcat(g1series[1] - g3[1, :p0], diff(g1series))

@printf("  max flow across all hours: %.1f MW\n", MAXF)
@printf("  G1 ramp-bound hours: %s\n",
        join([t for t in 1:T if abs(abs(Δg1[t]) - g3[1, :ru]) < 1.0], ", "))

# ---------------------------------------------------------------------------
# 5. Render the animation
# ---------------------------------------------------------------------------
println("Rendering 24-hour animation...")

SUB = 6          # sub-frames per hour for smooth carrier motion
HOLD = 14        # extra frames holding the last hour

shots = NamedTuple[]
for (k, st) in enumerate(day_states), sub in 1:SUB
    push!(shots, (st = st, idx = (k - 1) * SUB + sub))
end
# Hold the final hour so the viewer can read the end state
for h in 1:HOLD
    push!(shots, (st = day_states[end], idx = T * SUB + h))
end

anim = @animate for fr in shots
    st = fr.st
    t = st.hour
    pinned = abs(abs(Δg1[t]) - g3[1, :ru]) < 1.0
    total_demand = sum(st.bus.pd)
    hourly_cost = sum(gc3[g, :c1] * st.generation.gen[g] for g in g3.id)

    grid_frame(st.bus, br3, st.generation, st.flows, st.field, BUS3_COORDS;
               phase = fr.idx / 30,
               maxflow_ref = MAXF,
               density = 34.0,
               seed = 7,
               jitter = 1.0,
               show_flow_labels = true,
               size = (1100, 950),
               title = @sprintf("DYNAMIC RAMPING  ·  24-HOUR DISPATCH  ·  %02d:00", t - 1),
               hud = [("system load",    @sprintf("%.0f MW", total_demand)),
                      ("G1  \$10/MWh",   @sprintf("%.0f MW   ramp %+.0f MW/h   %s",
                                                   st.generation.gen[1], Δg1[t],
                                                   pinned ? "RAMP-LIMITED" : "")),
                      ("G2  \$30/MWh",   @sprintf("%.0f MW", st.generation.gen[2])),
                      ("hourly cost",    @sprintf("\$%.0f/h", hourly_cost)),
                      ("bus 3 price",    @sprintf("\$%.0f/MWh", st.prices[3]))])
    println("  frame $(fr.idx) / $(T * SUB + HOLD)")
end

outpath = joinpath(HERE, "figures", "anim_part4_day.gif")
save_gif(anim, outpath; fps = 12)
println("\nDone: $(outpath)")
