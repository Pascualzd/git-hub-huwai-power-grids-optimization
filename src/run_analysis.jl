ENV["GKSwstype"] = "100"

using CSV
using DataFrames
using Measures
using Plots
using Statistics

include(joinpath(@__DIR__, "EconomicDispatch.jl"))
using .EconomicDispatch

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
        ]),
    )
    CSV.write(joinpath(PROCESSED, "analysis_summary.csv"), summary)

    println("Single-period and 24-hour models solved to optimality.")
    println("Peak net load: $(round(load.net_load_mw[peak_row]; digits=1)) MW at hour $peak_hour.")
    println("Marginal generator: $(single.marginal_generator).")
end


main()
