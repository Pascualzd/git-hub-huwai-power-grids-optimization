# Regression test against the assigned course manual.
#
# The professor's reference is the Power Systems Optimization course notebook
# 06-Optimal-Power-Flow.ipynb (Jenkins & Davidson), which builds the same transportation and
# DC-OPF formulations this project uses. This test rebuilds that notebook's canonical 3-bus
# example in our own data format, solves it with `solve_network_dispatch`, and checks that we
# reproduce the notebook's published dispatch, flows, and locational prices exactly — including
# the well-known result that Bus 3's price reaches $150/MWh, above either generator's cost, once
# the direct line saturates.
#
# Source data: opf_data/{gen,gencost,branch,bus}.csv in the course repository.
# Run standalone with:  julia --project=. test/opf_reference_test.jl

include(joinpath(@__DIR__, "..", "src", "EconomicDispatch.jl"))
include(joinpath(@__DIR__, "..", "src", "NetworkDispatch.jl"))
using .NetworkDispatch
using DataFrames

const ATOL = 1e-4

# Two generators: cheap GenA at Bus 1 ($50/MWh), costly GenB at Bus 2 ($100/MWh); Pmax 1000.
fleet = DataFrame(
    name=["GenA", "GenB"], fuel=["test", "test"],
    p_min_mw=[0.0, 0.0], p_max_mw=[1000.0, 1000.0],
    ramp_mw_per_hr=[1000.0, 1000.0], varcost_usd_per_mwh=[50.0, 100.0],
    co2_kg_per_mwh=[0.0, 0.0],
)
# All load sits at Bus 3, so the island demand passed below lands entirely there.
buses = DataFrame(bus=["B1", "B2", "B3"], load_share=[0.0, 0.0, 1.0])
# A triangle of three identical lines (x = 0.0281 p.u., 500 MW each). Transport cost is zeroed
# so total cost equals pure generation cost and matches the notebook's objective.
branches = DataFrame(
    branch=[1, 2, 3], from_bus=["B1", "B1", "B2"], to_bus=["B3", "B2", "B3"],
    x_pu=[0.0281, 0.0281, 0.0281], limit_mw=[500.0, 500.0, 500.0],
    transport_cost_usd_per_mwh=[0.0, 0.0, 0.0],
)
generator_bus = DataFrame(name=["GenA", "GenB"], bus=["B1", "B2"])


function solved(load, mode)
    result = solve_network_dispatch(fleet, buses, branches, generator_bus, [load];
        mode=mode, start_hour=1)
    gen = sort(result.dispatch, :name).dispatch_mw
    flow = sort(result.flows, :branch).flow_mw
    lmp = sort(result.prices, :bus).lmp_usd_per_mwh   # B1, B2, B3 in order
    return result.total_cost_usd, gen, flow, lmp
end


function check(label, actual, expected)
    @assert all(isapprox.(actual, expected; atol=ATOL)) (
        "$label mismatch:\n  expected $(expected)\n  got      $(actual)"
    )
    println("  ok  $label = $(round.(actual; digits=2))")
end


println("Validating against course manual 06-Optimal-Power-Flow.ipynb (3-bus example)")

# --- 600 MW: uncongested; DC power flow splits 400/200/200; one uniform price of $50 ---
println("\n600 MW demand at Bus 3 (uncongested):")
cost, gen, flow, lmp = solved(600.0, :dcopf)
check("DC-OPF objective", cost, 30_000.0)
check("DC-OPF generation (GenA, GenB)", gen, [600.0, 0.0])
check("DC-OPF flows (l13, l12, l23)", flow, [400.0, 200.0, 200.0])
check("DC-OPF LMPs (B1, B2, B3)", lmp, [50.0, 50.0, 50.0])

# --- 800 MW: line 1-3 binds at 500 MW; GenB must run; Bus 3 price rises to $150 ---
println("\n800 MW demand at Bus 3 (line 1-3 congested):")
cost, gen, flow, lmp = solved(800.0, :dcopf)
check("DC-OPF objective", cost, 45_000.0)
check("DC-OPF generation (GenA, GenB)", gen, [700.0, 100.0])
check("DC-OPF flows (l13, l12, l23)", flow, [500.0, 200.0, 300.0])
check("DC-OPF LMPs (B1, B2, B3)", lmp, [50.0, 100.0, 150.0])

# --- The transportation model routes freely, so it undercuts DC-OPF at 800 MW. The gap is
#     exactly the loop-flow cost this project reports on the Oʻahu network. ---
println("\nTransportation vs DC-OPF at 800 MW:")
transport_cost, _, _, _ = solved(800.0, :transport)
dcopf_cost, _, _, _ = solved(800.0, :dcopf)
check("transportation objective", transport_cost, 40_000.0)
@assert transport_cost < dcopf_cost "transportation must be a lower bound on DC-OPF"
println("  ok  loop-flow cost (DC-OPF − transport) = \$$(round(dcopf_cost - transport_cost))")

println("\nAll manual-reference checks passed.")
