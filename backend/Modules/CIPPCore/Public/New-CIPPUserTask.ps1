function New-CIPPUserTask {
    [CmdletBinding()]
    param (
        $UserObj,
        $APIName = 'New User Task',
        $TenantFilter,
        $Headers
    )
    $Results = [System.Collections.Generic.List[string]]::new()

    # How a license seat shortfall at execution time is handled. Absent (default) preserves the
    # original flow: create the user, attempt the assignment and report the outcome.
    #   defer          - check seats before creating anything; none free -> defer the whole task
    #   createAndRetry - create the user; assignment fails -> schedule an automatic retry task
    $ShortfallAction = ($UserObj.licenseShortfallAction.value ?? $UserObj.licenseShortfallAction) ?? 'legacy'
    # RowKey of the scheduled task currently executing this function (empty for immediate
    # creations). Same module-scoped storage Write-LogMessage uses for log attribution.
    $OwnTaskId = [string]$script:CippScheduledTaskIdStorage.Value

    if ($ShortfallAction -eq 'defer' -and $OwnTaskId -and $UserObj.licenses.value -and -not $UserObj.sherwebLicense.value) {
        # Pre-flight seat check BEFORE the user is created: when no seat is free nothing is
        # created and the task defers itself (Push-ExecScheduledCommand handles the DeferTask
        # throw). Sherweb creations skip this - they purchase their own seat. Requires $OwnTaskId
        # (i.e. actually running as a scheduled task): a DeferTask throw has no scheduler to catch
        # it on the immediate HTTP path, so a stale/leaked 'defer' value there must not abort the
        # request outright - it silently falls through to legacy create-and-report behavior.
        $SeatOverview = Get-CIPPLicenseOverview -TenantFilter $UserObj.tenantFilter -AlertMode
        $Claims = @(Get-CIPPLicenseReservation -TenantFilter $UserObj.tenantFilter)
        $NowUnix = [int64](([datetime]::UtcNow) - (Get-Date '1/1/1970')).TotalSeconds
        $OwnClaim = $Claims | Where-Object { $_.TaskId -eq $OwnTaskId } | Select-Object -First 1
        $OwnEffectiveTime = $OwnClaim ? $OwnClaim.EffectiveScheduledTime : $NowUnix

        $ShortSkus = foreach ($SkuId in @($UserObj.licenses.value)) {
            $SkuKey = ([string]$SkuId).ToLowerInvariant()
            $License = $SeatOverview | Where-Object { ([string]$_.skuId).ToLowerInvariant() -eq $SkuKey } | Select-Object -First 1
            if (-not $License) { continue } # excluded/unknown SKU: Graph stays the authority
            # Earliest scheduled date is first in line: leave seats for claims scheduled before
            # this task (ties broken by task id so two tasks can never both yield or both proceed).
            $EarlierClaims = @($Claims | Where-Object {
                    $_.SkuId -eq $SkuKey -and $_.TaskId -ne $OwnTaskId -and (
                        $_.EffectiveScheduledTime -lt $OwnEffectiveTime -or
                        ($_.EffectiveScheduledTime -eq $OwnEffectiveTime -and $_.TaskId -lt $OwnTaskId)
                    )
                }).Count
            if (([int]$License.CountAvailable - $EarlierClaims) -lt 1) {
                "$($License.License): $($License.CountAvailable) available, $EarlierClaims earlier scheduled claim(s)"
            }
        }
        if ($ShortSkus) {
            Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Deferring user creation: no available licenses. $($ShortSkus -join '; ')" -Sev 'Info'
            throw "DeferTask: No available licenses for this user. $($ShortSkus -join '; ')"
        }
    }

    try {
        $CreationResults = New-CIPPUser -UserObj $UserObj -APIName $APIName -Headers $Headers
        $Results.Add('Created New User.')
        $Results.Add("Username: $($CreationResults.Username)")
        $Results.Add("Password: $($CreationResults.Password)")
    } catch {
        $Results.Add("$($_.Exception.Message)" )
        throw @{'Results' = $Results }
    }

    $LicenseFailure = $null
    try {
        if ($UserObj.licenses.value) {
            if ($UserObj.sherwebLicense.value) {
                $null = Set-SherwebSubscription -Headers $Headers -TenantFilter $UserObj.tenantFilter -SKU $UserObj.sherwebLicense.value -Add 1
                $null = $Results.Add('Added Sherweb License, scheduling assignment')
                $taskObject = [PSCustomObject]@{
                    TenantFilter  = $UserObj.tenantFilter
                    Name          = "Assign License: $($CreationResults.Username)"
                    Command       = @{
                        value = 'Set-CIPPUserLicense'
                    }
                    Parameters    = [pscustomobject]@{
                        TenantFilter = $UserObj.tenantFilter
                        UserId       = $CreationResults.Username
                        APIName      = 'Sherweb License Assignment'
                        AddLicenses  = $UserObj.licenses.value
                    }
                    ScheduledTime = 0 #right now, which is in the next 15 minutes and should cover most cases.
                    PostExecution = @{
                        Webhook = [bool]$Request.Body.PostExecution.webhook
                        Email   = [bool]$Request.Body.PostExecution.email
                        PSA     = [bool]$Request.Body.PostExecution.psa
                    }
                }
                Add-CIPPScheduledTask -Task $taskObject -hidden $false -Headers $Headers
            } else {
                $LicenseResults = Set-CIPPUserLicense -UserId $CreationResults.Username -TenantFilter $UserObj.tenantFilter -AddLicenses $UserObj.licenses.value -Headers $Headers -ReturnDetailed
                foreach ($LicenseMessage in $LicenseResults.Results) { $Results.Add($LicenseMessage) }
                $FailedLicenses = @($LicenseResults.Requests | Where-Object { $_.Success -ne $true })
                if ($FailedLicenses.Count -gt 0) {
                    $LicenseFailure = "License assignment failed for $($CreationResults.Username): $(@($FailedLicenses.Messages) -join '; ')"
                    if ($ShortfallAction -in @('defer', 'createAndRetry')) {
                        # The user exists but has no license (in defer mode this means the seat was
                        # lost between the pre-flight check and the assignment). Schedule a retry
                        # task that defers itself until a seat frees up, inheriting the parent
                        # task's notification channels.
                        $ParentPostExecution = [pscustomobject]@{ Webhook = $false; Email = $false; PSA = $false }
                        if ($OwnTaskId) {
                            try {
                                $TaskTable = Get-CIPPTable -TableName 'ScheduledTasks'
                                $OwnTask = Get-CIPPAzDataTableEntity @TaskTable -Filter "PartitionKey eq 'ScheduledTask' and RowKey eq '$OwnTaskId'"
                                if ($OwnTask.PostExecution) {
                                    $ParentPostExecution = [pscustomobject]@{
                                        Webhook = $OwnTask.PostExecution -match 'Webhook'
                                        Email   = $OwnTask.PostExecution -match 'Email'
                                        PSA     = $OwnTask.PostExecution -match 'PSA'
                                    }
                                }
                            } catch {
                                Write-Information "Could not read parent task PostExecution: $($_.Exception.Message)"
                            }
                        }
                        $RetryTask = [PSCustomObject]@{
                            TenantFilter  = $UserObj.tenantFilter
                            Name          = "Assign License: $($CreationResults.Username)"
                            Command       = @{
                                value = 'Set-CIPPUserLicense'
                            }
                            Parameters    = [pscustomobject]@{
                                TenantFilter     = $UserObj.tenantFilter
                                UserId           = $CreationResults.Username
                                AddLicenses      = $UserObj.licenses.value
                                DeferOnShortfall = $true
                                APIName          = 'Scheduled License Retry'
                            }
                            ScheduledTime = 0
                            PostExecution = $ParentPostExecution
                        }
                        $null = Add-CIPPScheduledTask -Task $RetryTask -hidden $false -DisallowDuplicateName $true -Headers $Headers
                        $Results.Add("A license assignment retry task has been scheduled for $($CreationResults.Username).")
                    }
                }
            }
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to assign the license. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to assign the license. $($_.Exception.Message)")
        $LicenseFailure = "Failed to assign the license. $($_.Exception.Message)"
    }

    try {
        if ($UserObj.AddedAliases) {
            $AliasResults = Add-CIPPAlias -User $CreationResults.Username -Aliases ($UserObj.AddedAliases -split '\s') -UserPrincipalName $CreationResults.Username -TenantFilter $UserObj.tenantFilter -APIName $APIName -Headers $Headers
            $Results.Add($AliasResults)
        }
    } catch {
        Write-LogMessage -headers $Headers -API $APIName -tenant $($UserObj.tenantFilter) -message "Failed to create the Aliases. Error:$($_.Exception.Message)" -Sev 'Error'
        $Results.Add("Failed to create the Aliases: $($_.Exception.Message)")
    }
    if ($UserObj.copyFrom.value) {
        Write-Host "Copying from $($UserObj.copyFrom.value)"
        $CopyFrom = Set-CIPPCopyGroupMembers -Headers $Headers -CopyFromId $UserObj.copyFrom.value -UserID $CreationResults.Username -TenantFilter $UserObj.tenantFilter
        $CopyFrom.Success | ForEach-Object { $Results.Add($_) }
        $CopyFrom.Error | ForEach-Object { $Results.Add($_) }
    }

    # Add to groups
    if ($UserObj.AddToGroups) {
        $ExoGroupTypes = @('Distribution list', 'Mail-Enabled Security')
        $UserObj.AddToGroups | ForEach-Object {
            $Group = $_
            $GroupType = $Group.addedFields.groupType
            try {
                $AddMemberResult = Add-CIPPGroupMember -Headers $Headers -GroupType $GroupType -GroupId $Group.value -Member @($CreationResults.Username) -TenantFilter $UserObj.tenantFilter
                $Results.Add($AddMemberResult)
            } catch {
                # EXO group adds frequently fail right after user creation due to Exchange directory replication lag.
                # Schedule a delayed retry so the user lands in the group automatically once EXO sees the recipient.
                if ($GroupType -in $ExoGroupTypes) {
                    try {
                        $TaskBody = [PSCustomObject]@{
                            TenantFilter  = $UserObj.tenantFilter
                            Name          = "Retry Add Group Member: $($CreationResults.Username) -> $($Group.label)"
                            Command       = @{ value = 'Add-CIPPGroupMember' }
                            Parameters    = [PSCustomObject]@{
                                GroupType    = $GroupType
                                GroupId      = $Group.value
                                Member       = @($CreationResults.Username)
                                TenantFilter = $UserObj.tenantFilter
                                APIName      = 'Add Group Member (Retry)'
                            }
                            ScheduledTime = [int64](([datetime]::UtcNow).AddMinutes(15) - (Get-Date '1/1/1970')).TotalSeconds
                            PostExecution = @{ Webhook = $false; Email = $false; PSA = $false }
                        }
                        $null = Add-CIPPScheduledTask -Task $TaskBody -hidden $false -Headers $Headers -DisallowDuplicateName $true
                        $Results.Add("Could not add $($CreationResults.Username) to $($Group.label) yet (Exchange replication delay). A retry has been scheduled in 15 minutes.")
                    } catch {
                        $Results.Add("Failed to add to group $($Group.label): $_")
                    }
                } else {
                    $Results.Add("Failed to add to group $($Group.label): $_")
                }
            }
        }
    }

    if ($UserObj.setManager) {
        $ManagerResults = Set-CIPPManager -Users $CreationResults.Username -Manager $UserObj.setManager.value -TenantFilter $UserObj.tenantFilter -Headers $Headers
        $Results.Add($ManagerResults.Result)
    }

    if ($UserObj.setSponsor) {
        $SponsorResults = Set-CIPPSponsor -Users $CreationResults.Username -Sponsor $UserObj.setSponsor.value -TenantFilter $UserObj.tenantFilter -Headers $Headers
        $Results.Add($SponsorResults.Result)
    }

    $TaskResult = @{
        Results  = $Results
        Username = $CreationResults.Username
        Password = $CreationResults.Password
        CopyFrom = $CopyFrom
        User     = $CreationResults.User
    }
    if ($LicenseFailure) {
        # Surface the license failure in the task state: Push-ExecScheduledCommand marks the task
        # Failed instead of Completed while still storing the full results (including the password),
        # so the failure is visible and PostExecution alerts fire. Uses a CIPP-specific key rather
        # than the generic 'State' - several unrelated cmdlets already return a 'State' property
        # for their own purposes, and the scheduler's contract must not collide with those.
        $TaskResult.CippTaskState = 'Failed'
    }
    return $TaskResult
}
