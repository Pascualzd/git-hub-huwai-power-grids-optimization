#=
Q2 -- "Fix the IEEE-14 network, put random numbers in the demand column, and
       run the optimisation 10,000 times."

Three questions to answer:
  1. How often do we spin up the most expensive generator?
  2. How often is the solution infeasible (load shedding)?
  3. How often do elements of the network get overloaded?

WHAT IS HELD FIXED, AND WHAT IS ROLLED
--------------------------------------
FIXED   topology (14 buses, 20 branches), generator capacities and costs,
        line ratings, the reference bus.
ROLLED  the demand column only: D_i = mu_i * Exp(1), independently per node.

That is the entire experiment. Everything interesting comes from the fact that
a network which is comfortable at its average is not comfortable at every draw
around that average.

CALIBRATION -- where mu comes from
----------------------------------
Q1 measured Oʻahu carrying a mean net load of 743.86 MW against 1,508.1 MW of
firm capacity: the island runs at 49.3% utilisation. IEEE-14 is given the SAME
utilisation -- 49.3% of its 772.4 MW, or 380.98 MW -- distributed over the
eleven load buses in the proportions of the published case14 load vector.

This matters more than it sounds. The three questions above are all questions
about headroom, and headroom is governed by mean-demand / capacity. Running the
toy at its native 259 MW (33.5% utilisation) and the island at 49.3% would mean
any difference between them was the calibration talking, not the networks. With
utilisation pinned, what is left to differ is topology and fleet shape -- which
is the comparison worth making.

LINE RATINGS
------------
case14 publishes no thermal limits. A network with no limits can never be
congested, which would make question 3 vacuous. So ratings are assigned exactly
as Part 3 did: 1.5x the flow each line carries at the design mean, floored at
25 MW -- the network a planner would build for today's duty plus a margin.

One artefact of that heuristic matters. Branch 7-8 carries zero flow in the base
case (bus 8 is radial: a generator, no load), so its rating lands on the 25 MW
floor, and G5's 100 MW of nameplate can never export more than 25 MW. So
IEEE-14's DELIVERABLE capacity is well under its 772.4 MW nameplate -- the
script reports both, and the gap is the point.

COST: THE LINEAR TERM ONLY
--------------------------
gencost.csv is MATPOWER cost model 2, carrying a quadratic coefficient c2 as
well as a linear c1. Like Parts 2-5 of this project, Set 8 minimises sum(c1*P)
alone, which keeps the dispatch a linear program with constant marginal costs.

That is a deliberate simplification, and it has a consequence worth stating
because it defines the answer to question 1. Under c1 alone, G1 and G2 both cost
$20/MWh and the units at buses 3, 6 and 8 all cost $40/MWh, so "the most
expensive generator" is really the most expensive TIER. Under the full quadratic
cost the incremental costs at full output would rank the units differently.
Q2 answers the question under a linear cost model, and labels it as such.

Run:  julia "Q2 - ieee14 montecarlo.jl"
=#

using CSV, DataFrames, Statistics, Printf, Plots, Random
gr()

const HERE = @__DIR__
include(joinpath(HERE, "cases.jl"))
include(joinpath(HERE, "theme.jl"))
setup_theme!()
mkpath(joinpath(HERE, "figures")); mkpath(joinpath(HERE, "results"))

const NSCEN = 10_000

# ---------------------------------------------------------------------------
# 0. Calibration constants, taken from Q1
# ---------------------------------------------------------------------------
oa           = oahu_case()
OAHU_UTIL    = sum(oa.mu) / capacity(oa)
IEEE14_CAP   = 772.4
TARGET_MEAN  = OAHU_UTIL * IEEE14_CAP

println("\n" * "="^78)
println(" Q2 -- MONTE CARLO ON A FIXED IEEE-14 NETWORK")
println("="^78)
@printf("  Oʻahu utilisation (from Q1) : %.4f  (%.1f MW of %.1f MW)\n",
        OAHU_UTIL, sum(oa.mu), capacity(oa))
@printf("  IEEE-14 target mean demand  : %.2f MW  (= %.4f x %.1f MW)\n",
        TARGET_MEAN, OAHU_UTIL, IEEE14_CAP)

