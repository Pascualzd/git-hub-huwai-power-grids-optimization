# Set 9 — brief for 15 infographics

Instructions for generating a 15-panel visual deck. Each panel below is a
self-contained prompt: paste the **STYLE BLOCK** first, then one panel.

**Audience:** decision-makers who are not native English speakers. Every panel
must be readable *without* reading. The picture carries the argument; the words
only label it. Never more than ~25 words on a panel.

---

## STYLE BLOCK — paste this before every panel prompt

```
Create a flat-vector infographic, 16:9 landscape, for a technical audience
who are NOT native English speakers.

RULES
- The visual must carry the meaning. Text only labels it. Max ~25 words total.
- One idea per panel. No paragraphs. No decorative clutter.
- Numbers are the heroes: set key figures very large (72pt+ equivalent).
- Use icons and physical objects, not abstract shapes, wherever possible.
- Generous white space. Clean sans-serif. No drop shadows, no 3D, no gradients
  except flat two-tone fills.

FIXED COLOUR CODE — identical across all 15 panels, never reassigned:
  DEEP BLUE   #1E4E8C  = measured or officially filed data (trustworthy)
  AMBER       #E8952A  = assumed by us (a judgement call)
  TEAL        #158F7A  = a result, or something we corrected
  RED         #C0392B  = an error or a failure (use sparingly, max 1 per panel)
  WARM GREY   #6B7280  = context, background, labels

Add a thin footer strip on every panel:
  left: "Set 9 — O'ahu grid study"    right: the panel number, e.g. "4 / 15"
```

> **Language note.** Keep the numbers exactly as written; translate only the
> labels. The metaphors (a truck, a staircase, sacks of sand, a clock) survive
> translation — that is why they were chosen.

---

# ACT 1 — The question

## Panel 1 / 15 — Dials or machines?

**One message:** the earlier study treated power plants as dials you can set to
any value. Real plants are machines with physical limits.

```
Split the panel vertically into two halves.

LEFT, labelled "BEFORE" in warm grey: a simple volume knob / rotary dial,
drawn in warm grey, with a smooth arc from 0 to MAX and an arrow showing it
can be set anywhere instantly. Small caption under it: "any value, instantly".

RIGHT, labelled "SET 9" in teal: a heavy industrial diesel generator drawn in
deep blue, with three small warning badges attached to it showing: a minimum
gauge, a speed-limit sign, and a stopwatch. Small caption: "limits, and memory".

Between the halves, a bold teal arrow pointing left to right.

Title at top: "From dials to machines"
```

---

## Panel 2 / 15 — What the limits actually are

**One message:** three physical limits, each easy to feel as a truck rule.

```
Three columns, each with a big icon on top and a one-line label under it.
Draw each icon in deep blue on white.

COLUMN 1 — icon: a speedometer with a red zone at the BOTTOM of the dial.
   Heading: "MINIMUM OUTPUT"
   Line: "Switched on, it cannot idle below 40%"

COLUMN 2 — icon: a truck with a curved acceleration arrow, and a limit sign
   reading "30%/h" on the arrow.
   Heading: "RAMP LIMIT"
   Line: "It can only change speed so fast"

COLUMN 3 — icon: a stopwatch with a padlock on it.
   Heading: "MINIMUM RUN TIME"
   Line: "Once started, it must stay on for hours"

Title at top: "Three limits a real machine has"
Bottom strip in amber: "All three are ASSUMED by technology class — not filed"
```

---

## Panel 3 / 15 — The island we model

**One message:** this is one island, one fleet, nine points.

```
Centre: a simplified silhouette map of the island of O'ahu, Hawai'i, in warm
grey, with 9 circular nodes placed on it connected by a ring of lines in deep
blue. Make the node over Honolulu (south-east) noticeably the largest.

Around the map, four large stat blocks with big numbers in deep blue:
   "24"        units
   "1,508 MW"  total fleet capacity
   "1,054 MW"  highest hour of demand
   "9"         network nodes

Small amber tag pointing at the ring of lines: "network shape: ASSUMED"
Small deep-blue tag pointing at the plant nodes: "plants: EIA filings"

Title: "One island: O'ahu"
```

---

## Panel 4 / 15 — The fleet, by machine type

**One message:** it is mostly old oil steam, which is the slow, stubborn kind.

```
A horizontal stacked bar, full width, divided by number of units, each segment
a different tint of deep blue, with the unit count inside each segment:

   Oil steam           12 units
   Internal combustion  6 units
   Combustion turbine   3 units
   Municipal waste      2 units
   Combined cycle       1 unit

Under each segment, a tiny icon: steam = a tall chimney; internal combustion =
a piston; combustion turbine = a jet turbine; municipal waste = a recycling
bin; combined cycle = two linked turbines.

Below the bar, pull out the steam segment with a teal callout box:
   "12 of 24 units are oil steam — the slowest to start and stop"

Title: "What the island actually runs on"
```

