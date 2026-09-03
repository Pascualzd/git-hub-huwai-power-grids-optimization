# Constrained Descent — the gridflow instrument

`index.html` is a self-contained p5.js viewer for the DC-OPF solutions produced by
`OPT simple case/OPT part 5 - animations.jl`. Open the file directly in any browser —
no build step, no server, no install. The only external request is p5.js from a CDN.

## What you are looking at

| Ink on the canvas | What it encodes |
|---|---|
| **Ground / contour bands** | the scalar potential — voltage phase angle for the IEEE 14-bus case, locational price for the 3-bus day. Ridges are supply, basins are demand. Flat ground means nothing is binding. |
| **Conductor width** | `\|flow\|` relative to the largest flow anywhere in the sequence |
| **Conductor colour** | `\|flow\| / rateA` — cool when slack, amber when loaded, red when at the limit |
| **Carrier spacing** | `\|flow\|` — more power, denser stream |
| **Carrier speed** | `\|flow\| / rateA` — a corridor at its thermal limit visibly runs fast |
| **Carrier direction** | the true direction of the solved flow, so reversals read as the stream turning around |
| **Node size** | power the bus handles (generation + load) |
| **Node colour** | green = net supply, red = net demand, grey = pure junction; square = slack bus |

## Controls

- **Seed** moves only what the optimisation leaves undetermined: carrier phase offsets,
  lateral jitter, particle size. The physics is identical for every seed — same seed, same
  texture, always.
- **Network** switches between the IEEE 14-bus demand sweep (26 solved states, +0% to +50%)
  and the ramp-constrained 3-bus day (24 hourly states).
- **System stress / Hour of day** scrubs through the solved states. **Auto-advance** plays
  them in sequence.
- **Carrier density, descent speed, trail persistence, terrain bands, terrain relief, glow**
  retune the rendering without touching the underlying solution.
- **Colors** set the cool / loaded / ignited conductor ramp and the ground tint.
- **Download PNG** saves the current frame at canvas resolution.

## Where the numbers come from

`network.json` is written by `OPT simple case/OPT part 5 - animations.jl`. Each state is one
HiGHS solution: nodal demand, dispatch, line flows, phase angles, locational marginal prices,
total cost, and the count of binding lines. The browser has no LP solver — it replays real
optimisation output rather than approximating it. To regenerate after changing the model:

```bash
cd "OPT simple case"
julia "OPT part 5 - animations.jl"
```

then re-embed the JSON into `index.html` (the file inlines it so it can be opened offline):

```bash
python3 - <<'PY'
import json, re
data = json.load(open('viz/gridflow/network.json'))
html = open('viz/gridflow/index.html').read()
html = re.sub(r'const DATA = .*?;\n', 'const DATA = ' + json.dumps(data, separators=(',', ':')) + ';\n', html, count=1, flags=re.S)
open('viz/gridflow/index.html', 'w').write(html)
PY
```

The aesthetic this implements is stated in [`../../docs/GRIDFLOW_PHILOSOPHY.md`](../../docs/GRIDFLOW_PHILOSOPHY.md).
