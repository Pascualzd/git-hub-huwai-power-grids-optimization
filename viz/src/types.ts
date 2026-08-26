// Shapes of the bundle written by scripts/export_viz_data.py.

export interface Meta {
  peakHour: number;
  peakDemandMw: number;
  islandLmpUsdPerMwh: number;
  congestionCostUsdPerHr: number;
  loopflowCostUsdPerHr: number;
  bindingBranch: string;
  highestLmpBus: string;
  lmpSpanUsdPerMwh: string;
}

export interface Bus {
  id: string;
  district: string;
  latitude: number;
  longitude: number;
  population2020: number;
  loadShare: number;
  demandMw: number;
  lmpUsdPerMwh: number;
  unservedMw: number;
  generationCapacityMw: number;
  dispatchMw: number;
  emissionsKgCo2: number;
  generatorCount: number;
}

export interface Branch {
  id: number;
  from: string;
  to: string;
  corridor: string;
  circuits: number;
  lengthMi: number;
  reactancePu: number;
  limitMw: number;
  flowMw: number;
  loading: number;
}

export interface Generator {
  name: string;
  bus: string;
  fuel: string;
  technology: string;
  plantCode: number;
  pMinMw: number;
  pMaxMw: number;
  varCostUsdPerMwh: number;
  rampMwPerHr: number;
  heatRateMmbtuPerMwh: number;
  co2KgPerMwh: number;
  dispatchMw: number;
  emissionsKgCo2: number;
  capacitySource: string;
  varCostSource: string;
  constraintSource: string;
}

export interface ModeCost {
  totalCostUsd: number;
  generationCostUsd: number;
  transportCostUsd: number;
  unservedMwh: number;
}

export interface NetworkData {
  meta: Meta;
  buses: Bus[];
  branches: Branch[];
  generators: Generator[];
  costs: Record<string, ModeCost>;
}
