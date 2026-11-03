# Upstream drafts

Fixes Apex carries for upstream bugs, written up for the owner to file upstream. Nothing here
is filed: each file is a draft, and filing one, under whose name and where, is the owner's
call.

These files sit outside `packaging/**`, so no lane key moves when they change. The patches
Apex builds stay in `packaging/pkgs/*/patches/`. A draft here is the same change rebased
onto the project's main branch, with an upstream commit message and none of the Apex-only
notes.

| Directory | Project | Upstream |
|---|---|---|
| `gnome-shell/` | GNOME Shell | <https://gitlab.gnome.org/GNOME/gnome-shell> |

Each draft is a pair:

- `NNNN-name.patch`: `git format-patch` output against the project's main branch, checked
  with `git apply --check` on the commit its `.md` names.
- `NNNN-name.md`: what upstream already has, what to file, the evidence, and the issue,
  merge request or comment text, ready to paste.

`NNNN` is the number of the Apex series patch the draft comes from. A series patch is
dropped once its fix reaches the Fedora build Apex rebuilds. The draft goes when upstream
merges it or a fix of its own.