---

# ACT 2 — How we tested it

## Panel 5 / 15 — The staircase: one change at a time

**One message:** we added one constraint at a time so every movement in the
results is attributable.

```
A four-step staircase rising left to right, drawn in flat deep blue, each step
labelled on its face. Place a small walking figure at the bottom left.

STEP 1  "LP"     — only: output between zero and maximum
STEP 2  "+PMIN"  — add: minimum output when on
STEP 3  "+RAMP"  — add: limit on hour-to-hour change
STEP 4  "+FULL"  — add: minimum run time and start-up cost

Each step gets progressively darker blue.

Title: "One new rule per step"
Bottom line in warm grey: "If a number moves, we know exactly which rule moved it"
```

---

## Panel 6 / 15 — Two demand worlds

**One message:** the same average demand, two completely different shapes.

```
Two panels side by side, each showing a 24-hour line chart.

LEFT, deep blue, titled "REAL": a smooth realistic daily demand curve — low at
night, rising through the morning, peaking in the evening.

RIGHT, amber, titled "ASSUMED RANDOM": a violently jagged random line over the
same 24 hours, same average height.

Draw a horizontal dashed line at the same height across BOTH charts, labelled
at the far right: "identical average: 744 MW".

Title: "Same average. Different shape."
Bottom line: "The shape is the only thing being compared"
```

---

## Panel 7 / 15 — The trap we found

**One message:** we found a serious modelling bug because the economics looked
absurd. Include this — showing your own error proves the checking is real.

```
Three stages left to right, joined by arrows.

STAGE 1, in deep blue — a stopped generator at 0%, with a dashed arrow jumping
up to a line marked "40% minimum", and beside it a limit sign "30% per hour".
A large red X over the jump. Caption: "To start, it must jump 40%. It may only
climb 30%. So it can NEVER start."

STAGE 2, in red — a big number "95.8%" with the label "of hours shedding load",
and a small icon of expensive diesel engines running while cheap steam sits idle.
Caption: "The model said the island collapses"

STAGE 3, in teal — a checkmark with the label "Separate start-up ramp".
Caption: "Fixed. The tell was economics, not the error message."

Title: "The bug that looked like a blackout"
```

---

## Panel 8 / 15 — Why the hours must be in order

**One message:** machine limits link each hour to the one before, so hours can
no longer be shuffled.

```
Two rows of playing-card-like tiles, each tile showing a clock time.

TOP ROW, amber, labelled "BEFORE — hours drawn at random":
tiles reading 14:00, 03:00, 21:00, 07:00 in scattered rotation, with a
"shuffle" icon. A broken/greyed chain link between them.

BOTTOM ROW, deep blue, labelled "SET 9 — hours in real order":
tiles reading 01:00, 02:00, 03:00, 04:00 neatly aligned, joined by a solid
chain link.

Title: "A ramp needs a yesterday"
Bottom line: "8,760 hours, walked in order, in 24-hour blocks"
```

---

# ACT 3 — Rebuilding the demand

## Panel 9 / 15 — The frozen direction problem

**One message:** the old model let the nine locations only grow and shrink
together. They could never change their balance.

```
LEFT, amber, titled "OLD": nine vertical bars of different heights, all
connected to ONE single lever/handle at the side. Show the lever pulled up and
all nine bars rising by the same proportion. Caption: "one lever moves all nine"

RIGHT, teal, titled "NEW": the same nine bars, but each with its OWN small
handle, shown at clearly different heights from the left panel — some up,
some down. Caption: "each moves on its own"

Big stat in the centre bottom, teal: "RANK 1 → RANK 2"
with a small grey line beneath: "the demand can finally change direction"

Title: "The one thing that mattered most was frozen"
```

---

## Panel 10 / 15 — O'ahu is a commuter island

**One message:** people sleep in the suburbs and work downtown, so splitting
demand by population puts the load in the wrong place.

```
Centre: the O'ahu map silhouette in warm grey.

Draw thick teal arrows flowing from the outer districts INTO the Honolulu area
in the south-east, like a morning commute.

Two large opposed stat blocks:
   LEFT, in amber:     "39.9%"  label "of RESIDENTS live in Honolulu"
   RIGHT, in deep blue: "71.0%"  label "of JOBS are in Honolulu"

Between them a bold "+31 points" in teal.

Title: "People sleep in one place and work in another"
Bottom line: "Splitting electricity by where people sleep sends the load out of town"
```

---

## Panel 11 / 15 — Three sacks, three maps

**One message:** demand is not one substance. It is three, each landing in a
different place.

