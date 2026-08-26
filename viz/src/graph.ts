import cytoscape from "cytoscape";
import type { Core, ElementDefinition } from "cytoscape";
import type { Branch, Bus, NetworkData } from "./types";
import { domainOf, nodeSize, normalize, rampColor, type Metric } from "./metrics";

// Equirectangular projection of lat/lon to screen coordinates. Longitude is scaled by
// cos(latitude) so the island keeps its true east-west proportions; Cytoscape's y axis grows
// downward, so latitude is negated to keep north at the top.
function project(buses: Bus[]): Map<string, { x: number; y: number }> {
  const SCALE = 3200;
  const meanLat = (buses.reduce((s, b) => s + b.latitude, 0) / buses.length) * (Math.PI / 180);
  const positions = new Map<string, { x: number; y: number }>();
  for (const bus of buses) {
    positions.set(bus.id, {
      x: bus.longitude * Math.cos(meanLat) * SCALE,
      y: -bus.latitude * SCALE,
    });
  }
  return positions;
}

// Color of a line by how close its flow is to the thermal limit: calm blue-grey when slack,
// amber when heavily loaded, red at the limit.
export function loadingColor(loading: number): string {
  if (loading > 0.999) return "#c1121f";
  if (loading > 0.75) return "#f4a261";
  if (loading > 0.4) return "#9bb8c4";
  return "#c7d3d9";
}

function buildElements(data: NetworkData): ElementDefinition[] {
  const positions = project(data.buses);
  const nodes: ElementDefinition[] = data.buses.map((bus) => ({
    group: "nodes",
    data: {
      id: bus.id,
      label: bus.id,
      generates: bus.generationCapacityMw > 0 ? "yes" : "no",
      color: "#457b9d",
      size: 40,
    },
    position: positions.get(bus.id),
  }));

  const edges: ElementDefinition[] = data.branches.map((branch: Branch) => ({
    group: "edges",
    data: {
      id: `e${branch.id}`,
      source: branch.from,
      target: branch.to,
      label: `${Math.round(Math.abs(branch.flowMw))}/${Math.round(branch.limitMw)}`,
      color: loadingColor(branch.loading),
      width: 2 + 7 * branch.loading,
    },
  }));

  return [...nodes, ...edges];
}

export function createGraph(container: HTMLElement, data: NetworkData): Core {
  const cy = cytoscape({
    container,
    elements: buildElements(data),
    minZoom: 0.2,
    maxZoom: 4,
    wheelSensitivity: 0.3,
    style: [
      {
        selector: "node",
        style: {
          "background-color": "data(color)",
          width: "data(size)",
          height: "data(size)",
          label: "data(label)",
          color: "#17324d",
          "font-size": 13,
          "font-weight": 600,
          "text-valign": "bottom",
          "text-margin-y": 4,
          "text-outline-color": "#ffffff",
          "text-outline-width": 2.5,
          "border-width": 2,
          "border-color": "#ffffff",
          "overlay-opacity": 0,
        },
      },
      {
        selector: 'node[generates = "yes"]',
        style: { "border-width": 3, "border-color": "#ef8354" },
      },
      {
        selector: "edge",
        style: {
          "line-color": "data(color)",
          width: "data(width)",
          label: "data(label)",
          "font-size": 10,
          color: "#40606e",
          "text-background-color": "#ffffff",
          "text-background-opacity": 0.75,
          "text-background-padding": "2px",
          "curve-style": "straight",
        },
      },
      {
        selector: ".selected",
        style: { "border-width": 4, "border-color": "#1d3557" },
      },
      {
        selector: "edge.selected",
        style: { "line-color": "#1d3557", "text-background-color": "#e9eef2" },
      },
      { selector: ".faded", style: { opacity: 0.25 } },
    ],
    layout: { name: "preset", fit: true, padding: 70 },
  });
  return cy;
}

// Recolor and resize the bus nodes to reflect the chosen metric.
export function applyMetric(cy: Core, metric: Metric, buses: Bus[]): void {
  const domain = domainOf(metric, buses);
  const byId = new Map(buses.map((b) => [b.id, b]));
  cy.batch(() => {
    cy.nodes().forEach((node) => {
      const bus = byId.get(node.id());
      if (!bus) return;
      const t = normalize(metric.value(bus), domain);
      node.data("color", rampColor(metric, t));
      node.data("size", nodeSize(t));
    });
  });
}
