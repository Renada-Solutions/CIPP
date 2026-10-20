function Invoke-ListAIAccessPolicyTemplates {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.AI.Read
    .DESCRIPTION
        Lists AI Access Policy templates: per-group rules for Copilot licences, user consent to apps,
        approved enterprise AI apps and manual controls, deployed to tenants through the AIAccessPolicy
        standard. Pass ID to return a single template.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $Id = $Request.Query.ID ?? $Request.Query.id
    $Templates = if ($Id) { @(Get-CIPPAIAccessPolicyTemplate -Id $Id) } else { @(Get-CIPPAIAccessPolicyTemplate) }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @($Templates | Sort-Object -Property name)
        })
}
