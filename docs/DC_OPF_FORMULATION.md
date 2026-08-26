# Network dispatch on Oʻahu: transportation and DC optimal power flow

This note formulates the economic-dispatch problem with **network structure** — multiple
sources, multiple sinks, and transport over a graph — and situates DC optimal power flow
(DC-OPF) against the simpler transportation model. It is meant to be read on its own; the
implementation is `src/NetworkDispatch.jl` and the data is built by
`scripts/prepare_network.py`.

The starting point is the copper-plate economic dispatch already in this repository
(`src/EconomicDispatch.jl`), which enforces one island-wide supply-equals-demand equation and
has no notion of *where* anything sits. We extend it in two steps and keep all three side by
side, because the differences between them are the whole point.

---

## 0. Three models, one picture

| Model | Flows are… | Enforces | New in this model |
|---|---|---|---|
| **Copper plate** | ignored | one island-wide balance | — |
| **Transportation** | free decision variables | per-bus balance + line limits | you can send power any route, but lines have finite capacity |
| **DC-OPF** | *determined* by physics | the above + Kirchhoff's voltage law | flow on each line is fixed by voltage angles and reactances, not chosen |

Their feasible sets nest strictly,

$$\mathcal{X}_{\text{DC-OPF}} \subseteq \mathcal{X}_{\text{transport}} \subseteq \mathcal{X}_{\text{copper}},$$

so their minimized costs are ordered

$$z^\star_{\text{copper}} \le z^\star_{\text{transport}} \le z^\star_{\text{DC-OPF}}.$$

Two differences carry the economic meaning:

- $z^\star_{\text{transport}} - z^\star_{\text{copper}}$ is the **cost of congestion** — what
  finite line capacity costs you.
- $z^\star_{\text{DC-OPF}} - z^\star_{\text{transport}}$ is the **cost of loop flow** — what the
  laws of physics cost you *on top of* capacity limits, because you cannot freely route power
  on a meshed AC grid the way you can route trucks on a road network.

That second gap is the reason a power grid is not a pipeline network, and it is why the
professor's "transport costs on a graph" framing, while the right starting intuition, is not
the whole story for electricity.

---

## 1. Where DC-OPF comes from

The exact real-power flow from bus $i$ into line $ij$ in an AC network is

$$P_{ij} = V_i^2 g_{ij} - V_i V_j\left(g_{ij}\cos\theta_{ij} + b_{ij}\sin\theta_{ij}\right),
\qquad \theta_{ij} = \theta_i - \theta_j,$$

where $V$ are voltage magnitudes, $\theta$ are voltage angles, and $g_{ij} + \mathrm{j}\,b_{ij}$
is the series admittance of the line. This is nonlinear and non-convex. DC-OPF applies three
standard approximations, each with a clear consequence:

- **A1 — flat voltage magnitudes.** $|V_i| \approx 1.0$ per unit everywhere. This removes
  voltage magnitude as a decision variable and decouples real power from reactive power.
- **A2 — small angle differences.** $\sin\theta_{ij} \approx \theta_{ij}$ and
  $\cos\theta_{ij} \approx 1$. This removes the trigonometric nonlinearity.
- **A3 — lines are nearly lossless.** For transmission conductors $r_{ij} \ll x_{ij}$, so
  $g_{ij} \approx 0$ and $b_{ij} \approx -1/x_{ij}$.

Substituting collapses the expression to a linear relation between line flow and the angle
difference across the line:

$$\boxed{\,P_{ij} = \frac{\theta_i - \theta_j}{x_{ij}}\,}$$

(in per-unit; multiply by the system base MVA to get MW). The result is an LP: convex, fast,
and — crucially for economics — it yields meaningful dual variables (prices).

**What is given up.** DC-OPF has no losses (real Oʻahu transmission-and-distribution losses run
about 5–6%), no voltage or reactive-power limits, no contingency (N-1) security unless it is
added explicitly, and no representation of frequency, inertia, or stability limits — the last of
which is a live operating constraint on a small island grid with high inverter-based
penetration. DC-OPF is the standard *economic* screening model, not a reliability model.

