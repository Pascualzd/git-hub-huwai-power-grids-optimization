# The Dynamic (Multi-Period) Dispatch Problem

**Starting point:** the transport model in `OPT simple case/Code - work.jl`.
**What we add:** (1) demand that changes hour by hour, (2) generators that cannot
change their output instantly.

---

## 0. The one idea that changes everything

The static model is **one photograph**. You solve it, you get one answer, done.

The dynamic model is a **filmstrip of 24 photographs, welded together at the
edges**. The weld is the ramp constraint. Without the weld, you could solve each
frame separately and staple them together. With the weld, hour 14 constrains
hour 15, which constrains hour 16 — so the whole day must be solved **as one
object**.

```
        STATIC                          DYNAMIC
    ┌───────────┐              ┌────┐┌────┐┌────┐┌────┐
    │  1 frame  │              │ t1 ││ t2 ││ t3 ││ t4 │
    └───────────┘              └─┬──┘└─┬──┘└─┬──┘└─┬──┘
                                 └──┬──┘  ▲  └──┬──┘
     solve once                     └─────┴─────┘
                                  ramp welds: |p_t - p_{t-1}| <= R
                              solve all 24 hours simultaneously
```

**Mechanic's view of a ramp limit.** A generator is not a light switch. It is a
several-hundred-tonne turbine attached to a boiler full of superheated steam.
Ask it to go from 100 MW to 300 MW in five minutes and you thermally shock the
metal. So each machine comes with a rating: *"I will move at most `RU` MW per
hour upward and `RD` MW per hour downward."*

| Machine | The valve it behaves like | Typical ramp (% of capacity / hour) |
|---|---|---|
| Nuclear | A rusted-shut gate valve | ~5% |
| Coal | A heavy hand-wheel valve | 20–40% |
| Combined-cycle gas | A quarter-turn ball valve | 50–80% |
| Open-cycle gas / hydro | A light switch | 100%+ |
| Battery | A light switch, both directions | 100%+ |

---

## 1. Sets — the index cards

| Symbol | Set | The physical thing it counts |
|---|---|---|
| $i, j \in \mathcal{N}$ | buses | **junction boxes** — the places where wires meet and load hangs |
| $g \in \mathcal{G}$ | generators | **taps** you can open and close |
| $\mathcal{G}_i \subseteq \mathcal{G}$ | generators at bus $i$ | which taps are bolted to *this* junction box |
| $\ell \in \mathcal{L}$ | lines | **pipes** between junction boxes |
| $t \in \mathcal{T} = \{1,\dots,T\}$ | time periods | **frames of the filmstrip** — usually 24 hours |

Each line $\ell$ carries an orientation label — a "from" end $f(\ell)$ and a
"to" end $t(\ell)$ — painted on the pipe. It is **only a sign convention**: it
says which direction we will call positive, not which way power actually goes.

> **Notation caution.** $t$ is doing double duty above: $t$ the time index and
> $t(\ell)$ the to-bus of line $\ell$. In the code these are `t` and
> `branch.tbus`, which never collide. In the math below I write the to-bus as
> $\mathrm{to}(\ell)$ and the from-bus as $\mathrm{fr}(\ell)$ to keep them apart.

---

## 2. Parameters — the numbers stamped on the equipment

| Symbol | Units | Material analogy |
|---|---|---|
| $c_g$ | \$/MWh | the **price tag on the fuel** feeding tap $g$ |
| $\underline{P}_g,\ \overline{P}_g$ | MW | the **stops** on the tap: how far closed and how far open it physically goes |
| $RU_g$ | MW / period | how many turns of the hand-wheel you may make **upward** in one period |
| $RD_g$ | MW / period | the same wheel, turning **downward** |
| $P_g^{0}$ | MW | where the tap was set **the hour before the film starts** |
| $\overline{F}_\ell$ | MW | the **burst rating** of pipe $\ell$ |
| $D_{i,t}$ | MW | how much is being **drained** out of junction box $i$ during frame $t$ |
| $\Delta t$ | hours | **how long each frame lasts** (1 for hourly data) |
| $\text{VOLL}$ | \$/MWh | the fine for failing to deliver — "value of lost load" |