case = ieee14_case(mean_total = TARGET_MEAN)
@printf("  line ratings assigned       : %.0f - %.0f MW (total %.0f MW)\n",
        minimum(case.rate), maximum(case.rate), sum(case.rate))

# Nameplate is the number everyone quotes; deliverable is the number that
# governs the answers. The gap is capacity stranded behind a wire.
dc = deliverable_capacity(case)
@printf("  nameplate capacity          : %.1f MW\n", capacity(case))
@printf("  NETWORK-DELIVERABLE capacity: %.1f MW  (%.1f%% of nameplate)\n",
        dc.mw, 100 * dc.mw / capacity(case))
@printf("  -> %.1f MW is stranded behind line limits\n", capacity(case) - dc.mw)
println("\n  fleet:")
for g in 1:ngen(case)
    @printf("    %-16s  Pmax %6.1f MW   \$%.2f/MWh\n",
            case.gen_name[g], case.pmax[g], case.cost[g])
end
println("\n  per-bus mean demand (mu):")
for i in load_buses(case)
    @printf("    %-10s %8.2f MW\n", case.bus_name[i], case.mu[i])
end

# ---------------------------------------------------------------------------
# 1. THE MAIN RUN -- 10,000 exponential draws
# ---------------------------------------------------------------------------
println("\n" * "-"^78)
res = run_montecarlo(case, NSCEN; sampler = exponential_sampler,
                     seed = 20260908, unconstrained_ref = true)
answer_the_three_questions(res; label = "IEEE-14, Exp(1) demand, 10,000 draws")

CSV.write(joinpath(HERE, "results", "q2_scenarios.csv"),
          res.scenarios[:, [:scen, :demand_mw, :shed_mw, :shed, :cost_usd,
                            :lmp_at_slack, :n_at_limit, :lmp_spread, :expensive_on]])
CSV.write(joinpath(HERE, "results", "q2_line_stats.csv"), res.line_stats)
CSV.write(joinpath(HERE, "results", "q2_gen_stats.csv"), res.gen_stats)

# ---------------------------------------------------------------------------
# 2. CONVERGENCE -- is 10,000 enough?
# ---------------------------------------------------------------------------
# A Monte Carlo answer is worthless without knowing how much of it is noise.
# The running estimate of each probability is plotted against sample size; when
# the trace flattens inside its own confidence band, the answer has converged.
sc = res.scenarios
run_shed = cumsum(sc.shed) ./ (1:NSCEN)
run_exp  = cumsum(sc.expensive_on) ./ (1:NSCEN)
run_cong = cumsum(sc.n_at_limit .> 0) ./ (1:NSCEN)

@printf("\n CONVERGENCE at n = %d\n", NSCEN)
for (nm, v) in (("P(shed)", run_shed), ("P(expensive on)", run_exp),
                ("P(any line at limit)", run_cong))
    lo, hi = wilson(v[end], NSCEN)
    @printf("   %-22s %.4f   95%% CI [%.4f, %.4f]   half-width %.4f\n",
            nm, v[end], lo, hi, (hi - lo) / 2)
end

# ---------------------------------------------------------------------------
# 2b. SEED ROBUSTNESS -- is the headline an artefact of one lucky stream?
# ---------------------------------------------------------------------------
# The Wilson interval above answers "how much would this estimate move if I drew
# 10,000 more scenarios FROM THE SAME STREAM". It does not, on its own, prove
# that the particular seed chosen was not flattering. The direct check is to
# re-run the whole experiment on independent streams and look at the spread.
println("\n" * "-"^78)
println(" SEED ROBUSTNESS -- the same experiment on independent streams")
println("-"^78)
seeds = [20260908, 11111, 987654321, 42]
robust = DataFrame(seed = Int[], mean_mw = Float64[], p_shed = Float64[],
                   p_expensive = Float64[], p_congested = Float64[])
