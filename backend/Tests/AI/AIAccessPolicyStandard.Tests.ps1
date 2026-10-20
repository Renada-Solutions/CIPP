# Pester tests for the AIAccessPolicy standard and the preview endpoint
# Verifies remediation runs only when enabled, the tenant is re-checked afterwards, and not applicable
# rows are never reported as failures

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    foreach ($Name in @('Invoke-CIPPStandardAIAccessPolicy', 'Invoke-ListAIAccessPolicyPreview')) {
        $Path = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter "$Name.ps1" -File | Select-Object -First 1 -ExpandProperty FullName
        if (-not $Path) { throw "Could not locate $Name.ps1 under Modules/" }
        . $Path
    }

    ([PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')).GetMethod('Add').Invoke(
        $null, @('HttpStatusCode', [System.Net.HttpStatusCode]))
    class HttpResponseContext {
        [int]$StatusCode
        [object]$Body
    }

    function Get-CIPPAIAccessPolicyPlan { param($TenantFilter, $TemplateId) }
    function Invoke-CIPPAIAccessPolicyAction { param($TenantFilter, $Plan, $APIName) }
    function Get-CIPPAIAccessAppliedTemplateId { param($TenantFilter) }
    function Write-LogMessage { param($headers, $API, $tenant, $message, $sev, $LogData) }
    function Write-StandardsAlert { param($message, $object, $tenant, $standardName, $standardId) }
    function Set-CIPPStandardsCompareField { param($FieldName, $CurrentValue, $ExpectedValue, $TenantFilter) }
    function Add-CIPPBPAField { param($FieldName, $FieldValue, $StoreAs, $Tenant) }
    function Get-CippException { param($Exception) @{ NormalizedError = "$Exception" } }

    function New-Row ($Status, $Action) {
        [pscustomobject]@{ control = 'CopilotLicence'; item = 'Microsoft_365_Copilot'; target = 'Finance users'; expected = 'Assigned to group'; current = 'Not assigned to group'; status = $Status; detail = 'x'; action = $Action }
    }
}

Describe 'Invoke-CIPPStandardAIAccessPolicy' {
    BeforeEach {
        $script:PlanCalls = 0
        Mock Get-CIPPAIAccessPolicyPlan {
            $script:PlanCalls++
            if ($script:PlanCalls -eq 1) {
                [pscustomobject]@{ Plan = @((New-Row 'NonCompliant' ([pscustomobject]@{ type = 'AssignGroupLicense' })), (New-Row 'NotApplicable' $null)) }
            } else {
                [pscustomobject]@{ Plan = @((New-Row 'Compliant' $null), (New-Row 'NotApplicable' $null)) }
            }
        }
        Mock Invoke-CIPPAIAccessPolicyAction {}
        Mock Set-CIPPStandardsCompareField {}
        Mock Write-StandardsAlert {}
    }

    It 'does not change the tenant without remediate, and reports only real failures' {
        Invoke-CIPPStandardAIAccessPolicy -Tenant 'contoso.onmicrosoft.com' -Settings ([pscustomobject]@{ aiAccessPolicyTemplate = @([pscustomobject]@{ value = 'tpl-1' }); report = $true; alert = $true })
        Should -Invoke Invoke-CIPPAIAccessPolicyAction -Times 0 -Exactly
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -Exactly -ParameterFilter { @($CurrentValue.NonCompliant).Count -eq 1 }
        Should -Invoke Write-StandardsAlert -Times 1 -Exactly
    }

    It 'remediates, then re-checks the tenant before reporting' {
        Invoke-CIPPStandardAIAccessPolicy -Tenant 'contoso.onmicrosoft.com' -Settings ([pscustomobject]@{ aiAccessPolicyTemplate = @('tpl-1'); remediate = $true; report = $true })
        Should -Invoke Invoke-CIPPAIAccessPolicyAction -Times 1 -Exactly
        Should -Invoke Get-CIPPAIAccessPolicyPlan -Times 2 -Exactly
        Should -Invoke Set-CIPPStandardsCompareField -Times 1 -Exactly -ParameterFilter { @($CurrentValue.NonCompliant).Count -eq 0 }
    }

    It 'does nothing when no template is selected' {
        Invoke-CIPPStandardAIAccessPolicy -Tenant 'contoso.onmicrosoft.com' -Settings ([pscustomobject]@{ remediate = $true })
        Should -Invoke Get-CIPPAIAccessPolicyPlan -Times 0 -Exactly
    }
}

Describe 'Invoke-ListAIAccessPolicyPreview' {
    It 'refuses All Tenants' {
        $Response = Invoke-ListAIAccessPolicyPreview -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'AllTenants' }; Headers = @{}; Params = @{} })
        $Response.StatusCode | Should -Be 400
    }

    It 'explains when no policy is applied or selected' {
        Mock Get-CIPPAIAccessAppliedTemplateId { @() }
        $Response = Invoke-ListAIAccessPolicyPreview -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'contoso.onmicrosoft.com' }; Headers = @{}; Params = @{} })
        $Response.StatusCode | Should -Be 200
        $Response.Body.message | Should -BeLike 'No AI Access Policy is applied*'
    }

    It 'previews the selected templates and names the change type' {
        Mock Get-CIPPAIAccessPolicyPlan { [pscustomobject]@{ Policies = @('Finance'); Plan = @(New-Row 'NonCompliant' ([pscustomobject]@{ type = 'AssignGroupLicense' })) } }
        $Response = Invoke-ListAIAccessPolicyPreview -Request ([pscustomobject]@{ Query = @{ tenantFilter = 'contoso.onmicrosoft.com'; templateIds = 'tpl-1, tpl-2' }; Headers = @{}; Params = @{} })
        Should -Invoke Get-CIPPAIAccessPolicyPlan -Times 1 -Exactly -ParameterFilter { ($TemplateId -join ',') -eq 'tpl-1,tpl-2' }
        $Response.Body.source | Should -Be 'selected'
        $Response.Body.plan[0].change | Should -Be 'AssignGroupLicense'
    }
}
