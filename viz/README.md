# Oʻahu network explorer

An interactive, zoomable map of the 9-bus Oʻahu DC-OPF model. Every number it shows comes from
the committed `data/processed/` results — nothing is hand-entered.

- **Scroll** to zoom, **drag** to pan.
- **Click a bus** to open a panel with its load, locational price, and every power plant located
  there — each plant's minimum and maximum output, dispatched output, variable cost, ramp rate,
  heat rate, CO₂ intensity, and peak-hour emissions, with an operating-range bar and data
  provenance.
- **Click a line** to see its flow, thermal limit, loading, length, and reactance.
- **Recolor and resize** the buses by locational price, generation capacity, load, dispatch, or
  emissions using the selector in the top bar.

Built with [Vite](https://vitejs.dev), [TypeScript](https://www.typescriptlang.org), and
[Cytoscape.js](https://js.cytoscape.org).

## Run it

```bash
cd viz
npm install
npm run dev        # http://localhost:5173 with hot reload
```

To produce a static build (e.g. to host it):

```bash
npm run build      # writes viz/dist/
npm run preview    # serve the build locally
```

`npm run typecheck` runs the TypeScript compiler without emitting.

## Data

The app reads a single bundle, `src/network.json`, generated from the model outputs by:

```bash
bash scripts/python scripts/export_viz_data.py
```

Re-run that after re-solving the model (`scripts/verify.sh` does it automatically) to refresh the
explorer. The bundle's shape is typed in `src/types.ts`.

## Layout of the source

- `src/main.ts` — wires the graph, metric selector, legend, and detail panel together
- `src/graph.ts` — Cytoscape setup: geographic projection, styling, metric coloring
- `src/panel.ts` — the per-bus and per-line detail panels
- `src/metrics.ts` — the selectable bus metrics and their color ramps
- `src/network.json` — the generated data bundle (committed, refreshed by the exporter)
