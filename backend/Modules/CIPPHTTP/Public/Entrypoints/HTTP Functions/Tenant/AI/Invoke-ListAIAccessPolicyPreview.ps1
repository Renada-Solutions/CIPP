function Invoke-ListAIAccessPolicyPreview {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.Read
    .DESCRIPTION
        Previews AI Access Policies against one tenant without changing anything: each requirement
        with its current state, whether it complies, and the change CIPP would make. Pass templateIds
        (comma separated) to preview specific templates; otherwise the templates the AIAccessPolicy
        standard applies to the tenant are used.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $Requested = $Request.Query.templateIds ?? $Request.Body.templateIds

    try {
        if (-not $TenantFilter -or $TenantFilter -eq 'AllTenants') { throw 'Select a single tenant to preview.' }

        $TemplateIds = @(@($Requested) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $Source = 'selected'
        if ($TemplateIds.Count -eq 0) {
            $TemplateIds = @(Get-CIPPAIAccessAppliedTemplateId -TenantFilter $TenantFilter)
            $Source = 'applied'
        }

        $Body = if ($TemplateIds.Count -eq 0) {
            [pscustomobject]@{ source = $Source; policies = @(); plan = @(); message = 'No AI Access Policy is applied to this tenant. Select a policy to preview it.' }
        } else {
            $Result = Get-CIPPAIAccessPolicyPlan -TenantFilter $TenantFilter -TemplateId $TemplateIds
            [pscustomobject]@{
                source   = $Source
                policies = $Result.Policies
                plan     = @($Result.Plan | ForEach-Object {
                        $_ | Add-Member -NotePropertyName 'change' -NotePropertyValue $(if ($_.action) { $_.action.type } else { $null }) -Force -PassThru
                    })
            }
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $TenantFilter -message "Could not preview AI Access Policy: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $Body = @{ Results = "Could not preview AI Access Policy: $($ErrorMessage.NormalizedError)" }
        $StatusCode = [HttpStatusCode]::BadRequest
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
