#=
Q1 -- "Do we have usage statistics for a real power network? (Hawaii)"

ANSWER: YES. And they were already in this repository.

This script does not invent anything. It audits what the project's earlier
Hawaii work already assembled from primary filings, states the numbers Q2 and
Q3 will need, and produces the one chart that turns out to matter most for the
rest of Set 8: what the REAL demand distribution actually looks like next to
the exponential the assignment asks us to assume.

WHAT WE HAVE, AND WHERE IT CAME FROM
------------------------------------
  8,760 hourly load observations  Hawaiian Electric, Final Oʻahu Inputs
                                  Workbook 3 (filed 2022-03-31), 2021 base
                                  scenario, reconstructed by scripts/prepare_load.py
  24 dispatchable generators      EIA Form 860 (2024 final) summer capacity,
                                  EIA Form 923 (2024 final) implied heat rates,
                                  HECO 2024 base fuel-price forecast
  9-bus network                   Census 2020 judicial districts; 138 kV
                                  two-corridor ring per Hawaiian Electric's
                                  published Power Delivery description
  10 branches                     200 MW per 138 kV circuit, 1-3 circuits each

Full provenance, checksums and caveats live in the repo's SOURCES.md and
DATA_SOURCES.md. This is a research model, not Hawaiian Electric's own
operational case: the topology is stylised and bus loads are allocated by
resident population.

THE FINDING THAT DRIVES SET 8
-----------------------------
Real Oʻahu net load has a coefficient of variation of 0.168. The Exp(1)
distribution the assignment specifies has a coefficient of variation of 1.000.
The assumed demand is roughly SIX TIMES more volatile than the island really
is. Every risk number in Q2 and Q3 has to be read against that fact, which is
why Q3 runs the empirical distribution alongside the exponential.

Run:  julia "Q1 - hawaii data.jl"
=#

using CSV, DataFrames, Statistics, Printf, Plots
gr()

const HERE = @__DIR__
include(joinpath(HERE, "cases.jl"))
include(joinpath(HERE, "theme.jl"))
setup_theme!()
mkpath(joinpath(HERE, "figures")); mkpath(joinpath(HERE, "results"))

println("\n" * "="^78)
println(" Q1 -- REAL POWER NETWORK DATA: OʻAHU, HAWAIʻI")
println("="^78)

# ---------------------------------------------------------------------------
# 1. The load record
# ---------------------------------------------------------------------------
load  = CSV.read(joinpath(PROCESSED, "oahu_load_8760.csv"), DataFrame)
net   = Float64.(load.net_load_mw)
gross = Float64.(load.gross_load_mw)

@printf("\n LOAD RECORD  (Hawaiian Electric IGP Workbook 3, 2021 base scenario)\n")
@printf("   observations      : %d hourly values\n", length(net))
@printf("   net load  mean    : %.2f MW\n", mean(net))
@printf("             median  : %.2f MW\n", median(net))
@printf("             sd      : %.2f MW\n", std(net))
@printf("             CV      : %.4f   <-- compare Exp(1), whose CV is 1.0000\n",
        std(net) / mean(net))
@printf("             min     : %.2f MW  (hour %d)\n", minimum(net), argmin(net))
@printf("             max     : %.2f MW  (hour %d)\n", maximum(net), argmax(net))
@printf("   load factor       : %.3f   (mean / peak)\n", mean(net) / maximum(net))
@printf("   gross load mean   : %.2f MW   (before DGPV, storage, efficiency)\n",
        mean(gross))

# ---------------------------------------------------------------------------
# 2. The fleet
# ---------------------------------------------------------------------------
gendf = CSV.read(joinpath(PROCESSED, "oahu_generators.csv"), DataFrame)
mapdf = CSV.read(joinpath(PROCESSED, "oahu_generator_bus_map.csv"), DataFrame)
gcap  = sum(gendf.p_max_mw)

@printf("\n GENERATION FLEET  (EIA-860 / EIA-923, 2024 final)\n")
@printf("   dispatchable units: %d\n", nrow(gendf))
@printf("   installed capacity: %.1f MW\n", gcap)
@printf("   cheapest unit     : %s at \$%.2f/MWh\n",
        gendf.name[argmin(gendf.varcost_usd_per_mwh)], minimum(gendf.varcost_usd_per_mwh))
@printf("   costliest unit    : %s at \$%.2f/MWh\n",
        gendf.name[argmax(gendf.varcost_usd_per_mwh)], maximum(gendf.varcost_usd_per_mwh))
