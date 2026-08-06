# Pester tests for Resolve-CIPPAlertTickets.
#
# The regression that matters most is first: a persisting alert reporting UNCHANGED data must never
# close a ticket. Write-AlertTrace returns nothing in that case, exactly as it does when an alert
# clears, so anything inferring resolution from an empty result set would close tickets that are
# still perfectly valid. Resolution is read from the AlertLastRun stamp instead.

BeforeAll {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

    function Get-CIPPTable { param([string]$TableName) }
    function Get-CIPPAzDataTableEntity { param($TableName, $Filter, $Property, $First) }
    function Update-AzDataTableEntity { param($TableName, $Entity, $Context, [switch]$Force) }
    function Remove-CIPPAzDataTableEntity { param($TableName, $Entity, $Context, [switch]$Force) }
    function Write-LogMessage { param($API, $tenant, $message, $sev, $LogData, $headers) }
    function Close-HaloPSATicket { param([string]$TicketID, [string]$Note, [switch]$CloseTicket) }

    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/GraphHelper/Get-AlertContentHash.ps1')
    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/ConvertTo-CIPPODataFilterValue.ps1')
    . (Join-Path $BackendRoot 'Modules/CIPPCore/Public/Resolve-CIPPAlertTickets.ps1')

    function New-AlertItem {
        param([string]$Upn)
        [pscustomobject]@{ UserPrincipalName = $Upn; Issue = 'No MFA' }
    }

    function New-Link {
        param([string]$Upn, [string]$TicketID, [int]$ClearedRuns = 0)
        [pscustomobject]@{
            PartitionKey = 'AlertLink'
            RowKey       = "contoso.com-Get-CIPPAlertMFAAlertUsers-$Upn"
            Tenant       = 'contoso.com'
            CmdletName   = 'Get-CIPPAlertMFAAlertUsers'
            ContentHash  = (Get-AlertContentHash -AlertItem (New-AlertItem -Upn $Upn)).ContentHash
            TicketID     = $TicketID
            Provider     = 'HaloPSA'
            ClearedRuns  = $ClearedRuns
        }
    }
}

