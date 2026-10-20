function Invoke-CIPPAIAccessPolicyAction {
    <#
    .SYNOPSIS
        Applies the changes in an AI Access Policy plan to a tenant

    .DESCRIPTION
        Runs each row's action and returns one result per row. Group assignments to apps run before
        "assignment required" is switched on, so members of the policy groups never lose access while
        the change is applied, and an app whose group assignment fails in the same run is not switched to
        "assignment required". Otherwise a failure on one row does not stop the others.

    .PARAMETER TenantFilter
        The tenant to change

    .PARAMETER Plan
        Rows from ConvertTo-CIPPAIAccessPolicyPlan; rows without an action are ignored

    .PARAMETER APIName
        Name used in the CIPP log

    .PARAMETER Headers
        Request headers, for log attribution when run from an HTTP endpoint

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Plan,
        [string]$APIName = 'AIAccessPolicy',
        $Headers
    )

    $Order = @{ BlockUserConsent = 1; AssignGroupLicense = 2; RemoveGroupLicense = 3; AssignAppToGroup = 4; RequireAppAssignment = 5 }
    $Rows = @($Plan | Where-Object { $_.action -and $_.status -eq 'NonCompliant' } | Sort-Object -Property @{ Expression = { $Order[$_.action.type] ?? 99 } })

    $FailedAssignments = @{}

    foreach ($Row in $Rows) {
        $Action = $Row.action
        try {
            if ($Action.type -eq 'RequireAppAssignment' -and $FailedAssignments.ContainsKey($Action.servicePrincipalId)) {
                throw 'Not changed because assigning a policy group to the app failed; members would lose access.'
            }
            switch ($Action.type) {
                'BlockUserConsent' {
                    $Body = @{ defaultUserRolePermissions = @{ permissionGrantPoliciesAssigned = @($Action.permissionGrantPoliciesAssigned) } } | ConvertTo-Json -Depth 5 -Compress
                    $null = New-GraphPOSTRequest -uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -tenantid $TenantFilter -type PATCH -body $Body
                }
                'AssignGroupLicense' {
                    $Body = @{ addLicenses = @(@{ skuId = $Action.skuId; disabledPlans = @() }); removeLicenses = @() } | ConvertTo-Json -Depth 5 -Compress
                    $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/groups/$($Action.groupId)/assignLicense" -tenantid $TenantFilter -type POST -body $Body
                }
                'RemoveGroupLicense' {
                    $Body = @{ addLicenses = @(); removeLicenses = @($Action.skuId) } | ConvertTo-Json -Depth 5 -Compress
                    $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/groups/$($Action.groupId)/assignLicense" -tenantid $TenantFilter -type POST -body $Body
                }
                'AssignAppToGroup' {
                    $Body = @{ principalId = $Action.groupId; resourceId = $Action.servicePrincipalId; appRoleId = $Action.appRoleId } | ConvertTo-Json -Compress
                    $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Action.servicePrincipalId)/appRoleAssignedTo" -tenantid $TenantFilter -type POST -body $Body
                }
                'RequireAppAssignment' {
                    $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Action.servicePrincipalId)" -tenantid $TenantFilter -type PATCH -body '{"appRoleAssignmentRequired":true}'
                }
                default { throw "Unknown action type '$($Action.type)'." }
            }
            $Message = "AI Access Policy: $($Row.control) '$($Row.item)' for $($Row.target) set to $($Row.expected)."
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Info
            [pscustomobject]@{ control = $Row.control; item = $Row.item; target = $Row.target; success = $true; message = $Message }
        } catch {
            if ($Action.type -eq 'AssignAppToGroup') { $FailedAssignments[$Action.servicePrincipalId] = $true }
            $ErrorMessage = Get-CippException -Exception $_
            $Message = "AI Access Policy: could not set $($Row.control) '$($Row.item)' for $($Row.target): $($ErrorMessage.NormalizedError)"
            Write-LogMessage -headers $Headers -API $APIName -tenant $TenantFilter -message $Message -sev Error -LogData $ErrorMessage
            [pscustomobject]@{ control = $Row.control; item = $Row.item; target = $Row.target; success = $false; message = $Message }
        }
    }
}