```
Show three sacks at the top, each a different colour, pouring downward through
its own stencil onto the same island map at the bottom.

SACK 1 — deep blue — "HOMES"      — 26.75% — stencil icon: a house
SACK 2 — teal       — "BUSINESS"  — 31.12% — stencil icon: an office tower
SACK 3 — warm grey  — "INDUSTRY"  — 42.13% — stencil icon: a factory

Each sack pours onto a DIFFERENT concentration of the island: homes spread
wide, business concentrated on Honolulu, industry concentrated on the
south-west corner.

Title: "Electricity is not one thing"
Bottom strip, deep blue: "Shares from EIA Form 861 — filed by Hawaiian Electric"
```

---

## Panel 12 / 15 — The island's demand rotates through the day

**One message:** the balance between districts swings enormously between noon
and midnight — and nobody imposed that, it emerged.

```
A large circular clock face in the centre. Around it, four small island maps at
the 12, 3, 6 and 9 positions, each shaded to show where demand concentrates.

   MIDNIGHT map: demand spread out to the suburbs
   NOON map:     demand strongly concentrated on Honolulu, glowing
   EVENING map:  demand moving back out to the suburbs

Two enormous numbers side by side at the bottom:
   "52.7%"  in warm grey, labelled "Honolulu's share at its lowest"
   "84.1%"  in teal,      labelled "Honolulu's share at its highest"

Title: "The island's demand moves during the day"
Bottom line: "Nobody programmed this. It came out of the sector shapes."
```

---

# ACT 4 — Honesty and results

## Panel 13 / 15 — Two errors we found in our own work

**One message:** we audited ourselves and found two real mistakes. Both fixed.

```
Two rows, each a before → after pair.

ROW 1 — "THE CALENDAR"
  BEFORE, red: a calendar week where SATURDAY and SUNDAY are highlighted as
  busy office days, with a confused office-building icon.
  AFTER, teal: the same calendar with MONDAY–FRIDAY correctly highlighted.
  Caption: "Our weather-year calendar was 2 days out of step. Offices looked
  busier on Sunday than Tuesday."

ROW 2 — "COUNTING HEADS, NOT ENERGY"
  BEFORE, red: a balance scale with lots of small person-icons on one side.
  AFTER, teal: the same scale, but with lightning-bolt icons, visibly
  rebalancing toward hotels and shops.
  Caption: "One office worker uses 6,912 kWh a year. One hotel worker uses
  36,179. Counting people is not counting electricity."

Title: "What we found when we checked ourselves"
```

---

## Panel 14 / 15 — What the model says

**One message:** as the machines get more realistic, the strain shows up as
*speed*, not as a shortage of capacity.

```
Reuse the four-step staircase from Panel 5, but now put two numbers ON each
step, stacked:

STEP 1  "LP"      hours with a line at its limit: 94.8%   energy not served: 0
STEP 2  "+PMIN"   hours with a line at its limit: 58.9%   energy not served: 0
STEP 3  "+RAMP"   hours with a line at its limit: 90.4%   energy not served: 33.8 MWh
STEP 4  "+FULL"   hours with a line at its limit: 62.7%   energy not served: 11.7 MWh

Put a large teal callout arrow on STEP 3:
   "The fleet has enough capacity. Sometimes it cannot move fast enough."

Title: "Where the strain appears"
Bottom line, warm grey: "Reserve margin is 43%. The problem is not size."
```

---

## Panel 15 / 15 — What is real and what we assumed

**One message:** the honest inventory. This is the slide that makes every other
slide credible.

```
A two-column "bill of materials" table with a stamp icon beside each row.

LEFT COLUMN, headed "FILED / MEASURED", all rows in DEEP BLUE with a
official-looking stamp icon:
   Generator capacities        — EIA Form 860
   Fuel use and heat rates     — EIA Form 923
   Sector split of electricity — EIA Form 861
   Population by district      — US Census 2020
   Jobs by district            — US Census LODES
   Hourly island demand        — Hawaiian Electric filing

RIGHT COLUMN, headed "ASSUMED BY US", all rows in AMBER with a hand-drawn
pencil icon:
   Minimum output and ramp rates
   Minimum run times, start-up costs
   THE ENTIRE NETWORK: lines, lengths, limits
   How demand splits between the 9 nodes

At the bottom, a full-width teal banner with a target/bullseye icon:
   "Every DIRECTION in our results is robust.
    No network MAGNITUDE is a claim about the real grid."

Title: "What we stand behind"
```

---

## Generation notes

**Order of work.** Generate Panel 1 first and iterate on it until the style is
right. Then reuse that exact image as a style reference for the other 14 —
consistency across the set matters more than any single panel.

**Reused assets.** Panels 3, 10, 11 and 12 all use the O'ahu map silhouette, and
Panels 5 and 14 use the same four-step staircase. Generate each once and reuse
it, or the deck will look like it came from five different studies.

**If a panel comes back too busy**, delete elements rather than shrinking them.
A panel that is unreadable at the back of a room has failed regardless of how
much it contains.

**The three panels that must land** if time is short: **10** (commuter island),
**12** (demand rotates), **15** (real vs assumed). Those carry the finding, the
mechanism, and the credibility.
