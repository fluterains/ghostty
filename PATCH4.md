# Ghostty v1.3.1-patched.4

This patch builds on `v1.3.1-patched.3` and corrects GTK initial window sizing
when client-side header and tab bars occupy space inside the window.

- Treat the initial terminal size as content dimensions, adding the measured
  vertical space outside the terminal tab view before setting the window size.
- Measure the current widget hierarchy instead of assuming a fixed titlebar
  height, accounting for visible header/tab bars and the debug warning.
- Account for GTK window CSS borders and padding so resize insets do not
  consume terminal columns or rows.
- Use the same conversion for the pre-presentation size estimate, the first
  surface's authoritative size, and its minimum-height hint.
- Preserve the existing one-time initialization guard. Creating subsequent
  tabs or splits does not reapply the initial window dimensions.

`window-width` and `window-height` still specify terminal columns and rows.
Window-manager constraints, maximization, and fullscreen can override initial
window sizing. A split layout shares the content area between its panes.
