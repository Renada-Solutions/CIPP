function Invoke-ListAIAgents {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.Read
    .DESCRIPTION
        Lists AI agents for a tenant (or all tenants) as normalised records: Microsoft Entra Agent ID
        identities merged with the Microsoft Agent 365 / Copilot catalog packages that reference them.
        Each record includes status, sponsors, owners, resolved permissions (read or write), risk, and
        an attention list of issues to act on. Reads CACHED data only; refresh it with the AIAgents
        cache collection (ExecCIPPDBCache).
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = 'ListAIAgents'
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter

    try {
        $Results = [System.Collections.Generic.List[object]]::new()
        foreach ($Tenant in @(Get-CIPPAIAgentTenants -TenantFilter $TenantFilter)) {
            try {
                $Inventory = Get-CIPPAIAgentInventory -TenantFilter $Tenant
                foreach ($Agent in $Inventory.Agents) {
                    $Agent | Add-Member -NotePropertyName 'Tenant' -NotePropertyValue $Tenant -Force
                    $Results.Add($Agent)
                }
            } catch {
                if ($TenantFilter -ne 'AllTenants') { throw }
                Write-LogMessage -API $APIName -tenant $Tenant -message "Failed to build AI agent inventory: $($_.Exception.Message)" -sev Warning
            }
        }
        $Body = @($Results)
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $TenantFilter -message "Failed to list AI agents: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $Body = @{ Results = "Failed to list AI agents: $($ErrorMessage.NormalizedError)" }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
