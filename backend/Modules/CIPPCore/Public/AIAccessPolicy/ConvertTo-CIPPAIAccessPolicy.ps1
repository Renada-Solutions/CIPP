function ConvertTo-CIPPAIAccessPolicy {
    <#
    .SYNOPSIS
        Normalises and validates an AI Access Policy from form input or a stored template

    .DESCRIPTION
        Accepts the shape the CIPP form posts (autocomplete fields as {label, value} objects) or an
        already-normalised policy, and returns the canonical policy:

            name, description
            target          { type = allUsers | group; groupName }
            copilotLicence  { mode = notManaged | grant | deny; skuPartNumbers[] }
            userConsent     notManaged | block
            approvedAiApps  [ { appId; displayName } ]
            manualControls  [ control id ]

        Licence and approved-app rules act on a group, so they require a group target. Throws with a
        readable message when the input is invalid.

    .PARAMETER InputObject
        The posted form body or stored policy

    .PARAMETER ManualControlIds
        Valid manual control ids (from Config/AIAccessManualControls.json); unknown ids are rejected

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [string[]]$ManualControlIds = @()
    )

    $DefaultCopilotSkus = @('Microsoft_365_Copilot', 'M365_Copilot', 'Microsoft_365_Copilot_EDU')
    $GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

    # Autocomplete and select fields arrive as {label, value}; plain values pass through
    function Get-Value ($Item) {
        if ($null -eq $Item) { return $null }
        if ($Item -is [string] -or $Item -is [bool] -or $Item -is [ValueType]) { return $Item }
        if ($Item.PSObject.Properties.Name -contains 'value') { return $Item.value }
        return $Item
    }

    # De-duplicates case-insensitively and keeps the original order, so a saved policy reloads unchanged
    function Get-UniqueOrdered ($Values) {
        $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        @($Values | Where-Object { $_ -and $Seen.Add($_) })
    }

    $Name = ([string](Get-Value $InputObject.name)).Trim()
    if (-not $Name) { throw 'The policy needs a name.' }

    # Target: form posts targetType/groupName; stored policies carry target.type/target.groupName
    $TargetType = [string](Get-Value ($InputObject.target.type ?? $InputObject.targetType))
    if (-not $TargetType) { $TargetType = 'allUsers' }
    if ($TargetType -notin @('allUsers', 'group')) { throw "Unknown target type '$TargetType'." }
    $GroupName = ([string](Get-Value ($InputObject.target.groupName ?? $InputObject.groupName))).Trim()
    if ($TargetType -eq 'group' -and -not $GroupName) { throw 'A group target needs a group name.' }
    if ($TargetType -eq 'allUsers') { $GroupName = $null }

    # Copilot licence
    $LicenceMode = [string](Get-Value ($InputObject.copilotLicence.mode ?? $InputObject.copilotLicenceMode))
    if (-not $LicenceMode) { $LicenceMode = 'notManaged' }
    if ($LicenceMode -notin @('notManaged', 'grant', 'deny')) { throw "Unknown Copilot licence mode '$LicenceMode'." }
    $Skus = @(Get-UniqueOrdered @(@($InputObject.copilotLicence.skuPartNumbers ?? $InputObject.copilotSkus) | ForEach-Object { ([string](Get-Value $_)).Trim() }))
    if ($LicenceMode -ne 'notManaged') {
        if ($TargetType -ne 'group') { throw 'Copilot licence rules need a group target: licences are assigned to a group, not to all users.' }
        if ($Skus.Count -eq 0) { $Skus = $DefaultCopilotSkus }
    } else {
        $Skus = @()
    }

    # User consent: form posts a switch (true = block); stored policies carry the string
    $ConsentInput = Get-Value $InputObject.userConsent
    $UserConsent = if ($ConsentInput -is [bool]) {
        if ($ConsentInput) { 'block' } else { 'notManaged' }
    } elseif ([string]::IsNullOrWhiteSpace([string]$ConsentInput)) {
        'notManaged'
    } else {
        [string]$ConsentInput
    }
    if ($UserConsent -notin @('notManaged', 'block')) { throw "Unknown user consent setting '$UserConsent'." }

    # Approved AI apps: {appId, displayName}, {value, label}, "appId", "appId|Display name", or the form's
    # multiline text with one "appId, Display name" per line
    $AppInput = $InputObject.approvedAiApps
    if ($AppInput -is [string]) {
        $AppInput = @($AppInput -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $_ -replace '^([^,|]+?)\s*,\s*', '$1|' })
    }
    $Apps = [System.Collections.Generic.List[object]]::new()
    $SeenApps = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Item in @($AppInput) | Where-Object { $_ }) {
        $AppId = $null; $DisplayName = $null
        if ($Item -is [string]) {
            $Parts = $Item -split '\|', 2
            $AppId = $Parts[0].Trim()
            $DisplayName = if ($Parts.Count -gt 1) { $Parts[1].Trim() }
        } else {
            $AppId = [string]($Item.appId ?? $Item.value)
            $DisplayName = [string]($Item.displayName ?? $Item.label)
            if ($AppId -match '\|') {
                $Parts = $AppId -split '\|', 2
                $AppId = $Parts[0]
                if (-not $DisplayName -or $DisplayName -eq $Item.value) { $DisplayName = $Parts[1] }
            }
            $AppId = $AppId.Trim()
            $DisplayName = ([string]$DisplayName).Trim()
        }
        if ($AppId -notmatch $GuidPattern) { throw "Approved AI app '$AppId' is not an application (client) ID." }
        if ($SeenApps.Add($AppId)) {
            $Apps.Add([pscustomobject]@{ appId = $AppId.ToLower(); displayName = if ($DisplayName -and $DisplayName -ne $AppId) { $DisplayName } else { $null } })
        }
    }
    if ($Apps.Count -gt 0 -and $TargetType -ne 'group') {
        throw 'Approved AI apps need a group target: CIPP requires assignment on each app and assigns it to that group.'
    }

    # Manual controls
    $Manual = @(Get-UniqueOrdered @(@($InputObject.manualControls) | ForEach-Object { ([string](Get-Value $_)).Trim() }))
    if ($ManualControlIds.Count -gt 0) {
        $Unknown = @($Manual | Where-Object { $_ -notin $ManualControlIds })
        if ($Unknown.Count -gt 0) { throw "Unknown manual control: $($Unknown -join ', ')." }
    }

    [pscustomobject]@{
        name           = $Name
        description    = ([string](Get-Value $InputObject.description)).Trim()
        target         = [pscustomobject]@{ type = $TargetType; groupName = $GroupName }
        copilotLicence = [pscustomobject]@{ mode = $LicenceMode; skuPartNumbers = @($Skus) }
        userConsent    = $UserConsent
        approvedAiApps = @($Apps)
        manualControls = @($Manual)
    }
}