---

## 3. Decision variables — the knobs the optimiser is allowed to touch

| Symbol | Range | What you are physically setting |
|---|---|---|
| $p_{g,t}$ | $\ \ge 0$ | **how far open tap $g$ is during frame $t$** |
| $f_{\ell,t}$ | free (any sign) | **how much power is moving through pipe $\ell$**, positive = from $\mathrm{fr}(\ell)$ toward $\mathrm{to}(\ell)$ |
| $s_{i,t}$ | $\ \ge 0$ | *(safety valve)* **load deliberately not served** at bus $i$ in frame $t$ |

The variable grid is a **table with $T$ columns and $|\mathcal{G}|$ rows**. The
static model solved one column. The ramp constraints are the horizontal
handcuffs between neighbouring columns:

```
            t=1     t=2     t=3     ...     t=T
   gen 1   p_1,1 ═ p_1,2 ═ p_1,3 ═ ... ═ p_1,T      ═  ramp handcuff
   gen 2   p_2,1 ═ p_2,2 ═ p_2,3 ═ ... ═ p_2,T
   gen 3   p_3,1 ═ p_3,2 ═ p_3,3 ═ ... ═ p_3,T
             │       │       │               │
             └───────┴───────┴───────────────┘
              each COLUMN must also satisfy
              nodal balance + line limits
```

---

## 4. THE PROGRAM

### 4.1 Transport version (extends `Code - work.jl`)

$$
\min_{p,\;f,\;s}\quad
\underbrace{\sum_{t\in\mathcal{T}}\ \sum_{g\in\mathcal{G}} c_g\, p_{g,t}\,\Delta t}_{\text{fuel bill}}
\;+\;
\underbrace{\sum_{t\in\mathcal{T}}\ \sum_{i\in\mathcal{N}} \text{VOLL}\cdot s_{i,t}\,\Delta t}_{\text{penalty for blackouts}}
$$

**subject to**

$$
\textbf{(C1) Nodal balance}\qquad
\sum_{g\in\mathcal{G}_i} p_{g,t}\;-\;\bigl(D_{i,t}-s_{i,t}\bigr)
\;=\;
\sum_{\ell\,:\,\mathrm{fr}(\ell)=i} f_{\ell,t}
\;-\;
\sum_{\ell\,:\,\mathrm{to}(\ell)=i} f_{\ell,t}
\qquad \forall i\in\mathcal{N},\ \forall t\in\mathcal{T}
$$

$$
\textbf{(C2) Generator stops}\qquad
\underline{P}_g \;\le\; p_{g,t} \;\le\; \overline{P}_g
\qquad \forall g\in\mathcal{G},\ \forall t\in\mathcal{T}
$$

$$
\textbf{(C3) Pipe ratings}\qquad
-\,\overline{F}_\ell \;\le\; f_{\ell,t} \;\le\; \overline{F}_\ell
\qquad \forall \ell\in\mathcal{L},\ \forall t\in\mathcal{T}
$$

$$
\textbf{(C4) Ramp up}\qquad
p_{g,t} \;-\; p_{g,t-1} \;\le\; RU_g
\qquad \forall g\in\mathcal{G},\ \forall t\in\{2,\dots,T\}
$$

$$
\textbf{(C5) Ramp down}\qquad
p_{g,t-1} \;-\; p_{g,t} \;\le\; RD_g
\qquad \forall g\in\mathcal{G},\ \forall t\in\{2,\dots,T\}
$$

$$
\textbf{(C6) Initial condition}\qquad
p_{g,1} - P_g^{0} \le RU_g
\quad\text{and}\quad
P_g^{0} - p_{g,1} \le RD_g
\qquad \forall g\in\mathcal{G}
$$

