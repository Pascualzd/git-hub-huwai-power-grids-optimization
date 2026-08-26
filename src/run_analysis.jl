ENV["GKSwstype"] = "100"

using CSV
using DataFrames
using Measures
using Plots
using Statistics

include(joinpath(@__DIR__, "EconomicDispatch.jl"))
using .EconomicDispatch

include(joinpath(@__DIR__, "NetworkDispatch.jl"))
using .NetworkDispatch

const ROOT = normpath(joinpath(@__DIR__, ".."))
const FIGURES = joinpath(ROOT, "figures")
const PROCESSED = joinpath(ROOT, "data", "processed")
mkpath(FIGURES)
default(
    fontfamily="Helvetica",
    guidefontsize=14,
    tickfontsize=11,
    legendfontsize=10,
    foreground_color_legend="#17324d",
)


function fleet_group(name::AbstractString)
    for group in ["H Power", "Kalaeloa", "Kahe", "Waiau", "Schofield", "Campbell"]
        startswith(name, group) && return group
    end
    return name
end


function grouped_dispatch(dispatch::DataFrame)
    grouped = transform(dispatch, :name => ByRow(fleet_group) => :group)
    return combine(
        groupby(grouped, [:window_hour, :demand_mw, :group]),
        :dispatch_mw => sum => :dispatch_mw,
        :emissions_kg_co2 => sum => :emissions_kg_co2,
    )
end


function make_single_period_figure(single::DataFrame)
    grouped = transform(single, :name => ByRow(fleet_group) => :group)
    grouped = combine(
        groupby(grouped, :group),
        :dispatch_mw => sum => :dispatch_mw,
        :p_max_mw => sum => :p_max_mw,
    )
    sort!(grouped, :dispatch_mw)
    positions = collect(1:nrow(grouped))
    p = plot(
        yticks=(positions, grouped.group),
        xlabel="Power (MW)",
        legend=false,
        xlims=(0, maximum(grouped.p_max_mw) * 1.08),
        ylims=(0.5, nrow(grouped) + 0.5),
        size=(1050, 600),
        left_margin=20mm,
    )
    for i in positions
        capacity = Shape(
            [0, grouped.p_max_mw[i], grouped.p_max_mw[i], 0],
            [i - 0.32, i - 0.32, i + 0.32, i + 0.32],
        )
        dispatch = Shape(
            [0, grouped.dispatch_mw[i], grouped.dispatch_mw[i], 0],
            [i - 0.19, i - 0.19, i + 0.19, i + 0.19],
        )
        plot!(p, capacity; color="#dbe4e8", linecolor=:white, label="")
        plot!(p, dispatch; color="#ef8354", linecolor=:white, label="")
    end
    savefig(p, joinpath(FIGURES, "single_period_dispatch.png"))
end


function make_multi_period_figures(multi::DataFrame)
    grouped = grouped_dispatch(multi)
    groups = unique(grouped.group)
    palette = ["#264653", "#2a9d8f", "#e9c46a", "#f4a261", "#e76f51", "#6d597a"]

    p_line = plot(
        xlabel="Hour of peak-load day",
        ylabel="Generation (MW)",
        xticks=1:2:24,
        legend=:outerright,
        size=(1100, 600),
        right_margin=15mm,
        bottom_margin=10mm,
    )
    for (index, group) in enumerate(groups)
        subset = grouped[grouped.group .== group, :]
        plot!(
            p_line,
            subset.window_hour,
            subset.dispatch_mw;
            label=group,
            linewidth=2.5,
            color=palette[mod1(index, length(palette))],
        )
    end
    savefig(p_line, joinpath(FIGURES, "multi_period_lines.png"))

    wide = unstack(select(grouped, :window_hour, :group, :dispatch_mw), :window_hour, :group, :dispatch_mw)
    sort!(wide, :window_hour)
    stack_groups = names(wide)[2:end]
    values = Matrix{Float64}(coalesce.(wide[:, stack_groups], 0.0))
    p_stack = areaplot(
        wide.window_hour,
        values;
        xlabel="Hour of peak-load day",
        ylabel="Power (MW)",
        xticks=1:2:24,
        label=permutedims(stack_groups),
        seriescolor=permutedims(palette[1:length(stack_groups)]),
        fillalpha=0.86,
        linewidth=0.6,
        legend=:outerright,
        size=(1100, 600),
        right_margin=15mm,
        bottom_margin=10mm,
    )
    demand = unique(select(grouped, :window_hour, :demand_mw))
    sort!(demand, :window_hour)
    plot!(
        p_stack,
        demand.window_hour,
        demand.demand_mw;
        color="#c1121f",
        linestyle=:dash,
        linewidth=3,
        label="Net load",
    )
    savefig(p_stack, joinpath(FIGURES, "multi_period_stack.png"))
