module EconomicDispatch

using CSV
using DataFrames
using HiGHS
using JuMP

export load_inputs, solve_multi_period, solve_single_period


function load_inputs(root::AbstractString)
    fleet = CSV.read(joinpath(root, "data", "processed", "oahu_generators.csv"), DataFrame)
    load = CSV.read(joinpath(root, "data", "processed", "oahu_load_8760.csv"), DataFrame)
    return fleet, load
end


function check_single_period(fleet::DataFrame, dispatch::Vector{Float64}, demand::Float64)
    tolerance = 1e-5
    @assert isapprox(sum(dispatch), demand; atol=tolerance) "dispatch does not equal demand"
    @assert all(dispatch .>= fleet.p_min_mw .- tolerance) "a generator is below Pmin"
    @assert all(dispatch .<= fleet.p_max_mw .+ tolerance) "a generator is above Pmax"

    # For a linear single-period model, no expensive unit should produce above minimum while
    # a strictly cheaper unit still has available headroom.
    for expensive in eachindex(dispatch), cheaper in eachindex(dispatch)
        if fleet.varcost_usd_per_mwh[cheaper] + tolerance < fleet.varcost_usd_per_mwh[expensive]
            @assert !(
                dispatch[expensive] > fleet.p_min_mw[expensive] + tolerance &&
                dispatch[cheaper] < fleet.p_max_mw[cheaper] - tolerance
            ) "dispatch violates the hand-sorted merit order"
        end
    end
end


function solve_single_period(fleet::DataFrame, demand::Real; hour::Integer)
    G = 1:nrow(fleet)
    p_min = Float64.(fleet.p_min_mw)
    p_max = Float64.(fleet.p_max_mw)
    variable_cost = Float64.(fleet.varcost_usd_per_mwh)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, p_min[g] <= y[g in G] <= p_max[g])
    @objective(model, Min, sum(variable_cost[g] * y[g] for g in G))
    @constraint(model, demand_balance, sum(y[g] for g in G) == Float64(demand))
    optimize!(model)

    @assert termination_status(model) == MOI.OPTIMAL "single-period model is not optimal"
    dispatch = Array(value.(y))
    check_single_period(fleet, dispatch, Float64(demand))

    tolerance = 1e-5
    marginal = findall(
        g -> dispatch[g] > p_min[g] + tolerance && dispatch[g] < p_max[g] - tolerance,
        G,
    )
    marginal_generator = if isempty(marginal)
        active = findall(g -> dispatch[g] > p_min[g] + tolerance, G)
        fleet.name[active[argmax(variable_cost[active])]]
    else
        fleet.name[marginal[argmax(variable_cost[marginal])]]
    end

    result = select(
        fleet,
        :name,
        :fuel,
        :p_min_mw,
        :p_max_mw,
        :varcost_usd_per_mwh,
        :co2_kg_per_mwh,
    )
    result.hour = fill(Int(hour), nrow(result))
    result.demand_mw = fill(Float64(demand), nrow(result))
    result.dispatch_mw = dispatch
    result.emissions_kg_co2 = dispatch .* Float64.(fleet.co2_kg_per_mwh)

    return (
        dispatch=result,
        total_cost_usd_per_hr=objective_value(model),
        total_emissions_kg_co2=sum(result.emissions_kg_co2),
        marginal_generator=marginal_generator,
        marginal_cost_usd_per_mwh=dual(demand_balance),
    )
end


function solve_multi_period(fleet::DataFrame, demand::AbstractVector{<:Real}; start_hour::Integer)
    G = 1:nrow(fleet)
    T = 1:length(demand)
    p_min = Float64.(fleet.p_min_mw)
    p_max = Float64.(fleet.p_max_mw)
    ramp = Float64.(fleet.ramp_mw_per_hr)
    variable_cost = Float64.(fleet.varcost_usd_per_mwh)
    demand_values = Float64.(demand)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, p_min[g] <= y[g in G, t in T] <= p_max[g])
    @objective(model, Min, sum(variable_cost[g] * y[g, t] for g in G, t in T))
    @constraint(model, demand_balance[t in T], sum(y[g, t] for g in G) == demand_values[t])
    @constraint(model, ramp_up[g in G, t in 1:(length(T) - 1)], y[g, t + 1] - y[g, t] <= ramp[g])
    @constraint(model, ramp_down[g in G, t in 1:(length(T) - 1)], y[g, t] - y[g, t + 1] <= ramp[g])
    optimize!(model)

    @assert termination_status(model) == MOI.OPTIMAL "multi-period model is not optimal"
    dispatch = Array(value.(y))
    tolerance = 1e-5
    for t in T
        @assert isapprox(sum(dispatch[:, t]), demand_values[t]; atol=tolerance) "hourly balance failed"
    end
    @assert all(dispatch .>= p_min .- tolerance) "a generator is below Pmin"
    @assert all(dispatch .<= p_max .+ tolerance) "a generator is above Pmax"
    if length(T) > 1
        @assert all(abs.(diff(dispatch; dims=2)) .<= ramp .+ tolerance) "a ramp constraint failed"
    end

    result = DataFrame(
        hour=Int[],
        window_hour=Int[],
        demand_mw=Float64[],
        name=String[],
        fuel=String[],
        dispatch_mw=Float64[],
        varcost_usd_per_mwh=Float64[],
        emissions_kg_co2=Float64[],
    )
    for t in T, g in G
        push!(
            result,
            (
                Int(start_hour + t - 1),
                Int(t),
                demand_values[t],
                String(fleet.name[g]),
                String(fleet.fuel[g]),
                dispatch[g, t],
                variable_cost[g],
                dispatch[g, t] * Float64(fleet.co2_kg_per_mwh[g]),
            ),
        )
    end

    return (
        dispatch=result,
        total_cost_usd=objective_value(model),
        total_emissions_kg_co2=sum(result.emissions_kg_co2),
        marginal_cost_usd_per_mwh=dual.(demand_balance),
    )
end

end