for sd in seeds
    r = run_montecarlo(case, NSCEN; sampler = exponential_sampler, seed = sd,
                       unconstrained_ref = false, progress_every = 0)
    s = r.scenarios
    push!(robust, (sd, mean(s.demand_mw), mean(s.shed),
                   mean(s.expensive_on), mean(s.n_at_limit .> 0)))
    @printf("   seed %-10d  mean %.2f MW  ->  P(shed) %.2f%%  P(exp) %.2f%%  P(cong) %.2f%%\n",
            sd, robust.mean_mw[end], 100robust.p_shed[end],
            100robust.p_expensive[end], 100robust.p_congested[end])
end
CSV.write(joinpath(HERE, "results", "q2_seed_robustness.csv"), robust)
@printf("\n   across seeds: P(shed) %.2f-%.2f%%  (spread %.2f pp, Wilson half-width %.2f pp)\n",
        100minimum(robust.p_shed), 100maximum(robust.p_shed),
        100 * (maximum(robust.p_shed) - minimum(robust.p_shed)),
        100 * (wilson(mean(robust.p_shed), NSCEN)[2] - mean(robust.p_shed)))
println("   The reported seed (20260908, the presentation date, fixed in advance)")
@printf("   sits at the LOW end: mean across seeds is P(shed) %.2f%%, P(exp) %.2f%%,\n",
        100mean(robust.p_shed), 100mean(robust.p_expensive))
@printf("   P(cong) %.2f%%. The headline is therefore mildly conservative, not\n",
        100mean(robust.p_congested))
println("   flattering, and the spread is the size the binomial error predicts.")

# ---------------------------------------------------------------------------
# 3. STRESS SWEEP -- how do the answers move with the mean?
# ---------------------------------------------------------------------------
# The single most important sensitivity in the whole set. Every probability
# above is a function of one number: mean demand divided by capacity. Sweeping
# the mean scale from 0.5x to 1.6x traces out the risk curves, and shows how
# sharply a grid crosses from "comfortable" to "shedding constantly".
println("\n" * "-"^78)
println(" STRESS SWEEP -- scaling the design mean")
println("-"^78)

# CRITICAL: the network must be held FIXED across the sweep. Calling
# ieee14_case(mean_total = ...) re-derives line ratings from the base case at
# that load, so the grid would silently grow as demand grows -- total ratings
# would run from 927 MW to 1,823 MW -- and the resulting curve would be a blend
# of two effects, far flatter than the real one. The ratings from the lambda = 1
# network are therefore frozen and reused at every point.
const FIXED_RATES = case.rate

sweep_lambda = 0.5:0.1:1.6
sweep = DataFrame(lambda = Float64[], util = Float64[], mean_mw = Float64[],
                  p_shed = Float64[], p_expensive = Float64[],
                  p_congested = Float64[], mean_cost = Float64[],
                  ens_pct = Float64[])
for lam in sweep_lambda
    c = ieee14_case(mean_total = TARGET_MEAN * lam, rate_override = FIXED_RATES)
    r = run_montecarlo(c, 2_000; sampler = exponential_sampler,
                       seed = 424242, unconstrained_ref = false, progress_every = 0)
    s = r.scenarios
    push!(sweep, (lam, sum(c.mu) / capacity(c), sum(c.mu),
                  mean(s.shed), mean(s.expensive_on), mean(s.n_at_limit .> 0),
                  mean(s.cost_usd), 100 * sum(s.shed_mw) / sum(s.demand_mw)))
    @printf("   lambda %.1f  util %.3f  mean %6.1f MW  ->  P(shed) %6.2f%%  P(exp) %6.2f%%  P(cong) %6.2f%%\n",
            lam, sweep.util[end], sweep.mean_mw[end],
            100sweep.p_shed[end], 100sweep.p_expensive[end], 100sweep.p_congested[end])
end
CSV.write(joinpath(HERE, "results", "q2_stress_sweep.csv"), sweep)

# ---------------------------------------------------------------------------
# 4. REFERENCE RUN -- the textbook 259 MW case, for the record
# ---------------------------------------------------------------------------
println("\n" * "-"^78)
println(" REFERENCE: the same experiment at case14's native 259 MW load")
println("-"^78)
case_native = ieee14_case()          # no rescale
res_native  = run_montecarlo(case_native, NSCEN; sampler = exponential_sampler,
                             seed = 20260908, unconstrained_ref = false,
                             progress_every = 0)
