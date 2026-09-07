#=
montecarlo.jl -- the shared risk engine for Set 8.

WHAT THIS FILE IS
-----------------
Parts 2-5 of the earlier work asked "what does this grid do?" -- one network,
one demand vector, one answer. Set 8 asks a different kind of question:

    "What does this grid do across TEN THOUSAND POSSIBLE DAYS?"

That turns a deterministic optimisation into a MONTE CARLO EXPERIMENT. The
network is held fixed -- same wires, same generators, same limits -- and only
the demand column is re-rolled. Every roll is a separate DC-OPF. The output is
not a number; it is a DISTRIBUTION.

THE PHYSICAL PICTURE
--------------------
Think of the grid as a fixed plumbing rig bolted to a wall: the pipes have
fixed diameters, the pumps have fixed capacities, and you cannot change either.
What you CAN change is how hard each tap at the far end is opened. Set 8 opens
every tap to a random position, ten thousand times, and records three things
each time:

    1. Did we have to fire up the most expensive pump?      (cost risk)
    2. Was there simply not enough water to go around?       (adequacy risk)
    3. Which pipes ran completely full?                      (congestion risk)

THE TAP-OPENING DISTRIBUTION
----------------------------
Each demand node i draws

    D_i = mu_i * E_i ,      E_i ~ Exponential(1)   i.i.d. across nodes

so E[D_i] = mu_i and, crucially, sd(D_i) = mu_i as well: the exponential has a
COEFFICIENT OF VARIATION OF EXACTLY 1. That is a deliberately violent
assumption, and Set 8 measures what it costs (see `bootstrap_sampler`, which
draws from the real 8,760-hour Oʻahu record instead and gets CV = 0.168).

A note on the tail. Exp(1) has P(E > 3) = 4.98%, P(E > 5) = 0.67%. With ~10
independent nodes you should EXPECT a few nodes at 3-5x their mean in most
draws. The system total is far tamer than any single node, because independent
draws diversify -- and how much they diversify depends on how CONCENTRATED the
load is. That is one of the findings of this set.

FEASIBILITY, AND WHY WE NEVER LET THE SOLVER FAIL
-------------------------------------------------
A naive Monte Carlo would call the solver and count INFEASIBLE returns. That is
a bad instrument: "infeasible" is a single bit, it tells you nothing about HOW
short the system was, and a solver can also return INFEASIBLE for numerical
reasons that have nothing to do with physics.

So every bus gets a LOAD-SHEDDING variable S_i in [0, D_i], priced at VOLL
(value of lost load). The LP is then ALWAYS feasible, and "infeasible" becomes
a measurable quantity: sum(S) > 0 means the network could not serve the draw,
and the size of sum(S) says by how much. This is exactly how system operators
and reliability studies actually do it.

DEPENDENCIES: JuMP, HiGHS, DataFrames, Random, Statistics, Printf
=#

using JuMP, HiGHS
using DataFrames, Random, Statistics, Printf

# Value of lost load, USD/MWh. Set far above the most expensive generator on
# either system (Oʻahu's costliest unit is $237.97/MWh) so the optimiser always
# prefers to generate rather than shed, and only sheds when it is physically
# forced to.
const VOLL = 10_000.0

# A flow is called "at limit" when it reaches this fraction of its rating.
# In a hard-constrained DC-OPF the flow can never EXCEED the rating -- the
# constraint binds instead -- so this measures saturation, not violation.
const AT_LIMIT_TOL = 0.999

# Below this many MW, shedding is treated as numerical noise, not a blackout.
const SHED_TOL = 1e-4

