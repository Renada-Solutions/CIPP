#Requires -Version 7.2
<#
.SYNOPSIS
    Tests which AI governance APIs CIPP can reach in a customer tenant through GDAP.

.DESCRIPTION
    Signs a partner user in to a CUSTOMER tenant with the device code flow (the same delegated,
    GDAP-backed access CIPP uses), then calls every Microsoft API the AI Access Policy design relies
    on and reports, per call, whether it worked and why not: GDAP role missing, app not consented,
    tenant not licensed, or another error.

    Read-only by default. Write tests are opt-in and are no-op writes: each one reads the current
    value and writes the same value back, which proves the permission without changing the tenant.
    The optional DLP test creates a DISABLED test policy and deletes it again.

    Calls made:
      Graph (delegated)   Copilot packages, policy settings, limited mode, personalisation, cost
                          management, Agent ID identities and sponsors, risky agents, Global Secure
                          Access filtering, consent policy, Intune configuration policies
      Graph (app-only)    the same reads with the CIPP app's own permissions, if -ClientSecret given
      Security & Compliance PowerShell (REST, as CIPP calls it)   Get-DlpCompliancePolicy
      Power Platform API  governance/ruleBasedPolicies (advanced connector policies)

    Tokens are never printed or written to disk.

.PARAMETER CustomerTenantId
    The customer tenant ID (GUID) to test against.

.PARAMETER ClientId
    Application (client) ID of the CIPP-SAM app. Used for delegated sign-in and app-only tokens.

.PARAMETER ClientSecret
    Optional CIPP-SAM client secret. When given, app-only variants of the reads are also tested.

.PARAMETER PowerPlatformClientId
    Optional client ID to use for the Power Platform API. Defaults to -ClientId. CIPP-SAM does not
    currently request Power Platform API permissions, so with the default a consent error is expected
    and is reported as such.

.PARAMETER IncludeWriteTests
    Also run no-op writes (read current value, write the same value back).

.PARAMETER TestPackageId
    Copilot package ID to use for the package availability no-op write. Skipped if not given.

.PARAMETER TestAgentIdentityId
    Agent identity object ID to use for the enable/disable no-op write. Skipped if not given.

.PARAMETER IncludeDlpCreateTest
    Create a disabled DLP policy on the Microsoft 365 Copilot location, then delete it. Proves the
    CopilotExperiences parameters work over CIPP's REST path.

.PARAMETER OutputPath
    Folder for the results (JSON and CSV). Defaults to the current folder.

.EXAMPLE
    ./Test-CIPPAIGdapAccess.ps1 -CustomerTenantId 00000000-0000-0000-0000-000000000000 -ClientId <CIPP-SAM app id>
    Read-only run with delegated (GDAP) access.

.EXAMPLE
    ./Test-CIPPAIGdapAccess.ps1 -CustomerTenantId <tenant id> -ClientId <app id> -ClientSecret (Read-Host -AsSecureString) -IncludeWriteTests -TestPackageId <id>
    Adds app-only reads and no-op writes.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$CustomerTenantId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId,

    [securestring]$ClientSecret,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$PowerPlatformClientId,

    [switch]$IncludeWriteTests,
    [string]$TestPackageId,
    [string]$TestAgentIdentityId,
    [switch]$IncludeDlpCreateTest,
    [string]$OutputPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$LoginBase = "https://login.microsoftonline.com/$CustomerTenantId/oauth2/v2.0"
$Graph = 'https://graph.microsoft.com'
$ComplianceResource = 'https://ps.compliance.protection.outlook.com'
$PowerPlatform = 'https://api.powerplatform.com'
$Results = [System.Collections.Generic.List[object]]::new()

#region Tokens
function Invoke-TokenRequest ([hashtable]$Body) {
    $Response = Invoke-WebRequest -Method Post -Uri "$LoginBase/token" -Body $Body -SkipHttpErrorCheck
    $Json = $Response.Content | ConvertFrom-Json
    if ($Response.StatusCode -ne 200) {
        return [pscustomobject]@{ Error = $Json.error; Description = ($Json.error_description -split "`r?`n")[0] }
    }
    return $Json
}

