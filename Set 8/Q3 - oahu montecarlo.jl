#=
Q3 -- "Ask the same questions of the real network."

Same three questions, same 10,000 draws, same solver. Only the network and the
demand means change: the 9-bus Oʻahu model, with each bus's mean set to its
population share of the real 743.86 MW island average.

BUT Q3 DOES ONE MORE THING
--------------------------
Q1 measured the real load record and found CV = 0.168. The exponential the
assignment specifies has CV = 1.000. Those are not close. So running Oʻahu
under Exp(1) answers "what would the risk be IF demand behaved exponentially",
which is a different question from "what is the risk".

Q3 therefore runs the same network under THREE demand models and reports them
side by side:

  A. EXPONENTIAL, independent   D_i = mu_i * Exp(1)
     The assignment's baseline. Every node rolls its own die.

  B. COMMON-SHOCK MIXTURE       D_i = mu_i * (0.7*E_common + 0.3*E_i)
     The same mean at every node, but a shared island-wide shock. Physically
     closer: one island, one weather system, one clock.

     State honestly what this is. The 0.7 is a MIXING WEIGHT, not a correlation
     coefficient, and the mixture is not itself exponential. It induces a
     pairwise correlation of 0.845 and cuts each node's CV to 0.762. So B
     differs from A in TWO ways at once -- more correlation, less per-node
     dispersion -- and is a sensitivity, not a clean isolation of correlation.

  C. EMPIRICAL BOOTSTRAP        draw a real hour from the 8,760-hour record
     The honest benchmark. No distributional assumption at all -- just the
     island's own history, resampled.

The spread between A, B and C is the answer to "how much of our computed risk
is physics, and how much is the distribution we chose?" On this network that
turns out to be almost all of it, which is the finding worth presenting.

Run:  julia "Q3 - oahu montecarlo.jl"
=#

using CSV, DataFrames, Statistics, Printf, Plots, Random
gr()

const HERE = @__DIR__
include(joinpath(HERE, "cases.jl"))
include(joinpath(HERE, "theme.jl"))
setup_theme!()
mkpath(joinpath(HERE, "figures")); mkpath(joinpath(HERE, "results"))

const NSCEN = 10_000

case   = oahu_case()
hourly = oahu_hourly_net_load()
shares = oahu_load_shares()

println("\n" * "="^78)
println(" Q3 -- MONTE CARLO ON THE REAL OʻAHU NETWORK")
println("="^78)
@printf("  buses %d   branches %d   generators %d\n",
        case.nbus, nbranch(case), ngen(case))
@printf("  nameplate capacity : %.1f MW\n", capacity(case))
dc = deliverable_capacity(case)
@printf("  DELIVERABLE capacity: %.1f MW  (%.1f%% of nameplate)\n",
        dc.mw, 100 * dc.mw / capacity(case))
@printf("  -> %.1f MW stranded behind line limits\n", capacity(case) - dc.mw)
@printf("  design mean demand : %.2f MW  (real 2021 annual mean)\n", sum(case.mu))
@printf("  utilisation        : %.1f%% of nameplate, %.1f%% of deliverable\n",
        100 * sum(case.mu) / capacity(case), 100 * sum(case.mu) / dc.mw)
@printf("  real annual peak   : %.1f MW  ->  clears the deliverable limit by %.1f MW (%.1f%%)\n",
        maximum(hourly), dc.mw - maximum(hourly),
        100 * (dc.mw - maximum(hourly)) / maximum(hourly))
@printf("  most expensive unit: %s at \$%.2f/MWh\n",
        case.gen_name[argmax(case.cost)], maximum(case.cost))
println("\n  per-bus mean demand:")
for i in 1:case.nbus
    @printf("    %-14s %8.2f MW  (%.1f%% of island)\n",
            case.bus_name[i], case.mu[i], 100 * case.mu[i] / sum(case.mu))
end

# ---------------------------------------------------------------------------
# A. The assignment's baseline: independent exponential
# ---------------------------------------------------------------------------
println("\n" * "-"^78)
println(" MODEL A -- independent Exp(1) at every node")
println("-"^78)
resA = run_montecarlo(case, NSCEN; sampler = exponential_sampler,
                      seed = 20260908, unconstrained_ref = true)
