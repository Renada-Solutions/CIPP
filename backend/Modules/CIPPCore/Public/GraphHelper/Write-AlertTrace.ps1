function Write-AlertTrace {
    <#
    .FUNCTIONALITY
    Internal function. Pleases most of Write-AlertTrace for alerting purposes
    #>
    param(
        $cmdletName,
        $data,
        $tenantFilter,
        [string]$PartitionKey = (Get-Date -UFormat '%Y%m%d').ToString(),
        [string]$AlertComment = $null
    )
    $Table = Get-CIPPTable -tablename AlertLastRun
    $AlertRowKey = "$($tenantFilter)-$($cmdletName)"
    $Row = Get-CIPPAzDataTableEntity @Table -Filter "RowKey eq '$AlertRowKey' and PartitionKey eq '$PartitionKey'"

    # LastSeen records that this alert ran and still had something to report. Callers only ever see
    # $null back from an unchanged run and from a fully snoozed one, which is indistinguishable from
    # the alert having produced nothing at all - so Resolve-CIPPAlertTickets reads this stamp rather
    # than the return value to decide whether a condition has actually cleared.
    $LastSeen = [string](Get-Date).ToUniversalTime().ToString('o')

    # Filter out snoozed alert items before comparison and storage
    $data = @(Remove-SnoozedAlerts -Data $data -CmdletName $cmdletName -TenantFilter $tenantFilter)
    if (-not $data -or $data.Count -eq 0) {
        Write-Host "All alert items are snoozed for cmdlet '$cmdletName' and tenant '$tenantFilter'. Skipping alert trace." -ForegroundColor Yellow
        # Snoozed is not resolved, so the stamp is still refreshed - but LogData is left alone. The
        # previously recorded items stay "current" and their tickets are left open.
        if ($Row) {
            $null = Update-AzDataTableEntity -Force @Table -Entity @{
                PartitionKey = $PartitionKey
                RowKey       = $AlertRowKey
                LastSeen     = $LastSeen
            }
        }
        return $null
    }

    $LogData = ConvertTo-Json -InputObject $data -Compress -Depth 10 | Out-String

    # A missing row means this is the first run in this partition, which counts as changed.
    # Compare-Object throws on a null reference object, hence the guard rather than a try/catch.
    $HasChanged = $true
    if ($null -ne $Row.LogData) {
        $Compare = Compare-Object $Row.LogData $LogData
        Write-Host "Comparing new alert data with existing data for cmdlet '$cmdletName' and tenant '$tenantFilter'. Differences: $Compare"
        $HasChanged = [bool]$Compare
    }

    # Written on every reporting run, changed or not, so LastSeen stays current. The row content is
    # identical to what the changed-only write produced before, plus the stamp.
    $TableRow = @{
        'PartitionKey' = $PartitionKey
        'RowKey'       = $AlertRowKey
        'CmdletName'   = "$cmdletName"
        'Tenant'       = "$tenantFilter"
        'LogData'      = [string]$LogData
        'AlertComment' = [string]$AlertComment
        'LastSeen'     = $LastSeen
    }
    $Table.Entity = $TableRow
    Add-CIPPAzDataTableEntity @Table -Force | Out-Null

    # Unchanged data returns nothing so alerts still only notify on change.
    if ($HasChanged) {
        return $data
    }
}