# Deterministic tie-break between generators of EQUAL marginal cost.
#
# IEEE-14 gives G1 (bus 1) and G2 (bus 2) the same $20/MWh linear cost. When two
# units tie, the LP has infinitely many optimal solutions -- the total is pinned
# but the SPLIT between them is not -- and which one the solver reports is
# decided by its pivoting rule, not by the model. Probing the optimal face shows
# G1's output free to move by up to 140 MW at identical cost, so an unadjusted
# per-generator statistic would be reporting HiGHS's internals as if they were
# a result.
#
# Adding g * TIEBREAK to unit g's cost makes the choice explicit and
# reproducible (lower-indexed unit first). At 1e-6 USD/MWh against dispatches of
# a few hundred MW this perturbs the objective by well under a thousandth of a
# dollar, so no genuinely distinct solution is ever selected.
#
# Quantities that were ALREADY unique -- total cost, total shedding, whether the
# expensive tier runs -- are unaffected. Quantities that were never unique are
# now at least stable and documented. Where units tie, read the TIER, not the
# individual unit.
const TIEBREAK = 1e-6


# ===========================================================================
# 1. THE NETWORK CONTAINER
# ===========================================================================
"""
    GridCase

Everything the Monte Carlo needs about one fixed network, in solver-ready form.

Fields
  name       : label for reports
  nbus       : number of buses
  gen_bus    : gen_bus[g] = index of the bus generator g sits on
  pmax       : gen_bus-aligned capacity vector, MW
  cost       : gen_bus-aligned marginal cost vector, USD/MWh
  gen_name   : label per generator
  fbus,tbus  : branch endpoints, as bus INDICES (1..nbus)
  sus        : branch susceptance, per unit (= 1/x)
  rate       : branch thermal rating, MW
  mu         : per-bus MEAN demand, MW (0 at pure generation/junction nodes)
  slack      : index of the reference bus
  baseMVA    : power base
  bus_name   : label per bus
  coords     : bus index -> (x, y) for plotting
"""
struct GridCase
    name::String
    nbus::Int
    gen_bus::Vector{Int}
    pmax::Vector{Float64}
    cost::Vector{Float64}
    gen_name::Vector{String}
    fbus::Vector{Int}
    tbus::Vector{Int}
    sus::Vector{Float64}
    rate::Vector{Float64}
    mu::Vector{Float64}
    slack::Int
    baseMVA::Float64
    bus_name::Vector{String}
    coords::Dict{Int,Tuple{Float64,Float64}}
end

ngen(c::GridCase)    = length(c.pmax)
nbranch(c::GridCase) = length(c.rate)
capacity(c::GridCase) = sum(c.pmax)
"""Indices of buses that actually carry load (mu > 0)."""
load_buses(c::GridCase) = findall(>(0.0), c.mu)

"""
    deliverable_capacity(case) -> (mw, alpha)

The demand level at which the network -- not the fleet -- runs out.

`capacity(case)` adds up nameplate and is the number everyone quotes, but it is
the wrong yardstick: a megawatt that cannot cross a line is not capacity. This
solves

    max alpha   s.t.  demand = alpha * mu is served with ZERO shedding,
                      subject to every generator stop and every line rating

which is an LP because alpha enters the balance constraints linearly. The
result is the largest load, scaled along the network's own demand shape, that
the system can actually deliver.

On both networks in Set 8 this sits far below nameplate, and the gap is the
single most useful diagnostic in the study: it says how much of the fleet is
stranded behind a wire.
"""
function deliverable_capacity(case::GridCase)
    G = 1:ngen(case); N = 1:case.nbus; L = 1:nbranch(case)
    m = Model(HiGHS.Optimizer); set_silent(m)

    @variable(m, 0 <= P[g in G] <= case.pmax[g])
    @variable(m, THETA[N])
    @variable(m, alpha >= 0)
    @constraint(m, THETA[case.slack] == 0)
    @expression(m, F[l in L],
        case.baseMVA * case.sus[l] * (THETA[case.fbus[l]] - THETA[case.tbus[l]]))
    @constraint(m, [i in N],
        sum(P[g] for g in G if case.gen_bus[g] == i; init = 0.0)
        - sum(F[l] for l in L if case.fbus[l] == i; init = 0.0)
        + sum(F[l] for l in L if case.tbus[l] == i; init = 0.0)
        == alpha * case.mu[i])
    @constraint(m, [l in L], -case.rate[l] <= F[l] <= case.rate[l])
    @objective(m, Max, alpha)
    optimize!(m)

    termination_status(m) == MOI.OPTIMAL ||
        return (mw = NaN, alpha = NaN)
    a = value(alpha)
    return (mw = a * sum(case.mu), alpha = a)
