function Merge-CIPPAIAccessPolicy {
    <#
    .SYNOPSIS
        Merges the AI Access Policies that apply to one tenant into a single set of requirements

    .DESCRIPTION
        Policies layer: an MSP baseline plus client or group policies. Where two policies set the same
        thing, the stricter value wins:
          - user consent: block beats notManaged
          - Copilot licence for a group and SKU: deny beats grant
          - approved AI apps: assignment is required, and every group any policy names is assigned
          - manual controls: the union of all policies
        Each requirement records which policies asked for it.

    .PARAMETER Policies
        Normalised policies (see ConvertTo-CIPPAIAccessPolicy)

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Policies
    )

    $Consent = [pscustomobject]@{ value = 'notManaged'; from = [System.Collections.Generic.List[string]]::new() }
    $Licences = [ordered]@{}
    $Apps = [ordered]@{}
    $Manual = [ordered]@{}

    foreach ($Policy in @($Policies | Where-Object { $_ })) {
        if ($Policy.userConsent -eq 'block') {
            $Consent.value = 'block'
            $Consent.from.Add($Policy.name)
        }

        if ($Policy.copilotLicence.mode -in @('grant', 'deny') -and $Policy.target.groupName) {
            foreach ($Sku in @($Policy.copilotLicence.skuPartNumbers)) {
                $Key = "$($Policy.target.groupName.ToLower())|$($Sku.ToLower())"
                if (-not $Licences.Contains($Key)) {
                    $Licences[$Key] = [pscustomobject]@{ groupName = $Policy.target.groupName; skuPartNumber = $Sku; mode = $Policy.copilotLicence.mode; from = [System.Collections.Generic.List[string]]::new() }
                } elseif ($Policy.copilotLicence.mode -eq 'deny') {
                    $Licences[$Key].mode = 'deny'
                }
                $Licences[$Key].from.Add($Policy.name)
            }
        }

        foreach ($App in @($Policy.approvedAiApps)) {
            if (-not $App -or -not $Policy.target.groupName) { continue }
            if (-not $Apps.Contains($App.appId)) {
                $Apps[$App.appId] = [pscustomobject]@{ appId = $App.appId; displayName = $App.displayName; groupNames = [System.Collections.Generic.List[string]]::new(); from = [System.Collections.Generic.List[string]]::new() }
            }
            if (-not $Apps[$App.appId].displayName -and $App.displayName) { $Apps[$App.appId].displayName = $App.displayName }
            if ($Apps[$App.appId].groupNames -notcontains $Policy.target.groupName) { $Apps[$App.appId].groupNames.Add($Policy.target.groupName) }
            $Apps[$App.appId].from.Add($Policy.name)
        }

        foreach ($Id in @($Policy.manualControls)) {
            if (-not $Id) { continue }
            if (-not $Manual.Contains($Id)) { $Manual[$Id] = [pscustomobject]@{ id = $Id; from = [System.Collections.Generic.List[string]]::new() } }
            $Manual[$Id].from.Add($Policy.name)
        }
    }

    [pscustomobject]@{
        policies       = @($Policies | Where-Object { $_ } | ForEach-Object { $_.name })
        userConsent    = $Consent
        licences       = @($Licences.Values)
        approvedAiApps = @($Apps.Values)
        manualControls = @($Manual.Values)
    }
}
