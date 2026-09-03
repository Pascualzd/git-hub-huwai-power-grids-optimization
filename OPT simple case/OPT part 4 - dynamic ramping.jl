#=
OPT part 4 -- the dynamic (multi-period) transport model.

This is the runnable version of docs/DYNAMIC_DISPATCH_FORMULATION.md.

WHAT CHANGED FROM PART 1 (Code - work.jl)
-----------------------------------------
Part 1 solved ONE hour. This solves a whole DAY at once, because two new
facts are true:

  1. Demand at each bus is a curve, not a number:  D[i] becomes D[i,t]
  2. A turbine has inertia. It cannot jump from 60 MW to 250 MW between
     3 a.m. and 4 a.m. just because that would be cheap. That is the ramp
     constraint, and it is what WELDS the 24 hourly problems into one.

THE EXPERIMENT
--------------
Two generators serve the same day:

  G1 @ bus 1 : $10/MWh   -- CHEAP but SLOW  (30 MW/h ramp; a coal unit)
  G2 @ bus 2 : $30/MWh   -- DEAR but FAST   (250 MW/h ramp; a gas turbine)

Solve the day twice:
  (a) IGNORING ramp limits -- 24 independent snapshots, the naive answer
  (b) RESPECTING ramp limits -- one welded 24-hour program

The gap between (a) and (b) is the true cost of physical inertia, and the
naive model cannot see it.
=#

using JuMP, HiGHS
using Plots
using DataFrames, CSV, PrettyTables, Printf
ENV["COLUMNS"] = 200
gr()
mkpath(joinpath(@__DIR__, "figures"))   # make sure the output folder exists

const HERE = @__DIR__

# ---------------------------------------------------------------------------
# 1. The network (same 3-bus triangle as Parts 1 and 2)
# ---------------------------------------------------------------------------
gen     = CSV.read(joinpath(HERE, "gen.csv"),     DataFrame)
gencost = CSV.read(joinpath(HERE, "gencost.csv"), DataFrame)
branch  = CSV.read(joinpath(HERE, "branch.csv"),  DataFrame)
bus     = CSV.read(joinpath(HERE, "bus.csv"),     DataFrame)
for f in (gen, gencost, branch, bus); rename!(f, lowercase.(names(f))); end
gen.id = 1:nrow(gen); gencost.id = 1:nrow(gencost); branch.id = 1:nrow(branch)

# ---------------------------------------------------------------------------
# 2. NEW DATA: the ramp plate on each machine, and a day of demand
# ---------------------------------------------------------------------------
# RU / RD in MW per hour. P0 = where the machine was set at midnight.
gen.ru = [30.0, 250.0]      # G1 is a heavy hand-wheel; G2 is a light switch
gen.rd = [30.0, 250.0]
gen.p0 = [100.0, 50.0]

const T  = 24
const Δt = 1.0              # hours per period
hours = 1:T

# Two different demand SHAPES on two different buses -- this is the
# "demand at each bus changes" part of the brief.
#   bus 2 = a commercial district : flat-ish, peaks at midday
#   bus 3 = a residential city    : deep night trough, sharp evening peak
resi = [0.46,0.44,0.43,0.44,0.48,0.56,0.68,0.80,0.86,0.88,0.87,0.86,
        0.85,0.84,0.85,0.88,0.94,1.00,0.98,0.92,0.83,0.72,0.60,0.51]
comm = [0.22,0.20,0.20,0.20,0.24,0.35,0.55,0.78,0.92,0.98,1.00,1.00,
        0.96,0.98,1.00,0.98,0.92,0.80,0.62,0.48,0.38,0.32,0.28,0.24]

PEAK = Dict(1 => 0.0, 2 => 80.0, 3 => 300.0)
SHAPE = Dict(1 => zeros(T), 2 => comm, 3 => resi)

# D[i,t] : MW drawn out of bus i during hour t
D = Dict((i, t) => PEAK[i] * SHAPE[i][t] for i in bus.bus_i, t in hours)

const VOLL = 5000.0         # $/MWh penalty for failing to serve load

