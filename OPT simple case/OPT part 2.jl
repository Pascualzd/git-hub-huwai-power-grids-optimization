#=
Overview of this script's pipeline:
  1. Load packages
  2. Load raw network data (buses, generators, lines, costs) from CSV
  3. Clean/prepare that data (column names, ids, line susceptance)
  4. Print the raw input tables for inspection
  5. Define `dcopf`, a linearized "DC" OPF model (JuMP + HiGHS) that adds
     voltage phase angles and physically-correct line flows on top of
     the transport model from Part 1 (Code - work.jl)
  6. Solve the model on this system's data
  7. Print the resulting generation/flow/angle solution
  8. Draw the solution as a network graph  <-- NEW (see gridviz.jl)
=#

# --- 1. Package imports ---
using JuMP, HiGHS
using Plots;
using DataFrames, CSV, PrettyTables
ENV["COLUMNS"]=120; # Set so all columns of DataFrames and Matrices are displayed
gr()                # headless-safe plotting backend
mkpath(joinpath(@__DIR__, "figures"))   # make sure the output folder exists

# --- 2. Load raw data ---
# Each CSV mirrors a MATPOWER-style table: bus/gen/branch/cost.
datadir = joinpath(@__DIR__)
gen = CSV.read(joinpath(datadir,"gen.csv"), DataFrame);
gencost = CSV.read(joinpath(datadir,"gencost.csv"), DataFrame);
branch = CSV.read(joinpath(datadir,"branch.csv"), DataFrame);
bus = CSV.read(joinpath(datadir,"bus.csv"), DataFrame);

# --- 3. Clean/prepare data ---
# Rename all columns to lowercase (by convention)
for f in [gen, gencost, branch, bus]
    rename!(f,lowercase.(names(f)))
end

# create generator ids
gen.id = 1:nrow(gen);
gencost.id = 1:nrow(gencost);

# create line ids
branch.id = 1:nrow(branch);

# Susceptance of each line (b = 1/x), assuming resistance r ~= 0 (DC approximation)
branch.sus = 1 ./ branch.x

# Base power for the network (MVA). MATPOWER-style datasets are per-unit
# relative to this; standard default is 100 MVA (matches gen.mbase here).
baseMVA = 100

# --- 4. Display raw input tables ---
print("\n Buses Data Frame\n")
pretty_table(bus)
print("\n Generators Data Frame\n")
pretty_table(gen)
print("\n Generator's cost Data Frame\n")
pretty_table(gencost)
print("\n Branch Data Frame\n")
pretty_table(branch)

# --- 5. Optimization model ---
#=
Function to solve the "DC" optimal power flow problem
Inputs:
    gen -- dataframe with generator info
    branch -- dataframe with transmission lines info
    gencost -- dataframe with generator info
    bus -- dataframe with bus types and loads
    baseMVA -- system base power (MVA), used to convert per-unit angle
               differences into physical MW flows

Role in the pipeline: builds and solves the linearized DC-OPF model, which
replaces Part 1's freely-routable FLOW variables with physically-derived
flows driven by voltage phase angle differences and line susceptance:
  - decision variables: GEN (output per generator), THETA (voltage phase
    angle per bus, in radians)
  - objective: minimize total linear generation cost (gencost.c1 * GEN)
  - constraints:
      * nodal supply/demand balance (net injection = net line flow out)
      * line flow definition: FLOW_l = baseMVA * sus_l * (theta_f(l) - theta_t(l))
      * line flow limits (+/- ratea)
      * generator capacity (Pmin/Pmax)
      * slack bus angle fixed to 0 (reference for all angle differences)
