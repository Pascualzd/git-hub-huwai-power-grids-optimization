# =====================================================================
# Set 9 -- commitment.jl
#
# A chronological unit-commitment + economic-dispatch model on the Set 8
# network, built as a LADDER so each constraint's effect is attributable.
#
#   :lp     Set 8's constraint set.  0 <= P <= pmax.  Hours do not interact.
#   :pmin   + binary commitment and minimum stable generation.
#   :ramp   + hour-to-hour ramp limits.
#   :full   + minimum up/down times and start-up costs.
#
# Running the ladder rather than jumping straight to :full is the point.
# Set 8's own lesson is that changing several things at once produces a
# number you cannot attribute. Each rung here changes exactly one thing.
#
# WHY THIS MODEL NEEDS TIME AND SET 8 DID NOT
# Ramp limits couple hour t to hour t-1. Minimum up/down times couple a
# decision to the several hours after it. Set 8 sampled hours independently
# WITH REPLACEMENT -- hour 5,000 could follow hour 12 -- so there was no
# "previous hour" for a ramp constraint to attach to. Set 9 therefore walks
# the 8,760 hours of the filed profile in their real order. That is not a
# refinement of Set 8's design; it is a different design.
# =====================================================================

using JuMP, HiGHS

const MIP_GAP          = 0.01   # 1% -- see the note in solve_block
const BLOCK_TIME_LIMIT = 20.0   # seconds per 24-hour block