function Get-DeviceCodeToken ([string]$AppId, [string]$Scope) {
    $Code = Invoke-RestMethod -Method Post -Uri "$LoginBase/devicecode" -Body @{ client_id = $AppId; scope = "$Scope offline_access" }
    Write-Host ''
    Write-Host $Code.message -ForegroundColor Yellow
    Write-Host 'Sign in with the partner account whose GDAP access you want to test.' -ForegroundColor Yellow
    $Deadline = (Get-Date).AddSeconds([int]$Code.expires_in)
    $Interval = [int]$Code.interval
    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds $Interval
        $Token = Invoke-TokenRequest @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $AppId; device_code = $Code.device_code }
        if ($Token.access_token) { return $Token }
        switch ($Token.Error) {
            'authorization_pending' { continue }
            'slow_down' { $Interval += 5; continue }
            default { throw "Sign-in failed: $($Token.Error) $($Token.Description)" }
        }
    }
    throw 'Sign-in timed out.'
}

# Redeems the refresh token for another resource. Returns an object with Error when consent or
# access is missing, so the caller can report it instead of failing the run.
function Get-RefreshedToken ([string]$AppId, [string]$RefreshToken, [string]$Scope) {
    Invoke-TokenRequest @{ grant_type = 'refresh_token'; client_id = $AppId; refresh_token = $RefreshToken; scope = "$Scope offline_access" }
}

function Get-AppOnlyToken ([string]$Scope) {
    $Secret = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
    Invoke-TokenRequest @{ grant_type = 'client_credentials'; client_id = $ClientId; client_secret = $Secret; scope = $Scope }
}

function Get-TokenClaims ([string]$AccessToken) {
    $Payload = $AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($Payload.Length % 4) { 2 { $Payload += '==' } 3 { $Payload += '=' } }
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload)) | ConvertFrom-Json
}
#endregion

#region Test runner
function ConvertTo-Outcome ([int]$Status, [string]$Content) {
    $ErrorCode = $null; $Message = $null
    try {
        $Json = $Content | ConvertFrom-Json -ErrorAction Stop
        $ErrorCode = $Json.error.code ?? $Json.error ?? $Json.code
        $Message = $Json.error.message ?? $Json.message ?? $Json.error_description
    } catch {
        $Message = $Content
    }
    $Text = "$ErrorCode $Message"
    $Outcome = if ($Status -ge 200 -and $Status -lt 300) { 'Pass' }
    elseif ($Text -match 'licen[cs]e|not licensed|subscription|SKU') { 'NotLicensed' }
    elseif ($Status -eq 401) { 'Unauthorised' }
    elseif ($Status -eq 403) { 'Forbidden (GDAP role or permission missing)' }
    elseif ($Status -eq 404) { 'NotFound' }
    else { 'Error' }
    [pscustomobject]@{ Outcome = $Outcome; ErrorCode = $ErrorCode; Message = if ($Message) { ([string]$Message).Substring(0, [Math]::Min(300, ([string]$Message).Length)) } }
}

function Add-Result ([string]$Claim, [string]$Name, [string]$Auth, [string]$Method, [string]$Uri, $Status, $Outcome, $ErrorCode, $Message) {
    $Results.Add([pscustomobject]@{
            Claim = $Claim; Test = $Name; Auth = $Auth; Method = $Method; Uri = $Uri
            Status = $Status; Outcome = $Outcome; ErrorCode = $ErrorCode; Message = $Message
        })
    $Colour = if ($Outcome -eq 'Pass') { 'Green' } elseif ($Outcome -like 'Skipped*') { 'DarkGray' } else { 'Red' }
    Write-Host ("  [{0,-11}] {1,-9} {2}" -f ($Outcome -split ' ')[0], $Auth, $Name) -ForegroundColor $Colour
}

