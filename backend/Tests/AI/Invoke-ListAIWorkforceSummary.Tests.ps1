# Pester tests for Invoke-ListAIWorkforceSummary
# Verifies per-tenant counts, totals and the cross-tenant attention list

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'Invoke-ListAIWorkforceSummary.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate Invoke-ListAIWorkforceSummary.ps1 under Modules/' }

    ([PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')).GetMethod('Add').Invoke(
        $null, @('HttpStatusCode', [System.Net.HttpStatusCode]))

    class HttpResponseContext {
        [int]$StatusCode
        [object]$Body
    }

    function Get-CIPPAIAgentTenants { param($TenantFilter) }
    function Get-CIPPAIAgentInventory { param($TenantFilter) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $sev, $LogData) }
    function Get-CippException { param($Exception) @{ NormalizedError = "$Exception" } }

    . $FunctionPath

    function New-Agent ($Id, $Status = 'Enabled', $Sponsor = 'Assigned', $Access = 'Read', $Attention = @()) {
        $Top = if ($Attention.Count -gt 0) { $Attention[0].severity } else { 'None' }
        [pscustomobject]@{ id = $Id; displayName = "Agent $Id"; source = 'Entra Agent ID'; status = $Status; sponsorStatus = $Sponsor; accessLevel = $Access; attention = $Attention; attentionCount = $Attention.Count; attentionSeverity = $Top }
    }
    function New-Item ($Severity, $Issue) { [pscustomobject]@{ severity = $Severity; issue = $Issue; action = 'Fix it' } }
}

Describe 'Invoke-ListAIWorkforceSummary' {
    BeforeEach {
        Mock Get-CIPPAIAgentTenants { @('a.onmicrosoft.com', 'b.onmicrosoft.com') }
        Mock Get-CIPPAIAgentInventory {
            $Status = @([pscustomobject]@{ type = 'AgentPackages'; collected = ($TenantFilter -eq 'a.onmicrosoft.com'); lastRefresh = [datetime]'2026-10-20' })
            if ($TenantFilter -eq 'a.onmicrosoft.com') {
                [pscustomobject]@{ Agents = @(
                        New-Agent 'a1' -Sponsor 'None' -Attention @(New-Item 'Warning' 'No sponsor assigned')
                        New-Agent 'a2' -Status 'Disabled'
                    ); DataStatus = $Status
                }
            } else {
                [pscustomobject]@{ Agents = @(
                        New-Agent 'b1' -Access 'Read and write' -Sponsor 'None' -Attention @(New-Item 'Critical' 'Can change data but has no sponsor')
                    ); DataStatus = $Status
                }
            }
        }
    }

    It 'aggregates totals across tenants' {
        $Response = Invoke-ListAIWorkforceSummary -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' }; Headers = @{} })
        $Response.StatusCode | Should -Be 200
        $Totals = $Response.Body.totals
        $Totals.tenants | Should -Be 2
        $Totals.agents | Should -Be 3
        $Totals.active | Should -Be 2
        $Totals.needAttention | Should -Be 2
        $Totals.critical | Should -Be 1
        $Totals.noSponsor | Should -Be 2
        $Totals.writeAccess | Should -Be 1
    }

    It 'orders tenants and attention items by severity' {
        $Response = Invoke-ListAIWorkforceSummary -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' }; Headers = @{} })
        $Response.Body.tenants[0].Tenant | Should -Be 'b.onmicrosoft.com'
        $Response.Body.attention.severity | Should -Be @('Critical', 'Warning')
        $Response.Body.attention[0].Tenant | Should -Be 'b.onmicrosoft.com'
        $Response.Body.tenants | Where-Object Tenant -EQ 'a.onmicrosoft.com' | Select-Object -ExpandProperty agent365Synced | Should -BeTrue
    }

    It 'skips a failing tenant in the all tenants view' {
        Mock Get-CIPPAIAgentInventory { throw 'boom' } -ParameterFilter { $TenantFilter -eq 'a.onmicrosoft.com' }
        $Response = Invoke-ListAIWorkforceSummary -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' }; Headers = @{} })
        $Response.StatusCode | Should -Be 200
        $Response.Body.totals.tenants | Should -Be 1
    }

    It 'returns an error for a failing single tenant' {
        Mock Get-CIPPAIAgentTenants { @('a.onmicrosoft.com') }
        Mock Get-CIPPAIAgentInventory { throw 'boom' }
        $Response = Invoke-ListAIWorkforceSummary -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'a.onmicrosoft.com' }; Headers = @{} })
        $Response.StatusCode | Should -Be 500
    }

    It 'returns zero totals when no tenant has data' {
        Mock Get-CIPPAIAgentTenants { @() }
        $Response = Invoke-ListAIWorkforceSummary -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' }; Headers = @{} })
        $Response.Body.totals.agents | Should -Be 0
        @($Response.Body.attention).Count | Should -Be 0
    }
}