end


function make_merit_order_figure(fleet::DataFrame)
    order = sort(fleet, :varcost_usd_per_mwh)
    cumulative = cumsum(order.p_max_mw)
    starts = vcat(0.0, cumulative[1:end-1])
    p = plot(
        xlabel="Cumulative summer capacity (MW)",
        ylabel="Variable cost (2024 USD/MWh)",
        legend=false,
        size=(1050, 560),
        ylims=(0, maximum(order.varcost_usd_per_mwh) * 1.12),
        left_margin=15mm,
        bottom_margin=8mm,
    )
    colors = Dict(
        "Municipal solid waste" => "#2a9d8f",
        "LSFO" => "#ef8354",
        "Diesel" => "#9c6644",
        "ULSD_CIP" => "#6d597a",
        "ULSD_SGS" => "#457b9d",
    )
    for index in 1:nrow(order)
        shape = Shape(
            [starts[index], cumulative[index], cumulative[index], starts[index]],
            [0, 0, order.varcost_usd_per_mwh[index], order.varcost_usd_per_mwh[index]],
        )
        plot!(p, shape; color=get(colors, order.fuel[index], "#999999"), linecolor=:white, alpha=0.9)
    end
    savefig(p, joinpath(FIGURES, "oahu_merit_order.png"))

    categories = ["Hydro", "Biomass", "Natural-gas CCGT", "Natural-gas CT", "Oahu firm fleet"]
    lows = [0.0, 5.0, 22.0, 38.0, minimum(order.varcost_usd_per_mwh)]
    highs = [0.0, 5.0, 36.0, 46.0, maximum(order.varcost_usd_per_mwh)]
    p_compare = plot(
        xlabel="Variable-cost span (USD/MWh)",
        yticks=(1:5, categories),
        xlims=(-5, maximum(highs) * 1.08),
        legend=false,
        size=(1000, 500),
        left_margin=25mm,
        bottom_margin=10mm,
    )
    for i in eachindex(categories)
        plot!(p_compare, [lows[i], highs[i]], [i, i]; linewidth=12, color=i == 5 ? "#ef8354" : "#457b9d")
        scatter!(p_compare, [lows[i], highs[i]], [i, i]; markersize=5, color=i == 5 ? "#ef8354" : "#457b9d")
    end
    savefig(p_compare, joinpath(FIGURES, "textbook_vs_oahu_cost_span.png"))
end


function make_duck_curve_figure(load::DataFrame)
    spread = load.gross_load_mw .- load.net_load_mw
    day = cld(argmax(spread), 24)
    start_index = (day - 1) * 24 + 1
    selected = load[start_index:(start_index + 23), :]
    p = plot(
        1:24,
        selected.gross_load_mw;
        label="Gross load before DER/EE",
        color="#264653",
        linewidth=3,
        xlabel="Hour of day",
        ylabel="Power (MW)",
        xticks=1:2:24,
        size=(1000, 540),
        bottom_margin=10mm,
    )
    plot!(p, 1:24, selected.net_load_mw; label="Net load", color="#ef8354", linewidth=3)
    fill_between = Shape(
        vcat(collect(1:24), collect(24:-1:1)),
        vcat(selected.gross_load_mw, reverse(selected.net_load_mw)),
    )
    plot!(p, fill_between; color="#e9c46a", alpha=0.22, label="DER + efficiency effect")
    savefig(p, joinpath(FIGURES, "oahu_duck_curve.png"))
    return day
end