$$
\textbf{(C7) Non-negativity}\qquad
p_{g,t}\ \ge\ 0,\qquad 0 \le s_{i,t} \le D_{i,t}
$$

That is the whole program. **(C4)–(C6) are the only new lines**; everything else
is the Part-1 transport model with a $t$ stapled onto every subscript.

### 4.2 What each constraint is doing, physically

| | Reads as | If you deleted it |
|---|---|---|
| **C1** | *"Whatever is poured into a junction box must leave it — through a load or through a pipe."* Kirchhoff's current law. | Power would appear from nowhere |
| **C2** | *"A tap cannot open past its stop."* | A 100 MW plant would produce 4000 MW |
| **C3** | *"A pipe cannot carry more than its rating."* | Lines would melt |
| **C4** | *"You cannot spin a turbine up faster than $RU$ per hour."* | Every hour would be independent again |
| **C5** | *"You cannot cool a boiler faster than $RD$ per hour."* | Cheap plants would flick on and off freely |
| **C6** | *"The film does not start from a blank screen — the plant was already running at $P^0$."* | Hour 1 would be a free lunch |
| **C7** | *"Taps do not suck; you cannot shed more load than exists."* | Nonsense solutions |

### 4.3 DC-OPF version (extends `OPT part 2.jl`)

Everything above holds. The only change is that you **stop choosing the flows
directly**. In the transport model $f_{\ell,t}$ was a free knob — power could be
routed anywhere, like traffic choosing a road. In the real grid it cannot:
power splits itself across every parallel path according to physics.

So introduce the **terrain variable**:

| Symbol | Units | Material analogy |
|---|---|---|
| $\theta_{i,t}$ | radians | the **height** of junction box $i$ during frame $t$ |
| $B_\ell = 1/x_\ell$ | per unit | the **diameter** of pipe $\ell$ (susceptance) |

and replace the free flow variable with a *derived* quantity:

$$
\textbf{(C8) Flow is a consequence, not a choice}\qquad
f_{\ell,t} \;=\; S_{\text{base}}\, B_\ell \left(\theta_{\mathrm{fr}(\ell),\,t} - \theta_{\mathrm{to}(\ell),\,t}\right)
\qquad \forall \ell,\ \forall t
$$

$$
\textbf{(C9) Sea level}\qquad
\theta_{\text{slack},\,t} \;=\; 0 \qquad \forall t
$$

**The picture.** The optimiser is no longer a traffic controller assigning trucks
to roads. It is a landscape architect. It raises and lowers the ground at each
junction; water (power) then runs downhill on its own, and the amount running
down any pipe is *diameter × height drop*. C9 just nails one corner of the
landscape to a fixed elevation so "height" has a reference — only differences
matter, exactly like measuring altitude from sea level.

Note that $\theta$ carries **no time coupling**. Only $p$ does. The terrain is
re-sculpted freely every hour; it is the *turbines* that have memory.

---

## 5. Size of the thing

| | Static (Part 2) | Dynamic, $T = 24$ |
|---|---|---|
| Generation variables | $\lvert\mathcal{G}\rvert$ | $24\,\lvert\mathcal{G}\rvert$ |
| Angle variables | $\lvert\mathcal{N}\rvert$ | $24\,\lvert\mathcal{N}\rvert$ |
| Balance constraints | $\lvert\mathcal{N}\rvert$ | $24\,\lvert\mathcal{N}\rvert$ |
| Line constraints | $2\lvert\mathcal{L}\rvert$ | $48\,\lvert\mathcal{L}\rvert$ |
| **Ramp constraints** | **0** | $\mathbf{2\,\lvert\mathcal{G}\rvert\,(T-1)}$ |

For IEEE 14-bus over a day: 120 generation vars, 336 angle vars, 336 balance
rows, 960 line rows, 230 ramp rows. Still a small LP — a few milliseconds. The
problem stays **linear**, so it is still convex and solvable to global optimality
by HiGHS. Nothing about ramping breaks that.

---

## 6. Three consequences worth knowing before you code it

