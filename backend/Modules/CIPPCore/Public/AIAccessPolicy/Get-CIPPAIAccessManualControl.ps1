function Get-CIPPAIAccessManualControl {
    <#
    .SYNOPSIS
        Returns the catalogue of AI Access Policy controls that must be set by hand

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param()

    @(Get-Content (Join-Path $env:CIPPRootPath 'Config\AIAccessManualControls.json') -Raw | ConvertFrom-Json)
}
