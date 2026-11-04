# Wallpapers for board 23's chooser

`run.sh` replaces the system's `gnome-background-properties` lists with `apex-test.xml`, which lists
these PNGs in a fixed order. Upstream's JXL wallpapers decode a few pixels differently on
different CPUs (libjxl picks its SIMD path at runtime), and their lists load in no set order. That
left board 23's capture flipping between runners. A PNG decodes the same everywhere.

The images are cropped and scaled copies of GNOME's wallpapers from **gnome-backgrounds 51.0.1**
(Fedora 45's `gnome-backgrounds-51.0.1-1.fc45`), by the GNOME Design Team and contributors. Each
is a centred 16:10 crop at 240×150, the size the chooser draws a thumbnail at scale 2. Amber is a
centred 400×400 crop, wide enough for the Style previews' 4:3 crop at scale 2. `apex-test.xml`
keeps upstream's names, options and colours.

Licence: Creative Commons Attribution-ShareAlike 3.0 United States (CC-BY-SA-3.0-US), as
upstream. See `COPYING`, upstream's licence notice from the package, and
<https://creativecommons.org/licenses/by-sa/3.0/us/>. The rest of `tests/` is GPL-3.0-or-later.
