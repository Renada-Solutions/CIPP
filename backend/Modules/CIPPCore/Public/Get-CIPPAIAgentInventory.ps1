function Get-CIPPAIAgentInventory {
    <#
    .SYNOPSIS
        Returns the normalised AI agent inventory for a tenant from the CIPP reporting database

    .DESCRIPTION
        Reads only cached data (refresh it with the AIAgents cache collection or ExecCIPPDBCache) and
        hands it to ConvertTo-CIPPAIAgentInventory. Also reports, per source, whether data has been
        collected and when, so the UI can tell "no agents" apart from "not collected" or "not licensed".

    .PARAMETER TenantFilter
        The tenant domain to read

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    $Sources = [ordered]@{
        AgentIdentities         = 'Entra Agent ID'
        AgentIdentityBlueprints = 'Entra Agent ID blueprints'
        AgentPackages           = 'Agent 365 catalog'
        RiskyAgents             = 'Identity Protection'
    }

    $Counts = @{}
    foreach ($Row in @(Get-CIPPDbItem -TenantFilter $TenantFilter -CountsOnly)) {
        $Type = ([string]$Row.RowKey) -replace '-Count$', ''
        $Counts[$Type] = $Row
    }

    $DataStatus = foreach ($Type in $Sources.Keys) {
        [PSCustomObject]@{
            type        = $Type
            source      = $Sources[$Type]
            collected   = $Counts.ContainsKey($Type)
            count       = $Counts[$Type].DataCount
            lastRefresh = $Counts[$Type].Timestamp
        }
    }

    # Only read a type that holds rows: an empty refresh resets the count to 0 but does not remove
    # the previous rows, so a stale agent or risk would otherwise linger after it is gone
    $HasRows = { param($Type) $Counts.ContainsKey($Type) -and [int]$Counts[$Type].DataCount -gt 0 }

    $Data = @{}
    foreach ($Type in @('AgentIdentities', 'AgentIdentityBlueprints', 'AgentPackages', 'RiskyAgents')) {
        $Data[$Type] = if (& $HasRows $Type) { @(New-CIPPDbRequest -TenantFilter $TenantFilter -Type $Type) } else { @() }
    }

    # Permissions are only resolved for agent identities, and these are among the largest cached
    # types, so skip them for tenants without agents (most tenants in an AllTenants view)
    foreach ($Type in @('AppRoleAssignments', 'OAuth2PermissionGrants')) {
        $Data[$Type] = if ($Data['AgentIdentities'].Count -gt 0 -and (& $HasRows $Type)) { @(New-CIPPDbRequest -TenantFilter $TenantFilter -Type $Type) } else { @() }
    }
    # Only the fields needed to name permissions
    $Data['ServicePrincipals'] = if (($Data['AppRoleAssignments'].Count -gt 0 -or $Data['OAuth2PermissionGrants'].Count -gt 0) -and (& $HasRows 'ServicePrincipals')) {
        @(New-CIPPDbRequest -TenantFilter $TenantFilter -Type 'ServicePrincipals' -Fields @('id', 'displayName', 'appRoles'))
    } else { @() }

    try {
        $RiskyPermissions = @(Get-Content (Join-Path $env:CIPPRootPath 'Config\RiskyPermissions.json') -Raw -ErrorAction Stop | ConvertFrom-Json)
    } catch {
        Write-LogMessage -API 'AIAgents' -tenant $TenantFilter -message "Could not load RiskyPermissions.json: $($_.Exception.Message)" -sev Warning
        $RiskyPermissions = @()
    }

    $Agents = ConvertTo-CIPPAIAgentInventory -AgentIdentities $Data['AgentIdentities'] -Blueprints $Data['AgentIdentityBlueprints'] -Packages $Data['AgentPackages'] -RiskyAgents $Data['RiskyAgents'] -ServicePrincipals $Data['ServicePrincipals'] -AppRoleAssignments $Data['AppRoleAssignments'] -OAuth2PermissionGrants $Data['OAuth2PermissionGrants'] -RiskyPermissions $RiskyPermissions

    return [PSCustomObject]@{
        Tenant     = $TenantFilter
        Agents     = @($Agents)
        DataStatus = @($DataStatus)
    }
}
