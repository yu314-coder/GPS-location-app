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
| `velocity_mode.pdf` | Compiled, 8 pages |
| `figures/` | Five figures, generated from the recorded logs |

Every number in the paper compares the newest version with GPS recorded at the same time and used
only as the answer key. Earlier recordings were re-run through the newest speed and direction
methods: the speed model is rebuilt as the app builds it, with a memory drawn from every other
journey, and the direction method runs over the saved motion sensor readings. The paper and its
figures carry no recording dates or times.