---

## 2. Sets, indices, and parameters

| Symbol | Meaning |
|---|---|
| $n \in \mathcal{N}$ | buses (nodes); 9 in the Oʻahu model |
| $\ell \in \mathcal{L}$ | branches (lines), each with a reference orientation $\mathrm{fr}(\ell) \to \mathrm{to}(\ell)$ |
| $g \in \mathcal{G}$ | generators; $\mathcal{G}_n \subseteq \mathcal{G}$ are those located at bus $n$ |
| $t \in \mathcal{T}$ | hours in the dispatch horizon |
| $c_g$ | variable cost of generator $g$ (\$/MWh) |
| $P^{\min}_g,\ P^{\max}_g$ | minimum and maximum output of $g$ (MW) |
| $R_g$ | ramp limit of $g$ (MW/h) |
| $d_{n,t}$ | demand at bus $n$ in hour $t$ (MW) |
| $x_\ell$ | series reactance of line $\ell$ (per unit); $B_\ell = 1/x_\ell$ is its susceptance |
| $\bar{F}_\ell$ | thermal (capacity) limit of line $\ell$ (MW) |
| $w_\ell$ | transport cost on line $\ell$ (\$ per MWh flowed) |
| $\text{VOLL}$ | value of lost load (\$/MWh); the price of shedding |
| $n_0$ | reference (slack) bus |
| $S_{\text{base}}$ | system base power, 100 MVA |

The graph is directed only by convention: $f_\ell > 0$ means flow runs from $\mathrm{fr}(\ell)$
to $\mathrm{to}(\ell)$, and $f_\ell < 0$ means it runs the other way.

---

## 3. Decision variables

$$
\begin{aligned}
y_{g,t} &\in [P^{\min}_g,\ P^{\max}_g] && \text{generator output (MW)}\\
f_{\ell,t} &\in \mathbb{R} && \text{signed line flow (MW)}\\
f^{+}_{\ell,t},\ f^{-}_{\ell,t} &\ge 0 && \text{positive / negative parts of the flow}\\
\theta_{n,t} &\in \mathbb{R} && \text{bus voltage angle (radians) — DC-OPF only}\\
r_{n,t} &\in [0,\ d_{n,t}] && \text{load shed at bus } n \text{ (MW)}
\end{aligned}
$$

Two modeling choices deserve a word:

- The **split** $f_\ell = f^+_\ell - f^-_\ell$ lets the objective price the *magnitude* of flow,
  $|f_\ell| = f^+_\ell + f^-_\ell$, while keeping everything linear.
- **Load shedding** $r_{n,t}$ is carried in every model, priced at a very high VOLL. It is a
  modeling safety valve: rather than returning "infeasible" when the network physically cannot
  deliver enough power to a bus, the model serves what it can and reports *where* and *how much*
  it fell short. In a well-built base case $r \equiv 0$; a positive $r$ is a finding, not noise.

---

## 4. Objective

Minimize total system cost over the horizon:

$$
\min\ \sum_{t \in \mathcal{T}} \left[
\underbrace{\sum_{g \in \mathcal{G}} c_g\, y_{g,t}}_{\text{generation}}
\;+\;
\underbrace{\sum_{\ell \in \mathcal{L}} w_\ell \left(f^{+}_{\ell,t} + f^{-}_{\ell,t}\right)}_{\text{transport}}
\;+\;
\underbrace{\sum_{n \in \mathcal{N}} \text{VOLL}\cdot r_{n,t}}_{\text{unserved energy}}
\right]
$$

The copper-plate model has no flow variables, so its objective keeps only the generation and
shedding terms.

---

## 5. Constraints

The three models differ only in which of these blocks are active. A check mark means the
constraint is present.

