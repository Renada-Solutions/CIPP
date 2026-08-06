function Resolve-CIPPAlertTickets {
    <#
    .SYNOPSIS
        Closes PSA tickets whose alert condition has stopped appearing.
    .DESCRIPTION
        Compares the alert items currently being reported against the items recorded against open
        PSA tickets by Add-CIPPAlertTicketLink. Anything linked but no longer reported has been
        resolved: the ticket gets a note saying so, and is closed once none of its items remain.

        The comparison deliberately does not use the alert's return value. Write-AlertTrace returns
        nothing both when an alert clears AND when it fires with data identical to the previous run,
        so treating an empty result as "resolved" would close a ticket every time a persisting alert
        reported unchanged data. Instead the AlertLastRun row's LastSeen stamp - refreshed on every
        run that reported anything - is what separates the two: a stamp from this run means the
        alert still has something to say, and its LogData is the authoritative current item set.
    .PARAMETER CmdletName
        The alert cmdlet that just ran.
    .PARAMETER TenantFilter
        The tenant it ran against.
    .PARAMETER RunStartUtc
        When this run began. A LastSeen at or after this marks the alert as having reported.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CmdletName,

        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [datetime]$RunStartUtc
    )

    try {
        $Table = Get-CIPPTable -TableName 'PSATickets'
        $SafeTenant = ConvertTo-CIPPODataFilterValue -Value $TenantFilter -Type String
        $SafeCmdlet = ConvertTo-CIPPODataFilterValue -Value $CmdletName -Type String
        $Links = @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq 'AlertLink' and Tenant eq '$SafeTenant' and CmdletName eq '$SafeCmdlet'")
        if ($Links.Count -eq 0) {
            return
        }

        $CurrentHashes = Get-CIPPCurrentAlertHash -CmdletName $CmdletName -TenantFilter $TenantFilter -RunStartUtc $RunStartUtc
        $GoneLinks = @($Links | Where-Object { $_.ContentHash -notin $CurrentHashes })

        # An item disappearing once is not proof it was fixed. Plenty of alert scripts catch their own
        # Graph failures and return nothing (Get-CIPPAlertAppSecretExpiry is typical), which is
        # indistinguishable from a genuine clear. Requiring the same item to be absent on two
        # consecutive runs means one bad API call can't close a tenant's tickets; the cost is that a
        # real fix takes one extra run to close, which is the right way round for someone's tickets.
        $RequiredClearRuns = 2

        # Counts are tracked in a side table keyed by RowKey rather than written onto the entities,
        # so this does not depend on what object type the storage layer hands back.
        $ClearedNow = @{}
        foreach ($Link in $Links) {
            $ClearedRuns = 0
            if ($Link.ClearedRuns) { $ClearedRuns = [int]$Link.ClearedRuns }
            $IsGone = $Link.ContentHash -notin $CurrentHashes
            $NewCount = if ($IsGone) { $ClearedRuns + 1 } else { 0 }

            if ($NewCount -ne $ClearedRuns) {
                $null = Update-AzDataTableEntity -Force @Table -Entity @{
                    PartitionKey = $Link.PartitionKey
                    RowKey       = $Link.RowKey
                    ClearedRuns  = $NewCount
                }
            }
            $ClearedNow[[string]$Link.RowKey] = $NewCount
        }

        $ResolvedLinks = @($Links | Where-Object { $ClearedNow[[string]$_.RowKey] -ge $RequiredClearRuns })
        if ($ResolvedLinks.Count -eq 0) {
            $Pending = @($GoneLinks).Count
            Write-Information "No confirmed alert resolutions for $CmdletName in $TenantFilter ($Pending item(s) awaiting a second clear run)"
            return
        }

        # A ticket is only closed once nothing it reported is still true. Partial clears get a note
        # so the technician can see progress without the ticket disappearing from under them.
        foreach ($TicketGroup in ($ResolvedLinks | Group-Object -Property TicketID)) {
            $TicketID = $TicketGroup.Name
            if ([string]::IsNullOrWhiteSpace($TicketID)) { continue }

            # Anything not yet confirmed counts as outstanding, so a ticket never closes while one of
            # its items is still mid-confirmation.
            $TicketLinks = @($Links | Where-Object { $_.TicketID -eq $TicketID })
            $Remaining = @($TicketLinks | Where-Object { $ClearedNow[[string]$_.RowKey] -lt $RequiredClearRuns })
            $ShouldClose = $Remaining.Count -eq 0
            $Provider = ($TicketGroup.Group | Select-Object -First 1).Provider

            $ResolvedPreviews = @($TicketGroup.Group | ForEach-Object { $_.RowKey })
            $Note = Get-CIPPAlertResolutionNote -CmdletName $CmdletName -TenantFilter $TenantFilter -ResolvedCount $TicketGroup.Group.Count -RemainingCount $Remaining.Count

            $Acted = $false
            switch ($Provider) {
                'HaloPSA' {
                    if ($PSCmdlet.ShouldProcess("HaloPSA ticket $TicketID", $(if ($ShouldClose) { 'Resolve and close' } else { 'Add resolution note' }))) {
                        $Acted = Close-HaloPSATicket -TicketID $TicketID -Note $Note -CloseTicket:$ShouldClose
                    }
                }
                default {
                    Write-Information "No close-back support for provider '$Provider' on ticket $TicketID - leaving links in place"
                    continue
                }
            }

            if (-not $Acted) {
                # Left in place so a transient PSA failure gets another attempt on the next run.
                Write-Information "Could not act on ticket $TicketID - keeping $($TicketGroup.Group.Count) link(s) for retry"
                continue
            }

            foreach ($Link in $TicketGroup.Group) {
                $null = Remove-CIPPAzDataTableEntity -Force @Table -Entity $Link
            }
            Write-Information "Resolved $($TicketGroup.Group.Count) item(s) on ticket $TicketID (closed: $ShouldClose). Items: $($ResolvedPreviews -join ', ')"
            Write-LogMessage -API 'AlertResolution' -tenant $TenantFilter -message "$(if ($ShouldClose) { 'Closed' } else { 'Updated' }) PSA ticket $TicketID - $($TicketGroup.Group.Count) alert item(s) from $CmdletName no longer present" -sev Info
        }
    } catch {
        # Never let close-back failures affect the alert run that triggered it.
        Write-Information "Failed to resolve alert tickets for $CmdletName in $TenantFilter`: $($_.Exception.Message)"
    }
}

