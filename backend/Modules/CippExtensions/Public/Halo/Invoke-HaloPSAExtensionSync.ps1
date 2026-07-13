function Invoke-HaloPSAExtensionSync {
    <#
    .SYNOPSIS
        Syncs HaloPSA client custom fields to CIPP tenant custom variables
    .DESCRIPTION
        Pulls the custom fields from the HaloPSA client mapped to the tenant and upserts them
        into the CippReplacemap table as %halo_<field>% tenant variables, so Halo-maintained
        metadata (org IDs, deployment codes, naming standards) is usable everywhere CIPP does
        text replacement. One-way, Halo -> CIPP. Previously synced variables whose field was
        removed or emptied in Halo are cleaned up; user-created variables are never touched.
    .PARAMETER Configuration
        The full extensions configuration object (narrowed to HaloPSA internally)
    .PARAMETER TenantFilter
        The default domain name of the tenant to sync
    #>
    param(
        $Configuration,
        $TenantFilter
    )
    $Configuration = $Configuration.HaloPSA

    if ($Configuration.SyncClientFields -ne $true) {
        return 'HaloPSA client field sync is not enabled'
    }

    $Tenant = Get-Tenants -TenantFilter $TenantFilter -IncludeErrors
    if (!$Tenant) {
        return "Tenant $TenantFilter not found"
    }

    $Mapping = Get-ExtensionMapping -Extension 'Halo' | Where-Object { $_.RowKey -eq $Tenant.customerId }
    if (!$Mapping.IntegrationId) {
        return 'Tenant not found in mapping table'
    }

    $Result = [PSCustomObject]@{
        Name    = "$($Mapping.IntegrationName)"
        Synced  = 0
        Removed = 0
        Errors  = [System.Collections.Generic.List[string]]::new()
        Logs    = [System.Collections.Generic.List[string]]::new()
    }

    try {
        $Token = Get-HaloToken -configuration $Configuration
        $Client = Invoke-RestMethod -Uri "$($Configuration.ResourceURL)/Client/$($Mapping.IntegrationId)?includedetails=true" -Method GET -ContentType 'application/json' -Headers @{Authorization = "Bearer $($Token.access_token)" }
    } catch {
        $Message = if ($_.ErrorDetails.Message) { Get-NormalizedError -Message $_.ErrorDetails.Message } else { $_.Exception.Message }
        $Result.Errors.Add("Could not get client $($Mapping.IntegrationId) from HaloPSA: $Message")
        Write-LogMessage -tenant $Tenant.defaultDomainName -tenantid $Tenant.customerId -API 'HaloPSA Sync' -message "Could not get client $($Mapping.IntegrationId) from HaloPSA: $Message" -Sev 'Error'
        return $Result
    }

    # filter entries may be typed as the Halo field name or the %halo_*% variable name -
    # normalise both to the slug the variable names are built from
    function ConvertTo-HaloFieldSlug {
        param($Name)
        $Slug = ("$Name".ToLower() -replace '[^a-z0-9]+', '_').Trim('_')
        return ($Slug -replace '^halo_', '')
    }

    # nothing syncs until the user selects '*All Fields' (value AllFields) or specific fields
    $IncludeValues = @($Configuration.SyncIncludeFields | ForEach-Object { "$($_.value ?? $_)" })
    $SyncAllFields = $IncludeValues -contains 'AllFields'
    $IncludeSlugs = @($IncludeValues | Where-Object { $_ -ne 'AllFields' } | ForEach-Object { ConvertTo-HaloFieldSlug -Name $_ } | Where-Object { $_ })
    $ExcludeSlugs = @($Configuration.SyncExcludeFields | ForEach-Object { ConvertTo-HaloFieldSlug -Name ($_.value ?? $_) } | Where-Object { $_ })

    # multi-select/group-member fields hold arrays of option rows ({id, fkid, display}) -
    # stringifying those yields PowerShell '@{...}' noise, so unwrap each row to its display text
    function ConvertTo-HaloFieldText {
        param($Raw)
        $Parts = foreach ($Item in @($Raw)) {
            if ($null -eq $Item) { continue }
            if ($Item -is [System.Management.Automation.PSCustomObject] -or $Item -is [System.Collections.IDictionary]) {
                if (![string]::IsNullOrWhiteSpace("$($Item.display)")) { "$($Item.display)" }
                elseif (![string]::IsNullOrWhiteSpace("$($Item.name)")) { "$($Item.name)" }
                else { "$($Item.value)" }
            } else {
                "$Item"
            }
        }
        return (($Parts | Where-Object { ![string]::IsNullOrWhiteSpace($_) }) -join ', ')
    }

    $SyncMarker = 'Synced from HaloPSA'
    $DesiredVariables = @{}
    $SkippedTables = 0
    foreach ($Field in $Client.customfields) {
        # custom-table fields (type 7) hold multi-row/multi-column data that flattens into
        # meaningless text in a single variable, so they are not synced
        if ($Field.type -eq 7) {
            $SkippedTables++
            continue
        }
        # select-type fields hold an internal id in value; display carries the readable form
        $Value = ConvertTo-HaloFieldText -Raw $Field.display
        if ([string]::IsNullOrWhiteSpace($Value)) {
            # Unset lookup fields come back as value 0 with a blank display and unset checkboxes
            # as false - falling back to value would sync spurious '0'/'False' variables.
            $RawValue = ConvertTo-HaloFieldText -Raw $Field.value
            $Value = if ($RawValue -notin @('0', 'False')) { $RawValue } else { '' }
        }
        if ([string]::IsNullOrWhiteSpace($Value) -or [string]::IsNullOrWhiteSpace("$($Field.name)")) { continue }
        # Get-CIPPTextReplacement splices the RowKey un-escaped into a regex, so names must be [a-z0-9_] only
        $VariableName = 'halo_' + ("$($Field.name)".ToLower() -replace '[^a-z0-9]+', '_').Trim('_')
        if ($VariableName -eq 'halo_') { continue }
        $FieldSlug = $VariableName -replace '^halo_', ''
        if (-not $SyncAllFields -and $FieldSlug -notin $IncludeSlugs) { continue }
        if ($FieldSlug -in $ExcludeSlugs) { continue }
        if ($DesiredVariables.ContainsKey($VariableName)) {
            $Result.Logs.Add("Field '$($Field.name)' collides with another field after sanitising to $VariableName - last value wins")
        }
        $DesiredVariables[$VariableName] = $Value
    }

    $ReplaceTable = Get-CIPPTable -tablename 'CippReplacemap'
    $ExistingRows = Get-CIPPAzDataTableEntity @ReplaceTable -Filter "PartitionKey eq '$($Tenant.customerId)'"
    $ExistingSyncedRows = $ExistingRows | Where-Object { $_.Description -eq $SyncMarker }
    # rows without the sync marker belong to the user - never overwrite or adopt them
    $UserOwnedKeys = @($ExistingRows | Where-Object { $_.Description -ne $SyncMarker } | Select-Object -ExpandProperty RowKey)

    $Entities = foreach ($Variable in $DesiredVariables.GetEnumerator()) {
        if ($Variable.Key -in $UserOwnedKeys) {
            $Result.Logs.Add("Skipped $($Variable.Key): a user-created variable with that name already exists")
            continue
        }
        @{
            PartitionKey = "$($Tenant.customerId)"
            RowKey       = $Variable.Key
            Value        = "$($Variable.Value)"
            Description  = $SyncMarker
        }
    }
    if (($Entities | Measure-Object).Count -gt 0) {
        Add-CIPPAzDataTableEntity @ReplaceTable -Entity @($Entities) -Force
        $Result.Synced = ($Entities | Measure-Object).Count
    }

    # only rows this sync created (marked by Description) are eligible for cleanup
    $StaleRows = $ExistingSyncedRows | Where-Object { $_.RowKey -notin @($DesiredVariables.Keys) }
    if (($StaleRows | Measure-Object).Count -gt 0) {
        Remove-AzDataTableEntity -Force @ReplaceTable -Entity @($StaleRows | Select-Object -Property PartitionKey, RowKey, ETag)
        $Result.Removed = ($StaleRows | Measure-Object).Count
    }

    if (-not $SyncAllFields -and $IncludeSlugs.Count -eq 0) {
        $Result.Logs.Add('No custom fields selected to sync - select *All Fields or specific custom fields in the integration settings')
    }
    if ($SkippedTables -gt 0) {
        $Result.Logs.Add("Skipped $SkippedTables table-type field(s) - tables are not synced")
    }
    $Result.Logs.Add("Synced $($Result.Synced) client fields from HaloPSA client $($Result.Name) as %halo_*% variables, removed $($Result.Removed) stale")
    Write-LogMessage -tenant $Tenant.defaultDomainName -tenantid $Tenant.customerId -API 'HaloPSA Sync' -message "Synced $($Result.Synced) client fields from HaloPSA client $($Result.Name), removed $($Result.Removed) stale" -Sev 'Info'
    return $Result
}
