# Ghostty v1.3.1-patched.1

This patch contains the spatial split-navigation hardening developed for the
1.3.1 GTK runtime.

## Spatial focus navigation

- Do not let a recent-focus candidate with a tiny edge overlap beat a
  substantially aligned neighbor.
- Prefer explicit view equality when available instead of relying only on
  pointer identity.
- Add `split-focus-wrap` to optionally disable wrapping at split-layout edges.
- Preserve existing geometric navigation and screen-edge wrapping behavior when
  enabled.
- Resolve transient multi-focus states using the explicit last-focused pane.
- Avoid mutating focus state when creating a split fails.
- Remove stale focus-history entries when a split tree is replaced or a
  terminal closes.

The GTK runtime remains the supported implementation for this patch.

## Linux desktop integration

- Localize the desktop entry comment and new-window action into Simplified
  Chinese (`zh_CN`).
- Apply initial maximize and fullscreen state after the GTK window is mapped,
  because X11 window managers may ignore requests made before presentation.
