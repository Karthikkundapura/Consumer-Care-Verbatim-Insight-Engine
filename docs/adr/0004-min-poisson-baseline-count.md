# ADR-0004: Minimum Poisson Baseline Count

## Context

The Detection pipeline uses a Poisson scan to detect complaint spikes. The scan is not statistically meaningful at low baselines: a jump from 0 to 3 complaints is not a Poisson spike. A switch is needed between the Poisson scan and a deterministic low-volume policy.

## Decision

`MIN_POISSON_BASELINE_COUNT = 5`. Below this baseline, `detection.py` uses the low-volume detection policy. At or above it, `detection.py` uses the Poisson scan.

## Justification

First principles: at baseline 0, Poisson is undefined. At baseline 1, a jump to 3 is 8% likely by chance. At baseline 2, a jump to 3 is 32% likely. At baseline 3, a jump to 5 is 19% likely. At baseline 4, a jump to 5 is 37% likely. Only at baseline >= 5 does a modest count increase become statistically distinguishable from noise.

Measurement: `evaluation/lead_time.py` runs the detector at thresholds 3 through 8 and reports FPR, FNR, and alerts per week. The threshold is confirmed or adjusted against that table. The current value (5) is the first-principles starting point.

## Consequences

- Below baseline 5, detection uses a deterministic policy, not a statistical test.
- The low-volume policy must mark its result explicitly as low-volume.
- The threshold is locked only after the sensitivity table is produced.
- A future change to this threshold requires a new ADR and an updated sensitivity row.

## Status

Accepted.
