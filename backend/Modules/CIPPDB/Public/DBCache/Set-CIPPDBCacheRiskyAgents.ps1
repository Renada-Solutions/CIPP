function Set-CIPPDBCacheRiskyAgents {
    <#
    .SYNOPSIS
        Caches risky agents from Identity Protection for a tenant

    .PARAMETER TenantFilter
        The tenant to cache risky agents for

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
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message 'Caching risky agents from Identity Protection' -sev Debug

        # Preview API; identityType values beyond the original enum need the Prefer header
        $RiskyAgents = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/identityProtection/riskyAgents' -tenantid $TenantFilter -AsApp $true -extraHeaders @{ Prefer = 'include-unknown-enum-members' }

        Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'RiskyAgents' -Data @($RiskyAgents) -AddCount
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Cached $(@($RiskyAgents).Count) risky agents" -sev Debug

    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Failed to cache risky agents (Identity Protection may not be available): $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
    }
}