"""
    solve_block(case, demand, level; u0, p0, up0, down0, silent=true)

Solve one chronological block of hours.

`demand[i, t]` is the MW wanted at bus i in hour t of the block. Taking a
full bus-by-hour matrix rather than an island total is what lets every demand
version reach the same solver unchanged: v1 and v2 are a frozen share vector
times an island total, so their direction cannot move; v3 and the exponential
draw both move magnitude and direction together. All must be expressible.

Carried state, so consecutive blocks join up properly:
  `u0`    commitment of each unit in the hour before the block
  `p0`    output of each unit in the hour before the block
  `up0`   consecutive hours each unit had been ON  entering the block
  `down0` consecutive hours each unit had been OFF entering the block

Returns a NamedTuple of per-hour results plus the state to carry forward.
"""
function solve_block(case, demand::AbstractMatrix{Float64}, level::Symbol;
                     u0::Vector{Int}, p0::Vector{Float64},
                     up0::Vector{Int}, down0::Vector{Int},
                     silent::Bool = true)

    G = 1:length(case.pmax)
    N = 1:case.nbus
    L = 1:length(case.rate)
    T = 1:size(demand, 2)

    binaries = level != :lp
    use_ramp = level in (:ramp, :full)
    use_time = level == :full

    # A 1% optimality gap and a per-block time limit are not laziness. Under
    # the exponential demand the fleet is being asked to follow swings it
    # physically cannot, so shedding at VOLL is the only escape and the MILP
    # becomes very hard to prove optimal. A near-optimal answer in seconds is
    # worth far more here than a proven-optimal one in hours, and every block
    # that hits the limit is counted and reported rather than hidden.
    m = Model(HiGHS.Optimizer)
    silent && set_silent(m)
    set_optimizer_attribute(m, "mip_rel_gap", MIP_GAP)
    set_optimizer_attribute(m, "time_limit", BLOCK_TIME_LIMIT)

    @variable(m, P[G, T] >= 0)
    @variable(m, THETA[N, T])
    @variable(m, S[N, T] >= 0)                       # load shed, priced at VOLL

    if binaries
        @variable(m, u[G, T], Bin)                   # 1 if the unit is running
        @variable(m, 0 <= v[G, T] <= 1)              # start-up indicator
        @variable(m, 0 <= w[G, T] <= 1)              # shut-down indicator
    end

    # ---- generation limits -------------------------------------------
    if binaries
        # A committed unit must produce AT LEAST its minimum stable output.
        # This is the constraint Set 8 could not express: with 0 <= P <= pmax
        # a 128 MW steam unit was free to idle at 3 MW.
        @constraint(m, [g in G, t in T], P[g, t] >= case.pmin[g] * u[g, t])
        @constraint(m, [g in G, t in T], P[g, t] <= case.pmax[g] * u[g, t])
    else
        @constraint(m, [g in G, t in T], P[g, t] <= case.pmax[g])
    end

    # ---- DC power flow, identical to Set 8 ---------------------------
    @expression(m, F[l in L, t in T],
        BASE_MVA * case.sus[l] * (THETA[case.fbus[l], t] - THETA[case.tbus[l], t]))

    @constraint(m, [t in T], THETA[case.slack, t] == 0)

    @constraint(m, cBal[i in N, t in T],
        sum(P[g, t] for g in G if case.gen_bus[g] == i; init = 0.0)
        + S[i, t]
        - sum(F[l, t] for l in L if case.fbus[l] == i; init = 0.0)
        + sum(F[l, t] for l in L if case.tbus[l] == i; init = 0.0)
        == demand[i, t])

    @constraint(m, cLine[l in L, t in T],
        -case.rate[l] <= F[l, t] <= case.rate[l])

    # ---- ramping -----------------------------------------------------
    # The first hour of the block ramps from p0, the carried state, so the
    # constraint holds across the block boundary and not just inside it.
    #
    # START-UP RAMPING IS SEPARATE, AND MUST BE.
    # On this fleet every steam unit has p_min = 40% of capacity but a ramp
    # rate of 30% per hour. A naive |P[t] - P[t-1]| <= ramp therefore makes
    # those units PERMANENTLY UNSTARTABLE: coming online means jumping from
    # 0 to p_min in one hour, which exceeds the ramp. The model then runs
    # expensive fast peakers forever and sheds load, which is an artefact of
    # the formulation and not a fact about the grid.
    #
    # The standard fix: a unit starting up (v=1) or shutting down (w=1) may
    # move by its start-up ramp capability instead, taken here as the larger
    # of p_min and the normal ramp -- i.e. it arrives at its minimum output.
    if use_ramp
        SU = [max(case.pmin[g], case.ramp[g]) for g in G]
        @constraint(m, [g in G],
            P[g, first(T)] - p0[g] <= case.ramp[g] * u0[g] + SU[g] * v[g, first(T)])
        @constraint(m, [g in G],
            p0[g] - P[g, first(T)] <= case.ramp[g] * u[g, first(T)] + SU[g] * w[g, first(T)])
        @constraint(m, [g in G, t in T; t > first(T)],
            P[g, t] - P[g, t-1] <= case.ramp[g] * u[g, t-1] + SU[g] * v[g, t])
        @constraint(m, [g in G, t in T; t > first(T)],
            P[g, t-1] - P[g, t] <= case.ramp[g] * u[g, t] + SU[g] * w[g, t])
    end

    # ---- commitment logic, minimum up/down times ---------------------
    if binaries
        # v and w are the start and stop events implied by the u sequence.
        @constraint(m, [g in G], u[g, first(T)] - u0[g] == v[g, first(T)] - w[g, first(T)])
        @constraint(m, [g in G, t in T; t > first(T)],
            u[g, t] - u[g, t-1] == v[g, t] - w[g, t])
    end

    if use_time
        for g in G, t in T
            mu, md = case.minup[g], case.mindown[g]
            # Having started at or after (t - minup + 1), the unit is still on at t.
            @constraint(m, sum(v[g, s] for s in T if s <= t && s > t - mu) <= u[g, t])
            # Having stopped in that window, it is still off at t.
            @constraint(m, sum(w[g, s] for s in T if s <= t && s > t - md) <= 1 - u[g, t])
        end
        # Honour time already served entering the block: a unit that has not
        # yet met its minimum up time cannot be shut off in the first hours.
        for g in G
            mu, md = case.minup[g], case.mindown[g]
            if u0[g] == 1 && up0[g] < mu
                for t in first(T):min(last(T), first(T) + (mu - up0[g]) - 1)
                    @constraint(m, u[g, t] == 1)
                end
            elseif u0[g] == 0 && down0[g] < md
                for t in first(T):min(last(T), first(T) + (md - down0[g]) - 1)
                    @constraint(m, u[g, t] == 0)
                end
            end
        end
    end

    # ---- objective ---------------------------------------------------
    fuel = @expression(m,
        sum((case.cost[g] + g * TIEBREAK) * P[g, t] for g in G, t in T))
    shed = @expression(m, VOLL * sum(S[i, t] for i in N, t in T))
    obj  = use_time ?
        @expression(m, fuel + shed + sum(case.startup[g] * v[g, t] for g in G, t in T)) :
        @expression(m, fuel + shed)
    @objective(m, Min, obj)

    optimize!(m)
    st = termination_status(m)
    # A time-limited solve that still found a feasible incumbent is usable;
    # `capped` records that it was not proven optimal.
    proven = st in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
    usable = proven || (st == MOI.TIME_LIMIT && primal_status(m) == MOI.FEASIBLE_POINT)
    usable || return (ok = false, status = st, capped = false)
    capped = !proven

    Pv = value.(P); Sv = value.(S); Fv = value.(F)
    uv = binaries ? round.(Int, value.(u)) : ones(Int, length(G), length(T))

    # per-hour summaries
    nT       = length(T)
    tot_gen  = [sum(Pv[g, t] for g in G) for t in T]
    tot_shed = [sum(Sv[i, t] for i in N) for t in T]
    cost_h   = [sum(case.cost[g] * Pv[g, t] for g in G) for t in T]
    atlim    = [sum(abs(Fv[l, t]) >= 0.999 * case.rate[l] for l in L) for t in T]
    # is the priciest committed unit the priciest in the fleet?
    gmax     = argmax(case.cost)
    exp_on   = [Pv[gmax, t] > 1e-6 for t in T]
    n_on     = [sum(uv[g, t] for g in G) for t in T]
    starts   = binaries ?
        [sum(round(Int, value(v[g, t])) for g in G) for t in T] : zeros(Int, nT)

    # state to carry into the next block
    last_t = last(T)
    u_end  = [uv[g, last_t] for g in G]
    p_end  = [Pv[g, last_t] for g in G]
    up_end   = zeros(Int, length(G))
    down_end = zeros(Int, length(G))
    for g in G
        if u_end[g] == 1
            c = 0
            for t in reverse(T); uv[g, t] == 1 ? (c += 1) : break; end
            up_end[g] = c + (c == nT && u0[g] == 1 ? up0[g] : 0)
        else
            c = 0
            for t in reverse(T); uv[g, t] == 0 ? (c += 1) : break; end
            down_end[g] = c + (c == nT && u0[g] == 0 ? down0[g] : 0)
        end
    end

    return (ok = true, status = st, capped = capped,
            gen = tot_gen, shed = tot_shed, cost = cost_h,
            at_limit = atlim, expensive_on = exp_on,
            n_on = n_on, starts = starts,
            P = Pv, u = uv,
            u_end = u_end, p_end = p_end, up_end = up_end, down_end = down_end)
