# Recording a route without satellites

LaTeX source and PDF for the paper describing **Velocity Mode**: vibration-derived speed
estimation and GPS-free direction, their measured accuracy across the instrumented journeys, and the
approaches that were implemented, measured and rejected along the way.

## Build

    pdflatex velocity_mode.tex && pdflatex velocity_mode.tex

Twice, so the figure references resolve. Requires a TeX distribution with `amsmath`, `booktabs`,
`graphicx` and `microtype`.

## Contents

| File | |
|---|---|
| `velocity_mode.tex` | Source |
| `velocity_mode.pdf` | Compiled, 11 pages |
| `figures/` | Six figures: five split into motorcycle, car, walking and plane, and the starting network |

Every number in the paper compares the latest version with GPS recorded at the same time and used
only as the answer key. Every recording was re-run through the latest app logic from its saved raw
sensor readings (acceleration, rotation and orientation angles at 50 Hz):
- speed: the model rebuilt as the app builds it, with a memory drawn from every other journey, plus
  its rules for stops, a handled phone and holding the last answer;
- walking: the step detector and its bookkeeping;
- direction and routes: the direction method.

Three inputs come from the recordings as they were: walking or riding, Apple's motion classifier,
and the car-park ramp flag. The phone's step counter and cabin pressure were not recorded. The paper
and its figures carry no recording dates or times.
