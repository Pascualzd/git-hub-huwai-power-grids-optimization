# =====================================================================
# SENSITIVITY CASE `gt_slow` -- the three gas turbines, re-specified
# against filed EIA-860 start-time data.
#
# WHY THIS EXISTS
#
# EIA-860's Operable sheet carries a field we had overlooked:
# "Time from Cold Shutdown to Full Load". Extracted for all 24 O'ahu
# units (see `data/processed/oahu_generators.csv`, columns
# `cold_start_eia860` / `cold_start_source`), it CORROBORATES four of our
# five technology classes and CONTRADICTS the fifth:
#
#     Schofield S1-S6   IC   10 min   we model fast      -> agrees
#     Kalaeloa          CC   1 h      we model 6 h up    -> agrees
#     Kahe/Waiau steam  ST   12 h     we model 8 h up    -> agrees
#     H-POWER           ST   over 12h we model must-run  -> agrees
#     Waiau W9, W10,    GT   12 h     we model 1 h up,   -> DISAGREES
#     CIP1                            quick-start peaker
#
# Those three machines are 215.4 MW, 14.2% of installed capacity, and the
# ONLY units in the baseline that can go zero-to-full inside one hour.
#
# WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# The filed field speaks to START TIME. It says nothing about minimum
# stable output or about ramp rate while already synchronised -- a machine
# can be slow to light off from cold and still move quickly once hot.
# So this case changes ONLY the three parameters that start time bears on:
#
#     minup    1 h  ->  8 h    (having paid a 12 h light-off, you keep it on)
#     mindown  1 h  ->  8 h    (once down it is not available within the hour)
#     startup  $20/MW -> $75/MW (steam-class, reflecting a 12 h trajectory)
#
# p_min stays 0 and ramp stays 100%/h. Those remain uncited technology
# conventions and this filing does not license changing them.
#
# Only the `:full` rung reads minup/mindown/startup, so only `:full` is
# re-run. The baseline v3 `:full` row it is compared against lives in
# `results/set9_v3_calfix_partial.csv`.
# =====================================================================
using Printf, Statistics, CSV, DataFrames, JSON3

include(joinpath(@__DIR__, "fleet.jl"))
include(joinpath(@__DIR__, "commitment.jl"))

const OUT   = joinpath(@__DIR__, "results"); mkpath(OUT)
const PART  = joinpath(OUT, "set9_gt_slow.csv")
const CHUNK = 20

# The re-specification, in one place so it is auditable.
const GT_UNITS       = ["Waiau W9", "Waiau W10", "Campbell Industrial Park CIP1"]
const GT_MINUP       = 8
const GT_MINDOWN     = 8
const GT_STARTUP_PMW = 75.0

function run_year_ckpt(case, demand, level, tag; block = 24, days = 365)
    ck = joinpath(OUT, "ckpt_$(tag)_$(level).json")
    G  = length(case.pmax)
    nH = min(days * block, size(demand, 2)); nblocks = nH ÷ block
    if isfile(ck)
        s  = JSON3.read(read(ck, String))
        b0 = s.next_block
        u0, p0 = Vector{Int}(s.u0), Vector{Float64}(s.p0)
        up0, down0 = Vector{Int}(s.up0), Vector{Int}(s.down0)
        acc = Dict(:cost=>Float64(s.cost), :shed_h=>Int(s.shed_h), :ens=>Float64(s.ens),
                   :atl_h=>Int(s.atl_h), :atl_sum=>Float64(s.atl_sum),
                   :hours=>Int(s.hours), :nfail=>Int(s.nfail), :ncap=>Int(s.ncap),
                   :starts=>Int(s.starts))
        @printf("    resuming %s/%s at day %d / %d\n", tag, level, b0, nblocks); flush(stdout)
    else
        b0    = 1
        u0    = [case.gen_tech[g] == "municipal_waste" ? 1 : 0 for g in 1:G]
        p0    = [u0[g] == 1 ? case.pmin[g] : 0.0 for g in 1:G]
        up0   = [u0[g] == 1 ? 100 : 0 for g in 1:G]
        down0 = [u0[g] == 0 ? 100 : 0 for g in 1:G]
        acc = Dict(:cost=>0.0, :shed_h=>0, :ens=>0.0, :atl_h=>0, :atl_sum=>0.0,
                   :hours=>0, :nfail=>0, :ncap=>0, :starts=>0)
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
        hasproperty(r, :starts) && (acc[:starts] += sum(r.starts))
        u0, p0, up0, down0 = r.u_end, r.p_end, r.up_end, r.down_end
        if b % CHUNK == 0 || b == nblocks
            open(ck, "w") do io
                JSON3.write(io, (next_block=b+1, u0=u0, p0=p0, up0=up0, down0=down0,
                    cost=acc[:cost], shed_h=acc[:shed_h], ens=acc[:ens],
                    atl_h=acc[:atl_h], atl_sum=acc[:atl_sum], hours=acc[:hours],
                    nfail=acc[:nfail], ncap=acc[:ncap], starts=acc[:starts]))
            end
            @printf("      %s/%s  %d/%d days\n", tag, level, b, nblocks); flush(stdout)
        end
    end
    rm(ck, force = true)
    return acc
end

case = oahu_set9(shares = :v2)
D3   = oahu_hourly_demand(case)
@printf("v3 demand loaded: %d buses x %d hours\n", size(D3,1), size(D3,2))

# ---- apply the re-specification, and prove it applied -------------------
hits = 0
for (g, nm) in enumerate(case.gen_name)
    nm in GT_UNITS || continue
    global hits += 1
    old = (case.minup[g], case.mindown[g], case.startup[g])
    case.minup[g]   = GT_MINUP
    case.mindown[g] = GT_MINDOWN
    case.startup[g] = GT_STARTUP_PMW * case.pmax[g]
    @printf("  respec %-32s  minup %d->%d  mindown %d->%d  startup \$%.0f->\$%.0f\n",
            nm, old[1], case.minup[g], old[2], case.mindown[g],
            old[3], case.startup[g])
end
hits == length(GT_UNITS) ||
    error("expected $(length(GT_UNITS)) GT units, matched $hits -- check names in oahu_generators.csv")
flush(stdout)

done = isfile(PART) ? Set(string.(CSV.read(PART, DataFrame).rung)) : Set{String}()

for lv in [:full]
    string(lv) in done && (println("  gt_slow / $lv ... cached"); continue)
    println("  gt_slow / $lv ..."); flush(stdout)
    t0 = time(); a = run_year_ckpt(case, D3, lv, "gtslow"; days = 365); dt = time() - t0
    row = DataFrame(demand=["v3"], fleet=["gt_slow"], rung=[string(lv)],
                    cost_musd=[a[:cost]/1e6],
                    p_shed=[100*a[:shed_h]/a[:hours]], ens_mwh=[a[:ens]],
                    p_at_limit=[100*a[:atl_h]/a[:hours]],
                    mean_lines_at_limit=[a[:atl_sum]/a[:hours]],
                    blocks_capped=[a[:ncap]], solve_s=[dt])
    ex = isfile(PART); CSV.write(PART, row; append=ex, writeheader=!ex)
    @printf("  gt_slow / %-5s DONE  %.0fs  shed %.2f%%  ens %.1f  atlimit %.2f%%  cost %.2f M  (capped %d)\n",
            lv, dt, row.p_shed[1], row.ens_mwh[1], row.p_at_limit[1],
            row.cost_musd[1], a[:ncap]); flush(stdout)
end
println("GT_SLOW COMPLETE")
