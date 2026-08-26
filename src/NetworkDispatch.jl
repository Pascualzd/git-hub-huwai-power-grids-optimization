module NetworkDispatch

using CSV
using DataFrames
using HiGHS
using JuMP

export load_network, solve_network_dispatch, MODES, VOLL_USD_PER_MWH


"""
Three nested formulations of the same dispatch problem.

  `:copper`    one island-wide balance; no network at all (the existing baseline)
  `:transport` nodal balance plus thermal limits, with flow freely routable
  `:dcopf`     the transportation model plus Kirchhoff's voltage law

Their feasible sets nest, `X_dcopf ⊆ X_transport ⊆ X_copper`, so their optimal costs are
non-decreasing in that order. `z_transport - z_copper` prices network congestion;
`z_dcopf - z_transport` prices the physics on top of it.
"""
const MODES = (:copper, :transport, :dcopf)

const BASE_MVA = 100.0
# High enough that shedding is never economic, low enough to keep the LP well scaled. Load
# shedding exists so an over-constrained network reports *where* it fails rather than
# returning INFEASIBLE.
const VOLL_USD_PER_MWH = 10_000.0
const TOLERANCE = 1e-5


function load_network(root::AbstractString)
    processed = joinpath(root, "data", "processed")
    buses = CSV.read(joinpath(processed, "oahu_network_buses.csv"), DataFrame)
    branches = CSV.read(joinpath(processed, "oahu_network_branches.csv"), DataFrame)
    generator_bus = CSV.read(joinpath(processed, "oahu_generator_bus_map.csv"), DataFrame)
    return buses, branches, generator_bus
end