end


# ===========================================================================
# 2. THE MODEL, BUILT ONCE
# ===========================================================================
#
# The single most important performance decision in this file.
#
# Rebuilding a JuMP model 10,000 times means re-parsing 10,000 sets of algebraic
# expressions, and the parsing costs far more than the solve. Instead we build
# the LP ONCE and, for each scenario, only:
#
#     - move the right-hand side of each nodal balance constraint  (new demand)
#     - move the upper bound on each shed variable                 (new D_i cap)
#
# Everything structural -- the topology, the susceptances, the line limits, the
# generator bounds, the objective -- is untouched. HiGHS then warm-starts from
# the previous basis, so successive solves are very fast.

"""
    build_model(case) -> (model, P, F, S, THETA, cBal)

Assemble the DC-OPF once, with demand entering only through constraint
right-hand sides so it can be re-parameterised cheaply.

The formulation (identical in structure to Parts 2-4, plus shedding):

    min  sum_g cost_g * P_g  +  VOLL * sum_i S_i

    s.t.  0 <= P_g <= Pmax_g                                (generator stops)
          THETA[slack] = 0                                  (angle reference)
          F_l = baseMVA * sus_l * (TH[from] - TH[to])       (DC power flow)
          sum_{g at i} P_g - (D_i - S_i) = net outflow_i    (Kirchhoff)
          -rate_l <= F_l <= rate_l                          (thermal limits)
          0 <= S_i <= D_i                                   (can't shed what
                                                             isn't demanded)

NOTE ON Pmin. Generator minimum stable output is set to zero here, on purpose.
Oʻahu's fleet carries 531 MW of nameplate Pmin; enforcing it in a continuous LP
without unit commitment would make every LOW-demand draw infeasible for a
reason that has nothing to do with adequacy (you cannot switch a unit off).
Set 8 is a study of whether the network can MEET demand, so the fleet is
allowed to shut down freely. This is stated in the deck as an assumption.
"""
function build_model(case::GridCase)
    G = 1:ngen(case); N = 1:case.nbus; L = 1:nbranch(case)

    m = Model(HiGHS.Optimizer)
    set_silent(m)

    @variable(m, 0 <= P[g in G] <= case.pmax[g])
    @variable(m, THETA[N])
    @variable(m, S[N] >= 0)                     # upper bound reset per scenario

    @constraint(m, THETA[case.slack] == 0)

    @expression(m, F[l in L],
        case.baseMVA * case.sus[l] * (THETA[case.fbus[l]] - THETA[case.tbus[l]]))

    # Nodal balance. Demand starts at mu and is moved per scenario via
    # set_normalized_rhs. Written so that the CONSTANT term is exactly -D_i:
    #     sum(P at i) + S_i - net_outflow_i  ==  D_i
    @constraint(m, cBal[i in N],
        sum(P[g] for g in G if case.gen_bus[g] == i; init = 0.0)
        + S[i]
        - sum(F[l] for l in L if case.fbus[l] == i; init = 0.0)
        + sum(F[l] for l in L if case.tbus[l] == i; init = 0.0)
        == case.mu[i])

    @constraint(m, cLine[l in L], -case.rate[l] <= F[l] <= case.rate[l])

    # The TIEBREAK term makes the dispatch unique when two units share a price.
    # See the constant's definition for why this is a correctness fix and not a
    # cosmetic one.
    @objective(m, Min,
        sum((case.cost[g] + g * TIEBREAK) * P[g] for g in G) +
        VOLL * sum(S[i] for i in N))

    return (model = m, P = P, F = F, S = S, THETA = THETA, cBal = cBal)
end

"""
    set_demand!(mdl, case, D)

Point the pre-built model at a new demand vector `D` (MW per bus).
Two touches per bus: the balance RHS, and the shed ceiling.
"""
function set_demand!(mdl, case::GridCase, D::Vector{Float64})
    for i in 1:case.nbus
        set_normalized_rhs(mdl.cBal[i], D[i])
        set_upper_bound(mdl.S[i], max(D[i], 0.0))
    end
    return mdl
