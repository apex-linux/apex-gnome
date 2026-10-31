# hc-default-buttons: white on the accent in the high-contrast sheet

Not from an Apex series patch: Apex keeps upstream's high-contrast sheet (DESIGN), and G2
records these failures as known gaps (`A11Y_GAPS` in `tests/shots/assert.sh`), 38 rows in
the `high-contrast` and `high-contrast-solid` cases. `hc-default-buttons.patch` is the fix
for upstream, Path A of the owner's choice. `git apply --check` passes on gnome-shell main
9a753aa (2026-10-29) and on 51.0, whose `_drawing.scss` and `_high-contrast-colors.scss`
are byte for byte main's.

## What upstream has (2026-10-30)

Nothing. Main's button mixin still boosts a default button's background with
`hc_color_mix()` towards `$hc_mix_color` (`$light_1`). Issue and MR searches for high
contrast, contrast ratios, the accent, `hc_color_mix` and the calendar's today find no
report. The nearest are:

- #4672 (2021, closed): high contrast used the wrong toggle style;
- !3109 (2024, merged): the refactor of the button and entry drawing that gave every
  button state the high-contrast boost;
- !3554 (2024, merged): the separation in quick setting buttons, which set the menu arrow's
  colour.

## What to file

An issue, then an MR with `hc-default-buttons.patch`. Text below.

## Evidence

- **The colours, compiled** (gnome-shell main with and without the patch, `sassc -a`):
  - the light and dark sheets are byte-identical;
  - the high-contrast sheet changes 12 `background-color` declarations and nothing else. At
    rest a checked quick toggle and today read `st-mix(-st-accent-color, #000000, 75%)`, and
    the menu arrow reads `st-mix(st-mix(-st-accent-color, #ffffff, 75%), #000000, 75%)`.
- **Measured in G2** (2026-10-30): `tests/shots/patched.sh` with `PATCHED_PART=pr` on
  apex-gnome main 84d0a54, built with the patch as a scratch 21st series patch, on 51.0.
  Contrast is measured from the stage's pixels at scale 2, under all nine accent colours:

  | Surface (`high-contrast` and `high-contrast-solid`) | Before | After |
  |---|---|---|
  | A checked quick toggle's text | 3.15:1 (blue) | 5.0:1 or more |
  | Its menu arrow | 2.31:1 (blue) | 3.93:1 or more |
  | The calendar's today | 2.59:1 (yellow) to 3.79:1 (red) | 5.0:1 (yellow) to 8.83:1 (purple) |

  - All 38 of G2's high-contrast gap rows hold now: 19 in `high-contrast`, 19 in
    `high-contrast-solid`, covering Quick Settings and the date menu, by default and under
    each accent. `lib.sh` fails each one as "a known gap … but it holds now".
  - Nothing else moved against the same run on main (#177's CI, 98d1ed8): 1653 assertions
    pass, the same 1653, and the other 12 gaps stay gaps. That is 1653 passed, 38 failed,
    12 known gaps, against main's 1653 passed, 0 failed, 50 known gaps.

## Issue text

> **High contrast: white text on default buttons falls below WCAG AA**
>
> In the high-contrast sheet, `%default_button` (a checked quick toggle, the calendar's
> today, a dialog's default button) draws `-st-accent-fg-color`, white, on the accent. The
> button mixin then boosts every button's background with `hc_color_mix()`, which mixes it
> 87% with `$hc_mix_color`, a light colour: for white text that lowers the contrast.
>
> Measured from the stage's pixels in gnome-shell 51.0 at scale 2, with each surface's own
> colours (WCAG 1.4.3 wants 4.5:1 for text, 1.4.11 3:1 for a glyph):
>
> | Surface | Contrast |
> |---|---|
> | A checked quick toggle's title, default blue | 3.15:1 |
> | Its menu arrow (the accent mixed 75% with the foreground first) | 2.31:1 |
> | The calendar's today, over the nine accent colours | 2.59:1 (yellow) to 3.79:1 (red) |
>
> Every accent but purple fails for the toggle; every one fails for today.

## Merge request text

> **theme: Darken default buttons' accent in high contrast**
>
> Default buttons draw white on the accent, so the high-contrast boost, which mixes a
> button's background towards a light colour, lowers their contrast. For the default style
> this mixes the accent with black instead: 75% of it at rest, 70% hovered or checked, 65%
> active (`$hc_default_mix_color`, `$hc_default_mix_factor` in
> `_high-contrast-colors.scss`).
>
> White text is then 5.0:1 or more on all nine accent colours (yellow is the lowest), the
> quick toggle's menu arrow 3.87:1 or more, and the arrow stays lighter than its toggle as
> in the other sheets. Interaction states darken instead of lighten, so they stay above
> 4.5:1 too: with the mixin's lightened states, hover would fall to 4.27:1 and active to
> 3.52:1 for yellow.
>
> Only `$contrast == 'high'` changes: the light and dark sheets compile to the same CSS.
> Focus and the combined states (active and hovered, checked and hovered) keep the mixin's
> existing mixes; I can extend them if you'd rather they followed.
>
> Fixes #NNNN