# Runs one HTTP call and records the result. Returns the parsed body on success, else $null.
function Invoke-Test {
    param(
        [string]$Claim, [string]$Name, [string]$Auth, $Token,
        [string]$Method = 'GET', [string]$Uri, $Body, [hashtable]$ExtraHeaders = @{}
    )
    if (-not $Token -or -not $Token.access_token) {
        $Reason = if ($Token.Error) { "No token: $($Token.Error) $($Token.Description)" } else { 'No token' }
        $Outcome = if ($Token.Description -match 'AADSTS65001|consent') { 'NoConsent (app not consented for this API)' } else { 'NoToken' }
        Add-Result $Claim $Name $Auth $Method $Uri $null $Outcome $Token.Error $Reason
        return $null
    }
    $Headers = @{ Authorization = "Bearer $($Token.access_token)" } + $ExtraHeaders
    $Params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) { $Params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $Params.ContentType = 'application/json' }
    try {
        $Response = Invoke-WebRequest @Params
    } catch {
        Add-Result $Claim $Name $Auth $Method $Uri $null 'Error' 'RequestFailed' $_.Exception.Message
        return $null
    }
    $Result = ConvertTo-Outcome -Status $Response.StatusCode -Content $Response.Content
    Add-Result $Claim $Name $Auth $Method $Uri $Response.StatusCode $Result.Outcome $Result.ErrorCode $Result.Message
    if ($Result.Outcome -eq 'Pass' -and $Response.Content) { return ($Response.Content | ConvertFrom-Json) }
    return $null
}

function Skip-Test ([string]$Claim, [string]$Name, [string]$Reason) {
    Add-Result $Claim $Name '-' '-' '-' $null "Skipped ($Reason)" $null $Reason
}
#endregion

#region Sign in
Write-Host "Testing customer tenant $CustomerTenantId" -ForegroundColor Cyan
$GraphToken = Get-DeviceCodeToken -AppId $ClientId -Scope "$Graph/.default"
$Claims = Get-TokenClaims $GraphToken.access_token
Write-Host "Signed in as $($Claims.upn ?? $Claims.unique_name) (home tenant $($Claims.idp ?? $Claims.iss))" -ForegroundColor Cyan

# GDAP roles appear as role template IDs in the token's wids claim; name them via the tenant.
$RoleNames = @{}
$RoleDefs = Invoke-RestMethod -Uri "$Graph/v1.0/roleManagement/directory/roleDefinitions?`$select=templateId,displayName" -Headers @{ Authorization = "Bearer $($GraphToken.access_token)" } -SkipHttpErrorCheck
foreach ($Role in @($RoleDefs.value)) { $RoleNames[[string]$Role.templateId] = $Role.displayName }
$ActiveRoles = @($Claims.wids | ForEach-Object { $RoleNames[[string]$_] ?? $_ })
Write-Host "Roles in token (GDAP): $($ActiveRoles -join ', ')" -ForegroundColor Cyan

$ComplianceToken = Get-RefreshedToken -AppId $ClientId -RefreshToken $GraphToken.refresh_token -Scope "$ComplianceResource/.default"
$PpClient = if ($PowerPlatformClientId) { $PowerPlatformClientId } else { $ClientId }
$PowerPlatformToken = if ($PpClient -eq $ClientId) {
    Get-RefreshedToken -AppId $ClientId -RefreshToken $GraphToken.refresh_token -Scope "$PowerPlatform/.default"
} else {
    Get-DeviceCodeToken -AppId $PpClient -Scope "$PowerPlatform/.default"
}
$AppToken = if ($ClientSecret) { Get-AppOnlyToken -Scope "$Graph/.default" }
#endregion

#region Graph reads (delegated and, if available, app-only)
$GraphReads = @(
    @{ Claim = 'C3'; Name = 'List Copilot packages'; Uri = "$Graph/beta/copilot/admin/catalog/packages" }
    @{ Claim = 'C3'; Name = 'List pending agent requests'; Uri = "$Graph/beta/copilot/admin/catalog/packages?`$filter=requestStatus eq 'pending'" }
    @{ Claim = 'C14'; Name = 'Read Copilot policy setting (web search)'; Uri = "$Graph/beta/copilot/admin/policySettings/microsoft.copilot.allowwebsearch" }
    @{ Claim = 'C16'; Name = 'Read Teams limited mode (v1.0)'; Uri = "$Graph/v1.0/copilot/admin/settings/limitedMode" }
    @{ Claim = 'Matrix'; Name = 'Read memory/personalisation'; Uri = "$Graph/beta/copilot/settings/people/enhancedpersonalization" }
    @{ Claim = 'Matrix'; Name = 'List Copilot spending policies'; Uri = "$Graph/beta/copilot/costManagement/spendingPolicies" }
    @{ Claim = 'PR1'; Name = 'List agent identities'; Uri = "$Graph/v1.0/servicePrincipals/microsoft.graph.agentIdentity" }
    @{ Claim = 'PR1'; Name = 'List agent identity blueprints'; Uri = "$Graph/v1.0/applications/microsoft.graph.agentIdentityBlueprint" }
    @{ Claim = 'PR1'; Name = 'List risky agents'; Uri = "$Graph/beta/identityProtection/riskyAgents" }
    @{ Claim = 'Matrix'; Name = 'List GSA filtering policies'; Uri = "$Graph/beta/networkAccess/filteringPolicies" }
    @{ Claim = 'C17'; Name = 'Read consent policy'; Uri = "$Graph/v1.0/policies/authorizationPolicy" }
    @{ Claim = 'C4'; Name = 'List Intune configuration policies'; Uri = "$Graph/beta/deviceManagement/configurationPolicies?`$top=1" }
)