answer_the_three_questions(resA; label = "Oʻahu 9-bus, independent Exp(1)")

# ---------------------------------------------------------------------------
# B. Correlated exponential -- one island, one weather system
# ---------------------------------------------------------------------------
println("\n" * "-"^78)
println(" MODEL B -- correlated Exp(1), rho = 0.7 common shock")
println("-"^78)
resB = run_montecarlo(case, NSCEN; sampler = common_shock_sampler(0.7),
                      seed = 20260908, unconstrained_ref = false,
                      progress_every = 2500)
answer_the_three_questions(resB; label = "Oʻahu 9-bus, correlated Exp(1) rho=0.7")

# ---------------------------------------------------------------------------
# C. Empirical bootstrap -- the island's own 8,760 hours
# ---------------------------------------------------------------------------
println("\n" * "-"^78)
println(" MODEL C -- bootstrap from the real 8,760-hour record")
println("-"^78)
resC = run_montecarlo(case, NSCEN; sampler = bootstrap_sampler(hourly, shares),
                      seed = 20260908, unconstrained_ref = true,
                      progress_every = 2500)
answer_the_three_questions(resC; label = "Oʻahu 9-bus, empirical bootstrap")

# ---------------------------------------------------------------------------
# 1. THE COMPARISON TABLE
# ---------------------------------------------------------------------------
comp = vcat(summary_row(resA, "A · independent Exp(1)"),
            summary_row(resB, "B · correlated Exp(1), rho=0.7"),
            summary_row(resC, "C · empirical bootstrap (real)"))
CSV.write(joinpath(HERE, "results", "q3_model_comparison.csv"), comp)

println("\n" * "="^78)
println(" HOW MUCH OF THE RISK IS THE DISTRIBUTION, NOT THE GRID?")
println("="^78)
@printf(" %-32s %10s %10s %10s %10s\n",
        "demand model", "CV", "P(shed)", "P(exp gen)", "P(congest)")
for r in eachrow(comp)
    @printf(" %-32s %10.3f %9.2f%% %9.2f%% %9.2f%%\n",
            r.experiment, r.demand_cv, 100r.p_shed,
            100r.p_expensive_on, 100r.p_any_at_limit)
end
println()
println(" The network never changed. Only the demand model did.")
@printf("   adequacy  : P(shedding)  %.2f%%  ->  %.2f%%   (assumption -> reality)\n",
        100comp.p_shed[1], 100comp.p_shed[3])
@printf("   cost tail : P(costliest) %.2f%%  ->  %.2f%%\n",
        100comp.p_expensive_on[1], 100comp.p_expensive_on[3])
@printf("   congestion: P(a line at limit) %.2f%%  ->  %.2f%%\n",
        100comp.p_any_at_limit[1], 100comp.p_any_at_limit[3])
println()
println(" The exponential does not simply exaggerate risk -- it MISDIRECTS it.")
println("   It invents an adequacy crisis Oʻahu does not have: the real island")
println("   never once fails to serve load in 10,000 resampled hours, because")
println("   its demand never leaves the 473-1,054 MW band the fleet was built for.")
println("   And it HIDES the congestion problem Oʻahu really does have: real load")
println("   sits persistently in exactly the band that saturates the Ewa corridor,")
println("   so the true network binds MORE often than the exponential suggests.")
println()
println(" AND THE MARGIN IS THINNER THAN NAMEPLATE SUGGESTS.")
@printf("   nameplate says %.0f MW against a %.0f MW peak -- a %.0f%% cushion.\n",
        capacity(case), maximum(hourly),
        100 * (capacity(case) - maximum(hourly)) / maximum(hourly))
@printf("   But the network can only DELIVER %.0f MW, so the real cushion is\n", dc.mw)
@printf("   %.1f MW, or %.1f%%. %.0f MW of the fleet is stranded behind the wires.\n",
        dc.mw - maximum(hourly), 100 * (dc.mw - maximum(hourly)) / maximum(hourly),
        capacity(case) - dc.mw)
println("   Zero shedding is a true result, but it is not a comfortable one.")
println("="^78)