function make_emissions_figure(single::DataFrame)
    grouped = transform(single, :name => ByRow(fleet_group) => :group)
    grouped = combine(groupby(grouped, :group), :emissions_kg_co2 => sum => :emissions_kg_co2)
    grouped.emissions_tonnes_co2 = grouped.emissions_kg_co2 ./ 1000
    sort!(grouped, :emissions_tonnes_co2)
    positions = collect(1:nrow(grouped))
    p = plot(
        yticks=(positions, grouped.group),
        legend=false,
        xlabel="Peak-hour operational emissions (tonnes CO2)",
        xlims=(0, maximum(grouped.emissions_tonnes_co2) * 1.08),
        ylims=(0.5, nrow(grouped) + 0.5),
        size=(1000, 520),
        left_margin=20mm,
        bottom_margin=10mm,
    )
    for i in positions
        bar = Shape(
            [0, grouped.emissions_tonnes_co2[i], grouped.emissions_tonnes_co2[i], 0],
            [i - 0.3, i - 0.3, i + 0.3, i + 0.3],
        )
        plot!(p, bar; color="#ef8354", linecolor=:white, label="")
    end
    savefig(p, joinpath(FIGURES, "peak_hour_emissions.png"))
end


const MODE_COLOR = Dict(:copper => "#264653", :transport => "#2a9d8f", :dcopf => "#e76f51")
const MODE_LABEL = Dict(
    :copper => "Copper plate",
    :transport => "Transportation",
    :dcopf => "DC-OPF",
)


function make_network_map_figure(buses::DataFrame, branches::DataFrame, flows::DataFrame,
    generator_bus::DataFrame)
    coord = Dict(String(b.bus) => (b.longitude, b.latitude) for b in eachrow(buses))
    capacity = combine(groupby(generator_bus, :bus), :p_max_mw => sum => :cap)
    cap = Dict(String(r.bus) => r.cap for r in eachrow(capacity))
    flow = Dict(Int(f.branch) => f for f in eachrow(flows))

    p = plot(
        legend=false,
        xlabel="Longitude", ylabel="Latitude",
        size=(1100, 720),
        left_margin=8mm, bottom_margin=8mm,
        grid=false,
    )
    for branch in eachrow(branches)
        x1, y1 = coord[String(branch.from_bus)]
        x2, y2 = coord[String(branch.to_bus)]
        f = flow[Int(branch.branch)]
        loading = f.loading
        color = loading > 0.999 ? "#c1121f" : (loading > 0.75 ? "#f4a261" : "#9bb8c4")
        plot!(p, [x1, x2], [y1, y2]; color=color, linewidth=1.5 + 5 * loading, alpha=0.9)
        plot!(p, [x1, x2], [y1, y2]; color=color, linewidth=0, label="")
        midx, midy = (x1 + x2) / 2, (y1 + y2) / 2
        annotate!(p, midx, midy + 0.004,
            text("$(round(Int, abs(f.flow_mw)))/$(round(Int, f.limit_mw))", 7, "#40606e"))
    end
    for bus in eachrow(buses)
        x, y = coord[String(bus.bus)]
        generation = get(cap, String(bus.bus), 0.0)
        size_marker = 6 + 34 * bus.load_share
        scatter!(p, [x], [y];
            markersize=size_marker,
            color=generation > 0 ? "#ef8354" : "#457b9d",
            markerstrokecolor=:white, markerstrokewidth=1.5)
        label = generation > 0 ? "$(bus.bus)\n$(round(Int, generation)) MW" : String(bus.bus)
        annotate!(p, x, y - 0.012, text(label, 8, "#17324d"))
    end
    savefig(p, joinpath(FIGURES, "oahu_network_map.png"))
end


function make_cost_comparison_figure(costs)
    modes = [:copper, :transport, :dcopf]
    totals = [costs[m].total_cost_usd / 1000 for m in modes]
    positions = 1:length(modes)
    p = plot(
        xticks=(positions, [MODE_LABEL[m] for m in modes]),
        ylabel="Peak-hour cost (thousand USD/h)",
        legend=false,
        ylims=(0, maximum(totals) * 1.18),
        size=(1000, 600),
        bottom_margin=8mm, left_margin=10mm,
    )
    for (i, m) in enumerate(modes)
        bar = Shape([i - 0.32, i + 0.32, i + 0.32, i - 0.32],
            [0, 0, totals[i], totals[i]])
        plot!(p, bar; color=MODE_COLOR[m], linecolor=:white, label="")
        annotate!(p, i, totals[i] + maximum(totals) * 0.03,
            text("\$$(round(totals[i]; digits=1))k", 10, "#17324d"))
    end
    congestion = totals[2] - totals[1]
    loopflow = totals[3] - totals[2]
    annotate!(p, 1.5, maximum(totals) * 1.10,
        text("congestion +\$$(round(congestion * 1000; digits=0))", 9, "#2a9d8f"))
    annotate!(p, 2.5, maximum(totals) * 1.10,
        text("loop flow +\$$(round(loopflow * 1000; digits=0))", 9, "#e76f51"))
    savefig(p, joinpath(FIGURES, "network_cost_comparison.png"))