println("\n Daily demand by bus (MW)\n")
pretty_table(DataFrame(hour = collect(hours),
                       bus2 = [round(D[(2, t)], digits = 1) for t in hours],
                       bus3 = [round(D[(3, t)], digits = 1) for t in hours],
                       total = [round(sum(D[(i, t)] for i in bus.bus_i), digits = 1) for t in hours]))
@printf("\n peak system load  : %.1f MW at hour %d\n",
        maximum(sum(D[(i, t)] for i in bus.bus_i) for t in hours),
        argmax([sum(D[(i, t)] for i in bus.bus_i) for t in hours]))
@printf(" trough system load: %.1f MW\n",
        minimum(sum(D[(i, t)] for i in bus.bus_i) for t in hours))
@printf(" steepest hourly climb: %.1f MW/h  (fleet ramp capability: %.1f MW/h)\n",
        maximum(diff([sum(D[(i, t)] for i in bus.bus_i) for t in hours])), sum(gen.ru))

# ---------------------------------------------------------------------------
# 3. THE MODEL  --  see DYNAMIC_DISPATCH_FORMULATION.md section 4.1
# ---------------------------------------------------------------------------
"""
    dyn_transport(gen, branch, gencost, bus, D, T; ramping)

Multi-period transport dispatch.

  min  sum_t sum_g  c_g p[g,t] dt   +   sum_t sum_i VOLL s[i,t] dt
  s.t. C1 nodal balance          (every bus, every hour)
       C2 generator stops        (every gen, every hour)
       C3 pipe ratings           (every line, every hour)
       C4 ramp up                p[g,t] - p[g,t-1] <= RU[g]
       C5 ramp down              p[g,t-1] - p[g,t] <= RD[g]
       C6 initial condition      against P0[g]
       C7 non-negativity, s <= D

Set `ramping = false` to drop C4-C6 and recover 24 independent snapshots.
"""
function dyn_transport(gen, branch, gencost, bus, D, T; ramping = true, Δt = 1.0)
    m = Model(HiGHS.Optimizer); set_silent(m)

    G = gen.id; N = bus.bus_i; L = branch.id; TT = 1:T

    @variable(m, 0 <= P[g in G, t in TT] <= gen[g, :pmax])       # C2, C7
    @variable(m, F[l in L, t in TT])                              # free sign
    @variable(m, 0 <= S[i in N, t in TT] <= max(D[(i, t)], 0.0))  # C7 shed

    # --- objective: fuel bill + blackout penalty ---
    @objective(m, Min,
        sum(gencost[g, :c1] * P[g, t] * Δt for g in G, t in TT) +
        sum(VOLL * S[i, t] * Δt for i in N, t in TT))

    # --- C1: nodal balance, one per bus PER HOUR ---
    @constraint(m, cBal[i in N, t in TT],
        sum(P[g, t] for g in gen[gen.bus .== i, :id])
            - (D[(i, t)] - S[i, t]) ==
        sum(F[l, t] for l in branch[branch.fbus .== i, :id]) -
        sum(F[l, t] for l in branch[branch.tbus .== i, :id]))

    # --- C3: pipe ratings, every hour ---
    @constraint(m, cLine[l in L, t in TT],
        -branch[l, :ratea] <= F[l, t] <= branch[l, :ratea])

    # --- C4/C5/C6: THE WELD between consecutive hours ---
    if ramping
        @constraint(m, cRampUp[g in G, t in 2:T], P[g, t] - P[g, t-1] <= gen[g, :ru])
        @constraint(m, cRampDn[g in G, t in 2:T], P[g, t-1] - P[g, t] <= gen[g, :rd])
        @constraint(m, cInitUp[g in G], P[g, 1] - gen[g, :p0] <= gen[g, :ru])
        @constraint(m, cInitDn[g in G], gen[g, :p0] - P[g, 1] <= gen[g, :rd])
    end

    optimize!(m)
    st = termination_status(m)
    st == MOI.OPTIMAL || return (status = st, cost = NaN)

    dispatch = DataFrame(hour = collect(TT))
    for g in G
        dispatch[!, Symbol("G$g")] = [value(P[g, t]) for t in TT]
    end
    flowdf = DataFrame(hour = collect(TT))
    for l in L
        flowdf[!, Symbol("L$(l)_$(branch[l,:fbus])to$(branch[l,:tbus])")] =
            [value(F[l, t]) for t in TT]
    end
    shed = DataFrame(hour = collect(TT),
                     shed = [sum(value(S[i, t]) for i in N) for t in TT])
    price = DataFrame(hour = collect(TT))
    for i in N
        price[!, Symbol("bus$i")] = [dual(cBal[i, t]) for t in TT]
    end

    return (status = st, cost = objective_value(m), dispatch = dispatch,
            flows = flowdf, shed = shed, prices = price)