"""
    solve_network_dispatch(fleet, buses, branches, generator_bus, demand; mode, start_hour)

Minimize generation, transport, and unserved-energy cost over `length(demand)` hours.

`demand` is island-wide net load in MW; it is allocated to buses by `buses.load_share`, so
the total served is identical across all three modes and the costs are comparable.
"""
function solve_network_dispatch(
    fleet::DataFrame,
    buses::DataFrame,
    branches::DataFrame,
    generator_bus::DataFrame,
    demand::AbstractVector{<:Real};
    mode::Symbol,
    start_hour::Integer,
)
    mode in MODES || error("mode must be one of $(MODES), got $(mode)")

    G = 1:nrow(fleet)
    N = 1:nrow(buses)
    L = 1:nrow(branches)
    T = 1:length(demand)

    p_min = Float64.(fleet.p_min_mw)
    p_max = Float64.(fleet.p_max_mw)
    ramp = Float64.(fleet.ramp_mw_per_hr)
    variable_cost = Float64.(fleet.varcost_usd_per_mwh)

    bus_index = Dict(String(name) => i for (i, name) in enumerate(buses.bus))
    generator_at = Dict(String(row.name) => String(row.bus) for row in eachrow(generator_bus))
    gen_bus = [bus_index[generator_at[String(name)]] for name in fleet.name]
    gens_at = [findall(==(n), gen_bus) for n in N]

    from_bus = [bus_index[String(name)] for name in branches.from_bus]
    to_bus = [bus_index[String(name)] for name in branches.to_bus]
    into = [findall(==(n), to_bus) for n in N]
    out_of = [findall(==(n), from_bus) for n in N]
    susceptance = 1.0 ./ Float64.(branches.x_pu)
    limit = Float64.(branches.limit_mw)
    transport_cost = Float64.(branches.transport_cost_usd_per_mwh)

    share = Float64.(buses.load_share)
    demand_values = Float64.(demand)
    d = [share[n] * demand_values[t] for n in N, t in T]

    # Angles are relative, so the reference choice shifts every θ by a constant and changes
    # no flow, cost, or price. Anchor on the largest load bus.
    reference = argmax(share)

    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, p_min[g] <= y[g in G, t in T] <= p_max[g])
    @variable(model, 0 <= r[n in N, t in T] <= d[n, t])

    generation_expr = sum(variable_cost[g] * y[g, t] for g in G, t in T)
    shedding_expr = sum(VOLL_USD_PER_MWH * r[n, t] for n in N, t in T)

    if mode === :copper
        @constraint(
            model,
            balance[t in T],
            sum(y[g, t] for g in G) + sum(r[n, t] for n in N) == sum(d[n, t] for n in N)
        )
        @objective(model, Min, generation_expr + shedding_expr)
    else
        @variable(model, -limit[l] <= f[l in L, t in T] <= limit[l])
        # Split the signed flow so the transport term can price |f| while staying linear.
        @variable(model, f_pos[l in L, t in T] >= 0)
        @variable(model, f_neg[l in L, t in T] >= 0)
        @constraint(model, split[l in L, t in T], f[l, t] == f_pos[l, t] - f_neg[l, t])

        @constraint(
            model,
            nodal[n in N, t in T],
            sum(y[g, t] for g in gens_at[n]) + sum(f[l, t] for l in into[n]) -
            sum(f[l, t] for l in out_of[n]) + r[n, t] == d[n, t]
        )

        if mode === :dcopf
            @variable(model, θ[n in N, t in T])
            @constraint(model, reference_angle[t in T], θ[reference, t] == 0)
            @constraint(
                model,
                kvl[l in L, t in T],
                f[l, t] == BASE_MVA * susceptance[l] * (θ[from_bus[l], t] - θ[to_bus[l], t])
            )
        end

        @objective(
            model,
            Min,
            generation_expr +
            sum(transport_cost[l] * (f_pos[l, t] + f_neg[l, t]) for l in L, t in T) +
            shedding_expr
        )
    end

    if length(T) > 1
        @constraint(model, ramp_up[g in G, t in 1:(length(T) - 1)], y[g, t + 1] - y[g, t] <= ramp[g])
        @constraint(model, ramp_down[g in G, t in 1:(length(T) - 1)], y[g, t] - y[g, t + 1] <= ramp[g])
    end

    optimize!(model)
    @assert termination_status(model) == MOI.OPTIMAL "$(mode) model is not optimal"

    dispatch = Array(value.(y))
    shedding = Array(value.(r))
    flows = mode === :copper ? zeros(length(L), length(T)) : Array(value.(f))
    angles = mode === :dcopf ? Array(value.(θ)) : zeros(length(N), length(T))

    prices = if mode === :copper
        repeat(reshape([dual(balance[t]) for t in T], 1, :), length(N), 1)
    else
        [dual(nodal[n, t]) for n in N, t in T]
    end

    check_solution(
        mode, fleet, buses, branches, dispatch, flows, angles, shedding, d,
        gens_at, into, out_of, susceptance, from_bus, to_bus, limit, ramp,
    )

    generation_cost = sum(variable_cost[g] * dispatch[g, t] for g in G, t in T)
    transport_total = mode === :copper ? 0.0 :
        sum(transport_cost[l] * abs(flows[l, t]) for l in L, t in T)
    shed_total = sum(shedding)

    return (
        mode=mode,
        dispatch=dispatch_frame(fleet, buses, gen_bus, dispatch, d, start_hour),
        flows=flow_frame(branches, flows, start_hour),
        prices=price_frame(buses, prices, shedding, d, start_hour),
        angles=angles,
        total_cost_usd=objective_value(model),
        generation_cost_usd=generation_cost,
        transport_cost_usd=transport_total,
        unserved_mwh=shed_total,
        unserved_cost_usd=shed_total * VOLL_USD_PER_MWH,
    )
end