end


# ===========================================================================
# 3. SAMPLERS
# ===========================================================================
#
# A sampler is any function (rng, case) -> Vector{Float64} of bus demands.
# Keeping this an argument rather than hard-coding the exponential is what lets
# Q2 and Q3 compare distributional assumptions on identical networks.

"""
    exponential_sampler(rng, case)

The assignment's baseline: `D_i = mu_i * E_i` with `E_i ~ Exp(1)` drawn
INDEPENDENTLY at every load node.

Per node this gives mean mu_i and CV exactly 1. At system level the CV is much
smaller, because independent draws partially cancel:

    CV_total = sqrt( sum_i mu_i^2 ) / sum_i mu_i

which is 1 only if a single node carries all the load, and shrinks toward
1/sqrt(n) when load is spread evenly. Load CONCENTRATION therefore controls how
volatile the system total is -- Oʻahu, where two buses carry 72% of the island,
diversifies far less than IEEE-14 does across its eleven load nodes.
"""
function exponential_sampler(rng::AbstractRNG, case::GridCase)
    D = zeros(Float64, case.nbus)
    for i in 1:case.nbus
        case.mu[i] > 0 && (D[i] = case.mu[i] * randexp(rng))
    end
    return D
end

"""
    common_shock_sampler(w) -> sampler

The independence in `exponential_sampler` is the strongest assumption in the
whole set, and it is physically wrong: demand on one island moves together,
because everybody shares the same weather, the same clock, and the same working
day.

This blends a COMMON island-wide shock with node-specific noise, with mixing
weight `w`:

    D_i = mu_i * ( w * E_common + (1 - w) * E_i ),    all E ~ Exp(1) iid

BE PRECISE ABOUT WHAT THIS DOES AND DOES NOT DO. `w` is a mixing weight, NOT a
correlation coefficient, and the mixture is not itself exponential. For weight
`w` the induced quantities are

    per-node CV        sqrt(w^2 + (1-w)^2)
    pairwise corr      w^2 / (w^2 + (1-w)^2)

so w = 0.7 gives CV 0.762 and correlation 0.845 -- verified by simulation at
0.7626 and 0.8454 over 200,000 draws. Two things therefore change at once
relative to the independent case: correlation goes UP and per-node dispersion
goes DOWN. It is a sensitivity, not a clean isolation of correlation, and the
write-up says so.

The mean is preserved exactly at mu_i, which is what matters for comparability.
Use `induced_moments(w)` to report the pair honestly.
"""
function common_shock_sampler(w::Float64)
    0.0 <= w <= 1.0 || error("mixing weight must lie in [0,1]")
    return function (rng::AbstractRNG, case::GridCase)
        common = randexp(rng)
        D = zeros(Float64, case.nbus)
        for i in 1:case.nbus
            case.mu[i] > 0 &&
                (D[i] = case.mu[i] * (w * common + (1 - w) * randexp(rng)))
        end
        return D
    end
end

"""Per-node CV and pairwise correlation induced by `common_shock_sampler(w)`."""
function induced_moments(w::Float64)
    v = w^2 + (1 - w)^2
    return (cv = sqrt(v), corr = w^2 / v)
end

"""
    bootstrap_sampler(hourly_total, case)

The reality check. Instead of inventing a distribution, draw an hour at random
from the real 8,760-hour Oʻahu record and split it across buses by their fixed
population shares.

This preserves the ACTUAL shape of island demand -- CV 0.168, a hard floor
around 473 MW, a ceiling at 1,054 MW -- and is the honest benchmark that says
how much of the exponential model's risk is real and how much is an artefact
of the distributional choice. Returns a sampler function.
"""
function bootstrap_sampler(hourly_total::Vector{Float64}, shares::Vector{Float64})
    return function (rng::AbstractRNG, case::GridCase)
        h = hourly_total[rand(rng, 1:length(hourly_total))]
        return h .* shares
    end
