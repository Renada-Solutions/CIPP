function Set-CIPPDBCacheAgentPackages {
    <#
    .SYNOPSIS
        Caches Microsoft Agent 365 / Copilot catalog packages for a tenant

    .PARAMETER TenantFilter
        The tenant to cache agent packages for

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
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message 'Caching Agent 365 packages' -sev Debug

        # Requires a Microsoft Agent 365 license; tenants without one fail here and keep no data
        $Packages = @(Get-CIPPAgent365Packages -TenantFilter $TenantFilter)

        Add-CIPPDbItem -TenantFilter $TenantFilter -Type 'AgentPackages' -Data @($Packages) -AddCount
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Cached $($Packages.Count) Agent 365 packages" -sev Debug

    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'CIPPDBCache' -tenant $TenantFilter -message "Failed to cache Agent 365 packages (a Microsoft Agent 365 license is required): $($ErrorMessage.NormalizedError)" -sev Warning -LogData $ErrorMessage
    }
}
