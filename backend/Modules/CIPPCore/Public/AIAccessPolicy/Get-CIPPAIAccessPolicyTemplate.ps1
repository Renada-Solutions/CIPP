function Get-CIPPAIAccessPolicyTemplate {
    <#
    .SYNOPSIS
        Loads AI Access Policy templates from the templates table, normalised

    .PARAMETER Id
        Template GUIDs to load; all templates when omitted

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [string[]]$Id
    )

    $Table = Get-CippTable -tablename 'templates'
    $Filter = "PartitionKey eq 'AIAccessPolicyTemplate'"
    if ($PSBoundParameters.ContainsKey('Id')) {
        # Ids were asked for: never fall back to every template when none of them is a GUID
        $Ids = @($Id | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' })
        if ($Ids.Count -eq 0) { return }
        $Filter += " and (RowKey eq '$($Ids -join "' or RowKey eq '")')"
    }

    foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter $Filter)) {
        try {
            $Policy = ConvertTo-CIPPAIAccessPolicy -InputObject ($Row.JSON | ConvertFrom-Json)
            $Policy | Add-Member -NotePropertyName 'GUID' -NotePropertyValue $Row.RowKey -Force
            $Policy
        } catch {
            Write-Information "Skipping invalid AI Access Policy template $($Row.RowKey): $($_.Exception.Message)"
        }
    }
}