| | Constraint | copper | transport | DC-OPF |
|---|---|:-:|:-:|:-:|
| **C0** | System balance: $\displaystyle\sum_{g} y_{g,t} + \sum_n r_{n,t} = \sum_n d_{n,t}$ | ✓ | — | — |
| **C1** | Nodal balance: $\displaystyle\sum_{g \in \mathcal{G}_n}\! y_{g,t} + \!\!\sum_{\ell:\,\mathrm{to}(\ell)=n}\!\! f_{\ell,t} - \!\!\sum_{\ell:\,\mathrm{fr}(\ell)=n}\!\! f_{\ell,t} + r_{n,t} = d_{n,t}$ | — | ✓ | ✓ |
| **C2** | Thermal limit: $-\bar{F}_\ell \le f_{\ell,t} \le \bar{F}_\ell$ | — | ✓ | ✓ |
| **C3** | Output bounds: $P^{\min}_g \le y_{g,t} \le P^{\max}_g$ | ✓ | ✓ | ✓ |
| **C4** | Ramping: $-R_g \le y_{g,t+1} - y_{g,t} \le R_g$ | ✓ | ✓ | ✓ |
| **C5** | Flow split: $f_{\ell,t} = f^{+}_{\ell,t} - f^{-}_{\ell,t}$ | — | ✓ | ✓ |
| **C6** | **DC power flow:** $f_{\ell,t} = S_{\text{base}}\, B_\ell \left(\theta_{\mathrm{fr}(\ell),t} - \theta_{\mathrm{to}(\ell),t}\right)$ | — | — | ✓ |
| **C7** | Reference angle: $\theta_{n_0,t} = 0$ | — | — | ✓ |
| **C8** | Shedding bound: $0 \le r_{n,t} \le d_{n,t}$ | ✓ | ✓ | ✓ |

**C1 is the network generalization of the old single balance.** It says: at every bus and every
hour, local generation, plus imports on incoming lines, minus exports on outgoing lines, plus any
shed load, equals local demand. Summing C1 over all buses recovers exactly C0 (the flow terms
cancel), which is why copper plate is the special case of one aggregated node.

**C6 is the entire difference between the two network models.** Read it carefully:

- In the **transportation** model, C6 is absent. Flow $f_\ell$ is a free decision — the optimizer
  routes power along whichever lines are cheapest, subject only to the capacity limits C2. This
  is a classic min-cost network flow problem, exactly the "transport costs on a graph" picture.
- In **DC-OPF**, C6 is present, and flow is *no longer chosen*. Once the injections
  $y - d + r$ are fixed, the angles $\theta$ and hence every line flow are pinned down by the
  reactances. On a meshed network, power divides across parallel paths in inverse proportion to
  their reactances, whether or not that split is economically convenient. You do not get to send
  it "the cheap way."

A corollary that is easy to miss: **with C6 present, the transport cost $w_\ell$ no longer routes
anything.** It still changes *which generators run* — because generation decisions move the
injections, which move the flows — but it cannot redirect a given flow around the network. In the
transportation model, $w_\ell$ genuinely routes power. The same parameter means two different
things in the two models. (In the Oʻahu study $w_\ell$ is small — a modeled loss/wheeling proxy,
not a tariff — so it perturbs the merit order only slightly; the dominant network effect is the
capacity and physics of the lines, not their per-MWh price.)

---

## 6. Prices: locational marginal cost

The dual variable $\lambda_{n,t}$ on the nodal balance C1 is the **locational marginal price
(LMP)** at bus $n$: the cost of serving one more MW of demand there. In the copper-plate model
there is a single dual on C0, so every bus shares one price. Add the network and two things
happen:

- Where lines are uncongested, LMPs stay equal — power flows freely enough to arbitrage the
  price difference away.
- Where a line binds (C2 active), the LMPs on its two sides *separate*. The spread equals the
  shadow price $\mu_\ell$ of the binding line — the marginal value of one more MW of capacity on
  it.