"""Verify the solution against the constraints as written, independently of the solver."""
function check_solution(
    mode, fleet, buses, branches, dispatch, flows, angles, shedding, d,
    gens_at, into, out_of, susceptance, from_bus, to_bus, limit, ramp,
)
    N = 1:nrow(buses)
    T = 1:size(dispatch, 2)

    @assert all(dispatch .>= Float64.(fleet.p_min_mw) .- TOLERANCE) "a generator is below Pmin"
    @assert all(dispatch .<= Float64.(fleet.p_max_mw) .+ TOLERANCE) "a generator is above Pmax"
    @assert all(shedding .>= -TOLERANCE) "negative load shedding"
    @assert all(shedding .<= d .+ TOLERANCE) "shed more load than exists at a bus"

    if size(dispatch, 2) > 1
        @assert all(abs.(diff(dispatch; dims=2)) .<= ramp .+ TOLERANCE) "a ramp constraint failed"
    end

    if mode === :copper
        for t in T
            served = sum(dispatch[:, t]) + sum(shedding[:, t])
            @assert isapprox(served, sum(d[:, t]); atol=TOLERANCE * length(N)) "island balance failed"
        end
        return
    end

    @assert all(abs.(flows) .<= limit .+ TOLERANCE) "a branch exceeds its thermal limit"

    for n in N, t in T
        injected = sum(dispatch[g, t] for g in gens_at[n]; init=0.0)
        imported = sum(flows[l, t] for l in into[n]; init=0.0)
        exported = sum(flows[l, t] for l in out_of[n]; init=0.0)
        residual = injected + imported - exported + shedding[n, t] - d[n, t]
        @assert abs(residual) <= TOLERANCE * 100 "nodal balance failed at bus $(buses.bus[n]), hour $t"
    end

    if mode === :dcopf
        # Recompute every flow from the solved angles. This is the constraint that separates
        # DC-OPF from a transportation model, so it is checked rather than trusted.
        for l in 1:size(flows, 1), t in T
            implied = BASE_MVA * susceptance[l] * (angles[from_bus[l], t] - angles[to_bus[l], t])
            @assert abs(implied - flows[l, t]) <= TOLERANCE * 100 (
                "KVL residual on branch $(branches.branch[l]), hour $t"
            )
        end
    end
end


function dispatch_frame(fleet, buses, gen_bus, dispatch, d, start_hour)
    result = DataFrame(
        hour=Int[], window_hour=Int[], name=String[], fuel=String[], bus=String[],
        dispatch_mw=Float64[], varcost_usd_per_mwh=Float64[], emissions_kg_co2=Float64[],
    )
    for t in 1:size(dispatch, 2), g in 1:size(dispatch, 1)
        push!(result, (
            Int(start_hour + t - 1), Int(t), String(fleet.name[g]), String(fleet.fuel[g]),
            String(buses.bus[gen_bus[g]]), dispatch[g, t],
            Float64(fleet.varcost_usd_per_mwh[g]),
            dispatch[g, t] * Float64(fleet.co2_kg_per_mwh[g]),
        ))
    end
    return result
end


function flow_frame(branches, flows, start_hour)
    result = DataFrame(
        hour=Int[], window_hour=Int[], branch=Int[], from_bus=String[], to_bus=String[],
        flow_mw=Float64[], limit_mw=Float64[], loading=Float64[],
    )
    for t in 1:size(flows, 2), l in 1:size(flows, 1)
        limit = Float64(branches.limit_mw[l])
        push!(result, (
            Int(start_hour + t - 1), Int(t), Int(branches.branch[l]),
            String(branches.from_bus[l]), String(branches.to_bus[l]),
            flows[l, t], limit, abs(flows[l, t]) / limit,
        ))
    end
    return result
end


function price_frame(buses, prices, shedding, d, start_hour)
    result = DataFrame(
        hour=Int[], window_hour=Int[], bus=String[], lmp_usd_per_mwh=Float64[],
        demand_mw=Float64[], unserved_mw=Float64[],
    )
    for t in 1:size(prices, 2), n in 1:size(prices, 1)
        push!(result, (
            Int(start_hour + t - 1), Int(t), String(buses.bus[n]),
            prices[n, t], d[n, t], shedding[n, t],
        ))
    end
    return result
end

end
