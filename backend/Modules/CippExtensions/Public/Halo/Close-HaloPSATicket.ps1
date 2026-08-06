function Close-HaloPSATicket {
  <#
    .SYNOPSIS
        Posts a resolution note to a HaloPSA ticket, optionally closing it.
    .DESCRIPTION
        Called when CIPP notices that the alert items a ticket was raised for have stopped being
        reported. Adds the note through the same /actions endpoint New-HaloPSATicket already uses for
        consolidation, with the configured resolution outcome when the ticket is being closed.

        The whole close-back is gated on HaloPSA.CloseResolvedTickets, which is off by default, so an
        instance that has not opted in behaves exactly as it did before.

        Halo closes a ticket by way of an action carrying an outcome that closes it, and which outcome
        that is differs per instance and per ticket type - so it comes from configuration rather than
        being guessed. With no resolution outcome configured the note is still posted and the ticket
        is left open, which is the safe half of the behaviour.
    .PARAMETER TicketID
        The HaloPSA ticket to act on.
    .PARAMETER Note
        HTML note body describing what cleared.
    .PARAMETER CloseTicket
        Close the ticket rather than just noting the change.
    .OUTPUTS
        [bool] True when the note was accepted, so the caller knows the links can be cleared.
    #>
  [CmdletBinding(SupportsShouldProcess)]
  param (
    [Parameter(Mandatory = $true)]
    [string]$TicketID,

    [Parameter(Mandatory = $true)]
    [string]$Note,

    [switch]$CloseTicket
  )

  $Table = Get-CIPPTable -TableName Extensionsconfig
  $Configuration = ((Get-CIPPAzDataTableEntity @Table).config | ConvertFrom-Json -ErrorAction SilentlyContinue).HaloPSA

  if (-not $Configuration -or -not $Configuration.Enabled) {
    return $false
  }
  if (-not $Configuration.CloseResolvedTickets) {
    Write-Information "HaloPSA close-back is disabled - leaving ticket $TicketID alone"
    return $false
  }

  $ResolutionOutcome = $Configuration.ResolutionOutcome.value ?? $Configuration.ResolutionOutcome
  # Fall back to the note outcome used elsewhere in the integration so the note still lands when no
  # resolution outcome has been picked. 7 is Halo's built-in Internal Note action.
  $NoteOutcome = $Configuration.Outcome.value ?? $Configuration.Outcome ?? 7

  $WillClose = $CloseTicket.IsPresent -and $ResolutionOutcome
  if ($CloseTicket.IsPresent -and -not $ResolutionOutcome) {
    Write-Information "No HaloPSA resolution outcome configured - adding the note to ticket $TicketID but leaving it open"
  }

  $Outcome = if ($WillClose) { $ResolutionOutcome } else { $NoteOutcome }

  try {
    $Token = Get-HaloToken -configuration $Configuration
    # sendemail = false is required, not cosmetic. A Halo instance's closing outcome usually has an
    # email template attached (the sandbox's built-in "Close" has emailtemplate_id 14), and Halo then
    # refuses the whole action with 400 "Please complete the Email To field in order to send an
    # Email" - so without this the close silently never happens on most instances. CIPP is posting an
    # internal system note here, already hidden from the end user, so suppressing the email is also
    # the behaviour we want: nobody should get a "your ticket is closed" mail from a CIPP sweep.
    $Object = [PSCustomObject]@{
      ticket_id      = $TicketID
      outcome_id     = $Outcome
      hiddenfromuser = $true
      sendemail      = $false
      note_html      = $Note
    }
    $Body = ConvertTo-Json -Compress -Depth 10 -InputObject @($Object)

    # Returning $false when ShouldProcess declines matters: the caller deletes its link rows on a
    # $true, so reporting success under -WhatIf would drop the links without ever closing the ticket
    # and the resolution would be lost for good.
    if (-not $PSCmdlet.ShouldProcess("HaloPSA ticket $TicketID", $(if ($WillClose) { 'Close ticket' } else { 'Add resolution note' }))) {
      return $false
    }

    $null = Invoke-RestMethod -Uri "$($Configuration.ResourceURL)/actions" -ContentType 'application/json; charset=utf-8' -Method Post -Body $Body -Headers @{Authorization = "Bearer $($Token.access_token)" }
    Write-Information "$(if ($WillClose) { 'Closed' } else { 'Noted resolution on' }) HaloPSA ticket $TicketID"
    return $true
  }
  catch {
    $Message = if ($_.ErrorDetails.Message) {
      Get-NormalizedError -Message $_.ErrorDetails.Message
    }
    else {
      $_.Exception.message
    }
    # Non-fatal by design: the link rows stay put and the next run tries again. The most common cause
    # is the API user not having rights to run the configured outcome, so say so.
    Write-LogMessage -message "Failed to close HaloPSA ticket $TicketID`: $Message - check the HaloPSA API user can run outcome $Outcome on this ticket type." -API 'AlertResolution' -sev Warning -LogData (Get-CippException -Exception $_)
    Write-Information "Failed to act on HaloPSA ticket $TicketID`: $Message"
    return $false
  }
}
