# Windows Terminal Skill for GitHub Copilot CLI

Control Windows Terminal tab title and color from within Copilot CLI sessions.

## Requirements

- **PowerShell 7+** (pwsh)
- Windows Terminal
- GitHub Copilot CLI

## Installation

1. Copy this folder to `~/.copilot/skills/windows-terminal/`
2. Add to your PowerShell `$PROFILE`:
   ```powershell
   Import-Module "$env:USERPROFILE\.copilot\skills\windows-terminal\WindowsTerminalSkill.psd1"
   ```
3. Restart your terminal

## Usage

From inside a Copilot CLI session:

```
!tab "Bug Fix" red
!tab "Feature Work" green  
!tab "Research" blue
!tab "My Task"              # default purple
```

## Named Colors

| Color | Alias | Hex |
|-------|-------|-----|
| red | bug | E74C3C |
| green | feature | 2ECC71 |
| blue | research | 3498DB |
| purple | refactor | 9B59B6 |
| orange | devops | E67E22 |
| yellow | test | F1C40F |
| pink | - | E91E63 |
| cyan | - | 00BCD4 |

Or use any 6-digit hex color: `!tab "Custom" "FF5733"`

## How It Works

Uses Windows Terminal's OSC 4 escape sequence with color table index 264 (FRAME_BACKGROUND) to set the tab color. The `!` prefix in Copilot CLI runs commands in the parent shell context where the escape codes reach Windows Terminal directly.

## Files

- `WindowsTerminalSkill.psm1` - PowerShell module
- `WindowsTerminalSkill.psd1` - Module manifest  
- `SKILL.md` - Copilot skill definition
- `README.md` - This file

## License

MIT
