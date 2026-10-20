function Get-CIPPAIAccessAppliedTemplateId {
    <#
    .SYNOPSIS
        Returns the AI Access Policy template GUIDs the standards engine applies to a tenant

    .PARAMETER TenantFilter
        The tenant to check

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter
    )

    $Applied = @(Get-CIPPStandards -Tenant $TenantFilter | Where-Object { $_.Standard -eq 'AIAccessPolicy' })
    @($Applied | ForEach-Object {
            foreach ($Item in @($_.Settings.aiAccessPolicyTemplate)) {
                if ($Item -is [string]) { $Item } elseif ($Item.value) { $Item.value }
            }
        } | Where-Object { $_ } | Sort-Object -Unique)
}
