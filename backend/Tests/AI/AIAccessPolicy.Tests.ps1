# Pester tests for the AI Access Policy compiler
# Covers normalising form input, merging layered policies (stricter wins), building the plan from
# tenant state, and the order the executor applies changes in

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    foreach ($Name in @('ConvertTo-CIPPAIAccessPolicy', 'Merge-CIPPAIAccessPolicy', 'ConvertTo-CIPPAIAccessPolicyPlan', 'Invoke-CIPPAIAccessPolicyAction')) {
        $Path = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter "$Name.ps1" -File | Select-Object -First 1 -ExpandProperty FullName
        if (-not $Path) { throw "Could not locate $Name.ps1 under Modules/" }
        . $Path
    }
    $script:Catalog = Get-Content (Join-Path $RepoRoot 'Config/AIAccessManualControls.json') -Raw | ConvertFrom-Json

    function New-Policy ([hashtable]$Overrides) {
        $Base = @{ name = 'Policy'; targetType = 'group'; groupName = 'Finance users' }
        foreach ($Key in $Overrides.Keys) { $Base[$Key] = $Overrides[$Key] }
        ConvertTo-CIPPAIAccessPolicy -InputObject ([pscustomobject]$Base) -ManualControlIds $script:Catalog.id
    }

    function New-State {
        @{
            permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-legacy', 'ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team')
            conflictingConsentStandard      = $false
            subscribedSkus                  = @([pscustomobject]@{ skuId = 'sku-copilot'; skuPartNumber = 'Microsoft_365_Copilot'; prepaidUnits = [pscustomobject]@{ enabled = 10 }; consumedUnits = 4 })
            groups                          = @{ 'finance users' = @([pscustomobject]@{ id = 'grp-fin'; displayName = 'Finance users'; assignedLicenses = @() }) }
            servicePrincipals               = @{}
            appAssignments                  = @{}
            checklist                       = @{}
        }
    }
}

