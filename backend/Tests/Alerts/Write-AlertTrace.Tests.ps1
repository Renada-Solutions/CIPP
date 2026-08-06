# Pester tests for Write-AlertTrace.
#
# Two properties matter here and they pull in opposite directions:
#   1. Callers must still only receive data back when it CHANGED - every alert's notify-on-change
#      behaviour rides on that return value.
#   2. The row must be stamped on EVERY run that reported something, changed or not, because
#      Resolve-CIPPAlertTickets uses that stamp to tell "still firing, same results" apart from
#      "produced nothing". Both return $null, so the return value cannot carry that meaning.

BeforeAll {
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $BackendRoot 'Modules/CIPPCore/Public/GraphHelper/Write-AlertTrace.ps1'

    function Get-CIPPTable { param([string]$TableName) }
    function Get-CIPPAzDataTableEntity { param($TableName, $Filter, $Property, $First) }
    function Add-CIPPAzDataTableEntity { param($TableName, $Entity, $Context, [switch]$Force) }
    function Update-AzDataTableEntity { param($TableName, $Entity, $Context, [switch]$Force) }
    function Remove-SnoozedAlerts { param($Data, $CmdletName, $TenantFilter) }

    . $FunctionPath
}

Describe 'Write-AlertTrace' {
    BeforeEach {
        $script:Written = [System.Collections.Generic.List[object]]::new()
        $script:Updated = [System.Collections.Generic.List[object]]::new()
        $script:ExistingRow = $null
        $script:SnoozeEverything = $false

        $script:Data = @(
            [pscustomobject]@{ UserPrincipalName = 'user1@contoso.com'; Issue = 'No MFA' }
        )

        Mock -CommandName Get-CIPPTable -MockWith { param([string]$TableName) @{ TableName = $TableName } }
        Mock -CommandName Get-CIPPAzDataTableEntity -MockWith { $script:ExistingRow }
        Mock -CommandName Remove-SnoozedAlerts -MockWith {
            param($Data, $CmdletName, $TenantFilter)
            if ($script:SnoozeEverything) { return @() }
            return $Data
        }
        Mock -CommandName Add-CIPPAzDataTableEntity -MockWith {
            param($TableName, $Entity, $Context, [switch]$Force)
            $script:Written.Add($Entity)
        }
        Mock -CommandName Update-AzDataTableEntity -MockWith {
            param($TableName, $Entity, $Context, [switch]$Force)
            $script:Updated.Add($Entity)
        }
    }

    Context 'first run with data' {
        It 'stores the data and returns it' {
            $Result = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $Result | Should -Not -BeNullOrEmpty
            $script:Written.Count | Should -Be 1
            $script:Written[0].LastSeen | Should -Not -BeNullOrEmpty
        }
    }

    Context 'repeat run with identical data' {
        BeforeEach {
            # What the previous run would have stored for this same data.
            $script:ExistingRow = [pscustomobject]@{
                PartitionKey = (Get-Date -UFormat '%Y%m%d').ToString()
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject $script:Data -Compress -Depth 10 | Out-String)
                LastSeen     = '2020-01-01T00:00:00.0000000Z'
            }
        }

        It 'returns nothing so the alert does not notify again' {
            $Result = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $Result | Should -BeNullOrEmpty
        }

        It 'still refreshes the stamp, so an unchanged alert is not mistaken for a cleared one' {
            $Before = [datetime]::UtcNow.AddSeconds(-1)

            $null = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $script:Written.Count | Should -Be 1
            ([datetime]$script:Written[0].LastSeen).ToUniversalTime() | Should -BeGreaterThan $Before
        }
    }

    Context 'repeat run with changed data' {
        BeforeEach {
            $script:ExistingRow = [pscustomobject]@{
                PartitionKey = (Get-Date -UFormat '%Y%m%d').ToString()
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject @([pscustomobject]@{ UserPrincipalName = 'someone-else@contoso.com' }) -Compress -Depth 10 | Out-String)
                LastSeen     = '2020-01-01T00:00:00.0000000Z'
            }
        }

        It 'returns the new data and stores it' {
            $Result = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $Result | Should -Not -BeNullOrEmpty
            $script:Written.Count | Should -Be 1
            $script:Written[0].LogData | Should -Match 'user1@contoso\.com'
        }
    }

    Context 'when every item is snoozed' {
        BeforeEach {
            $script:SnoozeEverything = $true
            $script:ExistingRow = [pscustomobject]@{
                PartitionKey = (Get-Date -UFormat '%Y%m%d').ToString()
                RowKey       = 'contoso.com-Get-CIPPAlertMFAAlertUsers'
                LogData      = (ConvertTo-Json -InputObject $script:Data -Compress -Depth 10 | Out-String)
                LastSeen     = '2020-01-01T00:00:00.0000000Z'
            }
        }

        It 'returns nothing' {
            $Result = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $Result | Should -BeNullOrEmpty
        }

        It 'refreshes the stamp without touching the stored items, because snoozed is not resolved' {
            $null = Write-AlertTrace -cmdletName 'Get-CIPPAlertMFAAlertUsers' -tenantFilter 'contoso.com' -data $script:Data

            $script:Written.Count | Should -Be 0
            $script:Updated.Count | Should -Be 1
            $script:Updated[0].LastSeen | Should -Not -BeNullOrEmpty
            $script:Updated[0].Keys | Should -Not -Contain 'LogData'
        }
    }
}
