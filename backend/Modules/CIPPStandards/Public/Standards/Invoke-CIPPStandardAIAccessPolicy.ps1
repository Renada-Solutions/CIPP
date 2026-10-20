function Invoke-CIPPStandardAIAccessPolicy {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) AIAccessPolicy
    .SYNOPSIS
        (Label) AI Access Policy
    .DESCRIPTION
        (Helptext) Applies AI Access Policy templates: Copilot licences by group, blocking user consent to apps, and restricting approved enterprise AI apps to their groups. Select every policy that applies to the tenant, including the baseline; the stricter setting wins.
        (DocsDescription) Applies one or more AI Access Policy templates to the tenant. Where policies overlap, the stricter setting wins. Copilot licences are assigned to or removed from groups through group-based licensing, user consent to apps is blocked (the CIPP consent policy from the OauthConsent standard counts as compliant), and approved enterprise AI apps such as ChatGPT Enterprise or Claude Enterprise are assigned to the policy groups before assignment is required. Controls with no API are reported from the AI Access checklist and are never changed automatically. Use the AI Access Policy preview to see every change before enabling remediation.
    .NOTES
        CAT
            Templates
        DISABLEDFEATURES
            {"report":false,"warn":false,"remediate":false}
        IMPACT
            High Impact
        ADDEDDATE
            2026-10-20
        EXECUTIVETEXT
            Applies the organisation's rules for who can use which AI: who receives Copilot licences, whether staff can connect AI apps to company data themselves, and which approved enterprise AI apps each team can sign in to. Every change can be previewed first, and controls that must be set by hand are tracked with who confirmed them and when.
        ADDEDCOMPONENT
            {"type":"autoComplete","multiple":true,"creatable":false,"name":"aiAccessPolicyTemplate","label":"Select AI Access Policies","api":{"url":"/api/ListAIAccessPolicyTemplates","labelField":"name","valueField":"GUID","queryKey":"ListAIAccessPolicyTemplates"}}
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards
    #>
    param($Tenant, $Settings)

    $TemplateIds = @(@($Settings.aiAccessPolicyTemplate ?? $Settings.TemplateList) | ForEach-Object {
            if ($_ -is [string]) { $_ } elseif ($_.value) { $_.value } else { $null }
        } | Where-Object { $_ })

    if ($TemplateIds.Count -eq 0) {
        Write-LogMessage -API 'Standards' -tenant $Tenant -message 'AI Access Policy: no policy templates selected.' -sev Error
        return
    }

    try {
        $Result = Get-CIPPAIAccessPolicyPlan -TenantFilter $Tenant -TemplateId $TemplateIds
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "AI Access Policy: could not evaluate the tenant. $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        return
    }
    $Plan = @($Result.Plan)

    if ($Settings.remediate -eq $true -and @($Plan | Where-Object { $_.action -and $_.status -eq 'NonCompliant' }).Count -gt 0) {
        $null = Invoke-CIPPAIAccessPolicyAction -TenantFilter $Tenant -Plan $Plan -APIName 'Standards'
        try {
            $Plan = @((Get-CIPPAIAccessPolicyPlan -TenantFilter $Tenant -TemplateId $TemplateIds).Plan)
        } catch {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "AI Access Policy: could not re-check the tenant after changes. $($_.Exception.Message)" -sev Warning
        }
    }

    # Not applicable rows (for example an approved app the tenant does not use) are not failures
    $NonCompliant = @($Plan | Where-Object { $_.status -in @('NonCompliant', 'Blocked') } | ForEach-Object {
            [pscustomobject]@{ control = $_.control; item = $_.item; target = $_.target; expected = $_.expected; current = $_.current; status = $_.status; detail = $_.detail }
        })

    if ($Settings.alert -eq $true -and $NonCompliant.Count -gt 0) {
        $Summary = ($NonCompliant | ForEach-Object { "$($_.item) for $($_.target): $($_.current)" }) -join '; '
        Write-StandardsAlert -message "AI Access Policy not met: $Summary" -object @{ NonCompliant = $NonCompliant } -tenant $Tenant -standardName 'AIAccessPolicy' -standardId $Settings.standardId
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "AI Access Policy not met: $Summary" -sev Info
    }

    if ($Settings.report -eq $true) {
        Set-CIPPStandardsCompareField -FieldName 'standards.AIAccessPolicy' -CurrentValue @{ NonCompliant = $NonCompliant } -ExpectedValue @{ NonCompliant = @() } -TenantFilter $Tenant
        Add-CIPPBPAField -FieldName 'AIAccessPolicy' -FieldValue ($NonCompliant.Count -eq 0) -StoreAs bool -Tenant $Tenant
    }
}