Under C6 there is a subtlety with no analogue in the transportation model: the congestion rent
of a single binding line redistributes across **every** line in a loop containing it, because
relieving that line requires re-steering flow around the whole loop. This loop coupling is
precisely what a transportation model cannot represent, and it is why DC-OPF LMPs can look
counterintuitive (a bus far from the binding line still sees a price change).

---

## 7. Equivalent PTDF form (documented, not implemented)

The angle variables can be eliminated. Let $A$ be the branch-to-node incidence matrix and
$B_d = \operatorname{diag}(B_\ell)$. The reduced bus susceptance matrix (dropping the reference
row/column) is $\mathbf{B}_{\text{bus}} = A^\top B_d A$, and line flows relate to net nodal
injections $p_{\text{inj}}$ by

$$f = B_d\, A\, \mathbf{B}_{\text{bus}}^{-1}\, p_{\text{inj}} = H\, p_{\text{inj}},$$

where $H$ is the matrix of **power transfer distribution factors (PTDFs)**. This is the same LP
with fewer variables, and it is the natural home for N-1 contingency constraints (via line outage
distribution factors). We keep the angle form C6/C7 in code because it reads directly next to the
math and needs no matrix inverse — at nine buses the variable count is trivial.

---

## 8. Predicted result, and what actually happened

**The prediction (written before running).** Oʻahu's generation is concentrated on the leeward
(west) side; urban Honolulu is a large sink with no local thermal generation. So I expected the
southern import corridor into Honolulu to bind first, Honolulu's LMP to rise above the island
price, and a cheap west-side unit to be backed down in favor of a more expensive unit that can
actually reach town.

**What the model returned** (peak hour, 1,054 MW island net load; full numbers in
`data/processed/analysis_summary.csv` and `network_cost_comparison.csv`):

| Quantity | Copper plate | Transportation | DC-OPF |
|---|---:|---:|---:|
| Total peak-hour cost | \$117,913 | \$123,751 | \$131,690 |
| Single system price / LMP span | \$134/MWh | \$126–224/MWh | \$126–456/MWh |
| Unserved energy | 0 | 0 | 0 |

- **Cost of congestion** = \$123,751 − \$117,913 = **\$5,839/h**
- **Cost of loop flow** = \$131,690 − \$123,751 = **\$7,938/h**
- Over the full 24-hour peak day: \$2.115M → \$2.165M → \$2.193M (same ordering).

The prediction was **directionally right but wrong on the specific bottleneck.** The line that
actually binds is not the southern tie into Honolulu — it is **Kahe → Waiʻanae**, the single
138 kV circuit forming the north corridor out of the island's largest power plant (Kahe, 582 MW).
Kahe is the cheapest generator at \$126/MWh and wants to run flat out, but it can only push
200 MW northward on that one circuit. So the northern and windward loads cannot all be served by
cheap Kahe power, and the LMP climbs steadily away from the generation:

- Cheapest at **Kahe (\$126)** and **Ewa-West (\$157)** — the generation buses.
- **Honolulu \$255** — above the island price of \$134, exactly as predicted, just not the
  extreme.
- Highest at **Waiʻanae (\$456)**, the load stranded directly behind the binding line.

So Honolulu's price does rise above the copper-plate λ, but the tightest constraint is the export
capacity *out of the cheapest plant*, not the import capacity *into the biggest city*. That is a
more interesting finding than the prediction, and it is the kind of thing the network model exists
to surface: the binding constraint was not where intuition first pointed.

**Loosening and tightening the binding line** (`network_congestion_sweep.csv`,
`figures/congestion_sensitivity.png`) confirms the mechanism. Widening Kahe → Waiʻanae past
~250 MW makes the congestion nearly vanish; tightening it drives congestion and loop-flow costs
up smoothly until, below about 180 MW, DC-OPF can no longer physically serve the north side and
begins shedding load — a delivery failure the transportation model masks by rerouting power the
physics does not permit.