end

"""
    run_year(case, demand, level; block=24, days=365)

Walk a bus-by-hour demand matrix in order, solving one block at a time and
carrying commitment state forward. `block=24` is a day-ahead horizon, which
is how the decision is actually made.
"""
function run_year(case, demand::AbstractMatrix{Float64}, level::Symbol;
                  block::Int = 24, days::Int = 365, verbose::Bool = true)
    G = length(case.pmax)
    nH = min(days * block, size(demand, 2))

    # Start the year from a plausible state rather than a cold grid: the
    # cheap must-run units already on, everything else off.
    u0    = [case.gen_tech[g] == "municipal_waste" ? 1 : 0 for g in 1:G]
    p0    = [u0[g] == 1 ? case.pmin[g] : 0.0 for g in 1:G]
    up0   = [u0[g] == 1 ? 100 : 0 for g in 1:G]
    down0 = [u0[g] == 0 ? 100 : 0 for g in 1:G]

    gen = Float64[]; shed = Float64[]; cost = Float64[]
    atl = Int[];     eon  = Bool[];    non = Int[]; sts = Int[]
    nfail = 0; ncap = 0

    nblocks = nH ÷ block
    for b in 1:nblocks
        rng = ((b-1)*block + 1):(b*block)
        D = @view demand[:, rng]
        r = solve_block(case, D, level;
                        u0 = u0, p0 = p0, up0 = up0, down0 = down0)
        if !r.ok
            nfail += 1
            # Fall back to the unconstrained rung for this block so the year
            # completes; counted and reported rather than silently patched.
            r = solve_block(case, D, :lp;
                            u0 = u0, p0 = p0, up0 = up0, down0 = down0)
            r.ok || error("block $b failed even as :lp ($(r.status))")
        end
        r.capped && (ncap += 1)
        append!(gen, r.gen); append!(shed, r.shed); append!(cost, r.cost)
        append!(atl, r.at_limit); append!(eon, r.expensive_on)
        append!(non, r.n_on); append!(sts, r.starts)
        u0, p0, up0, down0 = r.u_end, r.p_end, r.up_end, r.down_end
        verbose && b % 60 == 0 && println("    ... block $b / $nblocks")
    end

    return (level = level, hours = length(gen),
            gen = gen, shed = shed, cost = cost,
            at_limit = atl, expensive_on = eon, n_on = non, starts = sts,
            nfail = nfail, ncapped = ncap)
end
