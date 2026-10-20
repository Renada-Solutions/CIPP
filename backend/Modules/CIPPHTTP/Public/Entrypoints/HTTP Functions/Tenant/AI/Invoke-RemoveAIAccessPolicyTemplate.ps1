function Invoke-RemoveAIAccessPolicyTemplate {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.ReadWrite
    .DESCRIPTION
        Deletes an AI Access Policy template. Changes already made in tenants are left in place.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    $Id = $Request.Body.ID ?? $Request.Query.ID

    try {
        if ($Id -notmatch '^[0-9a-fA-F-]{36}$') { throw 'A template ID is required.' }
        $Table = Get-CippTable -tablename 'templates'
        $Row = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'AIAccessPolicyTemplate' and RowKey eq '$Id'" -Property PartitionKey, RowKey, ETag
        if (-not $Row) { throw "Template $Id not found." }
        Remove-CIPPAzDataTableEntity @Table -Entity $Row -Force
        $Result = "Deleted AI Access Policy template $Id."
        Write-LogMessage -headers $Headers -API $APIName -message $Result -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Could not delete AI Access Policy template: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $APIName -message $Result -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
