# Checkpointed rerun of the run_set9.jl 2x4 grid (REAL and EXPO x four rungs).
#
# WHY THIS EXISTS. results/set9_results.csv was produced when oahu_set9()
# still returned v1 population shares; it now returns v2 sector-weighted
# shares, so that file no longer reproduces from this code. Both worlds are
# affected, because expo_demand scales case.share too.
#
# Same checkpointing as run_v3_calfix.jl: the cloud sandbox reclaims the
# container on idle, so state and running totals are written every CHUNK days
# and a restart resumes instead of redoing the cell. EXPO/:full alone took
# nearly 40 minutes on the previous run.
using Printf, Statistics, Random, CSV, DataFrames, JSON3

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const OUT   = joinpath(@__DIR__, "results"); mkpath(OUT)
const PART  = joinpath(OUT, "set9_results_partial.csv")
const CHUNK = 20
const SEED  = 1

function run_ckpt(case, demand, level, tag; block = 24, days = 365)
    ck = joinpath(OUT, "ckpt_$(tag)_$(level).json")
    G  = length(case.pmax)
    nH = min(days * block, size(demand, 2)); nblocks = nH ÷ block
    if isfile(ck)
        s  = JSON3.read(read(ck, String)); b0 = s.next_block
        u0, p0 = Vector{Int}(s.u0), Vector{Float64}(s.p0)
        up0, down0 = Vector{Int}(s.up0), Vector{Int}(s.down0)
        acc = Dict(:cost=>Float64(s.cost), :shed_h=>Int(s.shed_h), :ens=>Float64(s.ens),
                   :atl_h=>Int(s.atl_h), :atl_sum=>Float64(s.atl_sum), :hours=>Int(s.hours),
                   :nfail=>Int(s.nfail), :ncap=>Int(s.ncap), :starts=>Int(s.starts))
        @printf("    resuming %s/%s at day %d / %d\n", tag, level, b0, nblocks); flush(stdout)
    else
        b0    = 1
        u0    = [case.gen_tech[g] == "municipal_waste" ? 1 : 0 for g in 1:G]
        p0    = [u0[g] == 1 ? case.pmin[g] : 0.0 for g in 1:G]
        up0   = [u0[g] == 1 ? 100 : 0 for g in 1:G]
        down0 = [u0[g] == 0 ? 100 : 0 for g in 1:G]
        acc = Dict(:cost=>0.0,:shed_h=>0,:ens=>0.0,:atl_h=>0,:atl_sum=>0.0,
                   :hours=>0,:nfail=>0,:ncap=>0,:starts=>0)
    end
    for b in b0:nblocks
        D = @view demand[:, ((b-1)*block + 1):(b*block)]
        r = solve_block(case, D, level; u0=u0, p0=p0, up0=up0, down0=down0)
        if !r.ok
            acc[:nfail] += 1
            r = solve_block(case, D, :lp; u0=u0, p0=p0, up0=up0, down0=down0)
            r.ok || error("block $b failed even as :lp ($(r.status))")
        end
        r.capped && (acc[:ncap] += 1)
        acc[:cost]   += sum(r.cost);              acc[:shed_h] += count(>(1e-4), r.shed)
        acc[:ens]    += sum(r.shed);              acc[:atl_h]  += count(>(0), r.at_limit)
        acc[:atl_sum]+= sum(r.at_limit);          acc[:hours]  += length(r.gen)
        acc[:starts] += sum(r.starts)
        u0, p0, up0, down0 = r.u_end, r.p_end, r.up_end, r.down_end
        if b % CHUNK == 0 || b == nblocks
            open(ck,"w") do io
                JSON3.write(io, (next_block=b+1, u0=u0, p0=p0, up0=up0, down0=down0,
                    cost=acc[:cost], shed_h=acc[:shed_h], ens=acc[:ens], atl_h=acc[:atl_h],
                    atl_sum=acc[:atl_sum], hours=acc[:hours], nfail=acc[:nfail],
                    ncap=acc[:ncap], starts=acc[:starts]))
            end
            @printf("      %s/%-5s %d/%d days\n", tag, level, b, nblocks); flush(stdout)
        end
    end
    rm(ck, force = true); return acc
end

case = oahu_set9()                      # v2 shares -- the current default
load = oahu_net_load()
nH   = 365 * 24

D_real = [case.share[i] * load[t] for i in 1:case.nbus, t in 1:nH]
rng    = MersenneTwister(SEED)
mu     = case.share .* mean(load)
D_expo = [mu[i] * (-log(1 - rand(rng))) for i in 1:case.nbus, t in 1:nH]
@printf("REAL mean %.1f MW | EXPO mean %.1f MW  (calibrated to match)\n",
        mean(sum(D_real,dims=1)), mean(sum(D_expo,dims=1))); flush(stdout)

done = isfile(PART) ? Set(string.(CSV.read(PART,DataFrame).world) .* "/" .*
                          string.(CSV.read(PART,DataFrame).rung)) : Set{String}()
isempty(done) || println("already banked: ", join(sort(collect(done)), ", "))

for (tag, D) in (("REAL", D_real), ("EXPO", D_expo))
    for lv in [:lp, :pmin, :ramp, :full]
        key = "$tag/$lv"
        key in done && (println("  $key ... cached"); flush(stdout); continue)
        println("  $key ..."); flush(stdout)
        t0 = time(); a = run_ckpt(case, D, lv, tag; days = 365); dt = time() - t0
        row = DataFrame(world=[tag], rung=[string(lv)], cost_musd=[a[:cost]/1e6],
                        p_shed=[100*a[:shed_h]/a[:hours]], ens_mwh=[a[:ens]],
                        p_at_limit=[100*a[:atl_h]/a[:hours]],
                        mean_lines_at_limit=[a[:atl_sum]/a[:hours]],
                        startups=[a[:starts]], blocks_capped=[a[:ncap]], solve_s=[dt])
        ex = isfile(PART); CSV.write(PART, row; append=ex, writeheader=!ex)
        @printf("  %-10s DONE %.0fs  shed %.2f%%  ens %.0f  atlimit %.2f%%  cost %.2f M (capped %d)\n",
                key, dt, row.p_shed[1], row.ens_mwh[1], row.p_at_limit[1],
                row.cost_musd[1], a[:ncap]); flush(stdout)
    end
end
println("SET9 GRID COMPLETE")