@printf("   reserve margin    : %.1f%% over mean load, %.1f%% over peak load\n",
        100 * (gcap - mean(net)) / mean(net), 100 * (gcap - maximum(net)) / maximum(net))

# merit order: sort by cost, accumulate capacity
mo = sort(gendf, :varcost_usd_per_mwh)
mo.cum_mw = cumsum(mo.p_max_mw)
println("\n MERIT ORDER (cheapest first) -- the stack demand climbs as it grows")
@printf("   %-32s %10s %10s %12s\n", "unit", "MW", "cum MW", "USD/MWh")
for r in eachrow(mo)
    @printf("   %-32s %10.1f %10.1f %12.2f\n",
            first(r.name, 32), r.p_max_mw, r.cum_mw, r.varcost_usd_per_mwh)
end
# where does mean and peak load land in that stack?
mean_marg = mo.varcost_usd_per_mwh[findfirst(>=(mean(net)), mo.cum_mw)]
peak_marg = mo.varcost_usd_per_mwh[findfirst(>=(maximum(net)), mo.cum_mw)]
@printf("\n   mean load %.0f MW is served up to \$%.2f/MWh\n", mean(net), mean_marg)
@printf("   peak load %.0f MW is served up to \$%.2f/MWh\n", maximum(net), peak_marg)

# ---------------------------------------------------------------------------
# 3. The network
# ---------------------------------------------------------------------------
busdf = CSV.read(joinpath(PROCESSED, "oahu_network_buses.csv"), DataFrame)
brdf  = CSV.read(joinpath(PROCESSED, "oahu_network_branches.csv"), DataFrame)

@printf("\n NETWORK  (Census 2020 districts; HECO two-corridor 138 kV ring)\n")
@printf("   buses   : %d\n", nrow(busdf))
@printf("   branches: %d   (%d independent loops)\n",
        nrow(brdf), nrow(brdf) - nrow(busdf) + 1)
@printf("   total transfer capability: %.0f MW across %d circuits\n",
        sum(brdf.limit_mw), sum(brdf.circuits))
println("\n   load concentration -- this is what makes Oʻahu's risk profile unusual:")
sh = sort(busdf, :load_share, rev = true)
sh.cum_share = cumsum(sh.load_share)
for r in eachrow(sh)
    r.load_share > 0 &&
        @printf("     %-14s %6.2f%% of island load   (cumulative %5.1f%%)\n",
                r.bus, 100r.load_share, 100r.cum_share)
end
top2 = sum(sort(busdf.load_share, rev = true)[1:2])
@printf("\n   the top two buses carry %.1f%% of the island.\n", 100top2)
@printf("   with independent Exp(1) draws the system CV is %.4f, not 1.0 --\n",
        sqrt(sum(busdf.load_share .^ 2)))
println("   independent nodes cancel each other out, but concentrated load cancels less.")

# ---------------------------------------------------------------------------
# 4. THE CHART THAT MATTERS: real load vs the assumed exponential
# ---------------------------------------------------------------------------
# Both curves are scaled to the SAME mean, so the only thing being compared is
# shape. The exponential's mode sits at zero and its tail runs to four times the
# mean; the real island never leaves a band roughly 0.6x-1.4x its own average.
mu = mean(net)
xs = range(0, 4mu; length = 400)
exp_pdf = (1 / mu) .* exp.(-xs ./ mu)

p1 = histogram(net; bins = 60, normalize = :pdf,
               color = C1, linecolor = SURFACE, linewidth = 0.6, alpha = 0.85,
               label = "real Oʻahu net load (8,760 h)",
               xlabel = "system load (MW)", ylabel = "density",
               title = "What the island actually does, vs what Exp(1) assumes",
               legend = :topright, xlims = (0, 4mu))
plot!(p1, xs, exp_pdf; lw = 3, color = C2,
      label = "Exp(1) scaled to the same mean")
vline!(p1, [mu]; lw = 2, ls = :dash, color = INK_2, label = "shared mean, 744 MW")
annotate!(p1, 2.55mu, 0.72 * maximum(exp_pdf),
          text("real CV = 0.168\nExp(1) CV = 1.000", 11, INK, :left))

# load duration curve -- the operator's own view of the same data
srt = sort(net, rev = true)
p2 = plot(100 .* (1:length(srt)) ./ length(srt), srt;
          lw = 3, color = C1, label = "",
          xlabel = "% of hours at or above", ylabel = "net load (MW)",
          title = "Load duration curve: the island lives in a narrow band",
          ylims = (0, 1.10 * maximum(net)))