**(a) Feasibility gets fragile.** The static model fails only if generation or
wires are insufficient. The dynamic model can also fail because the *slope* of
demand is too steep — the fleet simply cannot climb the morning ramp fast enough,
even though it has plenty of capacity. This is why $s_{i,t}$ (load shedding at
VOLL) is in the objective: it converts an unhelpful `INFEASIBLE` into an answer
that tells you **where and when** the system broke. Set VOLL high (e.g. \$1000–
\$10,000/MWh) so shedding is a last resort, never an economic choice.

**(b) Prices stop equalling marginal cost.** The dual of C1 is still the
locational marginal price, but now it also absorbs the ramp shadow prices. A
cheap generator that is *ramp-blocked* cannot set the price, so the LMP can
leave the range spanned by the generators' own marginal costs entirely.

> **Observed in `OPT part 4`.** With generators costing \$10/MWh and \$30/MWh,
> the price at bus 3 during hour 5 comes out at **−\$30/MWh**. Negative. The
> model is saying: *give me one more MW of load at 5 a.m. and my daily bill
> falls by \$30.* That is not a bug — adding load at 5 a.m. lets the slow cheap
> unit sit higher at 5 a.m., which puts it within ramp reach of a higher output
> at 7 a.m., displacing expensive fast generation later. The script verifies
> this by brute force: perturb $D_{3,5}$ by +1 MW, re-solve, and the objective
> moves by exactly −\$30.00, matching the dual. (Hour 24's dual is *degenerate*
> — the reported −\$30 is one of many valid duals; the true right-derivative is
> +\$2. Always sanity-check a surprising shadow price with a finite difference.)

**(c) The solution is anticipative.** Because all 24 hours are solved at once,
the model *knows the future*. It will hold an expensive plant part-loaded at
3 a.m. purely so it can reach the 7 a.m. peak in time — behaviour that is
invisible and impossible in the static model. That is the single best argument
for building the dynamic version.

---

## 7. Natural next extensions

| Add | New variable | New constraint | Still an LP? |
|---|---|---|---|
| **Storage / battery** | $e_{b,t}$ state of charge, $ch_{b,t}$, $dis_{b,t}$ | $e_{b,t} = e_{b,t-1} + \eta\, ch_{b,t} - dis_{b,t}/\eta$ | Yes |
| **Reserves** | $r_{g,t}$ | $\sum_g r_{g,t} \ge R_t$, $p_{g,t}+r_{g,t}\le \overline{P}_g$ | Yes |
| **Minimum up/down time** | $u_{g,t}\in\{0,1\}$ | $p_{g,t} \le \overline{P}_g u_{g,t}$, plus min-run logic | **No — becomes a MILP** |
| **Startup costs** | $v_{g,t}\in\{0,1\}$ | $v_{g,t}\ge u_{g,t}-u_{g,t-1}$ | **No — MILP** |

Adding a binary $u_{g,t}$ turns this into the **unit commitment** problem, which
is the standard next chapter after dynamic economic dispatch. Everything through
storage and reserves stays linear and cheap.

---

## 8. Mapping to JuMP

| Math | JuMP |
|---|---|
| $p_{g,t}$ | `@variable(m, 0 <= P[g in G, t in T] <= gen[g,:pmax])` |
| C1 | `@constraint(m, cBal[i in N, t in T], ...)` |
| C4 | `@constraint(m, cRampUp[g in G, t in 2:T], P[g,t] - P[g,t-1] <= RU[g])` |
| C5 | `@constraint(m, cRampDn[g in G, t in 2:T], P[g,t-1] - P[g,t] <= RD[g])` |
| C6 | `@constraint(m, cInit[g in G], P[g,1] - P0[g] <= RU[g])` |
| C8 | `@expression(m, FLOW[l in L, t in T], baseMVA*branch[l,:sus]*(TH[fbus,t]-TH[tbus,t]))` |

A runnable version of exactly this program is in
`OPT part 4 - dynamic ramping.jl`.
