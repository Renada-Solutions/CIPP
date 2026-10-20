function Invoke-AddAIAccessPolicyTemplate {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.ReadWrite
    .DESCRIPTION
        Creates or updates an AI Access Policy template. The body is validated and normalised; pass
        GUID to update an existing template.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers

    try {
        $Policy = ConvertTo-CIPPAIAccessPolicy -InputObject ([pscustomobject]$Request.Body) -ManualControlIds (Get-CIPPAIAccessManualControl).id
        $GUID = if ($Request.Body.GUID -match '^[0-9a-fA-F-]{36}$') { $Request.Body.GUID } else { (New-Guid).Guid }

        $Table = Get-CippTable -tablename 'templates'
        $Table.Force = $true
        Add-CIPPAzDataTableEntity @Table -Entity @{
            JSON         = [string]($Policy | ConvertTo-Json -Depth 10 -Compress)
            RowKey       = "$GUID"
            PartitionKey = 'AIAccessPolicyTemplate'
        }
        $Result = "Saved AI Access Policy '$($Policy.name)'."
        Write-LogMessage -headers $Headers -API $APIName -message "$Result GUID $GUID" -Sev 'Info'
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Could not save AI Access Policy: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -headers $Headers -API $APIName -message $Result -Sev 'Error' -LogData $ErrorMessage
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = @{ Results = $Result }
        })
}