end


# ===========================================================================
# 4. THE EXPERIMENT
# ===========================================================================

"""
    run_montecarlo(case, nscen; sampler, seed, unconstrained_ref)

Solve `nscen` DC-OPFs on a fixed network with re-rolled demand, and return a
tidy DataFrame with one row per scenario plus per-line and per-generator
frequency tables.

Returns a NamedTuple:

  scenarios  : DataFrame, one row per draw
                 scen, demand_mw, served_mw, shed_mw, shed, cost_usd,
                 marginal_cost, n_at_limit, max_lmp, min_lmp, lmp_spread,
                 expensive_on, gen_<k>..., util_<l>...
  line_stats : DataFrame, one row per branch
                 branch, from, to, rate_mw, p_at_limit, mean_util, p95_util,
                 p_overload_unconstrained, mean_overload_mw
  gen_stats  : DataFrame, one row per generator
                 gen, name, bus, pmax, cost, p_dispatched, mean_mw,
                 capacity_factor

`unconstrained_ref = true` additionally solves each scenario a SECOND time with
line limits removed. That answers the question a hard-limited OPF cannot: how
far OVER its rating would a line have gone if the operator had not been there
to redispatch around it? In the constrained model a line simply saturates; the
unconstrained twin measures the true stress the draw put on that corridor.
"""
function run_montecarlo(case::GridCase, nscen::Int;
                        sampler = exponential_sampler,
                        seed::Int = 20260908,
                        unconstrained_ref::Bool = true,
                        progress_every::Int = 1000)

    rng  = MersenneTwister(seed)
    mdl  = build_model(case)
    G, L, N = 1:ngen(case), 1:nbranch(case), 1:case.nbus

    # The reference model with line limits relaxed to effectively infinite.
    # Same demand draw, so the two solves are paired and directly comparable.
    case_free = GridCase(case.name * " (no line limits)", case.nbus, case.gen_bus,
                         case.pmax, case.cost, case.gen_name, case.fbus, case.tbus,
                         case.sus, fill(1e6, nbranch(case)), case.mu, case.slack,
                         case.baseMVA, case.bus_name, case.coords)
    mdl_free = unconstrained_ref ? build_model(case_free) : nothing

    # Which generator is the most expensive one? That is the unit whose start-up
    # is the question "how often do we spin up the most expensive generator".
    exp_idx  = argmax(case.cost)
    exp_cost = case.cost[exp_idx]
    # Every unit sharing that top price counts as "the expensive tier".
    exp_tier = findall(c -> c >= exp_cost - 1e-9, case.cost)

    # --- storage -----------------------------------------------------------
    demand   = zeros(nscen); shedmw  = zeros(nscen); costv  = zeros(nscen)
    natlim   = zeros(Int, nscen); maxlmp = zeros(nscen); minlmp = zeros(nscen)
    expon    = falses(nscen); margc  = zeros(nscen)
    gdisp    = zeros(nscen, ngen(case))
    util     = zeros(nscen, nbranch(case))
    over_mw  = zeros(nscen, nbranch(case))     # unconstrained overload, MW over rating
    over_hit = falses(nscen, nbranch(case))
    nrebuild = 0                               # cold restarts forced by the solver

    @printf("  running %d scenarios on %s (%d buses, %d branches, %d gens)\n",
            nscen, case.name, case.nbus, nbranch(case), ngen(case))

    for s in 1:nscen
        D = sampler(rng, case)
        demand[s] = sum(D)

        set_demand!(mdl, case, D)
        optimize!(mdl.model)
        st = termination_status(mdl.model)

        # Warm-starting thousands of re-solves from the previous basis is what
        # makes this fast, but it can occasionally accumulate numerical trouble
        # and return OTHER_ERROR on an otherwise ordinary instance. The model is
        # always feasible by construction (shedding is unbounded above only by
        # D itself), so a non-optimal status here is a solver artefact, not a
        # physical result. Rebuild from scratch -- discarding the basis -- and
        # try once more before giving up.
        if st != MOI.OPTIMAL
            nrebuild += 1
            mdl = build_model(case)
            set_demand!(mdl, case, D)
            optimize!(mdl.model)
            st = termination_status(mdl.model)
        end
        st == MOI.OPTIMAL || error("scenario $s did not solve even after a cold " *
                                   "restart: $st (demand $(sum(D)) MW)")

        # JuMP hands back DenseAxisArrays; unwrap to plain vectors so the
        # numeric bookkeeping below is ordinary array work.
        Pv = collect(value.(mdl.P).data)
        Sv = collect(value.(mdl.S).data)
        Fv = collect(value.(mdl.F).data)
        gdisp[s, :] = Pv
        shedmw[s]   = sum(Sv)
        # Fuel bill only -- the VOLL penalty is an accounting device, not a cost
        # anyone actually pays, so it is excluded from the reported cost.
        costv[s]    = sum(case.cost[g] * Pv[g] for g in G)

        lmps      = [dual(mdl.cBal[i]) for i in N]
        maxlmp[s] = maximum(lmps); minlmp[s] = minimum(lmps)
        # The locational price AT THE REFERENCE BUS -- not the "system marginal
        # cost". Those coincide only in an uncongested, fully-served network.
        # Once any line binds, price is locational and there is no single system
        # price; once load is shed, the true marginal cost of energy is VOLL,
        # which this number does not show. Named for what it is.
        margc[s]  = lmps[case.slack]

        for l in L
            util[s, l] = abs(Fv[l]) / case.rate[l]
        end
        natlim[s] = count(>=(AT_LIMIT_TOL), @view util[s, :])
        expon[s]  = any(g -> Pv[g] > SHED_TOL, exp_tier)

        # --- paired unconstrained solve ------------------------------------
        if unconstrained_ref
            set_demand!(mdl_free, case_free, D)
            optimize!(mdl_free.model)
            if termination_status(mdl_free.model) != MOI.OPTIMAL
                mdl_free = build_model(case_free)
                set_demand!(mdl_free, case_free, D)
                optimize!(mdl_free.model)
            end
            if termination_status(mdl_free.model) == MOI.OPTIMAL
                Ff = collect(value.(mdl_free.F).data)
                for l in L
                    ov = abs(Ff[l]) - case.rate[l]
                    over_mw[s, l]  = max(ov, 0.0)
                    over_hit[s, l] = ov > 1e-6
                end
            end
        end

        progress_every > 0 && s % progress_every == 0 &&
            @printf("    %6d / %d   (shed so far: %.2f%%)\n",
                    s, nscen, 100 * count(>(SHED_TOL), @view shedmw[1:s]) / s)
    end

    # --- assemble scenario table ------------------------------------------
    scen = DataFrame(
        scen          = 1:nscen,
        demand_mw     = demand,
        shed_mw       = shedmw,
        shed          = shedmw .> SHED_TOL,
        served_mw     = demand .- shedmw,
        cost_usd      = costv,
        lmp_at_slack  = margc,
        n_at_limit    = natlim,
        max_lmp       = maxlmp,
        min_lmp       = minlmp,
        lmp_spread    = maxlmp .- minlmp,
        expensive_on  = expon)
    for g in G
        scen[!, Symbol("gen_", g)] = gdisp[:, g]
    end
    for l in L
        scen[!, Symbol("util_", l)] = util[:, l]
    end

    # --- per-branch summary ------------------------------------------------
    line_stats = DataFrame(
        branch = collect(L),
        from   = [case.bus_name[case.fbus[l]] for l in L],
        to     = [case.bus_name[case.tbus[l]] for l in L],
        rate_mw = case.rate,
        p_at_limit = [mean(@view(util[:, l]) .>= AT_LIMIT_TOL) for l in L],
        mean_util  = [mean(@view util[:, l]) for l in L],
        p95_util   = [quantile(@view(util[:, l]), 0.95) for l in L],
        p_overload_unconstrained = [mean(@view over_hit[:, l]) for l in L],
        mean_overload_mw = [mean(@view over_mw[:, l]) for l in L],
        max_overload_mw  = [maximum(@view over_mw[:, l]) for l in L])

    # --- per-generator summary --------------------------------------------
    gen_stats = DataFrame(
        gen  = collect(G),
        name = case.gen_name,
        bus  = [case.bus_name[case.gen_bus[g]] for g in G],
        pmax = case.pmax,
        cost = case.cost,
        p_dispatched   = [mean(@view(gdisp[:, g]) .> SHED_TOL) for g in G],
        mean_mw        = [mean(@view gdisp[:, g]) for g in G],
        capacity_factor = [mean(@view gdisp[:, g]) / case.pmax[g] for g in G])

    nrebuild > 0 && @printf("    (%d of %d scenarios needed a cold solver restart)\n",
                            nrebuild, nscen)

    return (scenarios = scen, line_stats = line_stats, gen_stats = gen_stats,
            case = case, expensive_idx = exp_idx, expensive_tier = exp_tier,
            nscen = nscen, seed = seed, n_cold_restarts = nrebuild)