end


function make_lmp_figure(prices::DataFrame, island_lmp::Float64)
    lmp = sort(prices, :lmp_usd_per_mwh)
    positions = 1:nrow(lmp)
    p = plot(
        yticks=(positions, lmp.bus),
        xlabel="Locational marginal price (USD/MWh)",
        legend=:bottomright,
        xlims=(0, maximum(lmp.lmp_usd_per_mwh) * 1.12),
        ylims=(0.5, nrow(lmp) + 0.5),
        size=(1050, 620),
        left_margin=18mm, bottom_margin=8mm,
    )
    for i in positions
        generation = lmp.demand_mw[i] < 0.01
        bar = Shape([0, lmp.lmp_usd_per_mwh[i], lmp.lmp_usd_per_mwh[i], 0],
            [i - 0.32, i - 0.32, i + 0.32, i + 0.32])
        plot!(p, bar; color="#457b9d", linecolor=:white, label="")
    end
    vline!(p, [island_lmp]; color="#c1121f", linestyle=:dash, linewidth=2.5,
        label="Copper-plate λ = \$$(round(island_lmp; digits=0))")
    savefig(p, joinpath(FIGURES, "oahu_lmp_by_bus.png"))
end


function make_line_loading_figure(flows_24h::DataFrame)
    branches = sort(unique(flows_24h.branch))
    palette = ["#264653", "#2a9d8f", "#e9c46a", "#f4a261", "#e76f51", "#6d597a",
        "#457b9d", "#9c6644", "#1d3557", "#a8dadc"]
    p = plot(
        xlabel="Hour of peak-load day", ylabel="Line loading (|flow| / limit)",
        xticks=1:2:24, ylims=(0, 1.08),
        legend=:outerright,
        size=(1150, 620),
        right_margin=8mm, bottom_margin=8mm,
    )
    for (index, branch) in enumerate(branches)
        subset = sort(flows_24h[flows_24h.branch .== branch, :], :window_hour)
        label = "$(subset.from_bus[1])→$(subset.to_bus[1])"
        plot!(p, subset.window_hour, subset.loading;
            label=label, linewidth=2.2, color=palette[mod1(index, length(palette))])
    end
    hline!(p, [1.0]; color="#c1121f", linestyle=:dash, linewidth=2, label="thermal limit")
    savefig(p, joinpath(FIGURES, "line_loading_peak_day.png"))
end


function make_congestion_sensitivity_figure(sweep::DataFrame, base_rating::Float64)
    sorted = sort(sweep, :rating_mw)
    # Once DC-OPF must shed load, its "cost" is dominated by the value-of-lost-load penalty,
    # a delivery-failure regime rather than a redispatch cost. Plot the cost curves only where
    # the system is fully served, and mark the shedding onset as a boundary instead.
    served = sorted[sorted.unserved_mwh .<= 1e-3, :]
    shed = sorted[sorted.unserved_mwh .> 1e-3, :]
    ymax = maximum(served.total_gap_usd) * 1.15
    p = plot(
        xlabel="Kahe->Waianae north-corridor rating (MW)",
        ylabel="Peak-hour cost above copper plate (USD)",
        legend=:topright,
        ylims=(0, ymax),
        size=(1080, 620),
        left_margin=14mm, bottom_margin=8mm,
    )
    plot!(p, served.rating_mw, served.congestion_usd;
        label="Congestion (transport - copper)", color="#2a9d8f", linewidth=3, marker=:circle)
    plot!(p, served.rating_mw, served.total_gap_usd;
        label="Congestion + loop flow (DC-OPF - copper)", color="#e76f51", linewidth=3,
        marker=:circle)
    if nrow(shed) > 0
        onset = maximum(shed.rating_mw)
        vline!(p, [onset]; color="#c1121f", linestyle=:dash, linewidth=2,
            label="DC-OPF sheds load below $(round(Int, onset)) MW")
    end
    vline!(p, [base_rating]; color="#457b9d", linestyle=:dot, linewidth=2,
        label="Base rating = $(round(Int, base_rating)) MW")
    savefig(p, joinpath(FIGURES, "congestion_sensitivity.png"))
end