end

# ---------------------------------------------------------------------------
# 4. Solve it both ways
# ---------------------------------------------------------------------------
naive = dyn_transport(gen, branch, gencost, bus, D, T; ramping = false, Δt = Δt)
real_ = dyn_transport(gen, branch, gencost, bus, D, T; ramping = true,  Δt = Δt)

println("\n" * "="^72)
println(" (a) NAIVE  -- ramp limits IGNORED (24 independent snapshots)")
println("="^72)
@printf(" daily cost : \$%.2f\n", naive.cost)
pretty_table(hcat(naive.dispatch, DataFrame(shed = round.(naive.shed.shed, digits = 2))))

println("\n" * "="^72)
println(" (b) REAL   -- ramp limits ENFORCED (one welded 24-hour program)")
println("="^72)
@printf(" daily cost : \$%.2f\n", real_.cost)
pretty_table(hcat(real_.dispatch, DataFrame(shed = round.(real_.shed.shed, digits = 2))))

@printf("\n COST OF INERTIA: \$%.2f/day  (%.2f%% more than the naive model predicts)\n",
        real_.cost - naive.cost, 100 * (real_.cost - naive.cost) / naive.cost)

# Which hours are ramp-bound? (the machine is moving as fast as it legally can)
g1 = real_.dispatch.G1
Δg1 = vcat(g1[1] - gen[1, :p0], diff(g1))
bound = [t for t in 1:T if abs(abs(Δg1[t]) - gen[1, :ru]) < 1e-6]
println("\n Hours where the slow unit G1 is pinned against its ramp plate:")
println("   ", isempty(bound) ? "none" : join(bound, ", "))

# ---------------------------------------------------------------------------
# 5. Verification
# ---------------------------------------------------------------------------
println("\n VERIFICATION")
tot_load = [sum(D[(i, t)] for i in bus.bus_i) for t in 1:T]
tot_gen  = [sum(real_.dispatch[t, Symbol("G$g")] for g in gen.id) for t in 1:T]
balerr   = maximum(abs.(tot_gen .- (tot_load .- real_.shed.shed)))
@printf("   hourly energy balance : worst residual %.2e MW  -> %s\n",
        balerr, balerr < 1e-6 ? "PASS" : "FAIL")
rampok = all(abs(Δg1[t]) <= gen[1, :ru] + 1e-6 for t in 1:T)
@printf("   G1 ramp never exceeded: max |dP| = %.3f MW/h (limit %.1f) -> %s\n",
        maximum(abs.(Δg1)), gen[1, :ru], rampok ? "PASS" : "FAIL")
capok = all(0 - 1e-6 .<= g1 .<= gen[1, :pmax] + 1e-6)
@printf("   G1 within [0, Pmax]                                       -> %s\n",
        capok ? "PASS" : "FAIL")
naive_g1 = naive.dispatch.G1
naive_viol = maximum(abs.(vcat(naive_g1[1] - gen[1, :p0], diff(naive_g1))))
@printf("   naive model's worst ramp: %.1f MW/h -- %.1fx over the plate\n",
        naive_viol, naive_viol / gen[1, :ru])

