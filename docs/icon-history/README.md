# App icon history

The icon in use lives in `GPS location app/Assets.xcassets/AppIcon.appiconset/`.
These are the versions it replaced, kept as files so they can be looked at without
digging through git history.

| File | What it is |
|---|---|
| `01-original-rounded-with-white-margin.png` | The original artwork. |
| `02-full-bleed-crop-of-original.png` | The same artwork, cropped full-bleed. |
| `03-current-redrawn.png` | What ships today — a copy of the live icon. |

## Why it changed

**01 → 02.** The original was a pre-rounded tile sitting on white, with a drop
shadow beneath it: 3 px of margin at the top and 31 px at the bottom. iOS applies
its own squircle mask to whatever you give it, so that margin and shadow were not
hidden — they showed as white edging along the bottom of the icon on the home
screen. The fix was to crop to the tile, inset past the corner arcs, and rescale
to a square 1024 that reaches all four edges, with no rounded corners, no shadow
and no alpha. The watch icon was the same file and had the same problem under its
circular mask.

**02 → 03.** A higher-fidelity redraw of the same design: same composition, same
subjects, same palette, but with detail the original artwork did not carry —
window rows and panel lines along the fuselage, multi-layer reflections in the
chrome plates instead of flat gradients, a brighter teal-to-green sweep at the
bottom right. It is a redraw rather than an upscale, so small details differ from
02 on close comparison.

Any replacement must stay full-bleed: square, reaching all four edges, no rounded
corners, no drop shadow, no alpha. iOS adds the corners itself, and anything baked
in comes back as the white edging that 01 had.