---

## 9. How this maps to the code

Everything above is in `src/NetworkDispatch.jl`, with variable names chosen to match this
document: `y` for generation, `f` for flow, `θ` for angle, `r` for shed load. A single function
`solve_network_dispatch(...; mode)` builds C0/C1, C2, C6/C7 conditionally on
`mode ∈ (:copper, :transport, :dcopf)`, so the three models are genuinely the same code with
constraint blocks switched on and off — which is what makes the cost comparison honest. The
solver's solution is then re-checked independently: nodal balance at every bus, thermal limits,
ramp limits, and — for DC-OPF — that every flow recomputes correctly from the solved angles
(the KVL residual), plus the theoretical ordering
$z_{\text{copper}} \le z_{\text{transport}} \le z_{\text{DC-OPF}}$ itself as a regression test.

The network dataset (`scripts/prepare_network.py`, documented in `SOURCES.md`) is a stylized
9-bus representation of Oʻahu: seven judicial-district load zones from the 2020 Census, with the
generation-heavy Ewa district split so the leeward plants sit at distinct nodes, wired as the
two-corridor ring that Hawaiian Electric describes. Bus loads, plant locations, and topology come
from real data; the per-line electrical parameters (reactance, rating, transport cost) are
labeled technology assumptions, exactly as the generator table's minimum-output and ramp values
are. The point of the model is the *structure* — sources, sinks, corridors, loops — not a
claim to be Hawaiian Electric's actual network.

---

## 10. Relation to the course manual

This formulation is the one taught in the assigned reference, the *Power Systems Optimization*
course notebook
[`06-Optimal-Power-Flow.ipynb`](https://github.com/Power-Systems-Optimization-Course/power-systems-optimization/blob/master/Notebooks/06-Optimal-Power-Flow.ipynb)
(Jenkins & Davidson). That notebook builds the same transportation and DC-OPF models in Julia
with JuMP and HiGHS, on a 3-bus teaching case and then the IEEE 14-bus system. We use the same
objective, the same DC power-flow equation, the same slack-bus convention, and the same
LMP-as-constraint-dual definition; only the symbols differ, because our variable names follow the
economic-dispatch lecture the rest of this project is built around.

| This document / `src/NetworkDispatch.jl` | Course notebook | Meaning |
|---|---|---|
| $y_{g,t}$ | `GEN[g]` | generator output |
| $f_{\ell,t}$ | `FLOW[l]` | signed line flow |
| $\theta_{n,t}$ | `THETA[i]` | bus voltage angle |
| $r_{n,t}$ | *(none)* | load shed — our addition, a feasibility safety valve |
| C1 nodal balance | `cBalance[i]` | supply = demand at each bus |
| C2 thermal limit | `cLineLimits[l]` | $\pm\bar F_\ell$ |
| C6 DC power flow | `cLineFlows[l]` | $f = S_{\text{base}} B_\ell (\theta_{\text{fr}} - \theta_{\text{to}})$ |
| C7 reference angle | `fix(THETA[1], 0)` | slack bus |
| $\lambda_{n,t}=\text{dual}(C1)$ | `dual.(cBalance)` | locational marginal price |

Our work extends the manual in three ways, all layered on top of its structure rather than
replacing it: a **copper-plate** third model to isolate the cost of the network itself; an
explicit **congestion-versus-loop-flow** cost decomposition; and the **load-shedding** term that
lets an over-constrained network report where it fails instead of returning infeasible.

`test/opf_reference_test.jl` rebuilds the notebook's own 3-bus example in our data format and
confirms `solve_network_dispatch` reproduces its published results exactly — dispatch, line
flows, and prices — in both the uncongested 600 MW case (uniform \$50/MWh) and the congested
800 MW case, including the notebook's headline result that Bus 3's price rises to **\$150/MWh**,
above either generator's marginal cost, once the direct line saturates. The test runs as part of
`scripts/verify.sh`.
