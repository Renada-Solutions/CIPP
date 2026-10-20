function Get-CIPPAIAccessPolicyState {
    <#
    .SYNOPSIS
        Reads the live tenant state that merged AI Access Policy requirements are compared against

    .DESCRIPTION
        Only fetches what the requirements need: the consent policy when consent is managed, subscribed
        SKUs when licences are managed, each named group, each approved app's service principal and its
        assignments, and the tenant's manual checklist confirmations. Calls Graph live (not the reporting
        cache) so a preview shows the state the changes would be made against.

    .PARAMETER TenantFilter
        The tenant to read

    .PARAMETER Merged
        Output of Merge-CIPPAIAccessPolicy

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [Parameter(Mandatory = $true)]
        $Merged
    )

    $State = @{
        permissionGrantPoliciesAssigned = @()
        conflictingConsentStandard      = $false
        subscribedSkus                  = @()
        groups                          = @{}
        servicePrincipals               = @{}
        appAssignments                  = @{}
        checklist                       = @{}
    }

    if ($Merged.userConsent.value -eq 'block') {
        $Policy = New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -tenantid $TenantFilter -noPagination $true
        $State.permissionGrantPoliciesAssigned = @($Policy.defaultUserRolePermissions.permissionGrantPoliciesAssigned)
        try {
            $State.conflictingConsentStandard = [bool](Get-CIPPStandards -Tenant $TenantFilter | Where-Object { $_.Standard -eq 'OauthConsentLowSec' })
        } catch {
            Write-Information "Could not read applied standards for $TenantFilter`: $($_.Exception.Message)"
        }
    }

    if (@($Merged.licences).Count -gt 0) {
        $State.subscribedSkus = @(New-GraphGetRequest -uri 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuId,skuPartNumber,prepaidUnits,consumedUnits' -tenantid $TenantFilter)
    }

    $GroupNames = @(@($Merged.licences | ForEach-Object { $_.groupName }) + @($Merged.approvedAiApps | ForEach-Object { $_.groupNames })) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($GroupName in $GroupNames) {
        $Escaped = $GroupName -replace "'", "''"
        $Uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$([uri]::EscapeDataString($Escaped))'&`$select=id,displayName,assignedLicenses"
        $State.groups[$GroupName.ToLower()] = @(New-GraphGetRequest -uri $Uri -tenantid $TenantFilter)
    }

    foreach ($App in @($Merged.approvedAiApps)) {
        $Sp = @(New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($App.appId)'&`$select=id,appId,displayName,appRoleAssignmentRequired,appRoles" -tenantid $TenantFilter) | Select-Object -First 1
        if ($Sp) {
            $State.servicePrincipals[$App.appId] = $Sp
            $State.appAssignments[$Sp.id] = @(New-GraphGetRequest -uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Sp.id)/appRoleAssignedTo?`$select=principalId,principalType,appRoleId" -tenantid $TenantFilter)
        }
    }

    if (@($Merged.manualControls).Count -gt 0) {
        $Table = Get-CIPPTable -tablename 'AIAccessChecklist'
        $Escaped = $TenantFilter -replace "'", "''"
        foreach ($Row in @(Get-CIPPAzDataTableEntity @Table -Filter "PartitionKey eq '$Escaped'")) {
            $State.checklist[$Row.RowKey] = $Row
        }
    }

    return $State
}
