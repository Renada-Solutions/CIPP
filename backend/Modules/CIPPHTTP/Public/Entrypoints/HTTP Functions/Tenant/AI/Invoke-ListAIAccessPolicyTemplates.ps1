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

    # Flat summary columns for the policy list; the nested policy stays as-is for the edit form
    foreach ($Template in $Templates) {
        $Summary = [ordered]@{
            appliesTo      = if ($Template.target.type -eq 'group') { $Template.target.groupName } else { 'All users' }
            licenceSummary = switch ($Template.copilotLicence.mode) { 'grant' { 'Grant' } 'deny' { 'Deny' } default { 'Not managed' } }
            userConsentSet = if ($Template.userConsent -eq 'block') { 'Blocked' } else { 'Not managed' }
            approvedApps   = @($Template.approvedAiApps).Count
            manualCount    = @($Template.manualControls).Count
        }
        foreach ($Key in $Summary.Keys) { $Template | Add-Member -NotePropertyName $Key -NotePropertyValue $Summary[$Key] -Force }
    }

    return ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @($Templates | Sort-Object -Property name)
        })
}