function Get-CIPPCurrentAlertHash {
    <#
    .SYNOPSIS
        Returns the content hashes an alert is currently reporting.
    .DESCRIPTION
        Reads the most recent AlertLastRun row for the tenant/cmdlet pair. When its LastSeen predates
        this run, the alert ran without reporting anything and the current set is empty - every linked
        item has cleared. When LastSeen is from this run, its LogData holds what is still true.

        AlertLastRun is partitioned by run date, so the newest partition wins rather than assuming
        today's - an alert that last reported yesterday still has yesterday's row as its latest state.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CmdletName,

        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [datetime]$RunStartUtc
    )

    $Table = Get-CIPPTable -TableName 'AlertLastRun'
    $SafeRowKey = ConvertTo-CIPPODataFilterValue -Value "$TenantFilter-$CmdletName" -Type String
    $Rows = @(Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$SafeRowKey'")
    if ($Rows.Count -eq 0) {
        return @()
    }

    $Latest = $Rows | Sort-Object -Property { [string]$_.PartitionKey } | Select-Object -Last 1

    # No stamp at all means the row predates this feature. Treating that as "cleared" would close
    # every ticket on the first run after an upgrade, so it counts as still reporting instead.
    if ([string]::IsNullOrWhiteSpace($Latest.LastSeen)) {
        Write-Information "AlertLastRun row for $CmdletName in $TenantFilter has no LastSeen stamp yet - treating items as still present"
        return @(Get-CIPPAlertHashFromLog -LogData $Latest.LogData)
    }

    $LastSeen = [datetime]::MinValue
    if (-not [datetime]::TryParse($Latest.LastSeen, [ref]$LastSeen)) {
        return @(Get-CIPPAlertHashFromLog -LogData $Latest.LogData)
    }

    if ($LastSeen.ToUniversalTime() -lt $RunStartUtc) {
        # The alert ran and wrote nothing: the condition has gone entirely.
        return @()
    }

    return @(Get-CIPPAlertHashFromLog -LogData $Latest.LogData)
}

function Get-CIPPAlertHashFromLog {
    <#
    .SYNOPSIS
        Hashes each item in a stored AlertLastRun LogData payload.
    .DESCRIPTION
        Uses Get-AlertContentHash so the values line up with the hashes recorded against tickets and
        with the snooze feature's identity for the same row.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$LogData
    )

    if ([string]::IsNullOrWhiteSpace($LogData)) {
        return @()
    }

    try {
        $Items = @($LogData | ConvertFrom-Json -ErrorAction Stop)
        return @($Items | Where-Object { $_ -isnot [string] } | ForEach-Object { (Get-AlertContentHash -AlertItem $_).ContentHash })
    } catch {
        # Unreadable stored data is not evidence that anything cleared, so report nothing as gone.
        Write-Information "Could not parse stored alert data for hashing: $($_.Exception.Message)"
        return @()
    }
}

function Get-CIPPAlertResolutionNote {
    <#
    .SYNOPSIS
        Builds the PSA note body posted when alert items stop appearing.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CmdletName,

        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,

        [Parameter(Mandatory = $true)]
        [int]$ResolvedCount,

        [Parameter(Mandatory = $true)]
        [int]$RemainingCount
    )

    $Checked = [string](Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $Summary = if ($RemainingCount -eq 0) {
        "All $ResolvedCount item(s) reported on this ticket have cleared."
    } else {
        "$ResolvedCount item(s) reported on this ticket have cleared. $RemainingCount still outstanding, so the ticket stays open."
    }

    return @"
<p><strong>CIPP: alert condition cleared</strong></p>
<p>$Summary</p>
<p>Alert: $([System.Web.HttpUtility]::HtmlEncode($CmdletName))<br />Tenant: $([System.Web.HttpUtility]::HtmlEncode($TenantFilter))<br />Checked: $Checked UTC</p>
"@
}
