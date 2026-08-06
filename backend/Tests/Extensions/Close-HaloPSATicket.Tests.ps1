# Pester tests for Close-HaloPSATicket.
#
# The sendemail assertion is the one that matters most and it cannot be caught without a live Halo:
# a closing outcome normally has an email template attached, and Halo then rejects the entire action
# with 400 "Please complete the Email To field in order to send an Email". Verified against the
# sandbox, where the built-in "Close" outcome (id 88) carries emailtemplate_id 14 - posting without
# sendemail=false left the ticket open at status_id 1, and adding it closed the ticket (status_id 9).

BeforeAll {
    # Test lives at backend/Tests/Extensions/, so three levels up is backend/.
    $BackendRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Join-Path $BackendRoot 'Modules/CippExtensions/Public/Halo/Close-HaloPSATicket.ps1'

    function Get-CIPPTable { param([string]$TableName) }
    function Get-CIPPAzDataTableEntity { param($TableName, $Filter, $Property, $First) }
    function Get-HaloToken { param($configuration) }
    function Write-LogMessage { param($API, $tenant, $message, $sev, $LogData, $headers) }
    function Get-NormalizedError { param($Message) }
    function Get-CippException { param($Exception) }

    . $FunctionPath

    function New-HaloConfig {
        param($CloseResolved = $true, $ResolutionOutcome = 88, $Outcome = 155, $Enabled = $true)
        $Halo = [ordered]@{
            Enabled     = $Enabled
            ResourceURL = 'https://halo.example.com/api'
        }
        if ($null -ne $CloseResolved) { $Halo.CloseResolvedTickets = $CloseResolved }
        if ($null -ne $ResolutionOutcome) { $Halo.ResolutionOutcome = $ResolutionOutcome }
        if ($null -ne $Outcome) { $Halo.Outcome = $Outcome }
        [pscustomobject]@{ config = (@{ HaloPSA = $Halo } | ConvertTo-Json -Depth 5) }
    }
}

Describe 'Close-HaloPSATicket' {
    BeforeEach {
        $script:Posted = [System.Collections.Generic.List[object]]::new()
        $script:Config = New-HaloConfig

        Mock -CommandName Get-CIPPTable -MockWith { param([string]$TableName) @{ TableName = $TableName } }
        Mock -CommandName Get-CIPPAzDataTableEntity -MockWith { $script:Config }
        Mock -CommandName Get-HaloToken -MockWith { @{ access_token = 'token' } }
        Mock -CommandName Write-LogMessage -MockWith { }
        Mock -CommandName Get-NormalizedError -MockWith { param($Message) $Message }
        Mock -CommandName Get-CippException -MockWith { @{} }
        Mock -CommandName Invoke-RestMethod -MockWith {
            param($Uri, $ContentType, $Method, $Body, $Headers)
            $script:Posted.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = ($Body | ConvertFrom-Json) })
            return @{ id = 1 }
        }
    }

    Context 'when closing a ticket' {
        It 'suppresses the email so an outcome with an email template still applies' {
            $r = Close-HaloPSATicket -TicketID '1283' -Note '<p>cleared</p>' -CloseTicket

            $r | Should -BeTrue
            $script:Posted.Count | Should -Be 1
            # Halo returns 400 for the whole action without this.
            $script:Posted[0].Body[0].sendemail | Should -BeFalse
        }

        It 'posts the configured resolution outcome to the actions endpoint' {
            $null = Close-HaloPSATicket -TicketID '1283' -Note '<p>cleared</p>' -CloseTicket

            $script:Posted[0].Uri | Should -Be 'https://halo.example.com/api/actions'
            $script:Posted[0].Method | Should -Be 'Post'
            $script:Posted[0].Body[0].outcome_id | Should -Be 88
            $script:Posted[0].Body[0].ticket_id | Should -Be '1283'
            $script:Posted[0].Body[0].hiddenfromuser | Should -BeTrue
        }
    }

    Context 'when only noting a partial resolution' {
        It 'uses the note outcome rather than the closing one' {
            $null = Close-HaloPSATicket -TicketID '1284' -Note '<p>some cleared</p>'

            $script:Posted[0].Body[0].outcome_id | Should -Be 155
        }
    }

    Context 'when no resolution outcome is configured' {
        It 'still posts the note but does not use a closing outcome' {
            $script:Config = New-HaloConfig -ResolutionOutcome $null

            $r = Close-HaloPSATicket -TicketID '1285' -Note '<p>cleared</p>' -CloseTicket

            $r | Should -BeTrue
            $script:Posted.Count | Should -Be 1
            $script:Posted[0].Body[0].outcome_id | Should -Be 155
        }
    }

    Context 'when the feature is disabled' {
        It 'does nothing and reports failure so the caller keeps its links' {
            $script:Config = New-HaloConfig -CloseResolved $false

            $r = Close-HaloPSATicket -TicketID '1286' -Note '<p>cleared</p>' -CloseTicket

            $r | Should -BeFalse
            $script:Posted.Count | Should -Be 0
        }

        It 'does nothing when the integration itself is off' {
            $script:Config = New-HaloConfig -Enabled $false

            $r = Close-HaloPSATicket -TicketID '1287' -Note '<p>cleared</p>' -CloseTicket

            $r | Should -BeFalse
            $script:Posted.Count | Should -Be 0
        }
    }

    Context 'when Halo rejects the action' {
        It 'reports failure so the links are kept for the next run' {
            Mock -CommandName Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 400 (Bad Request).' }

            $r = Close-HaloPSATicket -TicketID '1288' -Note '<p>cleared</p>' -CloseTicket

            $r | Should -BeFalse
        }
    }

    Context 'under -WhatIf' {
        It 'reports failure rather than success, so links are not dropped without a close' {
            $r = Close-HaloPSATicket -TicketID '1289' -Note '<p>cleared</p>' -CloseTicket -WhatIf

            $r | Should -BeFalse
            $script:Posted.Count | Should -Be 0
        }
    }
}