# --- Are the NEGATIVE prices real, or a bug? -------------------------------
# A negative LMP says "give me MORE load here and my total bill FALLS".
# That sounds absurd until you remember the weld: extra load at 5 a.m. lets
# the slow cheap unit sit HIGHER at 5 a.m., which puts it within ramp reach
# of a higher output at 7 a.m., displacing expensive fast generation later.
# Test it the honest way: perturb the demand and re-solve.
println("\n   Perturbation test on the negative prices (finite difference vs dual):")
for (i, t) in [(3, 5), (3, 12), (3, 24)]
    Dp = copy(D); Dp[(i, t)] = D[(i, t)] + 1.0
    s2 = dyn_transport(gen, branch, gencost, bus, Dp, T; ramping = true, Δt = Δt)
    fd = s2.cost - real_.cost
    lm = real_.prices[t, Symbol("bus$i")]
    @printf("     bus %d hour %2d : dual = %+8.2f   finite-diff = %+8.2f   -> %s\n",
            i, t, lm, fd, abs(fd - lm) < 1e-3 ? "MATCH" : "differs (degenerate)")
end

# ---------------------------------------------------------------------------
# 6. Pictures
# ---------------------------------------------------------------------------
function stack_plot(sol, ttl)
    a = sol.dispatch.G1
    b = sol.dispatch.G1 .+ sol.dispatch.G2
    p = plot(1:T, a; fillrange = 0, fillalpha = 0.85, lw = 0,
             color = RGB(0.17, 0.40, 0.62), label = "G1  \$10/MWh (slow)",
             title = ttl, titlefontsize = 11, xlabel = "hour of day",
             ylabel = "MW", legend = :topleft, legendfontsize = 7,
             bottom_margin = 6Plots.mm, left_margin = 5Plots.mm,
             ylims = (0, 420))
    plot!(p, 1:T, b; fillrange = a, fillalpha = 0.85, lw = 0,
          color = RGB(0.85, 0.55, 0.15), label = "G2  \$30/MWh (fast)")
    plot!(p, 1:T, tot_load; lw = 2.5, color = :black, ls = :dash, label = "total demand")
    return p
end

pN = stack_plot(naive, @sprintf("(a) Ramp limits IGNORED  --  \$%.0f/day", naive.cost))
pR = stack_plot(real_, @sprintf("(b) Ramp limits ENFORCED --  \$%.0f/day", real_.cost))

# the ramp itself: hour-on-hour change against the plate rating
pD = plot(1:T, Δg1; lw = 2.5, marker = :circle, ms = 3, color = RGB(0.17, 0.40, 0.62),
          label = "G1 hour-on-hour change", xlabel = "hour of day",
          ylabel = "MW / h", title = "G1 is pinned against its ramp plate",
          titlefontsize = 11, legend = :topright, legendfontsize = 7,
          bottom_margin = 6Plots.mm, left_margin = 5Plots.mm)
hline!(pD, [gen[1, :ru], -gen[1, :rd]]; lw = 2, ls = :dash,
       color = RGB(0.72, 0.20, 0.20), label = "+/- ramp limit")

pP = plot(1:T, real_.prices.bus3; lw = 5, alpha = 0.45,
          color = RGB(0.55, 0.15, 0.45),
          label = "bus 3 (load)", xlabel = "hour of day", ylabel = "\$/MWh",
          title = "Marginal price: ramping breaks the \\\$10-\\\$30 range",
          titlefontsize = 11, legend = :bottomright, legendfontsize = 7,
          bottom_margin = 6Plots.mm, left_margin = 5Plots.mm)
plot!(pP, 1:T, real_.prices.bus1; lw = 1.8, ls = :dash, marker = :circle, ms = 2.5,
      color = RGB(0.10, 0.35, 0.25), label = "bus 1 (cheap gen)")
hline!(pP, [10, 30]; lw = 1.2, ls = :dot, color = :grey40,
       label = "generators' own marginal costs")

savefig(plot(pN, pR, pD, pP; layout = (2, 2), size = (1400, 900)),
        joinpath(HERE, "figures", "part4_dynamic.png"))
println("\n Figure written to figures/part4_dynamic.png")
