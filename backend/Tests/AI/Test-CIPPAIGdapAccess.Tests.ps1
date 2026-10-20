# Pester tests for build/tools/Test-CIPPAIGdapAccess.ps1
# Loads only its helper functions (the script itself signs in and calls live APIs) and checks how
# responses are classified, so a GDAP role gap is never reported as a licensing or consent problem.

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
    $ScriptPath = Join-Path $RepoRoot 'build/tools/Test-CIPPAIGdapAccess.ps1'
    if (-not (Test-Path $ScriptPath)) { throw "Could not locate $ScriptPath" }

    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    foreach ($Name in @('ConvertTo-Outcome', 'Get-TokenClaims')) {
        $Definition = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true) | Select-Object -First 1
        if (-not $Definition) { throw "Function $Name not found in $ScriptPath" }
        . ([scriptblock]::Create($Definition.Extent.Text))
    }
}

Describe 'Test-CIPPAIGdapAccess script' {
    It 'parses without errors' {
        $Errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$Errors)
        $Errors.Count | Should -Be 0
    }
}

Describe 'ConvertTo-Outcome' {
    It 'passes 2xx responses' {
        (ConvertTo-Outcome -Status 200 -Content '{"value":[]}').Outcome | Should -Be 'Pass'
        (ConvertTo-Outcome -Status 204 -Content '').Outcome | Should -Be 'Pass'
    }

    It 'reports a 403 as a missing GDAP role or permission' {
        $Result = ConvertTo-Outcome -Status 403 -Content '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}'
        $Result.Outcome | Should -BeLike 'Forbidden*'
        $Result.ErrorCode | Should -Be 'Authorization_RequestDenied'
    }

    It 'reports licensing errors as NotLicensed whatever the status' {
        (ConvertTo-Outcome -Status 403 -Content '{"error":{"code":"Forbidden","message":"The tenant does not have a valid Microsoft Agent 365 license."}}').Outcome | Should -Be 'NotLicensed'
        (ConvertTo-Outcome -Status 400 -Content '{"error":{"code":"BadRequest","message":"No subscription found"}}').Outcome | Should -Be 'NotLicensed'
    }

    It 'separates 401, 404 and other errors' {
        (ConvertTo-Outcome -Status 401 -Content '{"error":{"code":"InvalidAuthenticationToken","message":"Access token is empty."}}').Outcome | Should -Be 'Unauthorised'
        (ConvertTo-Outcome -Status 404 -Content '{"error":{"code":"ResourceNotFound","message":"Not found"}}').Outcome | Should -Be 'NotFound'
        (ConvertTo-Outcome -Status 502 -Content '{"error":{"code":"tooManyGroupPolicies","message":"Too many group policies"}}').Outcome | Should -Be 'Error'
    }

    It 'handles non-JSON bodies and trims long messages' {
        $Result = ConvertTo-Outcome -Status 500 -Content ('x' * 1000)
        $Result.Outcome | Should -Be 'Error'
        $Result.Message.Length | Should -Be 300
    }
}

Describe 'Get-TokenClaims' {
    It 'decodes the payload of an unsigned JWT including base64url characters' {
        $Payload = '{"upn":"tech@partner.example","wids":["62e90394-69f5-4237-9190-012177145e10"],"x":"??>>"}'
        $Encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $Claims = Get-TokenClaims "header.$Encoded.signature"
        $Claims.upn | Should -Be 'tech@partner.example'
        $Claims.wids | Should -Be @('62e90394-69f5-4237-9190-012177145e10')
    }
}
