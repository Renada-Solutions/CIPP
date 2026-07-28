function Get-CIPPAlertScheduledLicenseShortfall {
    <#
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [Alias('input')]
        $InputValue,
        $TenantFilter
    )

    try {
        $Claims = @(Get-CIPPLicenseReservation -TenantFilter $TenantFilter)
        if ($Claims.Count -eq 0) { return }
        $LicenseOverview = Get-CIPPLicenseOverview -TenantFilter $TenantFilter -AlertMode

        $AlertData = foreach ($SkuClaims in ($Claims | Group-Object -Property SkuId)) {
            $License = $LicenseOverview | Where-Object { ([string]$_.skuId).ToLowerInvariant() -eq $SkuClaims.Name } | Select-Object -First 1
            if (-not $License) { continue }
            $Available = [int]$License.CountAvailable
            $PendingClaims = $SkuClaims.Count
            $OverdueClaims = @($SkuClaims.Group | Where-Object { $_.Overdue }).Count
            $EarliestClaim = ($SkuClaims.Group | Sort-Object -Property EffectiveScheduledTime | Select-Object -First 1)
            $EarliestDate = ([datetime]'1/1/1970').AddSeconds([int64]$EarliestClaim.EffectiveScheduledTime).ToString('yyyy-MM-dd')

            if ($PendingClaims -gt $Available) {
                [PSCustomObject]@{
                    Message       = "$($License.License) is projected short: $PendingClaims scheduled task(s) need a seat but only $Available available (shortfall of $($PendingClaims - $Available)). Earliest scheduled date: $EarliestDate."
                    LicenseName   = $License.License
                    SkuId         = $License.skuId
                    PendingClaims = $PendingClaims
                    Available     = $Available
                    Shortfall     = $PendingClaims - $Available
                    OverdueClaims = $OverdueClaims
                    EarliestDate  = $EarliestDate
                    Tenant        = $TenantFilter
                }
            } elseif ($OverdueClaims -gt 0) {
                # Seats are available now, but tasks past their scheduled date are still waiting
                # (deferred creations or license retries) - surface the stale demand.
                [PSCustomObject]@{
                    Message       = "$($License.License): $OverdueClaims scheduled task(s) past their scheduled date are still waiting to consume a seat ($Available currently available). Tasks: $(@($SkuClaims.Group | Where-Object { $_.Overdue } | ForEach-Object { $_.TaskName }) -join '; ')."
                    LicenseName   = $License.License
                    SkuId         = $License.skuId
                    PendingClaims = $PendingClaims
                    Available     = $Available
                    Shortfall     = 0
                    OverdueClaims = $OverdueClaims
                    EarliestDate  = $EarliestDate
                    Tenant        = $TenantFilter
                }
            }
        }

        if ($AlertData) {
            Write-AlertTrace -cmdletName $MyInvocation.MyCommand -tenantFilter $TenantFilter -data $AlertData
        }
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'Alerts' -tenant $TenantFilter -message "Scheduled License Shortfall Alert Error occurred: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
    }
}