end


# ===========================================================================
# 5. REPORTING
# ===========================================================================

"""Wilson score interval for a binomial proportion -- honest error bars on a
frequency estimated from a finite number of draws."""
function wilson(p::Float64, n::Int; z::Float64 = 1.96)
    d  = 1 + z^2 / n
    c  = (p + z^2 / (2n)) / d
    hw = z * sqrt(p * (1 - p) / n + z^2 / (4n^2)) / d
    return (max(0.0, c - hw), min(1.0, c + hw))
end

"""
    answer_the_three_questions(res; label)

Print the assignment's three questions and their Monte Carlo answers, with
95% confidence intervals so the reader can see how much of the last digit is
real and how much is sampling noise.
"""
function answer_the_three_questions(res; label = res.case.name)
    sc = res.scenarios; n = res.nscen; c = res.case

    println("\n" * "="^78)
    println(" MONTE CARLO RESULT -- $label")
    println("="^78)
    @printf("  scenarios          : %d   (seed %d)\n", n, res.seed)
    @printf("  installed capacity : %.1f MW\n", capacity(c))
    @printf("  mean demand drawn  : %.1f MW   (design mean %.1f MW)\n",
            mean(sc.demand_mw), sum(c.mu))
    @printf("  demand CV realised : %.3f\n", std(sc.demand_mw) / mean(sc.demand_mw))
    @printf("  demand p50 / p95 / p99 / max : %.0f / %.0f / %.0f / %.0f MW\n",
            quantile(sc.demand_mw, 0.50), quantile(sc.demand_mw, 0.95),
            quantile(sc.demand_mw, 0.99), maximum(sc.demand_mw))

    # --- Q: how often do we spin up the most expensive generator? ---------
    p_exp = mean(sc.expensive_on); lo, hi = wilson(p_exp, n)
    names_tier = join(c.gen_name[res.expensive_tier], ", ")
    println("\n  Q: HOW OFTEN DO WE SPIN UP THE MOST EXPENSIVE GENERATOR?")
    @printf("     unit(s)          : %s\n", names_tier)
    @printf("     marginal cost    : \$%.2f/MWh\n", c.cost[res.expensive_idx])
    @printf("     dispatched in    : %.2f%% of scenarios   (95%% CI %.2f-%.2f%%)\n",
            100p_exp, 100lo, 100hi)

    # --- Q: how often is the solution infeasible (load shedding)? ---------
    p_shed = mean(sc.shed); lo2, hi2 = wilson(p_shed, n)
    shedpos = sc.shed_mw[sc.shed]
    println("\n  Q: HOW OFTEN IS THE SOLUTION INFEASIBLE (LOAD SHEDDING)?")
    @printf("     shedding occurs  : %.2f%% of scenarios   (95%% CI %.2f-%.2f%%)\n",
            100p_shed, 100lo2, 100hi2)
    @printf("     expected unserved: %.2f MW per scenario (all draws)\n", mean(sc.shed_mw))
    if !isempty(shedpos)
        @printf("     when it happens  : mean %.1f MW, p95 %.1f MW, worst %.1f MW\n",
                mean(shedpos), quantile(shedpos, 0.95), maximum(shedpos))
        @printf("     energy not served: %.4f%% of total demand drawn\n",
                100 * sum(sc.shed_mw) / sum(sc.demand_mw))
    end

    # --- Q: how often do network elements get overloaded? -----------------
    println("\n  Q: HOW OFTEN DO ELEMENTS OF THE NETWORK GET OVERLOADED?")
    @printf("     scenarios with >=1 line at its limit : %.2f%%\n",
            100 * mean(sc.n_at_limit .> 0))
    @printf("     mean lines at limit per scenario     : %.2f of %d\n",
            mean(sc.n_at_limit), nbranch(c))
    ls = sort(res.line_stats, :p_at_limit, rev = true)
    println("\n     per-branch (ranked by how often the limit binds):")
    @printf("     %-4s %-14s %-14s %8s %10s %10s %12s\n",
            "br", "from", "to", "rate", "P(at lim)", "mean util", "P(over|free)")
    for r in eachrow(ls)
        @printf("     %-4d %-14s %-14s %8.0f %9.2f%% %10.3f %11.2f%%\n",
                r.branch, first(r.from, 14), first(r.to, 14), r.rate_mw,
                100r.p_at_limit, r.mean_util, 100r.p_overload_unconstrained)
    end

    # --- cost and price -----------------------------------------------------
    println("\n  COST AND PRICE DISTRIBUTION")
    @printf("     hourly cost  mean %.0f | p50 %.0f | p95 %.0f | p99 %.0f | max %.0f USD/h\n",
            mean(sc.cost_usd), quantile(sc.cost_usd, 0.50),
            quantile(sc.cost_usd, 0.95), quantile(sc.cost_usd, 0.99),
            maximum(sc.cost_usd))
    # The price spread is reported ONLY over scenarios that served all load.
    # In a shedding scenario the marginal bus prices at VOLL, so an unfiltered
    # "mean LMP spread" is really P(shed) x VOLL wearing a price label -- a
    # blackout counter, not a congestion statistic.
    served = sc[.!sc.shed, :]
    if nrow(served) > 0
        @printf("     LMP spread, no-shed scenarios only (%d of %d):\n", nrow(served), n)
        @printf("        mean %.1f | p95 %.1f | max %.1f USD/MWh\n",
                mean(served.lmp_spread), quantile(served.lmp_spread, 0.95),
                maximum(served.lmp_spread))
    else
        println("     LMP spread: every scenario shed load; no congestion-only price to report.")
    end
    println("="^78)
    return nothing