Write-Host "`nGraph, delegated (GDAP)" -ForegroundColor Cyan
$Delegated = @{}
foreach ($Test in $GraphReads) {
    $Delegated[$Test.Name] = Invoke-Test -Claim $Test.Claim -Name $Test.Name -Auth 'Delegated' -Token $GraphToken -Uri $Test.Uri
}

# Sponsors are documented as application-only; test both to confirm.
$FirstAgent = @($Delegated['List agent identities'].value) | Select-Object -First 1
if ($FirstAgent) {
    $SponsorsUri = "$Graph/v1.0/servicePrincipals/$($FirstAgent.id)/microsoft.graph.agentIdentity/sponsors"
    $null = Invoke-Test -Claim 'PR1' -Name 'List agent sponsors (documented app-only)' -Auth 'Delegated' -Token $GraphToken -Uri $SponsorsUri
} else {
    Skip-Test 'PR1' 'List agent sponsors' 'no agent identities in tenant'
}

if ($AppToken) {
    Write-Host "`nGraph, app-only (CIPP-SAM permissions)" -ForegroundColor Cyan
    foreach ($Test in $GraphReads) {
        $null = Invoke-Test -Claim $Test.Claim -Name $Test.Name -Auth 'App' -Token $AppToken -Uri $Test.Uri
    }
    if ($FirstAgent) { $null = Invoke-Test -Claim 'PR1' -Name 'List agent sponsors' -Auth 'App' -Token $AppToken -Uri $SponsorsUri }
} else {
    Skip-Test 'All' 'App-only reads' 'no -ClientSecret'
}
#endregion

#region Security & Compliance PowerShell over REST (as CIPP's New-ExoRequest -Compliance does)
Write-Host "`nSecurity & Compliance (REST InvokeCommand)" -ForegroundColor Cyan
$Org = Invoke-RestMethod -Uri "$Graph/v1.0/organization?`$select=verifiedDomains" -Headers @{ Authorization = "Bearer $($GraphToken.access_token)" } -SkipHttpErrorCheck
$InitialDomain = (@($Org.value.verifiedDomains) | Where-Object isInitial | Select-Object -First 1).name
$ComplianceHost = $null
if ($ComplianceToken.access_token -and $InitialDomain) {
    $Anchor = "UPN:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$InitialDomain"
    $ComplianceHeaders = @{ Authorization = "Bearer $($ComplianceToken.access_token)"; 'X-AnchorMailbox' = $Anchor }
    $Banner = Invoke-WebRequest -Uri "$ComplianceResource/adminapi/beta/$CustomerTenantId/EXOBanner('AutogenSession')?Version=3.9.2" -Headers $ComplianceHeaders -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    $Location = @($Banner.Headers.Location) | Select-Object -First 1
    if ($Location) {
        $ComplianceHost = 'https://{0}.ps.compliance.protection.outlook.com' -f (([uri]$Location).Host -split '\.')[0]
    } else {
        Add-Result 'C6' 'Resolve regional compliance endpoint' 'Delegated' 'GET' 'EXOBanner' $Banner.StatusCode 'Error' 'NoRedirect' 'No regional redirect returned; check the GDAP role includes Compliance Administrator.'
    }
}

