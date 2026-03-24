# Niri Keybinding Compatibility

This document describes how idx0 maps niri-oriented actions in the keyboard system.

Legend:
- `exact`: same intent and same Mod-centric pattern.
- `adapted`: same intent with macOS-constrained equivalent.
- `unsupported`: action not available in idx0 today.

Default `Mod` in idx0 is `Command+Option`.

| Niri-oriented action | idx0 mapped action | Both mode (default) | macOS-first | Niri-first | Compatibility | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Focus left | `Niri: Focus Left` | `⌘⌥←` and `⌘⌥H` | `⌘⌥←` | `⌘⌥H` | exact | Keeps directional muscle memory (`H/J/K/L`). |
| Focus down | `Niri: Focus Down` | `⌘⌥↓` and `⌘⌥J` | `⌘⌥↓` | `⌘⌥J` | exact |  |
| Focus up | `Niri: Focus Up` | `⌘⌥↑` and `⌘⌥K` | `⌘⌥↑` | `⌘⌥K` | exact |  |
| Focus right | `Niri: Focus Right` | `⌘⌥→` and `⌘⌥L` | `⌘⌥→` | `⌘⌥L` | exact |  |
| Focus workspace up | `Niri: Focus Workspace Up` | `⌘⌥⌃↑`, `⌘⌥U`, `⌘⌥PgUp` | `⌘⌥⌃↑` | `⌘⌥U`, `⌘⌥PgUp` | exact | Supports `U/I` and page-style flows. |
| Focus workspace down | `Niri: Focus Workspace Down` | `⌘⌥⌃↓`, `⌘⌥I`, `⌘⌥PgDn` | `⌘⌥⌃↓` | `⌘⌥I`, `⌘⌥PgDn` | exact | Supports `U/I` and page-style flows. |
| Move column to workspace up | `Niri: Move Column To Workspace Up` | `⌘⌥⇧U`, `⌘⌥⇧PgUp` | unassigned | `⌘⌥⇧U`, `⌘⌥⇧PgUp` | exact | Exposed in command menu and shortcut settings. |
| Move column to workspace down | `Niri: Move Column To Workspace Down` | `⌘⌥⇧I`, `⌘⌥⇧PgDn` | unassigned | `⌘⌥⇧I`, `⌘⌥⇧PgDn` | exact | Exposed in command menu and shortcut settings. |
| Toggle overview | `Niri: Toggle Overview` | `⌘⌥O` | `⌘⌥O` | `⌘⌥O` | exact |  |
| Toggle tabbed column display | `Niri: Toggle Column Tabbed Display` | `⌘⌥⇧T` | `⌘⌥⇧T` | `⌘⌥⇧T` | exact | Remapped from `⌘⌥T` to avoid conflict with new add-terminal binding. |
| Toggle focused tile zoom | `Niri: Toggle Focused Tile Zoom` | `⌘⌥F` | `⌘⌥F` | `⌘⌥F` | adapted | Focused tile fills canvas viewport; `Esc` exits zoom mode. |
| Close focused tile/pane | `Close Pane / Tile` | `⌘⇧W`, `⌘⌥W`, and `⌘⌥⇧Q` | `⌘⇧W` | `⌘⌥W` | adapted | Keeps legacy `⌘⌥⇧Q` alias while promoting `⌘⌥W` in Niri flows. |
| Close focused session/window | `Close Session` | `⌘W` and `⌘⌥Q` | `⌘W` | `⌘⌥Q` | adapted | Uses session-close semantics in local monitor. |
| Spawn terminal right | `Niri: Add Terminal Right` | `⌘⌥T` and `⌘⌥\` | `⌘⌥T` | `⌘⌥T` | exact | `⌘⌥\` remains as a legacy alias. |
| Spawn task below | `Niri: Add Task Below` | `⌘⌥⇧\` | `⌘⌥⇧\` | `⌘⌥⇧\` | exact |  |
| Spawn browser tile | `Niri: Add Browser Tile` | `⌘⌥B` | `⌘⌥B` | `⌘⌥B` | adapted | Browser tile is an idx0 addition. |
| Zoom focused web tile in/out | `Zoom In/Out Focused Web Tile` | `⌘=` / `⌘-` and `⌘⌥=` / `⌘⌥-` | `⌘=` / `⌘-` | `⌘⌥=` / `⌘⌥-` | adapted | Applies to browser-like Niri tiles. |
| Move column left/right between columns | none | none | none | none | unsupported | Not implemented as dedicated command yet. |
| Move workspace left/right | none | none | none | none | unsupported | Workspace axis in idx0 is up/down. |

## Notes

- `Both` mode is the default and activates both preset families.
- `Custom` mode allows per-action overrides with strict conflict blocking.
- Keyboard display in menus, palette, first-run hints, and shortcut sheet is resolved from the same registry.