hline!(p2, [maximum(net)]; lw = 2, ls = :dash, color = S_CRIT,
       label = @sprintf("peak %.0f MW", maximum(net)))
hline!(p2, [mu]; lw = 2, ls = :dash, color = INK_2,
       label = @sprintf("mean %.0f MW", mu))
hline!(p2, [minimum(net)]; lw = 2, ls = :dot, color = S_GOOD,
       label = @sprintf("floor %.0f MW", minimum(net)))

savefig(plot(p1, p2; layout = (1, 2), size = (1500, 620)),
        joinpath(HERE, "figures", "q1_load_distribution.png"))
println("\n figure -> figures/q1_load_distribution.png")

# ---------------------------------------------------------------------------
# 5. Merit-order chart
# ---------------------------------------------------------------------------
# A step function: cumulative capacity on x, marginal cost on y. Where demand
# lands on this staircase IS the system marginal price, so the two vertical
# lines show what an average hour and the annual peak actually cost to serve.
step_x = Float64[0.0]; step_y = Float64[mo.varcost_usd_per_mwh[1]]
for r in eachrow(mo)
    push!(step_x, r.cum_mw); push!(step_y, r.varcost_usd_per_mwh)
    push!(step_x, r.cum_mw); push!(step_y, r.varcost_usd_per_mwh)
end
pop!(step_x); pop!(step_y)

p3 = plot(step_x, step_y; lw = 3, color = C1, label = "marginal cost stack",
          xlabel = "cumulative capacity (MW)", ylabel = "marginal cost (USD/MWh)",
          title = "Oʻahu merit order: where demand lands sets the price",
          legend = :topleft, ylims = (0, 260), size = (1300, 620))
vline!(p3, [mu]; lw = 2.5, ls = :dash, color = INK_2,
       label = @sprintf("mean load %.0f MW  ->  \$%.0f/MWh", mu, mean_marg))
vline!(p3, [maximum(net)]; lw = 2.5, ls = :dash, color = S_CRIT,
       label = @sprintf("peak load %.0f MW  ->  \$%.0f/MWh", maximum(net), peak_marg))
annotate!(p3, 60, 30, text("H-POWER\nwaste", 9, INK_2, :left))
annotate!(p3, 340, 112, text("Kahe LSFO steam", 9, INK_2, :left))
annotate!(p3, 1180, 212, text("diesel peakers\n(the expensive tail)", 9, S_CRIT, :left))
savefig(p3, joinpath(HERE, "figures", "q1_merit_order.png"))
println(" figure -> figures/q1_merit_order.png")

# ---------------------------------------------------------------------------
# 6. Export the calibration constants Q2 and Q3 both need
# ---------------------------------------------------------------------------
calib = DataFrame(
    quantity = ["oahu_mean_net_load_mw", "oahu_peak_net_load_mw",
                "oahu_min_net_load_mw", "oahu_load_cv", "oahu_load_factor",
                "oahu_capacity_mw", "oahu_utilisation",
                "oahu_n_buses", "oahu_n_branches", "oahu_n_generators",
                "oahu_top2_load_share", "oahu_exp_system_cv",
                "ieee14_capacity_mw", "ieee14_native_load_mw",
                "ieee14_calibrated_mean_mw"],
    value = [mean(net), maximum(net), minimum(net), std(net)/mean(net),
             mean(net)/maximum(net), gcap, mean(net)/gcap,
             nrow(busdf), nrow(brdf), nrow(gendf),
             top2, sqrt(sum(busdf.load_share .^ 2)),
             772.4, 259.0, (mean(net)/gcap) * 772.4],
    source = ["HECO IGP Workbook 3 via prepare_load.py", "same", "same", "same", "same",
              "EIA-860 2024 summer capacity", "derived",
              "Census 2020 districts", "HECO Power Delivery", "EIA-860 2024",
              "Census 2020 population shares", "analytic: sqrt(sum share^2)",
              "MATPOWER case14", "MATPOWER case14",
              "case14 capacity x Oʻahu utilisation"])
CSV.write(joinpath(HERE, "results", "q1_calibration.csv"), calib)
println(" table  -> results/q1_calibration.csv")

println("\n" * "="^78)
println(" Q1 ANSWER: YES -- 8,760 hours of filed Oʻahu load, a 24-unit fleet with")
println(" sourced costs, and a 9-bus network. Mean 743.86 MW, CV 0.168.")
println(" The exponential Q2 asks for is ~6x more volatile than the real island.")
println("="^78)
