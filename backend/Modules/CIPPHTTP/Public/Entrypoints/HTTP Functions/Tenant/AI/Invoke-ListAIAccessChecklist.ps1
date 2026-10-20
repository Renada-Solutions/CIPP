function Invoke-ListAIAccessChecklist {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.Read
    .DESCRIPTION
        Lists the AI controls that must be set by hand for a tenant (no Microsoft or vendor API), with
        who confirmed each one and when, whether a review is due (every 90 days), and which applied AI
        Access Policies require it.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $ReviewDays = 90

    try {
        if (-not $TenantFilter -or $TenantFilter -eq 'AllTenants') { throw 'Select a single tenant to see its checklist.' }

        $RequiredBy = @{}
        $TemplateIds = @(Get-CIPPAIAccessAppliedTemplateId -TenantFilter $TenantFilter)
        if ($TemplateIds.Count -gt 0) {
            foreach ($Policy in @(Get-CIPPAIAccessPolicyTemplate -Id $TemplateIds)) {
                foreach ($Id in @($Policy.manualControls)) {
                    if (-not $RequiredBy.ContainsKey($Id)) { $RequiredBy[$Id] = [System.Collections.Generic.List[string]]::new() }
                    $RequiredBy[$Id].Add($Policy.name)
                }
            }
        }

        $Table = Get-CIPPTable -tablename 'AIAccessChecklist'
        $Escaped = $TenantFilter -replace "'", "''"
        $Confirmations = @{}
        foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$Escaped'")) { $Confirmations[$Row.RowKey] = $Row }

        $Now = [datetime]::UtcNow
        $Body = foreach ($Control in @(Get-CIPPAIAccessManualControl)) {
            $Confirmation = $Confirmations[$Control.id]
            $ConfirmedAt = if ($Confirmation.ConfirmedAt) { try { ([datetime]$Confirmation.ConfirmedAt).ToUniversalTime() } catch { $null } }
            $Status = if (-not $ConfirmedAt) { 'Not confirmed' } elseif ($ConfirmedAt.AddDays($ReviewDays) -lt $Now) { 'Review due' } else { 'Confirmed' }
            [pscustomobject]@{
                id          = $Control.id
                title       = $Control.title
                area        = $Control.area
                where       = $Control.where
                link        = $Control.link
                reason      = $Control.reason
                required    = $RequiredBy.ContainsKey($Control.id)
                requiredBy  = @($RequiredBy[$Control.id])
                status      = $Status
                confirmedBy = $Confirmation.ConfirmedBy
                confirmedAt = $ConfirmedAt
                reviewBy    = if ($ConfirmedAt) { $ConfirmedAt.AddDays($ReviewDays) }
                note        = $Confirmation.Note
            }
        }
        $Body = @($Body | Sort-Object -Property @{ Expression = 'required'; Descending = $true }, 'area', 'title')
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $TenantFilter -message "Could not load AI Access checklist: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $Body = @{ Results = "Could not load AI Access checklist: $($ErrorMessage.NormalizedError)" }
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
