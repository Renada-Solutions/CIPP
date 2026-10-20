function Set-CIPPDBCacheAgentIdentities {
    <#
    .SYNOPSIS
        Caches Microsoft Entra Agent ID agent identities for a tenant, with their owners and sponsors

    .DESCRIPTION
        Owners need AgentIdentity.Read.All. Sponsors can only be read with the application permission
        AgentIdentity.ReadWrite.All (delegated is not supported), so they are best-effort: when the
        lookup fails, sponsorsKnown is false and sponsors is empty, which consumers must treat as
        "unknown" rather than "no sponsor".

    .PARAMETER TenantFilter
        The tenant to cache agent identities for

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
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message 'Caching agent identities' -sev Debug

        $Agents = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity' -tenantid $TenantFilter -AsApp $true)

        if ($Agents.Count -gt 0) {
            $Select = '$select=id,displayName,userPrincipalName,appId'
            $Requests = foreach ($Agent in $Agents) {
                @{ id = "owners-$($Agent.id)"; method = 'GET'; url = "/servicePrincipals/$($Agent.id)/owners?$Select" }
                @{ id = "sponsors-$($Agent.id)"; method = 'GET'; url = "/servicePrincipals/$($Agent.id)/microsoft.graph.agentIdentity/sponsors?$Select" }
            }
            $BulkResults = @(New-GraphBulkRequest -Requests @($Requests) -tenantid $TenantFilter -asapp $true -Version 'v1.0')
            $ResultsById = @{}
            foreach ($Result in $BulkResults) { $ResultsById[$Result.id] = $Result }

            $SponsorFailures = 0
            foreach ($Agent in $Agents) {
                $Owners = $ResultsById["owners-$($Agent.id)"]
                $Sponsors = $ResultsById["sponsors-$($Agent.id)"]
                $SponsorsKnown = [bool]($Sponsors -and $Sponsors.status -eq 200)
                if (-not $SponsorsKnown) { $SponsorFailures++ }

                $Agent | Add-Member -NotePropertyName 'owners' -NotePropertyValue @(if ($Owners.status -eq 200) { $Owners.body.value }) -Force
                $Agent | Add-Member -NotePropertyName 'sponsors' -NotePropertyValue @(if ($SponsorsKnown) { $Sponsors.body.value }) -Force
                $Agent | Add-Member -NotePropertyName 'sponsorsKnown' -NotePropertyValue $SponsorsKnown -Force
            }

            if ($SponsorFailures -gt 0) {
                Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Could not read sponsors for $SponsorFailures agent identities. Reading sponsors requires the AgentIdentity.ReadWrite.All application permission." -sev Debug
            }
        }

        # Write even when empty so "no agents" is distinguishable from "cache not run"
        Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'AgentIdentities' -Data $Agents -AddCount
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Cached $($Agents.Count) agent identities" -sev Debug

    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Failed to cache agent identities: $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
    }
}
