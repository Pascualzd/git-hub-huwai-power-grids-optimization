# =====================================================================
# Set 9 -- compare_shares.jl
#
# Isolate ONE change: how island demand is split across buses.
#
#   v1  2020 resident population alone          (Set 8's assumption)
#   v2  EIA-861 sector weights on Census population + LODES workplace jobs
#
# Everything else is held fixed -- same network, same fleet, same 8,760
# real hours, same constraint ladder. So any movement below is caused by
# the allocation and nothing else.
#
#   julia --project=. "Set 9/compare_shares.jl"      # full year
#   julia --project=. "Set 9/compare_shares.jl" 30   # first 30 days
# =====================================================================

using Printf, Statistics, CSV, DataFrames

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const DAYS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 365
const OUT  = joinpath(@__DIR__, "results"); mkpath(OUT)

load = oahu_net_load()
nH   = DAYS * 24

c1 = oahu_set9(shares = :v1)
c2 = oahu_set9(shares = :v2)

println("="^76)
println("SET 9 -- effect of the per-bus load allocation, everything else held fixed")
println("="^76)
@printf("%-14s %10s %10s %10s\n", "bus", "v1 pop", "v2 rebuilt", "change")
println("-"^48)
for i in 1:c1.nbus
    @printf("%-14s %9.2f%% %9.2f%% %+9.2fpp\n", c1.bus_name[i],
            100*c1.share[i], 100*c2.share[i], 100*(c2.share[i]-c1.share[i]))
end
println()

const LADDER = [(:lp, "Set 8 constraint set"), (:pmin, "+ min stable gen"),
                (:ramp, "+ ramp limits"),      (:full, "+ min up/down, start-ups")]

rows = DataFrame(shares=String[], rung=String[], cost_musd=Float64[],
                 p_shed=Float64[], ens_mwh=Float64[], p_at_limit=Float64[],
                 mean_lines_at_limit=Float64[], solve_s=Float64[])

for (tag, case) in (("v1", c1), ("v2", c2))
    D = [case.share[i] * load[t] for i in 1:case.nbus, t in 1:nH]
    for (lv, label) in LADDER
        print("  $tag / $lv ... "); flush(stdout)
        t0 = time(); r = run_year(case, D, lv; days = DAYS, verbose = false); dt = time()-t0
        push!(rows, (tag, string(lv), sum(r.cost)/1e6,
                     100*count(>(1e-4), r.shed)/r.hours, sum(r.shed),
                     100*count(>(0), r.at_limit)/r.hours,
                     mean(r.at_limit), dt))
        @printf("%.0fs  shed %.2f%%  atlimit %.2f%%  cost %.2f M\n", dt,
                100*count(>(1e-4), r.shed)/r.hours,
                100*count(>(0), r.at_limit)/r.hours, sum(r.cost)/1e6)
        flush(stdout)
    end
end

println("\n" * "="^76)
println("RESULT -- same demand, same fleet, same hours. Only the split changed.")
println("="^76)
show(rows, allrows=true, allcols=true); println("\n")
CSV.write(joinpath(OUT, "set9_share_comparison.csv"), rows)

for (lv, _) in LADDER
    a = rows[(rows.shares .== "v1") .& (rows.rung .== string(lv)), :][1, :]
    b = rows[(rows.shares .== "v2") .& (rows.rung .== string(lv)), :][1, :]
    @printf("%-6s  congestion %6.2f%% -> %6.2f%%  (%+6.2f pp)   shed %5.2f%% -> %5.2f%%   cost %+.2f M\n",
            string(lv), a.p_at_limit, b.p_at_limit, b.p_at_limit - a.p_at_limit,
            a.p_shed, b.p_shed, b.cost_musd - a.cost_musd)
end
println("\nwritten to $(OUT)")