function run_congestion_sweep(fleet, buses, branches, generator_bus, peak_demand, peak_hour)
    line = (from="Kahe", to="Waianae")
    idx = findfirst((branches.from_bus .== line.from) .& (branches.to_bus .== line.to))
    base_rating = Float64(branches.limit_mw[idx])
    copper = solve_network_dispatch(fleet, buses, branches, generator_bus, [peak_demand];
        mode=:copper, start_hour=peak_hour)
    ratings = Float64[400, 350, 300, 250, 200, 180, 160, 140, 120, 100]
    rows = DataFrame(rating_mw=Float64[], congestion_usd=Float64[], loopflow_usd=Float64[],
        total_gap_usd=Float64[], unserved_mwh=Float64[])
    for rating in ratings
        scenario = copy(branches)
        scenario.limit_mw[idx] = rating
        transport = solve_network_dispatch(fleet, buses, scenario, generator_bus, [peak_demand];
            mode=:transport, start_hour=peak_hour)
        dcopf = solve_network_dispatch(fleet, buses, scenario, generator_bus, [peak_demand];
            mode=:dcopf, start_hour=peak_hour)
        push!(rows, (
            rating,
            transport.total_cost_usd - copper.total_cost_usd,
            dcopf.total_cost_usd - transport.total_cost_usd,
            dcopf.total_cost_usd - copper.total_cost_usd,
            dcopf.unserved_mwh,
        ))
    end
    return rows, base_rating
end


function run_network_analysis(fleet, load, peak_row, peak_hour, peak_day_start, demand_24h)
    buses, branches, generator_bus = load_network(ROOT)
    peak_demand = load.net_load_mw[peak_row]

    single = Dict(m => solve_network_dispatch(fleet, buses, branches, generator_bus,
        [peak_demand]; mode=m, start_hour=peak_hour) for m in NetworkDispatch.MODES)
    multi = Dict(m => solve_network_dispatch(fleet, buses, branches, generator_bus,
        demand_24h; mode=m, start_hour=peak_day_start) for m in NetworkDispatch.MODES)

    # The feasible sets nest, so minimized cost must be non-decreasing across the three modes.
    # This theoretical result is the strongest end-to-end regression test on the formulation.
    for scenario in (single, multi)
        @assert scenario[:copper].total_cost_usd <= scenario[:transport].total_cost_usd + 1e-3 &&
                scenario[:transport].total_cost_usd <= scenario[:dcopf].total_cost_usd + 1e-3 (
            "cost ordering copper <= transport <= dcopf violated"
        )
    end

    CSV.write(joinpath(PROCESSED, "network_dispatch_single.csv"), single[:dcopf].dispatch)
    CSV.write(joinpath(PROCESSED, "network_dispatch_multi.csv"), multi[:dcopf].dispatch)
    CSV.write(joinpath(PROCESSED, "network_flows_single.csv"), single[:dcopf].flows)
    CSV.write(joinpath(PROCESSED, "network_flows_multi.csv"), multi[:dcopf].flows)
    CSV.write(joinpath(PROCESSED, "network_lmps.csv"), single[:dcopf].prices)

    cost_rows = DataFrame(
        mode=String[], total_cost_usd=Float64[], generation_cost_usd=Float64[],
        transport_cost_usd=Float64[], unserved_mwh=Float64[],
    )
    for m in NetworkDispatch.MODES
        push!(cost_rows, (String(m), single[m].total_cost_usd, single[m].generation_cost_usd,
            single[m].transport_cost_usd, single[m].unserved_mwh))
    end
    CSV.write(joinpath(PROCESSED, "network_cost_comparison.csv"), cost_rows)

    sweep, base_rating = run_congestion_sweep(fleet, buses, branches, generator_bus,
        peak_demand, peak_hour)
    CSV.write(joinpath(PROCESSED, "network_congestion_sweep.csv"), sweep)

    island_lmp = single[:copper].prices.lmp_usd_per_mwh[1]
    make_network_map_figure(buses, branches, single[:dcopf].flows, generator_bus)
    make_cost_comparison_figure(single)
    make_lmp_figure(single[:dcopf].prices, island_lmp)
    make_line_loading_figure(multi[:dcopf].flows)
    make_congestion_sensitivity_figure(sweep, base_rating)

    binding = single[:dcopf].flows[single[:dcopf].flows.loading .> 0.999, :]
    highest = single[:dcopf].prices[argmax(single[:dcopf].prices.lmp_usd_per_mwh), :]

    return (
        buses=buses, branches=branches,
        congestion_cost_usd=single[:transport].total_cost_usd - single[:copper].total_cost_usd,
        loopflow_cost_usd=single[:dcopf].total_cost_usd - single[:transport].total_cost_usd,
        dcopf_total_cost_usd=single[:dcopf].total_cost_usd,
        dcopf_day_cost_usd=multi[:dcopf].total_cost_usd,
        island_lmp=island_lmp,
        lmp_min=minimum(single[:dcopf].prices.lmp_usd_per_mwh),
        lmp_max=maximum(single[:dcopf].prices.lmp_usd_per_mwh),
        binding_branch=nrow(binding) > 0 ? "$(binding.from_bus[1])→$(binding.to_bus[1])" : "none",
        highest_lmp_bus=String(highest.bus),
        peak_unserved_mwh=single[:dcopf].unserved_mwh,
    )
