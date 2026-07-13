function Get-HaloClientField {
    <#
    .SYNOPSIS
        Lists the client-level custom fields defined in HaloPSA
    .DESCRIPTION
        Pulls all client-level custom field definitions from Halo's FieldInfo endpoint
        (typeid 2 = client), so every field is offered regardless of which clients hold
        data for it. Used to populate the field filter dropdowns in the integration
        settings. Custom-table fields (type 7) are excluded because they are not synced.
    #>
    [CmdletBinding()]
    param()

    $Table = Get-CIPPTable -TableName Extensionsconfig
    $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ErrorAction Stop).HaloPSA

    try {
        $Token = Get-HaloToken -configuration $Configuration
        $FieldInfo = Invoke-RestMethod -Uri "$($Configuration.ResourceURL)/FieldInfo?iscustomfieldsetup=true&isconfig=true&typeid=2" -Method GET -ContentType 'application/json' -Headers @{Authorization = "Bearer $($Token.access_token)" }
    } catch {
        $Message = if ($_.ErrorDetails.Message) { Get-NormalizedError -Message $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-LogMessage -Message "Could not get HaloPSA client custom fields: $Message" -Level Error -tenant 'CIPP' -API 'HaloPSA'
        return @()
    }

    $Fields = foreach ($Field in $FieldInfo) {
        if ([string]::IsNullOrWhiteSpace("$($Field.name)")) { continue }
        if ($Field.type -eq 7) { continue }
        [PSCustomObject]@{
            name  = if (![string]::IsNullOrWhiteSpace("$($Field.labellong)")) { "$($Field.labellong)" } else { "$($Field.name)" }
            value = "$($Field.name)"
        }
    }
    return @($Fields | Sort-Object -Property name -Unique)
}
