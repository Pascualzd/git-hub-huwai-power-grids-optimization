import "./style.css";
import type { Core } from "cytoscape";
import rawData from "./network.json";
import type { Bus, NetworkData } from "./types";
import { METRICS, domainOf, rampColor, type Metric } from "./metrics";
import { applyMetric, createGraph, loadingColor } from "./graph";
import { renderBusPanel, renderBranchPanel } from "./panel";

const data = rawData as unknown as NetworkData;
const busById = new Map(data.buses.map((b) => [b.id, b] as const));

const cyContainer = document.getElementById("cy")!;
const select = document.getElementById("metric") as HTMLSelectElement;
const fitButton = document.getElementById("fit") as HTMLButtonElement;
const legend = document.getElementById("legend")!;
const panelEmpty = document.getElementById("panel-empty")!;
const panelContent = document.getElementById("panel-content")!;

const cy: Core = createGraph(cyContainer, data);

for (const metric of METRICS) {
  const option = document.createElement("option");
  option.value = metric.key;
  option.textContent = metric.label;
  select.append(option);
}

let activeMetric: Metric = METRICS[0];

function showPanel(render: (target: HTMLElement) => void): void {
  panelEmpty.hidden = true;
  panelContent.hidden = false;
  render(panelContent);
}

function clearPanel(): void {
  cy.elements().removeClass("selected faded");
  panelContent.hidden = true;
  panelEmpty.hidden = false;
}

function highlight(id: string): void {
  cy.elements().removeClass("selected faded");
  const target = cy.getElementById(id);
  cy.elements().addClass("faded");
  const neighborhood = target.closedNeighborhood();
  neighborhood.removeClass("faded");
  target.addClass("selected");
}

function renderLegend(): void {
  const domain = domainOf(activeMetric, data.buses);
  const stops = [0, 0.25, 0.5, 0.75, 1]
    .map((t) => rampColor(activeMetric, t))
    .join(", ");
  legend.replaceChildren();

  const metricBlock = document.createElement("div");
  metricBlock.className = "legend-block";
  const title = document.createElement("div");
  title.className = "legend-title";
  title.textContent = `${activeMetric.label} (${activeMetric.unit})`;
  const gradient = document.createElement("div");
  gradient.className = "legend-gradient";
  gradient.style.background = `linear-gradient(to right, ${stops})`;
  const scale = document.createElement("div");
  scale.className = "legend-scale";
  const lo = document.createElement("span");
  lo.textContent = activeMetric.format(domain.min);
  const hi = document.createElement("span");
  hi.textContent = activeMetric.format(domain.max);
  scale.append(lo, hi);
  metricBlock.append(title, gradient, scale);

  const keyBlock = document.createElement("div");
  keyBlock.className = "legend-block legend-keys";
  keyBlock.append(
    swatch("#457b9d", "Load bus", true),
    swatch("#457b9d", "Generation bus", true, "#ef8354"),
    swatch(loadingColor(1), "Line at limit"),
    swatch(loadingColor(0.8), "Heavily loaded"),
    swatch(loadingColor(0.2), "Lightly loaded"),
  );

  const meta = document.createElement("div");
  meta.className = "legend-block legend-meta";
  meta.append(
    metaLine("Peak-hour congestion cost", `$${data.meta.congestionCostUsdPerHr.toLocaleString(undefined, { maximumFractionDigits: 0 })}/h`),
    metaLine("Peak-hour loop-flow cost", `$${data.meta.loopflowCostUsdPerHr.toLocaleString(undefined, { maximumFractionDigits: 0 })}/h`),
    metaLine("Binding line", data.meta.bindingBranch),
    metaLine("Price span", `$${data.meta.lmpSpanUsdPerMwh}/MWh`),
  );

  legend.append(metricBlock, keyBlock, meta);
}

function swatch(color: string, label: string, circle = false, border?: string): HTMLElement {
  const item = document.createElement("div");
  item.className = "legend-key";
  const mark = document.createElement("span");
  mark.className = circle ? "key-dot" : "key-line";
  mark.style.background = color;
  if (border) mark.style.boxShadow = `0 0 0 2px ${border}`;
  const text = document.createElement("span");
  text.textContent = label;
  item.append(mark, text);
  return item;
}

function metaLine(label: string, value: string): HTMLElement {
  const line = document.createElement("div");
  line.className = "meta-line";
  const k = document.createElement("span");
  k.textContent = label;
  const v = document.createElement("span");
  v.className = "meta-value";
  v.textContent = value;
  line.append(k, v);
  return line;
}

function setMetric(metric: Metric): void {
  activeMetric = metric;
  applyMetric(cy, metric, data.buses);
  renderLegend();
}

select.addEventListener("change", () => {
  const metric = METRICS.find((m) => m.key === select.value);
  if (metric) setMetric(metric);
});

fitButton.addEventListener("click", () => cy.animate({ fit: { eles: cy.elements(), padding: 70 }, duration: 300 }));

cy.on("tap", "node", (event) => {
  const bus = busById.get(event.target.id()) as Bus | undefined;
  if (!bus) return;
  highlight(bus.id);
  showPanel((target) => renderBusPanel(target, bus, data.generators));
});

cy.on("tap", "edge", (event) => {
  const branch = data.branches.find((b) => `e${b.id}` === event.target.id());
  if (!branch) return;
  highlight(event.target.id());
  showPanel((target) => renderBranchPanel(target, branch));
});

cy.on("tap", (event) => {
  if (event.target === cy) clearPanel();
});

setMetric(activeMetric);
