# Window Layouts

Window layouts are JSON trees composed of these node types:

- `window`: a top-level window containing tabs.
- `tab`: one tab containing a single split tree.
- `split`: exactly two child nodes. `direction` is `horizontal` (left/right)
  or `vertical` (top/bottom). `ratio` controls the first child's size and
  defaults to `0.5`.
- `terminal`: a terminal leaf. Optional fields are `command`,
  `working_directory`, `title`, and `focus`.

## Open a layout file directly

No temporary config file or launcher script is required:

```sh
ghostty --layout-file=./grid-10.json
```

The layout name is derived from the file name (`grid-10` above). Override it
with:

```sh
ghostty \
  --layout-name=workspace \
  --layout-file=./grid-10.json
```

Layouts supplied on the command line use an independent GTK instance so the
request cannot be consumed by an already-running process with different
configuration.

## Register named layouts

Register reusable layouts in Ghostty's configuration:

```ini
window-layout = dev=./dev.json
```

Use the layout explicitly with a key binding:

```ini
keybind = ctrl+shift+t=new_tab_with_layout:dev
```

Or make it the default for newly-created tabs and windows:

```ini
window-layout-default = dev
```

`new_tab_with_layout` currently requires a layout that resolves to exactly one
tab. Use a top-level `split` or `terminal`, or a `window` containing exactly one
`tab` child. Configured layout creation is currently implemented by the GTK app
runtime.

The same named layout can be selected when launching Ghostty:

```sh
ghostty --layout=dev
```

List all registered layouts, including a layout supplied on the command line:

```sh
ghostty +list-layouts
ghostty +list-layouts --layout-file=./dev.json
```
