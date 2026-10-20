function Get-CIPPAIAgentTenants {
    <#
    .SYNOPSIS
        Returns the tenants that have AI agent data in the CIPP reporting database

    .DESCRIPTION
        Expands a tenant filter into the tenants to read: AllTenants becomes every tenant whose latest
        AgentIdentities or AgentPackages refresh returned data and is still a managed tenant; any other value is
        returned as-is.

    .PARAMETER TenantFilter
        A tenant domain or AllTenants

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    if ($TenantFilter -ne 'AllTenants') {
        return @($TenantFilter)
    }

    $WithData = foreach ($Type in @('AgentIdentities', 'AgentPackages')) {
        # A zero count means the last refresh found nothing, even if older rows remain
        Get-CIPPDbItem -TenantFilter 'allTenants' -Type $Type -CountsOnly | Where-Object { [int]$_.DataCount -gt 0 } | Select-Object -ExpandProperty PartitionKey
    }
    $Managed = (Get-Tenants -IncludeErrors).defaultDomainName
    return @($WithData | Sort-Object -Unique | Where-Object { $Managed -contains $_ })
}