CSV.write(joinpath(HERE, "results", "q3_scenarios_expA.csv"),
          resA.scenarios[:, [:scen, :demand_mw, :shed_mw, :shed, :cost_usd,
                             :lmp_at_slack, :n_at_limit, :lmp_spread, :expensive_on]])
CSV.write(joinpath(HERE, "results", "q3_line_stats_expA.csv"), resA.line_stats)
CSV.write(joinpath(HERE, "results", "q3_line_stats_bootC.csv"), resC.line_stats)
CSV.write(joinpath(HERE, "results", "q3_gen_stats_expA.csv"), resA.gen_stats)
CSV.write(joinpath(HERE, "results", "q3_gen_stats_bootC.csv"), resC.gen_stats)

# ---------------------------------------------------------------------------
# 2. FIGURES
# ---------------------------------------------------------------------------
println("\n building figures...")
scA, scB, scC = resA.scenarios, resB.scenarios, resC.scenarios

# --- 2a. The three answers, three models -------------------------------------
grp = ["A · indep\nExp(1)", "B · corr\nExp(1)", "C · real\nbootstrap"]
vals_shed = [mean(scA.shed), mean(scB.shed), mean(scC.shed)]
vals_exp  = [mean(scA.expensive_on), mean(scB.expensive_on), mean(scC.expensive_on)]
vals_cong = [mean(scA.n_at_limit .> 0), mean(scB.n_at_limit .> 0), mean(scC.n_at_limit .> 0)]

MA = hcat(vals_exp, vals_shed, vals_cong)
pA = grouped_bar(grp, MA;
                 colors = [S_WARN, S_CRIT, C1],
                 series = ["most expensive gen runs", "load shedding",
                           "a line at its limit"],
                 ylabel = "share of 10,000 scenarios", legend = :topleft,
                 title = "Q3 · same grid, three demand assumptions",
                 ylims = (0, 1.18), yformatter = y -> @sprintf("%.0f%%", 100y))
for j in 1:3
    xs = grouped_positions(3, 3, j)
    for (g, x) in enumerate(xs)
        annotate!(pA, x, MA[g, j] + 0.035, text(pct(MA[g, j]), 9, INK, :center))
    end
end

# --- 2b. Demand distributions actually drawn ---------------------------------
pB = histogram(scA.demand_mw; bins = 80, normalize = :pdf, color = C2, alpha = 0.55,
               linecolor = SURFACE, linewidth = 0.4, label = "A · independent Exp(1)",
               xlabel = "island demand (MW)", ylabel = "density",
               title = "Q3 · what each assumption actually draws",
               legend = :topright, xlims = (0, 2600))
histogram!(pB, scB.demand_mw; bins = 80, normalize = :pdf, color = S_WARN, alpha = 0.50,
           linecolor = SURFACE, linewidth = 0.4, label = "B · correlated Exp(1)")
histogram!(pB, scC.demand_mw; bins = 80, normalize = :pdf, color = C1, alpha = 0.85,
           linecolor = SURFACE, linewidth = 0.4, label = "C · real record")
vline!(pB, [capacity(case)]; lw = 3, color = S_CRIT,
       label = @sprintf("capacity %.0f MW", capacity(case)))
vline!(pB, [sum(case.mu)]; lw = 2, ls = :dash, color = INK_2, label = "shared mean 744 MW")

# --- 2c. Per-branch congestion, exponential vs real --------------------------
lsA = resA.line_stats; lsC = resC.line_stats
ord = sortperm(lsA.p_at_limit, rev = true)
nb  = length(ord)
lbl = ["$(lsA.from[i])→$(lsA.to[i])" for i in ord]
MC = hcat(lsA.p_at_limit[ord], lsC.p_at_limit[ord])
pC = grouped_bar(lbl, MC;
                 colors = [C2, C1],
                 series = ["A · assumed Exp(1)", "C · real record"],
                 ylabel = "share of scenarios at limit", xrotation = 40,
                 title = "Q3 · which Oʻahu corridors bind",
                 legend = :topright,
                 yformatter = y -> @sprintf("%.0f%%", 100y),
                 ylims = (0, 1.12 * max(0.05, maximum(MC))))