end


function main()
    fleet, load = load_inputs(ROOT)
    peak_row = argmax(load.net_load_mw)
    peak_hour = Int(load.hour[peak_row])
    peak_day_start = ((peak_hour - 1) ÷ 24) * 24 + 1
    demand_24h = load.net_load_mw[peak_day_start:(peak_day_start + 23)]

    single = solve_single_period(fleet, load.net_load_mw[peak_row]; hour=peak_hour)
    multi = solve_multi_period(fleet, demand_24h; start_hour=peak_day_start)

    CSV.write(joinpath(PROCESSED, "single_period_dispatch.csv"), single.dispatch)
    CSV.write(joinpath(PROCESSED, "multi_period_dispatch.csv"), multi.dispatch)

    network = run_network_analysis(fleet, load, peak_row, peak_hour, peak_day_start, demand_24h)

    duck_curve_day = make_duck_curve_figure(load)
    make_single_period_figure(single.dispatch)
    make_multi_period_figures(multi.dispatch)
    make_merit_order_figure(fleet)
    make_emissions_figure(single.dispatch)

    summary = DataFrame(
        metric=[
            "annual_net_peak_hour",
            "annual_net_peak_mw",
            "peak_hour_dispatch_cost_usd",
            "peak_hour_marginal_cost_usd_per_mwh",
            "peak_hour_emissions_tonnes_co2",
            "peak_day_dispatch_cost_usd",
            "peak_day_emissions_tonnes_co2",
            "marginal_generator",
            "strongest_duck_curve_day_of_year",
            "fleet_summer_capacity_mw",
            "network_congestion_cost_usd_per_hr",
            "network_loopflow_cost_usd_per_hr",
            "network_dcopf_peak_hour_cost_usd",
            "network_dcopf_peak_day_cost_usd",
            "network_binding_branch_peak",
            "network_highest_lmp_bus",
            "network_lmp_span_usd_per_mwh",
            "network_peak_unserved_mwh",
        ],
        value=string.([
            peak_hour,
            round(load.net_load_mw[peak_row]; digits=3),
            round(single.total_cost_usd_per_hr; digits=2),
            round(single.marginal_cost_usd_per_mwh; digits=3),
            round(single.total_emissions_kg_co2 / 1000; digits=3),
            round(multi.total_cost_usd; digits=2),
            round(multi.total_emissions_kg_co2 / 1000; digits=3),
            single.marginal_generator,
            duck_curve_day,
            round(sum(fleet.p_max_mw); digits=1),
            round(network.congestion_cost_usd; digits=2),
            round(network.loopflow_cost_usd; digits=2),
            round(network.dcopf_total_cost_usd; digits=2),
            round(network.dcopf_day_cost_usd; digits=2),
            network.binding_branch,
            network.highest_lmp_bus,
            "$(round(network.lmp_min; digits=1))–$(round(network.lmp_max; digits=1))",
            round(network.peak_unserved_mwh; digits=4),
        ]),
    )
    CSV.write(joinpath(PROCESSED, "analysis_summary.csv"), summary)

    println("Single-period and 24-hour models solved to optimality.")
    println("Peak net load: $(round(load.net_load_mw[peak_row]; digits=1)) MW at hour $peak_hour.")
    println("Marginal generator: $(single.marginal_generator).")
    println("Network: congestion \$$(round(network.congestion_cost_usd; digits=0))/h, " *
            "loop flow \$$(round(network.loopflow_cost_usd; digits=0))/h; " *
            "binding $(network.binding_branch); LMP span " *
            "\$$(round(network.lmp_min; digits=0))–\$$(round(network.lmp_max; digits=0)).")
end


main()