function Invoke-ComplianceCmdlet ([string]$Claim, [string]$Name, [string]$Cmdlet, [hashtable]$Parameters = @{}) {
    if (-not $ComplianceHost) {
        if (-not $ComplianceToken.access_token) { return Invoke-Test -Claim $Claim -Name $Name -Auth 'Delegated' -Token $ComplianceToken -Uri 'InvokeCommand' }
        Skip-Test $Claim $Name 'compliance endpoint not resolved'
        return $null
    }
    $Body = @{ CmdletInput = @{ CmdletName = $Cmdlet; Parameters = $Parameters } }
    Invoke-Test -Claim $Claim -Name $Name -Auth 'Delegated' -Token $ComplianceToken -Method 'POST' -Uri "$ComplianceHost/adminapi/beta/$CustomerTenantId/InvokeCommand" -Body $Body -ExtraHeaders @{ 'X-AnchorMailbox' = $Anchor }
}

$null = Invoke-ComplianceCmdlet -Claim 'C6' -Name 'Get-DlpCompliancePolicy' -Cmdlet 'Get-DlpCompliancePolicy'
#endregion

#region Power Platform API
Write-Host "`nPower Platform API (client $PpClient)" -ForegroundColor Cyan
$PpSp = Invoke-RestMethod -Uri "$Graph/v1.0/servicePrincipals?`$filter=appId eq '8578e004-a5c6-46e7-913e-12f58912df43'&`$select=id" -Headers @{ Authorization = "Bearer $($GraphToken.access_token)" } -SkipHttpErrorCheck
if (-not @($PpSp.value).Count) {
    Write-Host '  Note: the Power Platform API service principal does not exist in this tenant; Microsoft documents creating it before use.' -ForegroundColor DarkYellow
}
$null = Invoke-Test -Claim 'C9' -Name 'List advanced connector policies' -Auth 'Delegated' -Token $PowerPlatformToken -Uri "$PowerPlatform/governance/ruleBasedPolicies?api-version=2024-10-01"
#endregion

#region No-op writes (opt-in)
if ($IncludeWriteTests) {
    Write-Host "`nNo-op writes (current value written back)" -ForegroundColor Cyan

    $Setting = $Delegated['Read Copilot policy setting (web search)']
    if ($Setting -and $PSCmdlet.ShouldProcess('Copilot policy setting allowwebsearch', 'Write current value back')) {
        $null = Invoke-Test -Claim 'C14' -Name 'Write Copilot policy setting (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/beta/copilot/admin/policySettings/microsoft.copilot.allowwebsearch" -Body @{ value = $Setting.value }
    } elseif (-not $Setting) { Skip-Test 'C14' 'Write Copilot policy setting' 'read failed' }

    $Limited = $Delegated['Read Teams limited mode (v1.0)']
    if ($Limited -and $PSCmdlet.ShouldProcess('Teams limited mode', 'Write current value back')) {
        $LimitedBody = @{ '@odata.type' = '#microsoft.graph.copilotAdminLimitedMode'; isEnabledForGroup = $Limited.isEnabledForGroup; groupId = $Limited.groupId }
        $null = Invoke-Test -Claim 'C16' -Name 'Write Teams limited mode (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/v1.0/copilot/admin/settings/limitedMode" -Body $LimitedBody
    } elseif (-not $Limited) { Skip-Test 'C16' 'Write Teams limited mode' 'read failed' }

    $Personal = $Delegated['Read memory/personalisation']
    if ($Personal -and $PSCmdlet.ShouldProcess('Enhanced personalisation', 'Write current value back')) {
        $PersonalBody = @{ isEnabledInOrganization = $Personal.isEnabledInOrganization; disabledForGroup = $Personal.disabledForGroup }
        $null = Invoke-Test -Claim 'Matrix' -Name 'Write memory/personalisation (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/beta/copilot/settings/people/enhancedpersonalization" -Body $PersonalBody
    } elseif (-not $Personal) { Skip-Test 'Matrix' 'Write memory/personalisation' 'read failed' }

    $Consent = $Delegated['Read consent policy']
    if ($Consent -and $PSCmdlet.ShouldProcess('Authorization policy consent settings', 'Write current value back')) {
        $ConsentBody = @{ defaultUserRolePermissions = @{ permissionGrantPoliciesAssigned = @($Consent.defaultUserRolePermissions.permissionGrantPoliciesAssigned) } }
        $null = Invoke-Test -Claim 'C17' -Name 'Write consent policy (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/v1.0/policies/authorizationPolicy" -Body $ConsentBody
    } elseif (-not $Consent) { Skip-Test 'C17' 'Write consent policy' 'read failed' }

    if ($TestPackageId) {
        $Package = Invoke-Test -Claim 'C3' -Name 'Read package detail' -Auth 'Delegated' -Token $GraphToken -Uri "$Graph/beta/copilot/admin/catalog/packages/$TestPackageId"
        if ($Package -and $PSCmdlet.ShouldProcess("Copilot package $TestPackageId", 'Write current availability back')) {
            $PackageBody = @{ availableTo = $Package.availableTo; allowedUsersAndGroups = @($Package.allowedUsersAndGroups) }
            $null = Invoke-Test -Claim 'C3' -Name 'Write package availability (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/beta/copilot/admin/catalog/packages/$TestPackageId" -Body $PackageBody
        }
    } else { Skip-Test 'C3' 'Write package availability' 'no -TestPackageId' }

    if ($TestAgentIdentityId) {
        $Agent = Invoke-Test -Claim 'PR1' -Name 'Read agent identity' -Auth 'Delegated' -Token $GraphToken -Uri "$Graph/v1.0/servicePrincipals/$TestAgentIdentityId/microsoft.graph.agentIdentity"
        if ($Agent -and $PSCmdlet.ShouldProcess("Agent identity $TestAgentIdentityId", 'Write current accountEnabled back')) {
            $null = Invoke-Test -Claim 'PR1' -Name 'Write agent enabled state (no-op)' -Auth 'Delegated' -Token $GraphToken -Method 'PATCH' -Uri "$Graph/v1.0/servicePrincipals/$TestAgentIdentityId/microsoft.graph.agentIdentity" -Body @{ accountEnabled = [bool]$Agent.accountEnabled }
        }
    } else { Skip-Test 'PR1' 'Write agent enabled state' 'no -TestAgentIdentityId' }
} else {
    Skip-Test 'All' 'No-op writes' 'no -IncludeWriteTests'
}
#endregion

