import type { Bus } from "./types";

// A metric is one selectable way to color and size the buses. Each knows how to read its
// value off a bus, how to format it for humans, and the two ends of its color ramp.
export interface Metric {
  key: string;
  label: string;
  unit: string;
  value: (bus: Bus) => number;
  format: (value: number) => string;
  low: RGB;
  high: RGB;
}

export type RGB = [number, number, number];

const money = (v: number) => `$${v.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
const mw = (v: number) => `${v.toLocaleString(undefined, { maximumFractionDigits: 0 })} MW`;
const tonnes = (v: number) => `${(v / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })} t`;

// Perceptually gentle ramps: pale sand to a saturated accent for each metric family.
export const METRICS: Metric[] = [
  {
    key: "lmp",
    label: "Locational price (LMP)",
    unit: "$/MWh",
    value: (b) => b.lmpUsdPerMwh,
    format: (v) => `$${v.toFixed(0)}/MWh`,
    low: [235, 240, 235],
    high: [193, 18, 31], // deep red — expensive to serve here
  },
  {
    key: "capacity",
    label: "Generation capacity",
    unit: "MW",
    value: (b) => b.generationCapacityMw,
    format: mw,
    low: [235, 238, 242],
    high: [239, 131, 84], // orange — generation
  },
  {
    key: "demand",
    label: "Load served",
    unit: "MW",
    value: (b) => b.demandMw,
    format: mw,
    low: [235, 238, 242],
    high: [38, 70, 83], // deep teal-blue — load
  },
  {
    key: "dispatch",
    label: "Generation dispatched",
    unit: "MW",
    value: (b) => b.dispatchMw,
    format: mw,
    low: [235, 238, 242],
    high: [42, 157, 143], // green
  },
  {
    key: "emissions",
    label: "CO₂ emissions",
    unit: "t CO₂",
    value: (b) => b.emissionsKgCo2,
    format: tonnes,
    low: [235, 238, 242],
    high: [109, 89, 122], // muted purple
  },
];

export interface Domain {
  min: number;
  max: number;
}

export function domainOf(metric: Metric, buses: Bus[]): Domain {
  const values = buses.map(metric.value);
  return { min: Math.min(...values), max: Math.max(...values) };
}

// Normalize a value to [0, 1] within its domain, guarding against a zero-width domain.
export function normalize(value: number, domain: Domain): number {
  if (domain.max <= domain.min) return 0;
  return (value - domain.min) / (domain.max - domain.min);
}

export function rampColor(metric: Metric, t: number): string {
  const mix = (a: number, b: number) => Math.round(a + (b - a) * t);
  const [r, g, b] = [0, 1, 2].map((i) => mix(metric.low[i], metric.high[i]));
  return `rgb(${r}, ${g}, ${b})`;
}

// Node diameter in pixels, scaled by the normalized metric value.
export function nodeSize(t: number): number {
  const MIN_PX = 26;
  const MAX_PX = 84;
  return MIN_PX + (MAX_PX - MIN_PX) * Math.sqrt(t);
}

export { money };
