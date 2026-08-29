# Recording a route without satellites

LaTeX source and PDF for the paper describing **Velocity Mode**: vibration-derived speed
estimation, its measured accuracy across 23 instrumented journeys, and the eight approaches that
were implemented, measured and rejected along the way.

## Build

    pdflatex velocity_mode.tex && pdflatex velocity_mode.tex

Twice, so the figure references resolve. Requires a TeX distribution with `amsmath`, `booktabs`,
`graphicx` and `microtype`.

## Contents

| File | |
|---|---|
| `velocity_mode.tex` | Source |
| `velocity_mode.pdf` | Compiled, 4 pages |
| `figures/` | Four figures, generated from the recorded logs |

Every number in the paper is measured against GPS recorded at the same moment as the estimate —
none is modelled, simulated or extrapolated. Where the method fails, the paper says so and gives
the magnitude.
