# Ghostty v1.3.1-patched.3

This patch builds on `v1.3.1-patched.2` and makes Fontconfig's monospace
spacing preference configurable for explicitly selected font families.

## Configure font matching

The new Linux/FreeBSD Fontconfig option defaults to the existing behavior:

```ini
font-family-prefer-monospace = true
```

With `true`, configured fonts are matched with `spacing=100` (FC_MONO).
This is a sorting preference, not a strict filter.

To avoid this preference replacing a dual-width CJK font with an unrelated
family, configure:

```ini
font-family = Maple Mono Normal NF CN
font-family-prefer-monospace = false
```

With `false`, specific font families are matched without the extra spacing
preference. Fontconfig still applies its aliases, style matching, and system
rules. Font metadata is not rewritten. Automatic character fallback and the
generic `monospace` family retain their monospace preference.

The option applies to regular, bold, italic, and bold-italic font-family
settings. It participates in font-grid cache keys and supports configuration
reloads. macOS font matching is unchanged.
