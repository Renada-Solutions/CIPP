# Pester tests for Get-CIPPAIAgentInventory
# Verifies stale rows behind a zero count are ignored and permission data is only read for tenants with agents

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    foreach ($Name in @('Get-CIPPAIAgentInventory.ps1', 'ConvertTo-CIPPAIAgentInventory.ps1')) {
        $Path = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter $Name -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $Path) { throw "Could not locate $Name under Modules/" }
        . $Path
    }

    function Get-CIPPDbItem { param($TenantFilter, $Type, [switch]$CountsOnly) }
    function New-CIPPDbRequest { param($TenantFilter, $Type, $Fields) }
    function Write-LogMessage { param($API, $tenant, $message, $sev) }
    $env:CIPPRootPath = Join-Path $RepoRoot 'NonExistent'

    function New-CountRow ($Type, $Count) { [pscustomobject]@{ RowKey = "$Type-Count"; DataCount = $Count; Timestamp = [datetime]'2026-10-20' } }
}

Describe 'Get-CIPPAIAgentInventory' {
    BeforeEach {
        Mock New-CIPPDbRequest {
            switch ($Type) {
                'AgentIdentities' { @([pscustomobject]@{ id = 'agent-1'; displayName = 'Stale agent'; accountEnabled = $true; sponsorsKnown = $true; sponsors = @() }) }
                'RiskyAgents' { @([pscustomobject]@{ id = 'agent-1'; riskLevel = 'high'; riskState = 'atRisk' }) }
                default { @() }
            }
        }
    }

    It 'ignores rows left behind when the latest refresh returned nothing' {
        Mock Get-CIPPDbItem { @((New-CountRow 'AgentIdentities' 0), (New-CountRow 'RiskyAgents' 0), (New-CountRow 'AppRoleAssignments' 50)) }
        $Result = Get-CIPPAIAgentInventory -TenantFilter 'contoso.onmicrosoft.com'

        $Result.Agents.Count | Should -Be 0
        Should -Invoke New-CIPPDbRequest -Times 0 -Exactly
        ($Result.DataStatus | Where-Object type -EQ 'AgentIdentities').collected | Should -BeTrue
    }

    It 'reads permission data only when the tenant has agents' {
        Mock Get-CIPPDbItem { @((New-CountRow 'AgentIdentities' 1), (New-CountRow 'RiskyAgents' 1), (New-CountRow 'AppRoleAssignments' 50), (New-CountRow 'OAuth2PermissionGrants' 5), (New-CountRow 'ServicePrincipals' 300)) }
        $Result = Get-CIPPAIAgentInventory -TenantFilter 'contoso.onmicrosoft.com'

        $Result.Agents.Count | Should -Be 1
        $Result.Agents[0].riskLevel | Should -Be 'high'
        Should -Invoke New-CIPPDbRequest -Times 1 -Exactly -ParameterFilter { $Type -eq 'AppRoleAssignments' }
        # No grants or assignments came back, so service principals are not needed
        Should -Invoke New-CIPPDbRequest -Times 0 -Exactly -ParameterFilter { $Type -eq 'ServicePrincipals' }
    }
}
