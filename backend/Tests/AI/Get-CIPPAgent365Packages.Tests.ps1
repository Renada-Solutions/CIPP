# Pester tests for Get-CIPPAgent365Packages
# Verifies the default and agent queries are merged, and that one failing query does not discard the other

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'Get-CIPPAgent365Packages.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate Get-CIPPAgent365Packages.ps1 under Modules/' }

    function New-GraphGetRequest { param($uri, $tenantid, $AsApp) }
    . $FunctionPath
}

Describe 'Get-CIPPAgent365Packages' {
    It 'merges the default list with the Copilot agent list and removes duplicates' {
        Mock -CommandName New-GraphGetRequest -MockWith {
            if ($uri -like '*supportedHosts*') {
                @([pscustomobject]@{ id = 'agent-1' }, [pscustomobject]@{ id = 'app-1' })
            } else {
                @([pscustomobject]@{ id = 'app-1' }, [pscustomobject]@{ id = 'app-2' })
            }
        }
        $Result = @(Get-CIPPAgent365Packages -TenantFilter 'contoso.onmicrosoft.com')
        $Result.id | Should -Be @('app-1', 'app-2', 'agent-1')
    }

    It 'keeps results from the query that succeeded when the other fails' {
        Mock -CommandName New-GraphGetRequest -MockWith {
            if ($uri -like '*supportedHosts*') { throw 'Forbidden' }
            @([pscustomobject]@{ id = 'app-1' })
        }
        $Result = @(Get-CIPPAgent365Packages -TenantFilter 'contoso.onmicrosoft.com')
        $Result.id | Should -Be @('app-1')
    }

    It 'throws when every query fails' {
        Mock -CommandName New-GraphGetRequest -MockWith { throw 'No Agent 365 license' }
        { Get-CIPPAgent365Packages -TenantFilter 'contoso.onmicrosoft.com' } | Should -Throw '*No Agent 365 license*'
    }

    It 'uses only the explicit filter when one is given' {
        Mock -CommandName New-GraphGetRequest -MockWith { @([pscustomobject]@{ id = 'pending-1' }) }
        $Result = @(Get-CIPPAgent365Packages -TenantFilter 'contoso.onmicrosoft.com' -Filter "requestStatus eq 'pending'")
        $Result.id | Should -Be @('pending-1')
        Should -Invoke New-GraphGetRequest -Times 1 -Exactly
    }
}
