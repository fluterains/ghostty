# Ghostty v1.3.1-patched.2

This patch builds on `v1.3.1-patched.1` and adds a complete command-line and
configuration path for creating GTK window layouts. Spatial navigation fixes
now live in Patch1.

## Launch layouts directly

- Add `--layout-file=/path/layout.json` to load and launch a layout without an
  auxiliary config file or launcher shell script.
- Add `--layout-name=NAME` to override the name derived from a layout file.
- Add `--layout=NAME` to launch a layout already registered by configuration.
- Layout launches use an independent GTK instance so their configuration cannot
  be silently discarded by an existing single-instance application.
- Add `+list-layouts` to list configured and temporary layouts.

## Configure named layouts

- Add `window-layout = name=path` for loading named JSON layout trees.
- Add `window-layout-default = name` for new GTK tabs and windows.
- Add `new_tab_with_layout:<name>` for key bindings.
- Support window, tab, horizontal/vertical split, and terminal nodes.
- Support per-terminal command, working directory, title, and initial focus.
- Validate layout file size, depth, node count, split shape, and focus count.
- Build the complete surface tree atomically before installing it.
- Initialize all panes as unfocused during bulk layout creation, then sync the
  selected surface into the core renderer before first render.

See `example/layouts/` for direct launch examples, a reusable named layout, and
a 10-pane layout.

Configured layout creation is currently implemented by the GTK runtime.

## Split rendering fixes

- Keep the complete GTK split hierarchy attached while toggling split zoom;
  zoom now hides and restores sibling branches instead of rebuilding the tree.
- Insert new splits directly into the existing hierarchy instead of detaching
  and reparenting every surface.
- Remove closed splits in place by promoting the surviving sibling subtree.
- Update split ratios for resize and equalize operations in place, without a
  full GTK widget-tree rebuild.
- Preserve split ratios when panes are hidden by zoom and restore focus after
  surfaces are mapped again.
- Retain the deferred full rebuild as a fallback when an incremental widget
  update cannot be completed safely.

## Split focus behavior

- Prefer the surviving sibling subtree when closing a split.
- When the sibling is a subtree, focus its leftmost leaf if the closed child was
  on the left, or its rightmost leaf if the closed child was on the right.
- This keeps focus continuous with the region that expands to replace the
  closed split while preserving deterministic behavior.
