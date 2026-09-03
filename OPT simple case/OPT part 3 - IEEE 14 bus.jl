#=
OPT part 3 -- the same DC-OPF machine, bolted onto a bigger grid.

WHY THIS FILE EXISTS
--------------------
Part 2 solved a 3-bus triangle. Nothing about `dcopf` was specific to three
buses, so this file proves it by feeding in the IEEE 14-bus test system:
14 junctions, 20 lines, 5 generators, 259 MW of load.

DATA PROVENANCE
---------------
ieee14/*.csv are transcribed from MATPOWER `case14.m` (the canonical IEEE
14-bus case), reshaped into the same four-table schema this project already
uses. Two honest caveats, both written into the code rather than hidden:

  1. MATPOWER's case14 lists rateA = 0 on every branch. In MATPOWER, 0 means
     "no thermal limit". Feeding 0 straight into the constraint
         -rateA <= FLOW <= rateA
     would clamp every flow to zero and make the problem infeasible. So the
     CSV stores 9900, and the model treats anything >= 9000 as unlimited.

  2. Branches 4-7, 4-9 and 5-6 are transformers with off-nominal tap ratios
     (0.978, 0.969, 0.932). The textbook DC approximation used here ignores
     the tap and uses b = 1/x. This is the standard simplification; a
     tap-aware version would use b = 1/(x * ratio).

WHAT IT PRODUCES
----------------
  Scenario A -- faithful case14: unlimited lines, 259 MW load.
                Answers "what does this grid cost when copper is free?"
  Scenario B -- ratings assigned from Scenario A's own flows (1.5x today's
                duty), then demand grown until the network has no feasible
                dispatch left. The ceiling is found by BISECTION, not by the
                coarse sweep -- "the last grid point that solved" and "the
                point where the network fails" are different claims, and only
                the second one is worth printing.
=#

using JuMP, HiGHS
using Plots
using DataFrames, CSV, PrettyTables, Printf
ENV["COLUMNS"] = 160
gr()
mkpath(joinpath(@__DIR__, "figures"))   # make sure the output folder exists

const HERE = @__DIR__
include(joinpath(HERE, "gridviz.jl"))

# ---------------------------------------------------------------------------
# 1. Load and prepare the IEEE 14-bus tables
# ---------------------------------------------------------------------------
function load_case(dir)
    gen     = CSV.read(joinpath(dir, "gen.csv"),     DataFrame)
    gencost = CSV.read(joinpath(dir, "gencost.csv"), DataFrame)
    branch  = CSV.read(joinpath(dir, "branch.csv"),  DataFrame)
    bus     = CSV.read(joinpath(dir, "bus.csv"),     DataFrame)
    for f in (gen, gencost, branch, bus)
        rename!(f, lowercase.(names(f)))
    end
    gen.id     = 1:nrow(gen)
    gencost.id = 1:nrow(gencost)
    branch.id  = 1:nrow(branch)
    branch.sus = 1 ./ branch.x          # DC approximation: r = 0, b = 1/x
    return gen, gencost, branch, bus
end

gen, gencost, branch, bus = load_case(joinpath(HERE, "ieee14"))
baseMVA = 100

println("\n" * "="^78)
println(" IEEE 14-BUS SYSTEM  (MATPOWER case14)")
println("="^78)
@printf("  buses      : %d\n", nrow(bus))
@printf("  lines      : %d\n", nrow(branch))
@printf("  generators : %d  (capacity %.1f MW)\n", nrow(gen), sum(gen.pmax))
@printf("  total load : %.1f MW\n", sum(bus.pd))
@printf("  slack bus  : %d\n", bus[bus.type .== 3, :bus_i][1])

print("\n Buses\n");       pretty_table(bus[:, [:bus_i, :type, :pd, :qd]])
print("\n Generators\n");  pretty_table(hcat(gen[:, [:id, :bus, :pmin, :pmax]],
                                             gencost[:, [:c2, :c1]]))
print("\n Branches\n");    pretty_table(branch[:, [:id, :fbus, :tbus, :x, :sus, :ratea, :ratio]])

# ---------------------------------------------------------------------------
# 2. The model -- identical in structure to Part 2
# ---------------------------------------------------------------------------
"""
    dcopf(gen, branch, gencost, bus, baseMVA)

Linearised DC optimal power flow.

The physical picture, in one paragraph. Every bus is given a HEIGHT, THETA
(the voltage phase angle). Power slides downhill from high angle to low
angle, and the amount that slides down a given line is proportional to the
height difference times that line's susceptance -- exactly like water flowing
between tanks through pipes of different diameters. You cannot choose the
flows directly; you choose the heights, and the flows follow. The optimiser
picks the cheapest set of injections whose resulting terrain drains all the
power to where the load sits, without over-filling any pipe.
"""
function dcopf(gen, branch, gencost, bus, baseMVA; silent = true)
    DCOPF = Model(HiGHS.Optimizer)
    silent && set_silent(DCOPF)

    G = gen.id                                   # generators
    N = bus.bus_i                                # buses
    L = branch.id                                # lines
    slack = bus[bus.type .== 3, :bus_i][1]       # reference bus

    @variables(DCOPF, begin
        gen[g, :pmin] <= GEN[g in G] <= gen[g, :pmax]
        THETA[N]
    end)

    @objective(DCOPF, Min, sum(gencost[g, :c1] * GEN[g] for g in G))

    @constraint(DCOPF, cSlack, THETA[slack] == 0)

    @expression(DCOPF, FLOW[l in L],
        baseMVA * branch[l, :sus] *
        (THETA[branch[l, :fbus]] - THETA[branch[l, :tbus]]))

    @constraint(DCOPF, cBalance[i in N],
        sum(GEN[g] for g in gen[gen.bus .== i, :id])
            - bus[bus.bus_i .== i, :pd][1] ==
        sum(FLOW[l] for l in branch[branch.fbus .== i, :id]) -
        sum(FLOW[l] for l in branch[branch.tbus .== i, :id]))

    @constraint(DCOPF, cLineLimits[l in L],
        -branch[l, :ratea] <= FLOW[l] <= branch[l, :ratea])

    optimize!(DCOPF)

    if termination_status(DCOPF) != MOI.OPTIMAL
        return (status = termination_status(DCOPF), cost = NaN,
                generation = DataFrame(), flows = DataFrame(),
                angles = DataFrame(), prices = DataFrame())
    end

    generation = DataFrame(id = gen.id, node = gen.bus, gen = value.(GEN).data)
    flows = DataFrame(id = branch.id, fbus = branch.fbus, tbus = branch.tbus,
                      flow = value.(FLOW).data, ratea = branch.ratea)
    flows.util = [r.ratea >= 9000 ? 0.0 : abs(r.flow) / r.ratea for r in eachrow(flows)]
    angles = DataFrame(bus = bus.bus_i, theta = value.(THETA).data)
    angles.deg = angles.theta .* (180 / pi)
    prices = DataFrame(bus = bus.bus_i, lmp = [dual(cBalance[i]) for i in N])

    return (generation = generation, flows = flows, angles = angles,
            prices = prices, cost = objective_value(DCOPF),
            status = termination_status(DCOPF))
end

function report(sol, label)
    println("\n" * "-"^78)
    println(" $label")
    println("-"^78)
    println(" status : ", sol.status)
    if sol.status != MOI.OPTIMAL
        println(" No feasible dispatch exists for this network + load combination.")
        return
    end
    @printf(" cost   : \$%.2f /hour\n", sol.cost)
    @printf(" served : %.1f MW\n", sum(sol.generation.gen))
    print("\n Dispatch\n"); pretty_table(sol.generation)
    print("\n Flows (util = |flow|/rateA; 1.00 means the pipe is full)\n")
    pretty_table(sort(sol.flows, :util, rev = true))
    print("\n Angles\n"); pretty_table(sol.angles)
    print("\n Locational marginal prices (\$/MWh)\n"); pretty_table(sol.prices)
    binding = sol.flows[sol.flows.util .>= 0.999, :]
    if nrow(binding) == 0
        println("\n No line is at its limit -- the network is not the bottleneck.")
    else
        println("\n CONGESTED LINES (these are what make prices differ by location):")
        for r in eachrow(binding)
            @printf("   line %2d : %2d -> %2d   %.1f MW of %.1f MW\n",
                    r.id, r.fbus, r.tbus, abs(r.flow), r.ratea)
        end
    end
end

# ---------------------------------------------------------------------------
# 3. SCENARIO A -- faithful case14, no thermal limits
# ---------------------------------------------------------------------------
solA = dcopf(gen, branch, gencost, bus, baseMVA)
report(solA, "SCENARIO A -- case14 as published (lines unlimited, load 259 MW)")

pA = plot_network(bus, branch, solA.generation, solA.flows;
                  coords = IEEE14_COORDS,
                  title = @sprintf("IEEE 14-bus  |  Scenario A: unlimited lines  |  \$%.0f/h", solA.cost))
savefig(pA, joinpath(HERE, "figures", "ieee14_A_network.png"))

# ---------------------------------------------------------------------------
# 4. SCENARIO B -- give the lines real ratings, then grow the load
# ---------------------------------------------------------------------------
# Ratings are derived from Scenario A's own flows rather than invented:
#   rateA_l = max(FLOOR, ceil(HEADROOM * |flow_l in Scenario A|))
# i.e. every line is built with HEADROOM x the duty it does today.
const HEADROOM = 1.50
const FLOOR_MW = 25.0

branchB = deepcopy(branch)
branchB.ratea = [max(FLOOR_MW, ceil(HEADROOM * abs(f))) for f in solA.flows.flow]

println("\n\n Assigned line ratings (each line built for $(HEADROOM)x today's duty)\n")
pretty_table(DataFrame(line = branchB.id, from = branchB.fbus, to = branchB.tbus,
                       flow_A = round.(solA.flows.flow, digits = 1),
                       rateA = branchB.ratea))

# --- 4a. How far can demand grow before this grid gives out? --------------
# Rather than GUESSING a growth factor and hoping it is feasible, sweep it.
# Physically: keep turning up every tap in the city by the same percentage,
# and watch (i) the hourly bill, and (ii) the moment the pipes cannot deliver.
println("\n\n DEMAND-GROWTH SWEEP -- scaling every bus load by the same factor\n")
sweep = DataFrame(growth = Float64[], load_MW = Float64[], status = String[],
                  cost = Float64[], avg_price = Float64[], n_congested = Int[])
sweep_sols = Dict{Float64,Any}()
for gr in 1.00:0.05:2.00
    busg = deepcopy(bus); busg.pd = bus.pd .* gr
    s = dcopf(gen, branchB, gencost, busg, baseMVA)
    feas = s.status == MOI.OPTIMAL
    feas && (sweep_sols[gr] = (sol = s, bus = busg))
    push!(sweep, (gr, sum(busg.pd), string(s.status),
                  feas ? s.cost : NaN,
                  feas ? s.cost / sum(busg.pd) : NaN,
                  feas ? sum(s.flows.util .>= 0.999) : -1))
end
pretty_table(sweep)

feasible = sweep[sweep.status .== "OPTIMAL", :]

# --- 4b. Where is the ceiling ACTUALLY? -----------------------------------
# The sweep above tells us the last point ON A 5% GRID that still solves. That
# is a weaker statement than "the network fails here", and quietly overclaiming
# it would make the headline number wrong. Bisect for the real boundary.
function feasibility_ceiling(solve_at, lo, hi; tol = 1e-4)
    solve_at(lo) === nothing && error("lower bound already infeasible")
    solve_at(hi) === nothing || error("upper bound still feasible; raise it")
    while hi - lo > tol
        mid = (lo + hi) / 2
        solve_at(mid) === nothing ? (hi = mid) : (lo = mid)
    end
    return lo
end

solve_growth(g) = begin
    b = deepcopy(bus); b.pd = bus.pd .* g
    s = dcopf(gen, branchB, gencost, b, baseMVA)
    s.status == MOI.OPTIMAL ? s : nothing
end

grid_last = maximum(feasible.growth)
GROWTH = feasibility_ceiling(solve_growth, 1.0, 3.0)
@printf("\n Coarse sweep's last feasible grid point : +%.0f%%\n", (grid_last - 1) * 100)
@printf(" TRUE feasibility ceiling (by bisection) : +%.2f%%  ->  %.1f MW\n",
        (GROWTH - 1) * 100, sum(bus.pd) * GROWTH)
@printf(" One further step (+%.2f%%) has NO feasible dispatch.\n", (GROWTH + 1e-4 - 1) * 100)
println(" The wires, not the generators, run out first:")
@printf(" installed generation %.1f MW, but the ceiling load is only %.1f MW.\n",
        sum(gen.pmax), sum(bus.pd) * GROWTH)

busB = deepcopy(bus); busB.pd = bus.pd .* GROWTH
solB = solve_growth(GROWTH)
report(solB, "SCENARIO B -- rated lines at the TRUE ceiling, demand " *
             "+$(round((GROWTH-1)*100, digits=2))% (load $(round(sum(busB.pd), digits=1)) MW)")

# cost / price curve  (only the feasible stretch is a real curve; beyond the
# cliff there is no answer to plot, so we draw the cliff itself)
cliff = sum(bus.pd) * GROWTH
pC = plot(feasible.load_MW, feasible.cost; lw = 3, marker = :circle, ms = 4,
          color = RGB(0.17, 0.40, 0.62), label = "total cost",
          xlabel = "system load (MW)", ylabel = "\$/hour",
          title = "Cost per hour vs system load", titlefontsize = 11,
          legend = :topleft, bottom_margin = 8Plots.mm, left_margin = 6Plots.mm)
vline!(pC, [cliff]; lw = 2, ls = :dash, color = RGB(0.55, 0.10, 0.10),
       label = "no feasible dispatch beyond here")
pP = plot(feasible.load_MW, feasible.avg_price; lw = 3, marker = :circle, ms = 4,
          color = RGB(0.72, 0.20, 0.20), label = "average \$/MWh",
          xlabel = "system load (MW)", ylabel = "\$/MWh",
          title = "Average price per MWh: flat, then it bites",
          titlefontsize = 11, legend = :topleft,
          bottom_margin = 8Plots.mm, left_margin = 6Plots.mm)
vline!(pP, [cliff]; lw = 2, ls = :dash, color = RGB(0.55, 0.10, 0.10),
       label = "network limit")
savefig(plot(pC, pP, layout = (1, 2), size = (1300, 500)),
        joinpath(HERE, "figures", "ieee14_growth_sweep.png"))

if solB.status == MOI.OPTIMAL
    pB = plot_network(busB, branchB, solB.generation, solB.flows;
                      coords = IEEE14_COORDS,
                      title = @sprintf("IEEE 14-bus  |  Scenario B: at the feasibility ceiling, demand +%.2f%%  |  \$%.0f/h",
                                       (GROWTH - 1) * 100, solB.cost))
    savefig(pB, joinpath(HERE, "figures", "ieee14_B_network.png"))

    pD = plot_dispatch(gen, gencost, solB.generation; title = "Scenario B dispatch vs capacity")
    pL = bar(string.("bus ", solB.prices.bus), solB.prices.lmp;
             label = "", color = RGB(0.17, 0.40, 0.62), linecolor = :white,
             title = "Scenario B locational marginal price", ylabel = "\$/MWh",
             titlefontsize = 12, xrotation = 45)
    pAll = plot(pB, plot(pD, pL, layout = (2, 1));
                layout = grid(1, 2, widths = [0.56, 0.44]), size = (1650, 900))
    savefig(pAll, joinpath(HERE, "figures", "ieee14_B_dashboard.png"))
end

# ---------------------------------------------------------------------------
# 5. Verification -- never trust a solver you have not audited
# ---------------------------------------------------------------------------
function verify(sol, bus_, branch_, label)
    println("\n VERIFICATION -- $label")
    ok = true
    g = sum(sol.generation.gen); d = sum(bus_.pd)
    @printf("   energy balance   : gen %.3f MW vs load %.3f MW   -> %s\n",
            g, d, abs(g - d) < 1e-4 ? "PASS" : "FAIL")
    ok &= abs(g - d) < 1e-4
    worst = maximum(abs.(sol.flows.flow) .- branch_.ratea)
    @printf("   line limits      : worst overload %+.6f MW          -> %s\n",
            worst, worst < 1e-6 ? "PASS" : "FAIL")
    ok &= worst < 1e-6
    slack = bus_[bus_.type .== 3, :bus_i][1]
    th = sol.angles[sol.angles.bus .== slack, :theta][1]
    @printf("   slack angle == 0 : %.2e                            -> %s\n",
            th, abs(th) < 1e-9 ? "PASS" : "FAIL")
    ok &= abs(th) < 1e-9
    lo = minimum(sol.generation.gen .- gen.pmin)
    hi = minimum(gen.pmax .- sol.generation.gen)
    @printf("   gen within Pmin/Pmax                                 -> %s\n",
            (lo > -1e-6 && hi > -1e-6) ? "PASS" : "FAIL")
    ok &= (lo > -1e-6 && hi > -1e-6)
    # Kirchhoff at every bus, recomputed from scratch
    worstbal = 0.0
    for i in bus_.bus_i
        inj = sum(sol.generation[sol.generation.node .== i, :gen]; init = 0.0) -
              bus_[bus_.bus_i .== i, :pd][1]
        out = sum(sol.flows[sol.flows.fbus .== i, :flow]; init = 0.0) -
              sum(sol.flows[sol.flows.tbus .== i, :flow]; init = 0.0)
        worstbal = max(worstbal, abs(inj - out))
    end
    @printf("   nodal Kirchhoff  : worst residual %.2e MW          -> %s\n",
            worstbal, worstbal < 1e-6 ? "PASS" : "FAIL")
    ok &= worstbal < 1e-6
    println("   ", ok ? ">>> ALL CHECKS PASS" : ">>> SOMETHING IS WRONG")
    return ok
end

println("\n" * "="^78)
verify(solA, bus, branch, "Scenario A")
solB.status == MOI.OPTIMAL && verify(solB, busB, branchB, "Scenario B")
println("="^78)
println("\nFigures written to figures/")
