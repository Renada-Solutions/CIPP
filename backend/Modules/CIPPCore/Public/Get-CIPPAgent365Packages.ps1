function Get-CIPPAgent365Packages {
    <#
    .SYNOPSIS
        Lists Microsoft Agent 365 / Copilot catalog packages for a tenant

    .DESCRIPTION
        Calls the Package Management API (requires a Microsoft Agent 365 license on the tenant) with
        delegated auth: the API currently fails under application context (424 Failed Dependency on
        GET, partial on LIST). Agents are NOT returned by the default list, so this also queries
        supportedHosts=Copilot and merges the results (deduped by id). An explicit OData filter
        overrides the default merge. A failed query is skipped as long as another query succeeds,
        so one bad call does not discard results already collected; if every query fails the last
        error is thrown.

    .PARAMETER TenantFilter
        The tenant to list packages for

    .PARAMETER Filter
        Optional OData filter expression that replaces the default queries

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [string]$Filter
    )

    $BaseUri = 'https://graph.microsoft.com/beta/copilot/admin/catalog/packages'
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $Uris = @("$BaseUri`?`$filter=$Filter")
    } else {
        $Uris = @(
            $BaseUri
            "$BaseUri`?`$filter=supportedHosts/any(x:x eq 'Copilot')"
        )
    }

    $Packages = [System.Collections.Generic.List[object]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new()
    $Succeeded = 0
    $LastError = $null
    foreach ($Uri in $Uris) {
        try {
            foreach ($Package in @(New-GraphGetRequest -uri $Uri -tenantid $TenantFilter)) {
                if ($Package.id -and $Seen.Add([string]$Package.id)) {
                    $Packages.Add($Package)
                }
            }
            $Succeeded++
        } catch {
            $LastError = $_
            Write-Information "Agent 365 package query failed for $TenantFilter ($Uri): $($_.Exception.Message)"
        }
    }

    if ($Succeeded -eq 0 -and $LastError) {
        throw $LastError
    }

    return @($Packages)
}
