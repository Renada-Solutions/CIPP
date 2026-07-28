function Set-CIPPUserLicense {
    [CmdletBinding()]
    param (
        [Parameter(ParameterSetName = 'Single', Mandatory)][string]$UserId,
        [Parameter(ParameterSetName = 'Single')][string]$UserPrincipalName,
        [Parameter(ParameterSetName = 'Single')][array]$AddLicenses = @(),
        [Parameter(ParameterSetName = 'Single')][array]$RemoveLicenses = @(),
        [Parameter(ParameterSetName = 'Bulk', Mandatory)][System.Collections.Generic.List[object]]$LicenseRequests,
        [Parameter(Mandatory)][string]$TenantFilter,
        $Headers,
        $APIName = 'Set User License',
        # Opt-in: return a structured object with per-request outcomes alongside the result strings.
        # Default output is unchanged so existing callers keep their exact contract.
        [switch]$ReturnDetailed,
        # Opt-in for scheduled license-retry tasks: pre-check seat availability and throw
        # 'DeferTask: ...' when seats are short so Push-ExecScheduledCommand reschedules instead
        # of recording a silent failure. Any other assignment failure throws a hard error so the
        # task is marked Failed rather than Completed. Default behavior is unchanged.
        [switch]$DeferOnShortfall
    )

    # Handle single user request (legacy support)
    if ($PSCmdlet.ParameterSetName -eq 'Single') {
        $LicenseRequests = [System.Collections.Generic.List[object]]::new()
        $LicenseRequests.Add([PSCustomObject]@{
                UserId            = $UserId
                UserPrincipalName = $UserPrincipalName
                AddLicenses       = @($AddLicenses)
                RemoveLicenses    = @($RemoveLicenses)
                IsReplace         = $false
            })
    }

    $Results = [System.Collections.Generic.List[string]]::new()

    # Get default usage location once for all users
    $Table = Get-CippTable -tablename 'UserSettings'
    $UserSettings = Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'UserSettings' and RowKey eq 'allUsers'"
    if ($UserSettings) { $DefaultUsageLocation = (ConvertFrom-Json $UserSettings.JSON -Depth 5 -ErrorAction SilentlyContinue).usageLocation.value }
    $DefaultUsageLocation ??= 'US'

    # Normalize license arrays to avoid sending null skuIds to Graph
    foreach ($Request in $LicenseRequests) {
        $Request.AddLicenses = @(
            @($Request.AddLicenses) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $Request.RemoveLicenses = @(
            @($Request.RemoveLicenses) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ([string]::IsNullOrWhiteSpace($Request.UserPrincipalName)) {
            $Request.UserPrincipalName = $Request.UserId
        }
    }

    # Track per-request outcomes for ReturnDetailed/DeferOnShortfall only: default callers (e.g.
    # bulk license operations on hundreds of users) pay no extra allocation for a feature they
    # don't use. Success stays $null until a definitive result is recorded; anything not $true
    # at the end is treated as failed.
    $TrackOutcomes = $ReturnDetailed -or $DeferOnShortfall
    $RequestOutcomes = @{}
    if ($TrackOutcomes) {
        foreach ($Request in $LicenseRequests) {
            $RequestOutcomes[$Request.UserId] = [PSCustomObject]@{
                UserId            = $Request.UserId
                UserPrincipalName = $Request.UserPrincipalName
                Success           = $null
                Messages          = [System.Collections.Generic.List[string]]::new()
            }
        }
    }

    if ($DeferOnShortfall) {
        # Seat pre-check via the same source of truth the license overview and alerts use.
        # SKUs missing from the overview (excluded or unknown) are skipped: Graph stays the authority.
        $SkuDemand = @{}
        foreach ($Request in $LicenseRequests) {
            foreach ($Sku in $Request.AddLicenses) {
                $SkuKey = ([string]$Sku).ToLowerInvariant()
                $SkuDemand[$SkuKey] = ($SkuDemand[$SkuKey] ?? 0) + 1
            }
        }
        if ($SkuDemand.Count -gt 0) {
            $SeatOverview = Get-CIPPLicenseOverview -TenantFilter $TenantFilter -AlertMode
            $ShortSkus = foreach ($Demand in $SkuDemand.GetEnumerator()) {
                $License = $SeatOverview | Where-Object { ([string]$_.skuId).ToLowerInvariant() -eq $Demand.Key } | Select-Object -First 1
                if (-not $License) { continue }
                if ([int]$License.CountAvailable -lt $Demand.Value) {
                    "$($License.License): $($License.CountAvailable) available, $($Demand.Value) needed"
                }
            }
            if ($ShortSkus) {
                throw "DeferTask: No available licenses to assign to $(@($LicenseRequests.UserPrincipalName) -join ', '). $($ShortSkus -join '; ')"
            }
        }
    }

    # Process Replace operations first (remove all licenses)
    $ReplaceRequests = $LicenseRequests | Where-Object { $_.IsReplace -and $_.RemoveLicenses.Count -gt 0 }
    if ($ReplaceRequests.Count -gt 0) {
        $RemoveBulkRequests = foreach ($Request in $ReplaceRequests) {
            @{
                id      = $Request.UserId
                method  = 'POST'
                url     = "/users/$($Request.UserId)/assignLicense"
                body    = @{
                    'addLicenses'    = @()
                    'removeLicenses' = $Request.RemoveLicenses
                }
                headers = @{ 'Content-Type' = 'application/json' }
            }
        }

        $RemoveResults = New-GraphBulkRequest -tenantid $TenantFilter -Requests @($RemoveBulkRequests)

        foreach ($Result in $RemoveResults) {
            $Request = $ReplaceRequests | Where-Object { $_.UserId -eq $Result.id }
            if ($Result.status -ge 200 -and $Result.status -le 299) {
                Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Removed existing licenses for user $($Request.UserPrincipalName)" -Sev 'Info'
            } else {
                $Results.Add("Failed to remove licenses for user $($Request.UserPrincipalName): $($Result.body.error.message)")
                Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to remove licenses for user $($Request.UserPrincipalName): $($Result.body.error.message)" -Sev 'Error'
            }
        }
    }

    # Build bulk requests for license assignment
    $BulkRequests = foreach ($Request in $LicenseRequests) {
        $AddLicensesArray = foreach ($license in $Request.AddLicenses) {
            @{ 'disabledPlans' = @(); 'skuId' = $license }
        }

        @{
            id      = $Request.UserId
            method  = 'POST'
            url     = "/users/$($Request.UserId)/assignLicense"
            body    = @{
                'addLicenses'    = @($AddLicensesArray)
                'removeLicenses' = $Request.IsReplace ? @() : $Request.RemoveLicenses
            }
            headers = @{ 'Content-Type' = 'application/json' }
        }
    }

    # Execute bulk request
    $BulkResults = New-GraphBulkRequest -tenantid $TenantFilter -Requests @($BulkRequests)

    # Collect users with usage location errors
    $UsageLocationErrors = [System.Collections.Generic.List[object]]::new()

    foreach ($Result in $BulkResults) {
        $Request = $LicenseRequests | Where-Object { $_.UserId -eq $Result.id }

        if ($Result.status -ge 200 -and $Result.status -le 299) {
            $Results.Add("Successfully set licenses for $($Request.UserPrincipalName). It may take 2–5 minutes before the changes become visible.")
            if ($TrackOutcomes) {
                $RequestOutcomes[$Request.UserId].Success = $true
                $RequestOutcomes[$Request.UserId].Messages.Add('Licenses assigned successfully.')
            }
            Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Assigned licenses to user $($Request.UserPrincipalName). Added: $($Request.AddLicenses -join ', '); Removed: $($Request.RemoveLicenses -join ', ')" -Sev 'Info'
        } elseif ($Result.body.error.message -like '*invalid usage location*' -or $Result.body.error.message -like '*UsageLocation*') {
            $UsageLocationErrors.Add($Request)
        } else {
            $Results.Add("Failed to assign licenses for user $($Request.UserPrincipalName): $($Result.body.error.message)")
            if ($TrackOutcomes) {
                $RequestOutcomes[$Request.UserId].Success = $false
                $RequestOutcomes[$Request.UserId].Messages.Add("$($Result.body.error.message)")
            }
            Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to assign licenses for user $($Request.UserPrincipalName): $($Result.body.error.message)" -Sev 'Error'
        }
    }

    # Handle usage location errors
    if ($UsageLocationErrors.Count -gt 0) {
        # Set usage location for all users with errors
        $UsageLocationRequests = foreach ($Request in $UsageLocationErrors) {
            @{
                id      = $Request.UserId
                method  = 'PATCH'
                url     = "/users/$($Request.UserId)"
                body    = @{ 'usageLocation' = $DefaultUsageLocation }
                headers = @{ 'Content-Type' = 'application/json' }
            }
        }

        $UsageLocationResults = New-GraphBulkRequest -tenantid $TenantFilter -Requests @($UsageLocationRequests)

        # Log usage location updates
        foreach ($Result in $UsageLocationResults) {
            $Request = $UsageLocationErrors | Where-Object { $_.UserId -eq $Result.id }
            if ($Result.status -ge 200 -and $Result.status -le 299) {
                Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Set usage location for user $($Request.UserPrincipalName) to $DefaultUsageLocation" -Sev 'Info'
            }
        }

        # Retry license assignment for users with fixed usage location
        $RetryBulkRequests = foreach ($Request in $UsageLocationErrors) {
            $AddLicensesArray = foreach ($license in $Request.AddLicenses) {
                @{ 'disabledPlans' = @(); 'skuId' = $license }
            }

            @{
                id      = $Request.UserId
                method  = 'POST'
                url     = "/users/$($Request.UserId)/assignLicense"
                body    = @{
                    'addLicenses'    = @($AddLicensesArray)
                    'removeLicenses' = $Request.IsReplace ? @() : $Request.RemoveLicenses
                }
                headers = @{ 'Content-Type' = 'application/json' }
            }
        }

        $RetryResults = New-GraphBulkRequest -tenantid $TenantFilter -Requests @($RetryBulkRequests)

        foreach ($Result in $RetryResults) {
            $Request = $UsageLocationErrors | Where-Object { $_.UserId -eq $Result.id }

            if ($Result.status -ge 200 -and $Result.status -le 299) {
                $Results.Add("Successfully set licenses for $($Request.UserPrincipalName) after setting usage location. It may take 2–5 minutes before the changes become visible.")
                if ($TrackOutcomes) {
                    $RequestOutcomes[$Request.UserId].Success = $true
                    $RequestOutcomes[$Request.UserId].Messages.Add('Licenses assigned successfully after usage location fix.')
                }
                Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Assigned licenses to user $($Request.UserPrincipalName) after usage location fix. Added: $($Request.AddLicenses -join ', '); Removed: $($Request.RemoveLicenses -join ', ')" -Sev 'Info'
            } else {
                $Results.Add("Failed to assign licenses for user $($Request.UserPrincipalName) after setting usage location: $($Result.body.error.message)")
                if ($TrackOutcomes) {
                    $RequestOutcomes[$Request.UserId].Success = $false
                    $RequestOutcomes[$Request.UserId].Messages.Add("$($Result.body.error.message)")
                }
                Write-LogMessage -Headers $Headers -API $APIName -tenant $TenantFilter -message "Failed to assign licenses for user $($Request.UserPrincipalName) after usage location fix: $($Result.body.error.message)" -Sev 'Error'
            }
        }
    }

    # Requests without a definitive success are treated as failed
    $FailedOutcomes = @($RequestOutcomes.Values | Where-Object { $_.Success -ne $true })

    if ($DeferOnShortfall -and $FailedOutcomes.Count -gt 0) {
        # The pre-check passed but assignment still failed (seat lost to a race, or another error).
        # Throw so the scheduled task is marked Failed and alerts fire instead of a silent Completed.
        throw "License assignment failed for $(@($FailedOutcomes.UserPrincipalName) -join ', '): $(@($FailedOutcomes.Messages) -join '; ')"
    }

    if ($ReturnDetailed) {
        return [PSCustomObject]@{
            Results  = $Results
            Requests = @($RequestOutcomes.Values)
        }
    }

    # Return single result for legacy support, or all results for bulk
    if ($PSCmdlet.ParameterSetName -eq 'Single') {
        return $Results[0]
    } else {
        return $Results
    }
}
