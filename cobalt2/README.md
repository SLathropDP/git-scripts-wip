# Cobalt2 Theme for Locked-Down VS Code

Apply the [Cobalt2 Theme Official](https://github.com/wesbos/cobalt2-vscode) colors to VS Code without installing the extension — useful when your organization restricts marketplace extensions.

The script re-skins the built-in **Tomorrow Night Blue** theme by injecting Cobalt2's UI colors, syntax highlighting, and semantic token rules into your user `settings.json`, scoped so other themes are unaffected.

## Files

| File | Description |
|------|-------------|
| `cobalt2-theme.json` | Complete Cobalt2 color definitions (UI, tokenColors, semanticTokenColors) |
| `apply-cobalt2-to-tomorrow-night-blue.ps1` | PowerShell script to apply/revert the theme |
| `cobalt2.bat` | CMD wrapper for the PowerShell script |

## Usage

```powershell
# Apply Cobalt2 colors to Tomorrow Night Blue
.\apply-cobalt2-to-tomorrow-night-blue.ps1

# Revert to original Tomorrow Night Blue
.\apply-cobalt2-to-tomorrow-night-blue.ps1 -Undo
```

Or from CMD:

```cmd
cobalt2.bat
cobalt2.bat -Undo
```

After running, open VS Code and select **Tomorrow Night Blue** from the theme picker (`Ctrl+K Ctrl+T`).

## Notes

- A timestamped backup of your `settings.json` is created before any changes.
- Only the **Tomorrow Night Blue** theme is affected — all other themes remain unchanged.
- Restart or reload VS Code after running the script to pick up changes.
