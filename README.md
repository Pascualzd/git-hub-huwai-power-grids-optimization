# Hawaiʻi Power Grid Optimization

An economic dispatch study of Hawaiʻi's island grids, focused on Oʻahu.

The project reproduces the structure of Cornell BEE 4750/5750 Lecture 12,
["Economic Dispatch"](https://envsys.viveks.me/fall2022/assets/lecture-notes/12-economic-dispatch/index.html)
(Vivek Srikrishnan) — single-period dispatch, multi-period dispatch with ramping constraints,
merit order, and the duck curve — but driven by real utility and federal data rather than a
textbook fleet.

**Toolchain:** Julia + JuMP + HiGHS for the optimization; Python/pandas for data prep;
Quarto revealjs for the presentation.

## Start here

- **[PROJECT_PLAN.md](PROJECT_PLAN.md)** — the six-step startup plan: repo scaffold, data
  acquisition, fleet table construction, the models, the analysis, and the deck.
- **[DATA_SOURCES.md](DATA_SOURCES.md)** — which dataset supplies which model parameter, with
  links. Read this before going looking for data; there are two non-obvious gaps.

## The two things that will trip you up

1. **Hawaiʻi is not in EIA Form 930.** The Hourly Electric Grid Monitor covers only the
   Lower 48, so there is no Hawaiʻi hourly demand series there. Hourly load has to come from
   Hawaiian Electric's Integrated Grid Planning filings. This is the critical path.
2. **`P^min` and ramp rates are not in any EIA form.** They come from Hawaiian Electric's PSIP
   and IGP filings with the Hawaiʻi PUC. These are exactly the two parameters the multi-period
   model turns on, so they cannot be skipped.

## Status

Planning. No code or data committed yet — Step 1 of the plan is the next action.
