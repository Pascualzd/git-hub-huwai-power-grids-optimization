# Constrained Descent

*An algorithmic philosophy for the visualisation of optimal power flow.*

---

## The movement

**Constrained Descent** holds that a network under optimisation is not a diagram
but a *landscape under load*, and that the honest way to draw one is to let it
run. Every optimal power flow solution already contains a terrain: the vector of
voltage phase angles is an elevation map, and power does not choose its route
across that map any more than rain chooses its river. It descends. The quantity
descending any given slope is the product of the drop and the conductance of the
channel — a relationship so simple that the entire apparatus of the DC power flow
is really just gravity with a different constant. To draw the arrows and suppress
the terrain, as almost every textbook figure does, is to photograph a waterfall
and publish only the arrow labelled *down*.

The movement therefore insists on two simultaneous layers, neither of which is
decoration. Beneath: the scalar potential, interpolated continuously across the
plane and banded into isolines, so that the viewer sees ridges where generation
sits and basins where load pulls the ground away. Above: discrete carriers,
advected along each channel, their spacing set by the magnitude of flow and their
velocity set by how close that channel runs to its own destruction. Every
particle is a number the solver produced. Nothing is sprinkled on for texture.
The algorithm must be built so that a specialist could read the flows off the
screen to within a few percent, and that constraint — beauty that is also
*measurement* — is the discipline the whole movement is organised around. It
demands a meticulously crafted algorithm; anything less produces a screensaver.

## What the system is actually dramatising

The subject is not electricity. The subject is **the moment a constraint becomes
active**. In the slack regime, a network is boring and the mathematics is boring:
every shadow price is identical, the terrain is a smooth bowl, and the carriers
drift. Then demand rises, some corridor reaches its rating, and everything
changes at once — the price surface fractures into locational values, the terrain
develops a discontinuity in its gradient, and the binding channel begins to run
hot and fast because it can no longer absorb what is being asked of it. This is
complementary slackness rendered as a physical event: a multiplier that was
pinned at zero comes off the floor, and the system's whole geometry reorganises
around the newly load-bearing inequality. Those who know the duality theory will
recognise the moment; everyone else will simply see a grid catch fire. Both
readings must be available in the same frame, and holding both simultaneously is
the mark of a master-level implementation.

## How it must behave in code

Emergence here is not stochastic emergence. The carriers do not negotiate with
each other, and there is no flocking, no repulsion, no soft-body physics —
introducing any of that would be a lie about the underlying model, which is a
linear program with a unique optimal face. The emergence is *parametric*: sweep
one exogenous quantity (demand, or the hour of the day) and let the optimiser
re-solve, and the visual complexity that appears — reversals, ignitions, the
terrain buckling, prices tearing apart — is emergent in the only sense that
matters, because none of it was drawn by hand. The algorithm's job is to hold
still and let the mathematics move. Seeded randomness enters only where the model
is genuinely silent: the phase offset of each carrier stream, the sub-pixel
jitter of a particle across the width of its conductor, the grain of the terrain
sampling.
Same seed, same texture, always — the Art Blocks contract, honoured exactly.

Restraint is the hardest requirement and must be enforced with painstaking care.
The temptation in generative work is to add: more particles, more bloom, more
octaves of noise. Here every addition is measured against a single question —
*does this encode a quantity, or does it merely fill space?* Glow is permitted
because glow is magnitude. Speed is permitted because speed is utilisation.
Colour temperature is permitted because temperature is the loading ratio. Trails
are permitted because a trail is the recent history of a flow. Perlin noise
drifting across the background for atmosphere is not permitted, and never will
be. A palette of four families — cold conductor, warm conductor, ignited
conductor, and the deep banded ground beneath them — is sufficient, and the
refusal to exceed it is what will make the finished piece look like the product
of deep computational expertise rather than an evening's enthusiasm.

## The finish

The output should read as though it had been tuned for months: contour bands
spaced so the eye finds the gradient without counting, carrier density calibrated
so that a fully loaded corridor is dense but never solid, ignition colour chosen
so that the first line to bind is unmistakable at a glance across a lecture hall,
easing on the state transitions so that a re-solve reads as the ground *settling*
rather than as a cut. Every one of those decisions is a threshold, and every
threshold should feel inevitable in the way that only painstaking optimisation
can make a threshold feel. The viewer should be able to sit with a single seed
for a long time, push demand up one increment at a time, and watch a purely
mathematical object behave like weather.

That is the whole movement: **let the constraint set do the drawing, and build
the instrument well enough that it disappears.**
