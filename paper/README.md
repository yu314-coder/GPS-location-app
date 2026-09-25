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
| `velocity_mode.pdf` | Compiled, 7 pages |
| `figures/` | Four figures, generated from the recorded logs |

Every number in the paper compares the current version with GPS recorded at the same time and used
only as the answer key. Speed, distance and whole-route results come from the nine journeys recorded
with the current version (22–24 September 2026); direction results also re-run the current direction
method over the sensor logs of all 61 recordings with the phone's orientation logged.
