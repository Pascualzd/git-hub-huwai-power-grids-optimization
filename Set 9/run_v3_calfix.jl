# v3-only ladder rerun after the PROFILE_DOW_OFFSET calendar fix.
#
# v1 and v2 build demand as `share[i] * island_total` and never open the hourly
# file, so their rows are unchanged and are reused from the previous run.
#
# This runs in the cloud sandbox, which reclaims the container on idle, so the
# year is checkpointed every CHUNK days: carried commitment state plus running
# aggregates go to JSON, and a restart resumes from the last checkpoint instead
# of redoing the rung.
using Printf, Statistics, CSV, DataFrames, JSON3

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const OUT   = joinpath(@__DIR__, "results"); mkpath(OUT)
const PART  = joinpath(OUT, "set9_v3_calfix_partial.csv")
const CHUNK = 20

function run_year_ckpt(case, demand, level; block = 24, days = 365)
    ck = joinpath(OUT, "ckpt_v3_$(level).json")
    G  = length(case.pmax)
    nH = min(days * block, size(demand, 2)); nblocks = nH ÷ block
    if isfile(ck)
        s  = JSON3.read(read(ck, String))
        b0 = s.next_block
        u0, p0 = Vector{Int}(s.u0), Vector{Float64}(s.p0)
        up0, down0 = Vector{Int}(s.up0), Vector{Int}(s.down0)
        acc = Dict(:cost=>Float64(s.cost), :shed_h=>Int(s.shed_h), :ens=>Float64(s.ens),
                   :atl_h=>Int(s.atl_h), :atl_sum=>Float64(s.atl_sum),
                   :hours=>Int(s.hours), :nfail=>Int(s.nfail), :ncap=>Int(s.ncap))
        @printf("    resuming %s at block %d / %d\n", level, b0, nblocks); flush(stdout)
    else
        b0    = 1
        u0    = [case.gen_tech[g] == "municipal_waste" ? 1 : 0 for g in 1:G]
        p0    = [u0[g] == 1 ? case.pmin[g] : 0.0 for g in 1:G]
        up0   = [u0[g] == 1 ? 100 : 0 for g in 1:G]
        down0 = [u0[g] == 0 ? 100 : 0 for g in 1:G]
        acc = Dict(:cost=>0.0, :shed_h=>0, :ens=>0.0, :atl_h=>0,
                   :atl_sum=>0.0, :hours=>0, :nfail=>0, :ncap=>0)
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
        acc[:cost]   += sum(r.cost)
        acc[:shed_h] += count(>(1e-4), r.shed)
        acc[:ens]    += sum(r.shed)
        acc[:atl_h]  += count(>(0), r.at_limit)
        acc[:atl_sum]+= sum(r.at_limit)
        acc[:hours]  += length(r.gen)
        u0, p0, up0, down0 = r.u_end, r.p_end, r.up_end, r.down_end
        if b % CHUNK == 0 || b == nblocks
            open(ck, "w") do io
                JSON3.write(io, (next_block=b+1, u0=u0, p0=p0, up0=up0, down0=down0,
                    cost=acc[:cost], shed_h=acc[:shed_h], ens=acc[:ens],
                    atl_h=acc[:atl_h], atl_sum=acc[:atl_sum], hours=acc[:hours],
                    nfail=acc[:nfail], ncap=acc[:ncap]))
            end
            @printf("      %s  %d/%d days\n", level, b, nblocks); flush(stdout)
        end
    end
    rm(ck, force = true)
    return acc
end

case = oahu_set9(shares = :v2)
D3   = oahu_hourly_demand(case)
@printf("v3 demand loaded: %d buses x %d hours\n", size(D3,1), size(D3,2)); flush(stdout)

done = isfile(PART) ? Set(string.(CSV.read(PART, DataFrame).rung)) : Set{String}()
isempty(done) || println("already banked: ", join(sort(collect(done)), ", "))

for lv in [:lp, :pmin, :ramp, :full]
    string(lv) in done && (println("  v3 / $lv ... cached"); flush(stdout); continue)
    println("  v3 / $lv ..."); flush(stdout)
    t0 = time(); a = run_year_ckpt(case, D3, lv; days = 365); dt = time() - t0
    row = DataFrame(demand=["v3"], rung=[string(lv)], cost_musd=[a[:cost]/1e6],
                    p_shed=[100*a[:shed_h]/a[:hours]], ens_mwh=[a[:ens]],
                    p_at_limit=[100*a[:atl_h]/a[:hours]],
                    mean_lines_at_limit=[a[:atl_sum]/a[:hours]], solve_s=[dt])
    ex = isfile(PART); CSV.write(PART, row; append=ex, writeheader=!ex)
    @printf("  v3 / %-5s DONE  %.0fs  shed %.2f%%  atlimit %.2f%%  cost %.2f M  (capped %d)\n",
            lv, dt, row.p_shed[1], row.p_at_limit[1], row.cost_musd[1], a[:ncap]); flush(stdout)
end
println("V3 LADDER COMPLETE")
