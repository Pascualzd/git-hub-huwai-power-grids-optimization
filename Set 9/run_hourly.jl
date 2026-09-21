# =====================================================================
# Set 9 -- run_hourly.jl
#
# Run the constraint ladder on the HOURLY per-bus demand, and compare it
# against the two fixed-share versions.
#
#   v1  population shares, frozen          (Set 8's assumption)
#   v2  sector-weighted shares, frozen     (prepare_demand.py)
#   v3  sector-resolved HOURLY demand      (prepare_hourly_demand.py)
#
# v1 and v2 are rank-one: the nine bus loads can only grow and shrink
# together. v3 separates offices, houses and industry, gives each its own
# daily shape and its own spatial footprint, and lets the island's demand
# vector actually rotate through the day.
#
# The island total is identical in all three. Only its distribution differs.
#
#   julia --project=. "Set 9/run_hourly.jl"       # full year
#   julia --project=. "Set 9/run_hourly.jl" 30    # first 30 days
# =====================================================================

using Printf, Statistics, LinearAlgebra, CSV, DataFrames

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const DAYS = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 365
const OUT  = joinpath(@__DIR__, "results"); mkpath(OUT)

load = oahu_net_load()
nH   = DAYS * 24

c1 = oahu_set9(shares = :v1)
c2 = oahu_set9(shares = :v2)
D1 = [c1.share[i] * load[t] for i in 1:c1.nbus, t in 1:nH]
D2 = [c2.share[i] * load[t] for i in 1:c2.nbus, t in 1:nH]
D3 = oahu_hourly_demand(c2)[:, 1:nH]

println("="^78)
println("SET 9 -- hourly per-bus demand vs frozen shares")
println("="^78)
for (tag, D) in (("v1", D1), ("v2", D2), ("v3", D3))
    tot = vec(sum(D, dims = 1))
    S   = D ./ max.(tot', 1e-9)
    sv  = svdvals(S)
    hon = S[1, :]
    @printf("%-4s  island total %.1f MW mean | share-matrix rank %d | Honolulu share %.1f%%-%.1f%%\n",
            tag, mean(tot), count(>(0.01 * sv[1]), sv), 100*minimum(hon), 100*maximum(hon))
end
println("\n(rank 1 means the demand direction cannot move at all)\n")

const LADDER = [(:lp, "Set 8 constraint set"), (:pmin, "+ min stable gen"),
                (:ramp, "+ ramp limits"),      (:full, "+ min up/down, start-ups")]

rows = DataFrame(demand=String[], rung=String[], cost_musd=Float64[],
                 p_shed=Float64[], ens_mwh=Float64[], p_at_limit=Float64[],
                 mean_lines_at_limit=Float64[], solve_s=Float64[])

for (tag, D) in (("v1", D1), ("v2", D2), ("v3", D3))
    for (lv, _) in LADDER
        print("  $tag / $lv ... "); flush(stdout)
        t0 = time(); r = run_year(c2, D, lv; days = DAYS, verbose = false); dt = time() - t0
        push!(rows, (tag, string(lv), sum(r.cost)/1e6,
                     100*count(>(1e-4), r.shed)/r.hours, sum(r.shed),
                     100*count(>(0), r.at_limit)/r.hours, mean(r.at_limit), dt))
        @printf("%.0fs  shed %.2f%%  atlimit %.2f%%  cost %.2f M\n", dt,
                100*count(>(1e-4), r.shed)/r.hours,
                100*count(>(0), r.at_limit)/r.hours, sum(r.cost)/1e6); flush(stdout)
    end
end

println("\n" * "="^78)
println("RESULT -- same island total every hour. Only the split across buses differs.")
println("="^78)
show(rows, allrows = true, allcols = true); println("\n")
CSV.write(joinpath(OUT, "set9_hourly_demand_comparison.csv"), rows)

for (lv, _) in LADDER
    g(t) = rows[(rows.demand .== t) .& (rows.rung .== string(lv)), :][1, :]
    a, b, c = g("v1"), g("v2"), g("v3")
    @printf("%-6s congestion %6.2f%% / %6.2f%% / %6.2f%%   shed %5.2f%% / %5.2f%% / %5.2f%%   (v1/v2/v3)\n",
            string(lv), a.p_at_limit, b.p_at_limit, c.p_at_limit,
            a.p_shed, b.p_shed, c.p_shed)
end
println("\nwritten to $(OUT)")
