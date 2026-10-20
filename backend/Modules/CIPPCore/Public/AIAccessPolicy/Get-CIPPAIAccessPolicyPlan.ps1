function Get-CIPPAIAccessPolicyPlan {
    <#
    .SYNOPSIS
        Builds the AI Access Policy plan for one tenant: what complies, and what CIPP would change

    .PARAMETER TenantFilter
        The tenant to evaluate

    .PARAMETER TemplateId
        AI Access Policy template GUIDs that apply to the tenant

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [Parameter(Mandatory = $true)]
        [string[]]$TemplateId
    )

    $Policies = @(Get-CIPPAIAccessPolicyTemplate -Id $TemplateId)
    if ($Policies.Count -eq 0) { throw 'None of the selected AI Access Policy templates could be loaded.' }

    $Merged = Merge-CIPPAIAccessPolicy -Policies $Policies
    $State = Get-CIPPAIAccessPolicyState -TenantFilter $TenantFilter -Merged $Merged
    $Plan = ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State -ManualCatalog (Get-CIPPAIAccessManualControl)

    [pscustomobject]@{
        Tenant   = $TenantFilter
        Policies = @($Merged.policies)
        Plan     = @($Plan)
    }
}
