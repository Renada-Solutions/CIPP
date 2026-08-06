function Add-CIPPAlertTicketLink {
    <#
    .SYNOPSIS
        Records which alert items a PSA ticket was raised for.
    .DESCRIPTION
        Writes one row per alert item into the PSATickets table under the 'AlertLink' partition,
        tying the item's content hash to the ticket that reports it. Resolve-CIPPAlertTickets reads
        these back on later runs to work out which tickets describe conditions that have cleared.

        Provider-agnostic on purpose - HaloPSA is the only writer today, but the rows carry the
        provider so a second PSA can reuse the same mechanism.

        Failures are swallowed. A missing link only costs the automatic close-back; it must never
        cost the alert that was being delivered.
    .PARAMETER AlertSource
        Object carrying CmdletName, TenantFilter and ContentHashes, built by Send-CIPPScheduledTaskAlert.
    .PARAMETER TicketID
        The PSA ticket the items were reported on.
    .PARAMETER Provider
        The PSA the ticket lives in.
    .PARAMETER Title
        Ticket title, stored for readable logging when the ticket is later closed.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $AlertSource,

        [Parameter(Mandatory = $true)]
        [string]$TicketID,

        [Parameter(Mandatory = $false)]
        [string]$Provider = 'HaloPSA',

        [Parameter(Mandatory = $false)]
        [string]$Title
    )

    try {
        $Hashes = @($AlertSource.ContentHashes | Where-Object { $_ })
        if ($Hashes.Count -eq 0 -or [string]::IsNullOrWhiteSpace($AlertSource.CmdletName)) {
            return
        }

        $Table = Get-CIPPTable -TableName 'PSATickets'
        $Created = [string](Get-Date).ToUniversalTime().ToString('o')

        foreach ($Hash in $Hashes) {
            # Content hashes are base64, which contains '/' - illegal in an Azure Table RowKey. An
            # allow-list keeps the key valid whatever the hash or tenant name contains; the real
            # hash lives in its own column, so lookups never depend on the sanitised key.
            $LinkRowKey = "$($AlertSource.TenantFilter)-$($AlertSource.CmdletName)-$Hash" -replace '[^A-Za-z0-9._@=-]', '_'
            $Entity = @{
                PartitionKey = 'AlertLink'
                RowKey       = [string]$LinkRowKey
                Tenant       = [string]$AlertSource.TenantFilter
                CmdletName   = [string]$AlertSource.CmdletName
                ContentHash  = [string]$Hash
                TicketID     = [string]$TicketID
                Provider     = [string]$Provider
                Title        = [string]$Title
                Created      = $Created
            }
            $Table.Entity = $Entity
            Add-CIPPAzDataTableEntity @Table -Force | Out-Null
        }

        Write-Information "Linked $($Hashes.Count) alert item(s) to $Provider ticket $TicketID"
    } catch {
        Write-Information "Failed to link alert items to ticket $TicketID`: $($_.Exception.Message)"
    }
}
