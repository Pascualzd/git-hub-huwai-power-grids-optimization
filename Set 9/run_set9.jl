# =====================================================================
# Set 9 -- run_set9.jl
#
# Set 9 does NOT reuse Set 8's numbers. It runs its own simulations,
# because the model has changed and results from a different model are
# not comparable. Everything below is generated fresh.
#
# THE DESIGN
#
# Two demand worlds, each an 8,760-hour sequence walked in real order:
#
#   REAL   the filed 2021 planning profile for the island total, split
#          across buses by `case.share` -- the SECTOR-WEIGHTED v2 shares,
#          which are what `oahu_set9()` now returns by default. Those
#          shares are still FROZEN, so in this script the demand DIRECTION
#          does not move. `run_hourly.jl` is the script that relaxes that,
#          using the v3 hourly matrix.
#
#   EXPO   D[i,t] = mu_i * E, with E ~ Exp(1) drawn independently for every
#          bus and every hour. mu_i is scaled so the island mean matches
#          the REAL record's mean exactly. Same mean, different shape --
#          which is the only comparison being made.
#
# crossed with a ladder that adds one constraint at a time:
#
#   :lp    0 <= P <= pmax                          (what Set 8 could express)
#   :pmin  + minimum stable generation
#   :ramp  + hour-to-hour ramp limits
#   :full  + minimum up/down times and start-up costs
#
# WHY THE CHRONOLOGY MATTERS FOR THE EXPONENTIAL CASE
# Set 8 drew hours independently and never placed them in an order, so a
# ramp constraint had nothing to attach to. Here the exponential draws are
# laid out as a sequence, which makes a question askable that Set 8 could
# not ask: never mind whether the fleet has enough capacity -- can it
# physically FOLLOW this demand hour to hour?
#
#   julia --project=. "Set 9/run_set9.jl"        # full year
#   julia --project=. "Set 9/run_set9.jl" 20     # first 20 days (quick)
# =====================================================================

using Printf, Statistics, Random, CSV, DataFrames

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const DAYS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 365
const SEED = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1
const OUT  = joinpath(@__DIR__, "results"); mkpath(OUT)

case = oahu_set9()
load = oahu_net_load()
nH   = DAYS * 24

"""
Real world: the filed island total, split by `case.share` -- the sector-
weighted v2 shares by default, population shares under
`oahu_set9(shares = :v1)`. Frozen either way, so the direction does not move.
"""
real_demand(case, load, nH) = [case.share[i] * load[t] for i in 1:case.nbus, t in 1:nH]

"""
Exponential world, calibrated to the real record's own mean.

mu_i = share_i * mean(real load), then D[i,t] = mu_i * Exp(1). Each bus and
each hour is independent, so magnitude and direction both move -- exactly
the assumption Set 8 tested, now laid out in time.
"""
function expo_demand(case, load, nH; seed = 1)
    rng = MersenneTwister(seed)
    mu  = case.share .* mean(load)
    [mu[i] * (-log(1 - rand(rng))) for i in 1:case.nbus, t in 1:nH]
end

D_real = real_demand(case, load, nH)
D_expo = expo_demand(case, load, nH; seed = SEED)

tot_real = vec(sum(D_real, dims = 1))
tot_expo = vec(sum(D_expo, dims = 1))
swing(x) = mean(abs.(diff(x)))

println("="^74)
println("SET 9 -- chronological dispatch under generator operating constraints")
println("="^74)
@printf("units %d | capacity %.1f MW | sum of minimum stable outputs %.1f MW\n",
        length(case.pmax), sum(case.pmax), sum(case.pmin))
@printf("horizon %d days = %d hours, solved in 24-hour blocks, seed %d\n\n", DAYS, nH, SEED)
@printf("%-6s %9s %9s %9s %9s %14s\n", "world", "mean", "min", "max", "CV", "mean |hr swing|")
@printf("%-6s %8.1f %8.1f %8.1f %8.3f %13.1f MW\n", "REAL",
        mean(tot_real), minimum(tot_real), maximum(tot_real),
        std(tot_real)/mean(tot_real), swing(tot_real))
@printf("%-6s %8.1f %8.1f %8.1f %8.3f %13.1f MW\n", "EXPO",
        mean(tot_expo), minimum(tot_expo), maximum(tot_expo),
        std(tot_expo)/mean(tot_expo), swing(tot_expo))
