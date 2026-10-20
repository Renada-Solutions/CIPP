function Set-CIPPDBCacheAgentIdentityBlueprints {
    <#
    .SYNOPSIS
        Caches Microsoft Entra Agent ID blueprints registered in a tenant

    .PARAMETER TenantFilter
        The tenant to cache agent identity blueprints for

    .PARAMETER QueueId
        The queue ID to update with total tasks (optional)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [string]$QueueId
    )

    try {
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message 'Caching agent identity blueprints' -sev Debug

        # Blueprints are applications, so credential expiry comes back with them
        $Blueprints = New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,appId,displayName,publisherDomain,createdDateTime,passwordCredentials,keyCredentials' -tenantid $TenantFilter -AsApp $true

        # Write an empty marker so "no blueprints" is distinguishable from "cache not run"
        Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'AgentIdentityBlueprints' -Data @($Blueprints) -AddCount
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Cached $(@($Blueprints).Count) agent identity blueprints" -sev Debug

    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Failed to cache agent identity blueprints: $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
    }
}