Describe 'Resolve-CIPPAlertTickets' {
    BeforeEach {
        $script:RunStart = [datetime]::UtcNow
        $script:Closed = [System.Collections.Generic.List[object]]::new()
        $script:Removed = [System.Collections.Generic.List[object]]::new()
        $script:Updated = [System.Collections.Generic.List[object]]::new()

        $script:Links = @()
        $script:LastRunRow = $null

        Mock -CommandName Get-CIPPTable -MockWith { param([string]$TableName) @{ TableName = $TableName } }
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName Get-CIPPAzDataTableEntity -MockWith {
            param($TableName, $Filter)
            switch ($TableName) {
                'PSATickets' { $script:Links }
                'AlertLastRun' { $script:LastRunRow }
                default { $null }
            }
        }
        Mock -CommandName Update-AzDataTableEntity -MockWith {
            param($TableName, $Entity, $Context, [switch]$Force)
            $script:Updated.Add($Entity)
        }
        Mock -CommandName Remove-CIPPAzDataTableEntity -MockWith {
            param($TableName, $Entity, $Context, [switch]$Force)
            $script:Removed.Add($Entity)
        }
        Mock -CommandName Close-HaloPSATicket -MockWith {
            param([string]$TicketID, [string]$Note, [switch]$CloseTicket)
            $script:Closed.Add([pscustomobject]@{ TicketID = $TicketID; Note = $Note; CloseTicket = $CloseTicket.IsPresent })
            return $true
        }
    }

    Context 'when the alert is still firing with unchanged data' {
        BeforeEach {
            # The alert reported this run - LastSeen is current - and reported the same item it was
            # ticketed for. Write-AlertTrace returned $null because nothing changed.
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101')
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @(New-AlertItem -Upn 'user1@contoso.com') -Compress -Depth 10 | Out-String)
                LastSeen     = [datetime]::UtcNow.AddSeconds(5).ToString('o')
            }
        }

        It 'does not touch the ticket' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 0
            $script:Removed.Count | Should -Be 0
        }

        It 'resets any part-completed clear count' {
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1)

            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 0
            $script:Updated.Count | Should -Be 1
            $script:Updated[0].ClearedRuns | Should -Be 0
        }
    }

    Context 'when the alert reported nothing at all' {
        BeforeEach {
            # Stale stamp: the alert ran this cycle but wrote nothing, so the condition has gone.
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @(New-AlertItem -Upn 'user1@contoso.com') -Compress -Depth 10 | Out-String)
                LastSeen     = [datetime]::UtcNow.AddDays(-1).ToString('o')
            }
        }

        It 'waits for a second consecutive clear run before closing' {
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101')

            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 0
            $script:Updated[0].ClearedRuns | Should -Be 1
        }

        It 'closes the ticket once the item has been absent twice' {
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1)

            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 1
            $script:Closed[0].TicketID | Should -Be '101'
            $script:Closed[0].CloseTicket | Should -BeTrue
            $script:Removed.Count | Should -Be 1
        }
    }

    Context 'when only some items have cleared' {
        BeforeEach {
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @(New-AlertItem -Upn 'user2@contoso.com') -Compress -Depth 10 | Out-String)
                LastSeen     = [datetime]::UtcNow.AddSeconds(5).ToString('o')
            }
            # user1 has gone, user2 is still reported. Both were on the same consolidated ticket.
            $script:Links = @(
                New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1
                New-Link -Upn 'user2@contoso.com' -TicketID '101'
            )
        }

        It 'notes the change but leaves the ticket open' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 1
            $script:Closed[0].CloseTicket | Should -BeFalse
            $script:Closed[0].Note | Should -Match '1 still outstanding'
        }

        It 'only clears the link for the item that resolved' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Removed.Count | Should -Be 1
            $script:Removed[0].ContentHash | Should -Be (New-Link -Upn 'user1@contoso.com' -TicketID '101').ContentHash
        }
    }

    Context 'when tickets were split per user' {
        BeforeEach {
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @(New-AlertItem -Upn 'user2@contoso.com') -Compress -Depth 10 | Out-String)
                LastSeen     = [datetime]::UtcNow.AddSeconds(5).ToString('o')
            }
            $script:Links = @(
                New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1
                New-Link -Upn 'user2@contoso.com' -TicketID '102'
            )
        }

        It 'closes only the ticket whose own user cleared' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 1
            $script:Closed[0].TicketID | Should -Be '101'
            $script:Closed[0].CloseTicket | Should -BeTrue
        }
    }

    Context 'when the PSA rejects the close' {
        BeforeEach {
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = ''
                LastSeen     = [datetime]::UtcNow.AddDays(-1).ToString('o')
            }
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1)
            Mock -CommandName Close-HaloPSATicket -MockWith { return $false }
        }

        It 'keeps the links so the next run tries again' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Removed.Count | Should -Be 0
        }
    }

    Context 'when there are no linked tickets' {
        It 'does nothing' {
            $script:Links = @()

            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 0
            $script:Updated.Count | Should -Be 0
        }
    }

    Context 'when the stored row predates the LastSeen stamp' {
        BeforeEach {
            # Rows written before this feature shipped have no stamp. Treating those as cleared would
            # close every open ticket on the first run after an upgrade.
            $script:LastRunRow = [pscustomobject]@{
                PartitionKey = '20260804'
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @(New-AlertItem -Upn 'user1@contoso.com') -Compress -Depth 10 | Out-String)
            }
            $script:Links = @(New-Link -Upn 'user1@contoso.com' -TicketID '101' -ClearedRuns 1)
        }

        It 'treats the recorded items as still present' {
            Resolve-CIPPAlertTickets -CmdletName 'Get-CIPPAlertMFAAlertUsers' -TenantFilter 'contoso.com' -RunStartUtc $script:RunStart

            $script:Closed.Count | Should -Be 0
        }
    }
}
