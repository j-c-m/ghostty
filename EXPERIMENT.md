# Cell-grid atlas + programming ligatures

Local experiment on `experiment/cell-grid-ligatures`. Not a Ghostty default.
Do not open an issue or PR.

## Flags

```
experimental-cell-grid = false
experimental-ligatures = programming   # off | programming | on
```

`experimental-ligatures` is ignored unless `experimental-cell-grid` is true.

Surfaces with different `experimental-cell-grid` values do not share a font
atlas. The flag is hashed into `SharedGridSet.Key`. Reload rebuilds the grid
the same way font size does.

## How to A/B

In `config`:

```
experimental-cell-grid = true
experimental-ligatures = programming
font-family = "JetBrains Mono"
```

Leave the flag off (default) for today's tight bbox + full-run shaping.

`-calt` on `font-feature` still prevents `=>` from confirming.

## Visual diffs when the flag is on

- Letters are cell-boxed: glyph quad is `cell_w × cell_h`, bearings
  `(0, cell_h)` so Metal `offset.y = cell_size.y - bearings.y` is 0.
- Italic `f` (and Nerd overflow) **clips** to the cell. It does not shrink
  via `Glyph.Constraint` `.fit` / `.cover` / `.stretch`.
- Confirmed ligatures (`=>`, `!=`, `===`, …) are one N-cell coverage tile
  over per-cell `cell_bg`. Selection and reverse still work because bg is
  not baked into the tile.
- `====` is not `===` (JetBrains `calt` exact-run rule).
- `hello` is never shaped in `programming` or `off`.
- Box drawing (U+2502) is still `sprite.Face` and meets the cell edge.
- Emoji, graphemes, Kitty, custom shaders stay on today's path.

Flag off: no new per-cell work on the ASCII path. Existing tests are the bar.

## What this did

**A.** Table + skip shaper. `src/font/programming_ligatures.zig` is Jetty's
raw list, longest-first, `repeatTouchesSame`. `rebuildRow` skips
`runIterator` when the flag is on. Programming hits shape only that
substring and confirm by cmap mismatch, not x-offset.

**B.** Cell-box raster in CoreText and FreeType `renderGlyph` when
`RenderOptions.cell_box` is set. Tight path remains for emoji / color /
sprites / the flag-off rasterizer.

**C.** Tests: table, `spanLength`, collect (`ab=>cd`, `hello`, `-calt`,
`====`), cell-box `'A'` size/bearings, italic clip box, U+2502 sprite
height, 80-wide `'y'` row shape-count 0, one `=>` per line shape-count 1.

## What this did not do

- **Phase D (opaque mix) was not done.** `cell_text` is still the letter
  pipeline. A new `cell_letter` mix shader would fight Ghostty
  alpha-blending / minimum-contrast / P3. Leave A–C as the experiment.
- No second instance buffer layout.
- No website docs. No default-on.
- Did not change `src/terminal/page.zig`, parse, PTY, or libghostty-vt.
- Did not replace `src/font/sprite`.
- Did not use `constraint.size = .fit` for letters.

## Performance check

Not a ship gate. On the same binary, `programming` / `off`:

- 80-wide row of `'y'`: `shape()` count is 0.
- Row with one `=>`: `shape()` count is 1, not cell count.

`ghostty-bench` TerminalStream is VT, not this path.