Returns generation, flow, and angle solutions, total cost, and solver status.
=#
function dcopf(gen, branch, gencost, bus, baseMVA)
    DCOPF = Model(HiGHS.Optimizer)

    # Definitions of sets
      # Set of all generators
    G = gen.id
      # Set of all nodes
    N = bus.bus_i
      # Set of all physical lines
    L = branch.id
      # Slack / reference bus (MATPOWER type == 3)
    slack = bus[bus.type .== 3, :bus_i][1]

    # Decision variables
    @variables(DCOPF, begin
        gen[g,:pmin] <= GEN[g in G] <= gen[g,:pmax]   # generation, bounded by Pmin/Pmax
        THETA[N]                                       # voltage phase angle per bus (radians)
    end)

    # Objective function: minimize sum of generation variable costs for all generators
    @objective(DCOPF, Min,
        sum( gencost[g,:c1] * GEN[g]
                        for g in G)
    )

    # Fix the slack bus angle to zero as the angle reference
    @constraint(DCOPF, cSlack, THETA[slack] == 0)

    # Line flows, defined by susceptance and angle difference (per unit -> MW via baseMVA)
    @expression(DCOPF, FLOW[l in L],
        baseMVA * branch[l,:sus] * (THETA[branch[l,:fbus]] - THETA[branch[l,:tbus]])
    )

    # Supply/demand balance constraints, accounting for power flows in/out of each node
    @constraint(DCOPF, cBalance[i in N],
        sum(GEN[g] for g in gen[gen.bus .== i,:id])
                - bus[bus.bus_i .== i,:pd][1] ==
        sum(FLOW[l] for l in branch[branch.fbus .== i,:id]) -
        sum(FLOW[l] for l in branch[branch.tbus .== i,:id])
    )

    # Flow limits on each branch
    @constraint(DCOPF, cLineLimits[l in L],
        -branch[l,:ratea] <= FLOW[l] <= branch[l,:ratea]
    )

    # Solve statement (! indicates runs in place)
    optimize!(DCOPF)

    # Dataframe of optimal decision variables
    generation = DataFrame(
        id = gen.id,
        node = gen.bus,
        gen = value.(GEN).data
        )

    flows = DataFrame(
        id = branch.id,
        fbus = branch.fbus,
        tbus = branch.tbus,
        flow = value.(FLOW).data
    )

    angles = DataFrame(
        bus = bus.bus_i,
        theta = value.(THETA).data
    )

    # Locational marginal prices: the shadow price of each nodal balance
    # constraint. Physically: "what does one extra MW at this bus cost me?"
    prices = DataFrame(
        bus = bus.bus_i,
        lmp = [dual(cBalance[i]) for i in N]
    )

    # Return the solution and objective as named tuple
    return (
        generation = generation,
        flows = flows,
        angles = angles,
        prices = prices,
        cost = objective_value(DCOPF),
        status = termination_status(DCOPF)
    )
end

# --- 6. Solve the model on this system's data ---
solution = dcopf(gen, branch, gencost, bus, baseMVA)

# --- 7. Display results ---
print("\n Optimal Generation\n")
pretty_table(solution.generation)
print("\n Optimal Flows\n")
pretty_table(solution.flows)
print("\n Optimal Voltage Angles (radians)\n")
pretty_table(solution.angles)
print("\n Locational Marginal Prices (\$/MWh)\n")
pretty_table(solution.prices)
println("\n Total cost: ", solution.cost)
println("Status: ", solution.status)

# --- 8. Draw the solution -------------------------------------------------
# gridviz.jl turns the three solution tables into a picture:
#   node  = bus (size = power handled, colour = supplies vs consumes)
#   edge  = line (width = |flow|, colour = |flow|/rateA, arrow = direction)
include(joinpath(@__DIR__, "gridviz.jl"))

p_net = plot_network(bus, branch, solution.generation, solution.flows;
                     coords = BUS3_COORDS,
                     title  = "3-bus DC-OPF  |  total cost \$$(round(Int, solution.cost))/h")
savefig(p_net, joinpath(@__DIR__, "figures", "part2_network.png"))

p_gen = plot_dispatch(gen, gencost, solution.generation)
p_ang = plot_angles(solution.angles)
p_all = plot(p_net, plot(p_gen, p_ang, layout = (2, 1));
             layout = grid(1, 2, widths = [0.58, 0.42]), size = (1500, 800))
savefig(p_all, joinpath(@__DIR__, "figures", "part2_dashboard.png"))

println("\nFigures written to figures/part2_network.png and figures/part2_dashboard.png")