#region DLP create and delete (opt-in)
if ($IncludeDlpCreateTest) {
    $PolicyName = "CIPP GDAP test $(Get-Date -Format 'yyyyMMddHHmmss') - safe to delete"
    if ($PSCmdlet.ShouldProcess($PolicyName, 'Create a disabled Copilot DLP policy, then delete it')) {
        $Locations = '[{"Workload":"Applications","Location":"470f2276-e011-4e9d-a6ec-20768be3a4b0","Inclusions":[{"Type":"Tenant","Identity":"All"}]}]'
        $Created = Invoke-ComplianceCmdlet -Claim 'C6' -Name 'New-DlpCompliancePolicy on Copilot location (disabled)' -Cmdlet 'New-DlpCompliancePolicy' -Parameters @{
            Name = $PolicyName; Mode = 'Disable'; Locations = $Locations; EnforcementPlanes = @('CopilotExperiences')
        }
        if ($Created) {
            $null = Invoke-ComplianceCmdlet -Claim 'C6' -Name 'Remove-DlpCompliancePolicy (clean up)' -Cmdlet 'Remove-DlpCompliancePolicy' -Parameters @{ Identity = $PolicyName; Confirm = $false }
        }
    }
} else {
    Skip-Test 'C6' 'Copilot DLP policy create' 'no -IncludeDlpCreateTest'
}
#endregion

#region Report
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Report = [pscustomobject]@{
    tenantId    = $CustomerTenantId
    signedInAs  = $Claims.upn ?? $Claims.unique_name
    gdapRoles   = $ActiveRoles
    runAt       = (Get-Date).ToUniversalTime().ToString('o')
    results     = $Results
}
$JsonPath = Join-Path $OutputPath "cipp-ai-gdap-test-$CustomerTenantId-$Stamp.json"
$CsvPath = Join-Path $OutputPath "cipp-ai-gdap-test-$CustomerTenantId-$Stamp.csv"
$Report | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonPath -Encoding utf8
$Results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8

$Summary = $Results | Group-Object { ($_.Outcome -split ' ')[0] } | Sort-Object Name | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Host "`nSummary: $($Summary -join ', ')" -ForegroundColor Cyan
Write-Host "Results written to $JsonPath and $CsvPath" -ForegroundColor Cyan
#endregion
