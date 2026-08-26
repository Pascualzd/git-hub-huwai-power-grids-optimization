import type { Branch, Bus, Generator } from "./types";

// Small DOM helpers. Text is always set via textContent, never innerHTML, so a stray character
// in a data field can never become markup.
function el(tag: string, className?: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function stat(label: string, value: string): HTMLElement {
  const wrap = el("div", "stat");
  wrap.append(el("span", "stat-value", value), el("span", "stat-label", label));
  return wrap;
}

function row(label: string, value: string): HTMLElement {
  const wrap = el("div", "kv");
  wrap.append(el("span", "k", label), el("span", "v", value));
  return wrap;
}

const mw = (v: number) => `${v.toLocaleString(undefined, { maximumFractionDigits: 1 })} MW`;

// A horizontal bar showing a generator's operating range: the full track is Pmax, a shaded
// band marks the always-on minimum, and the filled portion is the dispatched output. This is
// the "max and mins for each variable" view, per plant.
function operatingBar(gen: Generator): HTMLElement {
  const bar = el("div", "opbar");
  const track = el("div", "opbar-track");
  const minBand = el("div", "opbar-min");
  minBand.style.width = `${(gen.pMinMw / gen.pMaxMw) * 100}%`;
  const fill = el("div", "opbar-fill");
  fill.style.width = `${(gen.dispatchMw / gen.pMaxMw) * 100}%`;
  track.append(minBand, fill);

  const scale = el("div", "opbar-scale");
  scale.append(
    el("span", undefined, "0"),
    el("span", "opbar-mid", `dispatch ${gen.dispatchMw.toFixed(0)}`),
    el("span", undefined, `${gen.pMaxMw.toFixed(0)}`),
  );
  bar.append(track, scale);
  return bar;
}

function generatorCard(gen: Generator): HTMLElement {
  const card = el("div", "gen-card");
  const head = el("div", "gen-head");
  head.append(el("span", "gen-name", gen.name), el("span", "gen-fuel", gen.fuel));
  card.append(head, operatingBar(gen));

  const grid = el("div", "gen-grid");
  grid.append(
    row("Minimum output", mw(gen.pMinMw)),
    row("Maximum output", mw(gen.pMaxMw)),
    row("Dispatched", mw(gen.dispatchMw)),
    row("Variable cost", `$${gen.varCostUsdPerMwh.toFixed(2)}/MWh`),
    row("Ramp rate", `${gen.rampMwPerHr.toFixed(1)} MW/h`),
    row("Heat rate", `${gen.heatRateMmbtuPerMwh.toFixed(2)} MMBtu/MWh`),
    row("CO₂ intensity", `${gen.co2KgPerMwh.toFixed(0)} kg/MWh`),
    row("Peak-hour CO₂", `${(gen.emissionsKgCo2 / 1000).toFixed(1)} t`),
  );
  card.append(grid);

  const note = el("details", "gen-note");
  note.append(el("summary", undefined, "Data provenance"));
  note.append(
    row("Capacity", gen.capacitySource),
    row("Cost", gen.varCostSource),
    row("Constraints", gen.constraintSource),
  );
  card.append(note);
  return card;
}

export function renderBusPanel(target: HTMLElement, bus: Bus, generators: Generator[]): void {
  target.replaceChildren();
  target.append(el("h2", "panel-title", bus.id));
  target.append(el("p", "panel-sub", `${bus.district} district · ${bus.population2020.toLocaleString()} residents (2020)`));

  const stats = el("div", "stat-row");
  stats.append(
    stat("Load served", mw(bus.demandMw)),
    stat("Local price", `$${bus.lmpUsdPerMwh.toFixed(0)}/MWh`),
    stat("Generation", mw(bus.generationCapacityMw)),
  );
  target.append(stats);

  if (bus.unservedMw > 0.01) {
    target.append(el("p", "warn", `⚠ ${mw(bus.unservedMw)} of load is unserved at this bus.`));
  }

  const plants = generators.filter((g) => g.bus === bus.id);
  if (plants.length === 0) {
    target.append(el("p", "panel-hint", "No power plants at this bus — it is a pure load center, served entirely over the network."));
    return;
  }

  target.append(el("h3", "section-head", `${plants.length} power plant${plants.length > 1 ? "s" : ""} at this bus`));
  const sorted = [...plants].sort((a, b) => b.pMaxMw - a.pMaxMw);
  for (const gen of sorted) target.append(generatorCard(gen));
}

export function renderBranchPanel(target: HTMLElement, branch: Branch): void {
  target.replaceChildren();
  target.append(el("h2", "panel-title", `${branch.from} → ${branch.to}`));
  target.append(el("p", "panel-sub", branch.corridor));

  const stats = el("div", "stat-row");
  stats.append(
    stat("Flow", mw(Math.abs(branch.flowMw))),
    stat("Limit", mw(branch.limitMw)),
    stat("Loading", `${(branch.loading * 100).toFixed(0)}%`),
  );
  target.append(stats);

  if (branch.loading > 0.999) {
    target.append(el("p", "warn", "⚠ This line is at its thermal limit — it is congested and sets locational prices."));
  }

  const grid = el("div", "gen-grid");
  grid.append(
    row("Direction", branch.flowMw >= 0 ? `${branch.from} → ${branch.to}` : `${branch.to} → ${branch.from}`),
    row("Circuits", String(branch.circuits)),
    row("Length", `${branch.lengthMi.toFixed(1)} mi`),
    row("Reactance", `${branch.reactancePu.toFixed(4)} p.u.`),
  );
  target.append(grid);
}
