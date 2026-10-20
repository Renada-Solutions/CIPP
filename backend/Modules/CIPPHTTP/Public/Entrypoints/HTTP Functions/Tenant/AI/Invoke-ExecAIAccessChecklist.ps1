function Invoke-ExecAIAccessChecklist {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.ReadWrite
    .DESCRIPTION
        Records that a manual AI control has been set in a tenant (Confirm), or clears the record
        (Clear). The confirming user and time are stored; a review is due 90 days later.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    # Query first, as Test-CIPPAccess checks it first
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $Action = $Request.Body.Action ?? 'Confirm'
    $Ids = @(@($Request.Body.id ?? $Request.Body.ids) | ForEach-Object { if ($_.value) { $_.value } else { $_ } } | Where-Object { $_ })

    try {
        if (-not $TenantFilter -or $TenantFilter -eq 'AllTenants') { throw 'Select a single tenant.' }
        if ($Action -notin @('Confirm', 'Clear')) { throw "Unknown action '$Action'." }
        $Known = (Get-CIPPAIAccessManualControl).id
        $Unknown = @($Ids | Where-Object { $_ -notin $Known })
        if ($Ids.Count -eq 0 -or $Unknown.Count -gt 0) { throw "Unknown checklist item: $($Unknown -join ', ')" }

        $User = try {
            ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Headers.'x-ms-client-principal')) | ConvertFrom-Json).userDetails
        } catch { 'Unknown user' }

        $Table = Get-CIPPTable -tablename 'AIAccessChecklist'
        foreach ($Id in $Ids) {
            if ($Action -eq 'Confirm') {
                Add-CIPPAzDataTableEntity @Table -Force -Entity @{
                    PartitionKey = [string]$TenantFilter
                    RowKey       = [string]$Id
                    ConfirmedBy  = [string]$User
                    ConfirmedAt  = [datetime]::UtcNow.ToString('o')
                    Note         = [string]($Request.Body.Note ?? '')
                }
            } else {
                $Escaped = $TenantFilter -replace "'", "''"
                $Row = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$Escaped' and RowKey eq '$Id'"
                if ($Row) { Remove-CIPPAzDataTableEntity @Table -Entity $Row -Force }
            }
        }
        $Verb = if ($Action -eq 'Confirm') { 'Confirmed' } else { 'Cleared' }
        $Result = "$Verb $($Ids -join ', ') for $TenantFilter."
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message "AI Access checklist: $Result" -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Could not update the AI Access checklist: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Result -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