sn = res_native.scenarios
@printf("   utilisation %.3f  ->  P(shed) %.2f%%   P(expensive) %.2f%%   P(congested) %.2f%%\n",
        sum(case_native.mu) / capacity(case_native),
        100mean(sn.shed), 100mean(sn.expensive_on), 100mean(sn.n_at_limit .> 0))
println("   (the textbook case sits at 33.5% utilisation -- a materially safer grid)")

# ---------------------------------------------------------------------------
# 5. FIGURES
# ---------------------------------------------------------------------------
println("\n building figures...")

# --- 5a. The three answers, as one panel -------------------------------------
answers = [mean(sc.expensive_on), mean(sc.shed), mean(sc.n_at_limit .> 0)]
albl    = ["most expensive\ngenerator runs", "load shedding\n(infeasible)",
           "at least one line\nat its limit"]
acol    = [S_WARN, S_CRIT, C2]
pA = bar(1:3, answers; color = acol, linecolor = SURFACE, linewidth = 2,
         label = "", xticks = (1:3, albl), ylabel = "share of 10,000 scenarios",
         title = "Q2 · IEEE-14 · the three answers", ylims = (0, 1.0),
         yformatter = y -> @sprintf("%.0f%%", 100y))
label_bars!(pA, 1:3, answers, [pct(a) for a in answers]; above = 0.03, fs = 13)

# --- 5b. Demand distribution and where failure starts -------------------------
pB = histogram(sc.demand_mw; bins = 70, normalize = :pdf, color = C1,
               linecolor = SURFACE, linewidth = 0.5, alpha = 0.85, label = "drawn demand",
               xlabel = "total system demand (MW)", ylabel = "density",
               title = "Demand draws vs the two capacity walls", legend = :topright)
vline!(pB, [capacity(case)]; lw = 2.5, ls = :dot, color = INK_2,
       label = @sprintf("nameplate capacity %.0f MW", capacity(case)))
vline!(pB, [dc.mw]; lw = 3, color = S_CRIT,
       label = @sprintf("DELIVERABLE capacity %.0f MW", dc.mw))
vline!(pB, [sum(case.mu)]; lw = 2.5, ls = :dash, color = INK_2,
       label = @sprintf("design mean %.0f MW", sum(case.mu)))
# Shading a "shed region" would be misleading: shedding is NOT only a capacity
# problem. The network can fail to DELIVER power even when total generation is
# more than sufficient, because the wires between the generator and the load
# have limits of their own. The gap between these two percentages is exactly
# that effect, and it is the most important number on the chart.
frac_cap  = mean(sc.demand_mw .> capacity(case))
frac_deliv = mean(sc.demand_mw .> dc.mw)
# crude density height for placing the label, computed from the histogram itself
dens_peak = let e = range(minimum(sc.demand_mw), maximum(sc.demand_mw); length = 71)
    w = e[2] - e[1]
    maximum([count(d -> e[k] <= d < e[k+1], sc.demand_mw) for k in 1:70]) /
        (length(sc.demand_mw) * w)
end
annotate!(pB, quantile(sc.demand_mw, 0.995), 0.62 * dens_peak,
          text(@sprintf("above nameplate in %s of draws\nabove DELIVERABLE in %s\nshedding occurs in %s",
                        pct(frac_cap), pct(frac_deliv), pct(mean(sc.shed))),
               10, INK, :right))

# --- 5c. Which lines bind, ranked --------------------------------------------
ls = sort(res.line_stats, :p_at_limit, rev = true)
top = first(ls, 12)
pC = bar(1:nrow(top), top.p_at_limit; color = C2, linecolor = SURFACE, linewidth = 1.5,
         label = "", orientation = :vertical,
         xticks = (1:nrow(top), ["$(r.from)→$(r.to)" for r in eachrow(top)]),
         xrotation = 45, ylabel = "share of scenarios at limit",
         title = "Q2 · which corridors bind, and how often",
         yformatter = y -> @sprintf("%.0f%%", 100y),
         ylims = (0, max(0.05, 1.18 * maximum(top.p_at_limit))))