end

"""
    summary_row(res, label) -> DataFrame

One-line digest of a run, for stacking several experiments into a comparison
table.
"""
function summary_row(res, label)
    sc = res.scenarios; c = res.case
    served = sc[.!sc.shed, :]
    DataFrame(
        experiment      = label,
        network         = c.name,
        scenarios       = res.nscen,
        capacity_mw     = capacity(c),
        deliverable_mw  = deliverable_capacity(c).mw,
        design_mean_mw  = sum(c.mu),
        realised_mean_mw = mean(sc.demand_mw),
        demand_cv       = std(sc.demand_mw) / mean(sc.demand_mw),
        p_expensive_on  = mean(sc.expensive_on),
        p_shed          = mean(sc.shed),
        expected_shed_mw = mean(sc.shed_mw),
        ens_pct         = 100 * sum(sc.shed_mw) / sum(sc.demand_mw),
        p_any_at_limit  = mean(sc.n_at_limit .> 0),
        mean_lines_at_limit = mean(sc.n_at_limit),
        mean_cost_usd   = mean(sc.cost_usd),
        p95_cost_usd    = quantile(sc.cost_usd, 0.95),
        # congestion price spread, excluding shedding scenarios where the
        # marginal bus prices at VOLL -- see answer_the_three_questions
        mean_lmp_spread_served = nrow(served) > 0 ? mean(served.lmp_spread) : NaN)
end
