#=
Overview of this script's pipeline:
  1. Load packages
  2. Load raw network data (buses, generators, lines, costs) from CSV
  3. Clean/prepare that data (column names, ids, line susceptance)
  4. Print the raw input tables for inspection
  5. Define `transport`, a DC transport-flow OPF model (JuMP + HiGHS)
  6. Solve the model on this system's data
  7. Print the resulting generation/flow solution
=#

# --- 1. Package imports ---
# import Pkg; Pkg.add("VegaLite"); Pkg.add("PrettyTables")
using JuMP, HiGHS
using Plots;
using VegaLite  # to make some nice plots
using DataFrames, CSV, PrettyTables
ENV["COLUMNS"]=120; # Set so all columns of DataFrames and Matrices are displayedr

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
# id = row number, used later to index JuMP variables and to join gen<->gencost by position
gen.id = 1:nrow(gen);
gencost.id = 1:nrow(gencost);

# create line ids
# id = row number, used later to index JuMP variables (one FLOW var per line)
branch.id = 1:nrow(branch);

# Susceptance of each line (b = 1/x), assuming resistance r ~= 0 (DC approximation)
branch.sus = 1 ./ branch.x

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
Function to solve transport flow problem
Inputs:
    gen -- dataframe with generator info
    branch -- dataframe with transmission lines info
    gencost -- dataframe with generator info
    bus -- dataframe with bus types and loads

Role in the pipeline: builds and solves a linear "transport" (DC, lossless,
no line reactance/angle constraints) OPF model:
  - decision variables: GEN (output per generator), FLOW (signed flow per line)
  - objective: minimize total linear generation cost (gencost.c1 * GEN)
  - constraints: nodal supply/demand balance, generator capacity, line flow limits
Returns generation and flow solutions, total cost, and solver status.
=#
function transport(gen, branch, gencost, bus)
    Transport = Model(HiGHS.Optimizer) 

    #Definitions of sets
      # Set of all generators
    G = gen.id
      # Set of all nodes
    N = bus.bus_i
      # Set of all physical lines
    L = branch.id
      # Note: sets J_i and G_i will be described using dataframe indexing below

    # Decision variables
    @variables(Transport, begin
        GEN[G]  >= 0     # generation
        # Note: we assume Pmin = 0 for all resources for simplicty here
        FLOW[L]          # signed flow on each physical line
        # Note: flow is not constrained to be positive
        # By convention, positive values indicate flow from fbus to tbus,
        # while negative values indicate flow in the reverse direction.
    end)

    # Objective function: minimize sum of generation variable costs for all generators
    @objective(Transport, Min,
        sum( gencost[g,:c1] * GEN[g]
                        for g in G)
    )

    # Supply/demand balance constraints, accounting for power flows in/out of each node
    @constraint(Transport, cBalance[i in N],
        sum(GEN[g] for g in gen[gen.bus .== i,:id])
                - bus[bus.bus_i .== i,:pd][1] ==
        sum(FLOW[l] for l in branch[branch.fbus .== i,:id]) -
        sum(FLOW[l] for l in branch[branch.tbus .== i,:id])
    )

    # Max generation constraints
    @constraint(Transport, cMaxGen[g in G],
                    GEN[g] <= gen[g,:pmax])

    # Flow limits on each branch
    @constraint(Transport, cLineLimits[l in L],
        -branch[l,:ratea] <= FLOW[l] <= branch[l,:ratea]
    )

    # Solve statement (! indicates runs in place)
    optimize!(Transport)

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

    # Return the solution and objective as named tuple
    return (
        generation = generation,
        flows,
        cost = objective_value(Transport),
        status = termination_status(Transport)
    )
end

# --- 6. Solve the model on this system's data ---
solution = transport(gen, branch, gencost, bus)

# --- 7. Display results ---
print("\n Optimal Generation\n")
pretty_table(solution.generation)
print("\n Optimal Flows\n")
pretty_table(solution.flows)
println("\n Total cost: ", solution.cost)
println("Status: ", solution.status)