Describe 'ConvertTo-CIPPAIAccessPolicy' {
    It 'normalises form input with autocomplete objects' {
        $Policy = New-Policy @{
            copilotLicenceMode = [pscustomobject]@{ label = 'Grant'; value = 'grant' }
            copilotSkus        = @([pscustomobject]@{ label = 'Microsoft 365 Copilot'; value = 'Microsoft_365_Copilot' })
            userConsent        = $true
            approvedAiApps     = @([pscustomobject]@{ label = 'ChatGPT Enterprise'; value = '11111111-AAAA-4AAA-8AAA-111111111111' }, '22222222-2222-4222-8222-222222222222|Claude')
            manualControls     = @([pscustomobject]@{ label = 'x'; value = 'ModelProviders' })
        }
        $Policy.target.groupName | Should -Be 'Finance users'
        $Policy.copilotLicence.mode | Should -Be 'grant'
        $Policy.copilotLicence.skuPartNumbers | Should -Be @('Microsoft_365_Copilot')
        $Policy.userConsent | Should -Be 'block'
        $Policy.approvedAiApps.appId | Should -Be @('11111111-aaaa-4aaa-8aaa-111111111111', '22222222-2222-4222-8222-222222222222')
        $Policy.approvedAiApps.displayName | Should -Be @('ChatGPT Enterprise', 'Claude')
        $Policy.manualControls | Should -Be @('ModelProviders')
    }

    It 'defaults to the Copilot SKUs when a licence rule names none' {
        (New-Policy @{ copilotLicenceMode = 'deny' }).copilotLicence.skuPartNumbers | Should -Be @('Microsoft_365_Copilot', 'M365_Copilot', 'Microsoft_365_Copilot_EDU')
    }

    It 'round-trips a stored policy unchanged' {
        $Policy = New-Policy @{ copilotLicenceMode = 'grant'; userConsent = $true; approvedAiApps = @('22222222-2222-4222-8222-222222222222|Claude') }
        $Again = ConvertTo-CIPPAIAccessPolicy -InputObject ($Policy | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        ($Again | ConvertTo-Json -Depth 5) | Should -Be ($Policy | ConvertTo-Json -Depth 5)
    }

    It 'rejects licence and app rules without a group target' {
        { New-Policy @{ targetType = 'allUsers'; copilotLicenceMode = 'grant' } } | Should -Throw '*need a group target*'
        { New-Policy @{ targetType = 'allUsers'; approvedAiApps = @('22222222-2222-4222-8222-222222222222') } } | Should -Throw '*need a group target*'
    }

    It 'rejects invalid input' {
        { New-Policy @{ name = ' ' } } | Should -Throw '*needs a name*'
        { New-Policy @{ approvedAiApps = @('not-a-guid') } } | Should -Throw '*not an application*'
        { New-Policy @{ manualControls = @('Nope') } } | Should -Throw '*Unknown manual control*'
        { New-Policy @{ targetType = 'group'; groupName = '' } } | Should -Throw '*needs a group name*'
    }
}

Describe 'Merge-CIPPAIAccessPolicy' {
    It 'lets the stricter value win and records where it came from' {
        $Baseline = New-Policy @{ name = 'Baseline'; targetType = 'allUsers'; userConsent = $true; manualControls = @('ModelProviders') }
        $Grant = New-Policy @{ name = 'Finance grant'; copilotLicenceMode = 'grant'; copilotSkus = @('Microsoft_365_Copilot') }
        $Deny = New-Policy @{ name = 'Finance deny'; copilotLicenceMode = 'deny'; copilotSkus = @('Microsoft_365_Copilot'); manualControls = @('ModelProviders', 'AgentTools') }

        $Merged = Merge-CIPPAIAccessPolicy -Policies @($Baseline, $Grant, $Deny)
        $Merged.userConsent.value | Should -Be 'block'
        $Merged.userConsent.from | Should -Be @('Baseline')
        $Merged.licences.Count | Should -Be 1
        $Merged.licences[0].mode | Should -Be 'deny'
        $Merged.licences[0].from | Should -Be @('Finance grant', 'Finance deny')
        $Merged.manualControls.id | Should -Be @('ModelProviders', 'AgentTools')
    }

    It 'assigns an approved app to every group that approves it' {
        $Finance = New-Policy @{ name = 'Finance'; approvedAiApps = @('22222222-2222-4222-8222-222222222222|Claude') }
        $Legal = New-Policy @{ name = 'Legal'; groupName = 'Legal users'; approvedAiApps = @('22222222-2222-4222-8222-222222222222') }
        $Merged = Merge-CIPPAIAccessPolicy -Policies @($Finance, $Legal)
        $Merged.approvedAiApps.Count | Should -Be 1
        $Merged.approvedAiApps[0].groupNames | Should -Be @('Finance users', 'Legal users')
        $Merged.approvedAiApps[0].displayName | Should -Be 'Claude'
    }

    It 'returns empty requirements for no policies' {
        $Merged = Merge-CIPPAIAccessPolicy -Policies @()
        $Merged.userConsent.value | Should -Be 'notManaged'
        @($Merged.licences).Count | Should -Be 0
    }
}

Describe 'ConvertTo-CIPPAIAccessPolicyPlan' {
    Context 'User consent' {
        It 'plans to remove self-consent policies and keep the rest' {
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ userConsent = $true })
            $Row = @(ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State (New-State))[0]
            $Row.status | Should -Be 'NonCompliant'
            $Row.action.type | Should -Be 'BlockUserConsent'
            $Row.action.permissionGrantPoliciesAssigned | Should -Be @('ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team')
        }

        It 'treats the CIPP consent policy as compliant' {
            $State = New-State
            $State.permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.cipp-consent-policy')
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ userConsent = $true })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State)[0].status | Should -Be 'Compliant'
        }

        It 'blocks instead of fighting the low-risk consent standard' {
            $State = New-State
            $State.conflictingConsentStandard = $true
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ userConsent = $true })
            $Row = (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State)[0]
            $Row.status | Should -Be 'Blocked'
            $Row.action | Should -BeNullOrEmpty
        }
    }

    Context 'Copilot licences' {
        It 'plans a group assignment and reports available licences' {
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ copilotLicenceMode = 'grant'; copilotSkus = @('Microsoft_365_Copilot') })
            $Row = (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State (New-State))[0]
            $Row.status | Should -Be 'NonCompliant'
            $Row.action.type | Should -Be 'AssignGroupLicense'
            $Row.action.groupId | Should -Be 'grp-fin'
            $Row.action.skuId | Should -Be 'sku-copilot'
            $Row.detail | Should -BeLike '*6 unassigned licences available*'
        }

        It 'is compliant when the group already has the licence, and plans removal for deny' {
            $State = New-State
            $State.groups['finance users'][0].assignedLicenses = @([pscustomobject]@{ skuId = 'sku-copilot' })
            $Grant = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ copilotLicenceMode = 'grant'; copilotSkus = @('Microsoft_365_Copilot') })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Grant -State $State)[0].status | Should -Be 'Compliant'
            $Deny = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ copilotLicenceMode = 'deny'; copilotSkus = @('Microsoft_365_Copilot') })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Deny -State $State)[0].action.type | Should -Be 'RemoveGroupLicense'
        }

        It 'marks unsubscribed SKUs not applicable and missing or ambiguous groups blocked' {
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ copilotLicenceMode = 'grant'; copilotSkus = @('M365_Copilot') })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State (New-State))[0].status | Should -Be 'NotApplicable'

            $State = New-State
            $State.groups = @{}
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ copilotLicenceMode = 'grant'; copilotSkus = @('Microsoft_365_Copilot') })
            $Row = (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State)[0]
            $Row.status | Should -Be 'Blocked'
            $Row.detail | Should -BeLike '*does not exist*'

            $State.groups = @{ 'finance users' = @([pscustomobject]@{ id = 'a' }, [pscustomobject]@{ id = 'b' }) }
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State)[0].detail | Should -BeLike '*Several groups*'
        }
    }

    Context 'Approved AI apps' {
        BeforeEach {
            $script:AppId = '22222222-2222-4222-8222-222222222222'
            $script:AppState = New-State
            $script:AppState.servicePrincipals[$script:AppId] = [pscustomobject]@{
                id = 'sp-claude'; displayName = 'Claude'; appRoleAssignmentRequired = $false
                appRoles = @([pscustomobject]@{ id = 'role-user'; isEnabled = $true; allowedMemberTypes = @('User') })
            }
            $script:AppState.appAssignments['sp-claude'] = @([pscustomobject]@{ principalId = 'grp-other' })
        }

        It 'assigns the group with the app user role and requires assignment' {
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ approvedAiApps = @($script:AppId) })
            $Rows = ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $script:AppState
            $Rows.action.type | Should -Be @('AssignAppToGroup', 'RequireAppAssignment')
            $Rows[0].action.appRoleId | Should -Be 'role-user'
            $Rows[1].detail | Should -BeLike '*1 existing assignments*'
        }

        It 'uses the default role when the app has no user role' {
            $script:AppState.servicePrincipals[$script:AppId].appRoles = @()
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ approvedAiApps = @($script:AppId) })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $script:AppState)[0].action.appRoleId | Should -Be '00000000-0000-0000-0000-000000000000'
        }

        It 'is compliant once assigned and required, and not applicable when the app is absent' {
            $script:AppState.servicePrincipals[$script:AppId].appRoleAssignmentRequired = $true
            $script:AppState.appAssignments['sp-claude'] = @([pscustomobject]@{ principalId = 'grp-fin' })
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ approvedAiApps = @($script:AppId) })
            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $script:AppState).status | Should -Be @('Compliant', 'Compliant')

            (ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State (New-State))[0].status | Should -Be 'NotApplicable'
        }
    }

    Context 'Manual controls' {
        It 'reports unconfirmed, confirmed and review-due items' {
            $Now = [datetime]'2026-10-20T00:00:00Z'
            $State = New-State
            $State.checklist['AgentTools'] = [pscustomobject]@{ ConfirmedAt = '2026-09-01T00:00:00Z'; ConfirmedBy = 'tech@msp.example' }
            $State.checklist['CopilotFileUpload'] = [pscustomobject]@{ ConfirmedAt = '2026-01-01T00:00:00Z'; ConfirmedBy = 'tech@msp.example' }
            $Merged = Merge-CIPPAIAccessPolicy -Policies @(New-Policy @{ manualControls = @('ModelProviders', 'AgentTools', 'CopilotFileUpload') })
            $Rows = ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State -ManualCatalog $script:Catalog -Now $Now

            ($Rows | Where-Object item -Like 'Restrict AI model providers*').status | Should -Be 'NonCompliant'
            ($Rows | Where-Object item -Like 'Review the agent tools*').status | Should -Be 'Compliant'
            ($Rows | Where-Object item -Like 'Decide on Copilot file upload*').detail | Should -BeLike 'Review due*'
            @($Rows | Where-Object action).Count | Should -Be 0
        }
    }
}