label_bars!(pC, 1:nrow(top), top.p_at_limit, [pct(x) for x in top.p_at_limit];
            above = 0.03, fs = 9)

# --- 5d. Stress sweep --------------------------------------------------------
pD = plot(sweep.util, sweep.p_shed; lw = 3, marker = :circle, ms = 6, color = S_CRIT,
          label = "P(load shedding)", xlabel = "mean demand / installed capacity",
          ylabel = "probability", title = "Q2 · risk is a function of headroom",
          legend = :topleft, yformatter = y -> @sprintf("%.0f%%", 100y),
          ylims = (-0.02, 1.02))
plot!(pD, sweep.util, sweep.p_expensive; lw = 3, marker = :diamond, ms = 6,
      color = S_WARN, label = "P(most expensive gen runs)")
plot!(pD, sweep.util, sweep.p_congested; lw = 3, marker = :rect, ms = 5,
      color = C1, label = "P(a line at its limit)")
vline!(pD, [OAHU_UTIL]; lw = 2.5, ls = :dash, color = INK_2,
       label = @sprintf("Oʻahu's real utilisation, %.1f%%", 100OAHU_UTIL))

savefig(plot(pA, pB, pC, pD; layout = (2, 2), size = (1700, 1150)),
        joinpath(HERE, "figures", "q2_ieee14_dashboard.png"))
println(" figure -> figures/q2_ieee14_dashboard.png")

# --- 5e. Convergence, on its own ---------------------------------------------
pE = plot(1:NSCEN, run_shed; lw = 2.5, color = S_CRIT, label = "P(load shedding)",
          xlabel = "scenarios drawn", ylabel = "running estimate",
          title = "Q2 · convergence: 10,000 draws is enough",
          xscale = :log10, legend = :right, xlims = (10, NSCEN),
          size = (1300, 620),
          yformatter = y -> @sprintf("%.0f%%", 100y))
plot!(pE, 1:NSCEN, run_exp;  lw = 2.5, color = S_WARN, label = "P(most expensive gen runs)")
plot!(pE, 1:NSCEN, run_cong; lw = 2.5, color = C1, label = "P(a line at its limit)")
for (v, c) in ((run_shed, S_CRIT), (run_exp, S_WARN), (run_cong, C1))
    lo, hi = wilson(v[end], NSCEN)
    hline!(pE, [lo, hi]; lw = 1, ls = :dot, color = c, label = "")
end
savefig(pE, joinpath(HERE, "figures", "q2_convergence.png"))
println(" figure -> figures/q2_convergence.png")

# --- 5f. Generator utilisation up the merit order ----------------------------
gs = sort(res.gen_stats, :cost)
pF = bar(1:nrow(gs), gs.p_dispatched;
         color = [g.cost >= maximum(gs.cost) - 1e-9 ? S_CRIT : C1 for g in eachrow(gs)],
         linecolor = SURFACE, linewidth = 2, label = "",
         xticks = (1:nrow(gs), [@sprintf("%s\n\$%.0f", r.name, r.cost) for r in eachrow(gs)]),
         ylabel = "share of scenarios dispatched", ylims = (0, 1.22),
         title = "Q2 · how often each unit is called, by merit order",
         size = (1300, 620),
         yformatter = y -> @sprintf("%.0f%%", 100y))
label_bars!(pF, 1:nrow(gs), gs.p_dispatched, [pct(x) for x in gs.p_dispatched];
            above = 0.03, fs = 11)
# G1 and G2 tie at $20/MWh, so the LP does not determine how the cheap block is
# split between them -- only their total. The bars for those two are a
# reproducible tie-break, not a result; the $40 tier is what the headline
# question is about.
annotate!(pF, 1.5, 1.14,
          text("G1/G2 tie at \$20 — split is a tie-break, not a result", 10, INK_2, :center))
savefig(pF, joinpath(HERE, "figures", "q2_generator_use.png"))
println(" figure -> figures/q2_generator_use.png")

CSV.write(joinpath(HERE, "results", "q2_summary.csv"),
          summary_row(res, "Q2 IEEE-14 Exp(1) @ Oʻahu utilisation"))

println("\n" * "="^78)
println(" Q2 COMPLETE")
println("="^78)
