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

    # A selected policy that was deleted or no longer loads must not leave the tenant looking compliant
    # against the policies that remain
    $Loaded = @($Policies | ForEach-Object { "$($_.GUID)".ToLower() })
    $Missing = @($TemplateId | Where-Object { $_ -and "$_".ToLower() -notin $Loaded } | Select-Object -Unique)
    $MissingRows = @($Missing | ForEach-Object {
            [pscustomobject]@{ control = 'Policy'; item = "AI Access Policy $_"; target = 'All users'; expected = 'Loaded'; current = 'Missing or invalid'; status = 'Blocked'; detail = 'This selected policy was deleted or can no longer be read. Remove it from the standard or recreate it.'; action = $null; from = @() }
        })

    if ($Policies.Count -eq 0) {
        return [pscustomobject]@{ Tenant = $TenantFilter; Policies = @(); Plan = $MissingRows }
    }

    $Merged = Merge-CIPPAIAccessPolicy -Policies $Policies
    $State = Get-CIPPAIAccessPolicyState -TenantFilter $TenantFilter -Merged $Merged
    $Plan = ConvertTo-CIPPAIAccessPolicyPlan -Merged $Merged -State $State -ManualCatalog (Get-CIPPAIAccessManualControl)

    [pscustomobject]@{
        Tenant   = $TenantFilter
        Policies = @($Merged.policies)
        Plan     = @($MissingRows) + @($Plan)
    }
}
