function ConvertTo-CIPPAIAccessPolicyPlan {
    <#
    .SYNOPSIS
        Compares merged AI Access Policy requirements with a tenant's current state and lists changes

    .DESCRIPTION
        Pure function: no Graph or table calls, so the decision logic is testable. Returns one row per
        requirement:

            control   UserConsent | CopilotLicence | ApprovedAiApp | Manual
            item      what the row is about (SKU, app, manual control)
            target    the group, or All users
            expected  / current   readable values
            status    Compliant | NonCompliant | Blocked | NotApplicable
            detail    why, in a sentence
            action    the change CIPP would make ({ type; ... }), or $null when there is nothing CIPP
                      can do (already compliant, blocked, not applicable, or a manual control)
            from      the policies that asked for it

    .PARAMETER Merged
        Output of Merge-CIPPAIAccessPolicy

    .PARAMETER State
        Output of Get-CIPPAIAccessPolicyState (or an equivalent hashtable in tests)

    .PARAMETER ManualCatalog
        Entries from Config/AIAccessManualControls.json

    .PARAMETER Now
        Reference time for manual confirmation expiry

    .PARAMETER ReviewDays
        Days after which a manual confirmation must be reviewed again

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Merged,
        [Parameter(Mandatory = $true)]
        $State,
        $ManualCatalog = @(),
        [datetime]$Now = [datetime]::UtcNow,
        [int]$ReviewDays = 90
    )

    $DefaultAppRoleId = '00000000-0000-0000-0000-000000000000'
    $CippConsentPolicy = 'ManagePermissionGrantsForSelf.cipp-consent-policy'
    $Rows = [System.Collections.Generic.List[object]]::new()

    function Add-Row ($Control, $Item, $Target, $Expected, $Current, $Status, $Detail, $Action, $From) {
        $Rows.Add([pscustomobject]@{
                control  = $Control
                item     = $Item
                target   = $Target
                expected = $Expected
                current  = $Current
                status   = $Status
                detail   = $Detail
                action   = $Action
                from     = @($From)
            })
    }

    # Groups are resolved by display name; zero or several matches block the requirement
    function Resolve-Group ($Name) {
        $Found = @($State.groups[$Name.ToLower()])
        if ($Found.Count -eq 1 -and $Found[0]) { return [pscustomobject]@{ group = $Found[0]; problem = $null } }
        if ($Found.Count -gt 1) { return [pscustomobject]@{ group = $null; problem = "Several groups are named '$Name'; rename them so the policy targets one group." } }
        return [pscustomobject]@{ group = $null; problem = "Group '$Name' does not exist in this tenant. Create it (for example with a CIPP group template) and run the policy again." }
    }

    # --- User consent (tenant-wide) ---
    if ($Merged.userConsent.value -eq 'block') {
        $Assigned = @($State.permissionGrantPoliciesAssigned)
        $SelfConsent = @($Assigned | Where-Object { $_ -like 'ManagePermissionGrantsForSelf.*' })
        $Allowing = @($SelfConsent | Where-Object { $_ -ne $CippConsentPolicy })
        $Current = if ($SelfConsent.Count -eq 0) { 'Users cannot consent' } elseif ($Allowing.Count -eq 0) { 'Only apps approved in the CIPP consent policy' } else { "Users can consent ($($Allowing -join ', '))" }
        if ($Allowing.Count -eq 0) {
            Add-Row 'UserConsent' 'User consent to apps' 'All users' 'Blocked' $Current 'Compliant' 'Users cannot grant AI apps access to company data themselves.' $null $Merged.userConsent.from
        } elseif ($State.conflictingConsentStandard) {
            Add-Row 'UserConsent' 'User consent to apps' 'All users' 'Blocked' $Current 'Blocked' 'The "Allow users to consent to low risk apps" standard applies to this tenant; remove it before this policy can block consent.' $null $Merged.userConsent.from
        } else {
            $Keep = @($Assigned | Where-Object { $_ -notin $Allowing })
            Add-Row 'UserConsent' 'User consent to apps' 'All users' 'Blocked' $Current 'NonCompliant' 'Users can grant apps, including AI apps, access to company data without an admin.' ([pscustomobject]@{ type = 'BlockUserConsent'; permissionGrantPoliciesAssigned = $Keep }) $Merged.userConsent.from
        }
    }

    # --- Copilot licences per group ---
    # A rule usually lists several Copilot SKUs; one the tenant doesn't buy is only worth a row when
    # the tenant has none of the rule's SKUs for that group
    $SubscribedParts = @($State.subscribedSkus | ForEach-Object { $_.skuPartNumber })
    $GroupsWithASku = @{}
    foreach ($Licence in @($Merged.licences)) {
        if ($SubscribedParts -contains $Licence.skuPartNumber) { $GroupsWithASku[$Licence.groupName.ToLower()] = $true }
    }

    foreach ($Licence in @($Merged.licences)) {
        $Sku = @($State.subscribedSkus | Where-Object { $_.skuPartNumber -eq $Licence.skuPartNumber }) | Select-Object -First 1
        $Expected = if ($Licence.mode -eq 'grant') { 'Assigned to group' } else { 'Not assigned to group' }
        if (-not $Sku) {
            if ($GroupsWithASku.ContainsKey($Licence.groupName.ToLower())) { continue }
            Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected 'Not subscribed' 'NotApplicable' "The tenant has no $($Licence.skuPartNumber) subscription." $null $Licence.from
            continue
        }
        $Resolved = Resolve-Group $Licence.groupName
        if (-not $Resolved.group) {
            Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected 'Group missing' 'Blocked' $Resolved.problem $null $Licence.from
            continue
        }
        $Group = $Resolved.group
        $HasLicence = @($Group.assignedLicenses | Where-Object { $_.skuId -eq $Sku.skuId }).Count -gt 0
        $Current = if ($HasLicence) { 'Assigned to group' } else { 'Not assigned to group' }
        if ($Licence.mode -eq 'grant') {
            if ($HasLicence) {
                Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected $Current 'Compliant' 'Members get the licence through group-based licensing.' $null $Licence.from
            } else {
                $Available = [int]($Sku.prepaidUnits.enabled ?? 0) - [int]($Sku.consumedUnits ?? 0)
                $Detail = "Assign $($Licence.skuPartNumber) to the group. $Available unassigned licences available"
                if ($Available -le 0) { $Detail += '; members will show licence errors until more are bought' }
                Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected $Current 'NonCompliant' "$Detail." ([pscustomobject]@{ type = 'AssignGroupLicense'; groupId = $Group.id; skuId = $Sku.skuId }) $Licence.from
            }
        } else {
            if ($HasLicence) {
                Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected $Current 'NonCompliant' 'Remove the group-based assignment. Licences assigned directly to users are not changed.' ([pscustomobject]@{ type = 'RemoveGroupLicense'; groupId = $Group.id; skuId = $Sku.skuId }) $Licence.from
            } else {
                Add-Row 'CopilotLicence' $Licence.skuPartNumber $Licence.groupName $Expected $Current 'Compliant' 'The group does not grant this licence. Licences assigned directly to users are not checked.' $null $Licence.from
            }
        }
    }

    # --- Approved AI apps: assignment required, assigned to the policy groups ---
    foreach ($App in @($Merged.approvedAiApps)) {
        $Sp = $State.servicePrincipals[$App.appId]
        $Name = $App.displayName ?? $Sp.displayName ?? $App.appId
        if (-not $Sp) {
            Add-Row 'ApprovedAiApp' $Name ($App.groupNames -join ', ') 'Assignment required' 'Not in tenant' 'NotApplicable' 'This app has not been added to the tenant, so there is nothing to restrict.' $null $App.from
            continue
        }

        # Prefer an enabled user role (gallery SSO apps usually define one); otherwise the default role
        $UserRole = @($Sp.appRoles | Where-Object { $_.isEnabled -ne $false -and @($_.allowedMemberTypes) -contains 'User' }) | Select-Object -First 1
        $AppRoleId = if ($UserRole) { $UserRole.id } else { $DefaultAppRoleId }
        $AssignedTo = @($State.appAssignments[$Sp.id] | ForEach-Object { $_.principalId })

        # Assignment rows come first: the executor also assigns groups before requiring assignment
        foreach ($GroupName in @($App.groupNames)) {
            $Resolved = Resolve-Group $GroupName
            if (-not $Resolved.group) {
                Add-Row 'ApprovedAiApp' $Name $GroupName 'Group assigned' 'Group missing' 'Blocked' $Resolved.problem $null $App.from
                continue
            }
            if ($AssignedTo -contains $Resolved.group.id) {
                Add-Row 'ApprovedAiApp' $Name $GroupName 'Group assigned' 'Group assigned' 'Compliant' 'Members of the group can sign in.' $null $App.from
            } else {
                Add-Row 'ApprovedAiApp' $Name $GroupName 'Group assigned' 'Not assigned' 'NonCompliant' 'Assign the group so its members keep access.' ([pscustomobject]@{ type = 'AssignAppToGroup'; servicePrincipalId = $Sp.id; groupId = $Resolved.group.id; appRoleId = $AppRoleId }) $App.from
            }
        }

        if ($Sp.appRoleAssignmentRequired -eq $true) {
            Add-Row 'ApprovedAiApp' $Name 'All users' 'Assignment required' 'Assignment required' 'Compliant' 'Only assigned users and groups can sign in.' $null $App.from
        } else {
            $Others = @($AssignedTo).Count
            Add-Row 'ApprovedAiApp' $Name 'All users' 'Assignment required' 'Anyone can sign in' 'NonCompliant' "Require assignment so only the policy's groups (and $Others existing assignments) can sign in." ([pscustomobject]@{ type = 'RequireAppAssignment'; servicePrincipalId = $Sp.id }) $App.from
        }
    }

    # --- Manual controls: confirmed by a person, reviewed every ReviewDays ---
    foreach ($Control in @($Merged.manualControls)) {
        $Entry = @($ManualCatalog | Where-Object { $_.id -eq $Control.id }) | Select-Object -First 1
        $Title = $Entry.title ?? $Control.id
        $Confirmation = $State.checklist[$Control.id]
        $ConfirmedAt = if ($Confirmation.ConfirmedAt) { try { ([datetime]$Confirmation.ConfirmedAt).ToUniversalTime() } catch { $null } }
        if (-not $ConfirmedAt) {
            Add-Row 'Manual' $Title 'All users' 'Confirmed' 'Not confirmed' 'NonCompliant' "Set this in $($Entry.where), then confirm it on the AI Access checklist." $null $Control.from
        } elseif ($ConfirmedAt.AddDays($ReviewDays) -lt $Now) {
            Add-Row 'Manual' $Title 'All users' 'Confirmed' "Confirmed $($ConfirmedAt.ToString('yyyy-MM-dd')) by $($Confirmation.ConfirmedBy)" 'NonCompliant' "Review due: last confirmed more than $ReviewDays days ago." $null $Control.from
        } else {
            Add-Row 'Manual' $Title 'All users' 'Confirmed' "Confirmed $($ConfirmedAt.ToString('yyyy-MM-dd')) by $($Confirmation.ConfirmedBy)" 'Compliant' "Next review by $($ConfirmedAt.AddDays($ReviewDays).ToString('yyyy-MM-dd'))." $null $Control.from
        }
    }

    return , $Rows.ToArray()
}