println("\n(means agree by construction; everything else is the shape of the assumption)\n")

const LADDER = [(:lp,   "Set 8 constraint set"),
                (:pmin, "+ minimum stable generation"),
                (:ramp, "+ ramp limits"),
                (:full, "+ min up/down and start-up costs")]

rows = DataFrame(world=String[], rung=String[], constraint=String[],
                 cost_musd=Float64[], p_shed=Float64[], ens_mwh=Float64[],
                 p_at_limit=Float64[], p_expensive=Float64[],
                 mean_units_on=Float64[], startups=Int[], solve_s=Float64[],
                 blocks_time_capped=Int[])
traces = Dict{Tuple{String,Symbol},Any}()

for (world, D) in (("REAL", D_real), ("EXPO", D_expo))
    for (lv, label) in LADDER
        print("  $world / $lv ... "); flush(stdout)
        t0 = time()
        r  = run_year(case, D, lv; days = DAYS, verbose = false)
        dt = time() - t0
        traces[(world, lv)] = r
        push!(rows, (world, string(lv), label,
            sum(r.cost)/1e6,
            100*count(>(1e-4), r.shed)/r.hours,
            sum(r.shed),
            100*count(>(0), r.at_limit)/r.hours,
            100*count(r.expensive_on)/r.hours,
            mean(r.n_on), sum(r.starts), dt, r.ncapped))
        @printf("%.0fs  shed %.2f%%  atlimit %.2f%%  cost %.2f M  [capped %d/%d]\n",
                dt, 100*count(>(1e-4), r.shed)/r.hours,
                100*count(>(0), r.at_limit)/r.hours, sum(r.cost)/1e6,
                r.ncapped, DAYS)
        flush(stdout)
    end
end

println("\n" * "="^74)
println("SET 9 RESULTS -- all generated by Set 9, none carried over from Set 8")
println("="^74)
show(rows, allrows = true, allcols = true); println("\n")
CSV.write(joinpath(OUT, "set9_results.csv"), rows)

# ---------------------------------------------------------------------
# The question Set 8 could not ask
# ---------------------------------------------------------------------
println("="^74)
println("CAN THE FLEET FOLLOW THE DEMAND? (effect of adding ramp limits alone)")
println("="^74)
for world in ("REAL", "EXPO")
    a = traces[(world, :pmin)]; b = traces[(world, :ramp)]
    @printf("%-5s  shedding %.2f%%  ->  %.2f%%   (%+.2f pp)   ENS %.0f -> %.0f MWh\n",
            world,
            100*count(>(1e-4), a.shed)/a.hours,
            100*count(>(1e-4), b.shed)/b.hours,
            100*(count(>(1e-4), b.shed) - count(>(1e-4), a.shed))/a.hours,
            sum(a.shed), sum(b.shed))
end
println()

# ---------------------------------------------------------------------
# Hour-of-day profile under the fully constrained real run
# ---------------------------------------------------------------------
full = traces[("REAL", :full)]
hod  = [(h-1) % 24 for h in 1:full.hours]
println("="^74)
println("REAL WORLD, FULLY CONSTRAINED -- by hour of day")
println("="^74)
@printf("%6s %11s %12s %11s %11s\n", "hour", "mean load", "units on", "mean cost", "at limit")
for h in 0:23
    k = findall(==(h), hod)
    @printf("%02d:00 %8.0f MW %11.2f %9.0f \$ %9.1f%%\n", h,
            mean(tot_real[k]), mean(full.n_on[k]), mean(full.cost[k]),
            100*count(>(0), full.at_limit[k])/length(k))
end
println()

for ((world, lv), r) in traces
    lv == :full || continue
    CSV.write(joinpath(OUT, "set9_hourly_$(lowercase(world)).csv"),
        DataFrame(hour = 1:r.hours,
                  demand_mw = (world == "REAL" ? tot_real : tot_expo)[1:r.hours],
                  generation_mw = r.gen, shed_mw = r.shed, cost_usd = r.cost,
                  lines_at_limit = r.at_limit, units_on = r.n_on,
                  startups = r.starts))
end
println("results written to $(OUT)")
