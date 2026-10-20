function Invoke-ListAgent365Packages {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Standards.Read
    .DESCRIPTION
        Lists Microsoft Agent 365 / Copilot packages (agents and Microsoft 365 apps) in the tenant
        catalog via the Package Management API. Requires a Microsoft Agent 365 license on the tenant.
        Uses delegated auth: the Package Management API currently fails under application context
        (424 Failed Dependency on GET, partial on LIST). Agents are NOT returned by the default list,
        so this also queries supportedHosts=Copilot and merges the results (deduped by id). An explicit
        OData $filter (Filter query parameter) overrides the default merge.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $Filter = $Request.Query.Filter ?? $Request.Body.Filter

    try {
        $Results = @(Get-CIPPAgent365Packages -TenantFilter $TenantFilter -Filter $Filter)
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Results = $ErrorMessage.Message
        $StatusCode = [HttpStatusCode]::InternalServerError
        Write-LogMessage -API 'Agent365Packages' -tenant $TenantFilter -message "Could not list Agent 365 packages (a Microsoft Agent 365 license is required). Error: $($ErrorMessage.NormalizedError)" -Sev 'Error' -LogData $ErrorMessage
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Results
        })
}