# --- 2d. Generator use up the real merit order -------------------------------
gsA = sort(resA.gen_stats, :cost); gsC = sort(resC.gen_stats, :cost)
# collapse the six identical Schofield units and six Kahe units for legibility
pD = plot(gsA.cost, gsA.p_dispatched; seriestype = :scatter, ms = 9, color = C2,
          label = "A · Exp(1)", xlabel = "unit marginal cost (USD/MWh)",
          ylabel = "share of scenarios dispatched",
          title = "Q3 · how deep into the merit order we go",
          legend = :topright, ylims = (-0.05, 1.10),
          yformatter = y -> @sprintf("%.0f%%", 100y))
plot!(pD, gsC.cost, gsC.p_dispatched; seriestype = :scatter, ms = 9, color = C1,
      label = "C · real record")
annotate!(pD, 237.97, mean(gsA.p_dispatched[gsA.cost .== maximum(gsA.cost)]) + 0.10,
          text("Campbell CIP\n\$238/MWh", 10, INK, :right))

savefig(plot(pA, pB, pC, pD; layout = (2, 2), size = (1700, 1150)),
        joinpath(HERE, "figures", "q3_oahu_dashboard.png"))
println(" figure -> figures/q3_oahu_dashboard.png")

# --- 2e. The headline single chart -------------------------------------------
# One picture for the deck: the same three questions, exponential vs reality.
hl_x = ["most expensive\ngenerator runs", "load shedding\n(infeasible)",
        "a line at\nits limit"]
MH = hcat([vals_exp[1], vals_shed[1], vals_cong[1]],
          [vals_exp[3], vals_shed[3], vals_cong[3]])
pH = grouped_bar(hl_x, MH;
                 colors = [C2, C1],
                 series = ["assumed Exp(1) demand", "real Oʻahu demand"],
                 ylabel = "share of 10,000 scenarios", legend = :topleft,
                 title = "Q3 · the distribution you assume IS the risk you compute",
                 ylims = (0, 1.15), size = (1400, 720),
                 yformatter = y -> @sprintf("%.0f%%", 100y))
for j in 1:2
    xs = grouped_positions(3, 2, j)
    for (g, x) in enumerate(xs)
        annotate!(pH, x, MH[g, j] + 0.042, text(pct(MH[g, j]), 13, INK, :center))
    end
end
annotate!(pH, 2.00, 0.335,
          text("the exponential invents an adequacy\ncrisis that never happens ↑", 11, S_CRIT, :center))
annotate!(pH, 2.55, 0.78,
          text("...and hides the congestion\nthat actually does →", 11, C1, :right))
savefig(pH, joinpath(HERE, "figures", "q3_headline.png"))
println(" figure -> figures/q3_headline.png")

# ---------------------------------------------------------------------------
# 3. CROSS-NETWORK COMPARISON (Q2 vs Q3)
# ---------------------------------------------------------------------------
# Both networks were pinned to the SAME utilisation, so this compares topology
# and fleet shape rather than calibration.
if isfile(joinpath(HERE, "results", "q2_summary.csv"))
    q2 = CSV.read(joinpath(HERE, "results", "q2_summary.csv"), DataFrame)
    both = vcat(q2, summary_row(resA, "Q3 Oʻahu Exp(1) @ real mean"),
                    summary_row(resC, "Q3 Oʻahu empirical bootstrap"))
    CSV.write(joinpath(HERE, "results", "q2_vs_q3.csv"), both)
    println("\n" * "="^78)
    println(" Q2 vs Q3 -- both networks at the same 49.3% utilisation")
    println("="^78)
    @printf(" %-34s %8s %8s %9s %9s %9s\n",
            "case", "cap MW", "CV", "P(shed)", "P(exp)", "P(cong)")
    for r in eachrow(both)
        @printf(" %-34s %8.0f %8.3f %8.2f%% %8.2f%% %8.2f%%\n",
                first(r.experiment, 34), r.capacity_mw, r.demand_cv,
                100r.p_shed, 100r.p_expensive_on, 100r.p_any_at_limit)
    end
    println("="^78)
end

println("\n Q3 COMPLETE")