Describe 'Invoke-CIPPAIAccessPolicyAction' {
    BeforeAll {
        function New-GraphPOSTRequest { param($uri, $tenantid, $type, $body) $script:Calls.Add("$type $uri") }
        function Write-LogMessage { param($headers, $API, $tenant, $message, $sev, $LogData) }
        function Get-CippException { param($Exception) @{ NormalizedError = "$Exception" } }
    }
    BeforeEach { $script:Calls = [System.Collections.Generic.List[string]]::new() }

    It 'assigns groups before requiring assignment, and skips rows without changes' {
        $Plan = @(
            [pscustomobject]@{ control = 'ApprovedAiApp'; item = 'Claude'; target = 'All users'; expected = 'Assignment required'; status = 'NonCompliant'; action = [pscustomobject]@{ type = 'RequireAppAssignment'; servicePrincipalId = 'sp' } }
            [pscustomobject]@{ control = 'ApprovedAiApp'; item = 'Claude'; target = 'Finance users'; expected = 'Group assigned'; status = 'NonCompliant'; action = [pscustomobject]@{ type = 'AssignAppToGroup'; servicePrincipalId = 'sp'; groupId = 'g'; appRoleId = 'r' } }
            [pscustomobject]@{ control = 'Manual'; item = 'x'; target = 'All users'; expected = 'Confirmed'; status = 'NonCompliant'; action = $null }
            [pscustomobject]@{ control = 'CopilotLicence'; item = 'sku'; target = 'Finance users'; expected = 'Assigned'; status = 'Compliant'; action = $null }
        )
        $Results = @(Invoke-CIPPAIAccessPolicyAction -TenantFilter 'contoso.onmicrosoft.com' -Plan $Plan)
        $script:Calls | Should -Be @('POST https://graph.microsoft.com/v1.0/servicePrincipals/sp/appRoleAssignedTo', 'PATCH https://graph.microsoft.com/v1.0/servicePrincipals/sp')
        $Results.success | Should -Be @($true, $true)
    }

    It 'continues after a failed change and reports it' {
        function New-GraphPOSTRequest { param($uri, $tenantid, $type, $body) if ($uri -like '*assignLicense') { throw 'Insufficient licences' }; $script:Calls.Add("$type $uri") }
        $Plan = @(
            [pscustomobject]@{ control = 'CopilotLicence'; item = 'sku'; target = 'Finance users'; expected = 'Assigned'; status = 'NonCompliant'; action = [pscustomobject]@{ type = 'AssignGroupLicense'; groupId = 'g'; skuId = 's' } }
            [pscustomobject]@{ control = 'UserConsent'; item = 'User consent'; target = 'All users'; expected = 'Blocked'; status = 'NonCompliant'; action = [pscustomobject]@{ type = 'BlockUserConsent'; permissionGrantPoliciesAssigned = @() } }
        )
        $Results = @(Invoke-CIPPAIAccessPolicyAction -TenantFilter 'contoso.onmicrosoft.com' -Plan $Plan)
        $Results.success | Should -Be @($true, $false)
        $Results[1].message | Should -BeLike '*Insufficient licences*'
    }
}
