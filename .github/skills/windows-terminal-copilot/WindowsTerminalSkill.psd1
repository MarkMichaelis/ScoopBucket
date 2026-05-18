@{
    RootModule = 'WindowsTerminalSkill.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a1b2c3d4-5678-90ab-cdef-1234567890ab'
    Author = 'Copilot'
    Description = 'Control Windows Terminal tab title and color from child processes'
    FunctionsToExport = @('Start-TerminalListener', 'Set-TerminalDirect', 'Set-Tab', 'tab')
}
