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
| `velocity_mode.pdf` | Compiled, 29 pages |
| `figures/` | Seven figures, generated from the recorded logs |

Every number in the paper is measured against GPS recorded at the same moment as the estimate —
none is modelled, simulated or extrapolated. The direction results for the current method re-run
the shipped direction logic over the recorded sensor logs of every journey (61 with attitude
logged, 60 with enough GPS to compare whole routes), with GPS used only to grade; distance in
those routes is as each build recorded it. Where the method fails, the paper says so and gives
the magnitude.
