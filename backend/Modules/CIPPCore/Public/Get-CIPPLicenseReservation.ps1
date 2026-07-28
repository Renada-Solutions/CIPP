function Get-CIPPLicenseReservation {
    <#
    .SYNOPSIS
    Returns pending license claims derived from scheduled tasks for a tenant.

    .DESCRIPTION
    Derives license "reservations" from the ScheduledTasks table instead of keeping separate
    bookkeeping: every pending New-CIPPUserTask row that carries licenses, and every pending
    Set-CIPPUserLicense retry task created with -DeferOnShortfall, counts as one claim per SKU.
    Because the claims are computed from the same rows the scheduler executes, they can never
    drift out of sync: cancelling or completing a task releases its claim automatically.

    Claims expire 7 days after their effective scheduled time (the original scheduled time for
    tasks that have been deferred). This matches the deferral window in Push-ExecScheduledCommand,
    so a task that has exhausted its deferrals stops counting against availability.

    .PARAMETER TenantFilter
    The tenant (default domain name) to return claims for.

    .PARAMETER APIName
    The name of the API operation, used for logging.

    .FUNCTIONALITY
    Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantFilter,
        $APIName = 'Get License Reservation',
        $Headers
    )

    # Fixed claim TTL: 7 days past the effective scheduled time. Deliberately a code constant,
    # aligned with the deferral window in Push-ExecScheduledCommand.
    $ClaimTTLSeconds = 604800
    $ActiveStates = @('Planned', 'Pending', 'Running', 'Failed - Planned')
    $Now = [int64](([datetime]::UtcNow) - (Get-Date '1/1/1970')).TotalSeconds

    $Table = Get-CIPPTable -TableName 'ScheduledTasks'
    $SafeTenant = $TenantFilter -replace "'", "''"
    $Filter = "PartitionKey eq 'ScheduledTask' and Tenant eq '$SafeTenant' and (Command eq 'New-CIPPUserTask' or Command eq 'Set-CIPPUserLicense')"
    $Tasks = Get-CIPPAzDataTableEntity @Table -Filter $Filter

    $Claims = foreach ($Task in $Tasks) {
        if ($Task.TaskState -notin $ActiveStates) { continue }

        # ConvertFrom-Json throws a terminating error on malformed JSON, which -ErrorAction does
        # not suppress - Test-Json first (matching the idiom used elsewhere in the scheduler) so
        # one corrupted row cannot break the whole tally.
        $Parameters = $null
        if (-not [string]::IsNullOrWhiteSpace($Task.Parameters) -and (Test-Json -Json $Task.Parameters -ErrorAction SilentlyContinue)) {
            $Parameters = $Task.Parameters | ConvertFrom-Json
        }
        if ($null -eq $Parameters) { continue }

        # Determine the SKUs this task will consume when it runs
        $SkuIds = if ($Task.Command -eq 'New-CIPPUserTask') {
            @($Parameters.UserObj.licenses.value)
        } elseif ($Task.Command -eq 'Set-CIPPUserLicense' -and $Parameters.DeferOnShortfall -eq $true) {
            # Only deferring license-retry tasks count; ordinary Set-CIPPUserLicense tasks assign immediately
            @($Parameters.AddLicenses)
        } else {
            @()
        }
        $SkuIds = @($SkuIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($SkuIds.Count -eq 0) { continue }

        # Effective scheduled time: the original schedule survives deferrals so a deferring task
        # keeps its place in the queue (earliest scheduled date is first in line for a seat)
        $EffectiveScheduledTime = [int64]$Task.ScheduledTime
        if (-not [string]::IsNullOrWhiteSpace($Task.AdditionalProperties) -and (Test-Json -Json $Task.AdditionalProperties -ErrorAction SilentlyContinue)) {
            $AdditionalProps = $Task.AdditionalProperties | ConvertFrom-Json
            if ($AdditionalProps.OriginalScheduledTime) {
                $EffectiveScheduledTime = [int64]$AdditionalProps.OriginalScheduledTime
            }
        }

        # Stale claims stop counting so an abandoned task cannot hold seats forever
        if (($Now - $EffectiveScheduledTime) -gt $ClaimTTLSeconds) { continue }

        foreach ($SkuId in $SkuIds) {
            [PSCustomObject]@{
                TaskId                 = [string]$Task.RowKey
                TaskName               = [string]$Task.Name
                TaskState              = [string]$Task.TaskState
                Type                   = $Task.Command -eq 'New-CIPPUserTask' ? 'NewUser' : 'LicenseRetry'
                SkuId                  = $SkuId.ToLowerInvariant()
                EffectiveScheduledTime = $EffectiveScheduledTime
                Overdue                = $EffectiveScheduledTime -lt $Now
                Tenant                 = [string]$Task.Tenant
            }
        }
    }
    return @($Claims)
}
