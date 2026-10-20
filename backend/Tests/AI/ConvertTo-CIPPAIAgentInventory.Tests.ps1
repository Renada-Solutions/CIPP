# Pester tests for ConvertTo-CIPPAIAgentInventory
# Verifies merging of Entra agent identities with Agent 365 packages, permission classification and attention items

BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $FunctionPath = Get-ChildItem -Path (Join-Path $RepoRoot 'Modules') -Recurse -Filter 'ConvertTo-CIPPAIAgentInventory.ps1' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $FunctionPath) { throw 'Could not locate ConvertTo-CIPPAIAgentInventory.ps1 under Modules/' }
    . $FunctionPath

    $script:Now = [datetime]::Parse('2026-10-20T12:00:00Z').ToUniversalTime()
    $script:RiskyPermissions = @(
        [pscustomobject]@{ api = 'Microsoft Graph'; name = 'Mail.Send'; type = 'Application'; risk = 'High'; reason = 'Send as any user' }
        [pscustomobject]@{ api = 'Microsoft Graph'; name = 'RoleManagement.ReadWrite.Directory'; type = 'Application'; risk = 'Critical'; reason = 'Assign admin roles' }
    )
    $script:GraphSp = [pscustomobject]@{
        id          = 'graph-sp'
        displayName = 'Microsoft Graph'
        appRoles    = @(
            [pscustomobject]@{ id = 'role-mail-send'; value = 'Mail.Send' }
            [pscustomobject]@{ id = 'role-user-read'; value = 'User.Read.All' }
            [pscustomobject]@{ id = 'role-rolemgmt'; value = 'RoleManagement.ReadWrite.Directory' }
        )
    }

    function New-TestIdentity {
        param($Id = 'agent-1', $Name = 'Invoice Agent', [bool]$Enabled = $true, $Sponsors = @([pscustomobject]@{ displayName = 'Jo Bloggs' }), [bool]$SponsorsKnown = $true, $Blueprint = 'bp-app', $DisabledByMicrosoft = $null)
        [pscustomobject]@{
            id                        = $Id
            displayName               = $Name
            appId                     = "$Id-app"
            accountEnabled            = $Enabled
            agentIdentityBlueprintId  = $Blueprint
            disabledByMicrosoftStatus = $DisabledByMicrosoft
            createdDateTime           = '2026-09-01T00:00:00Z'
            owners                    = @([pscustomobject]@{ displayName = 'Owner One' })
            sponsors                  = $Sponsors
            sponsorsKnown             = $SponsorsKnown
        }
    }

    function Invoke-Inventory {
        param($AgentIdentities = @(), $Blueprints = @(), $Packages = @(), $RiskyAgents = @(), $AppRoleAssignments = @(), $OAuth2PermissionGrants = @())
        @(ConvertTo-CIPPAIAgentInventory -AgentIdentities $AgentIdentities -Blueprints $Blueprints -Packages $Packages -RiskyAgents $RiskyAgents `
                -ServicePrincipals @($script:GraphSp) -AppRoleAssignments $AppRoleAssignments -OAuth2PermissionGrants $OAuth2PermissionGrants `
                -RiskyPermissions $script:RiskyPermissions -Now $script:Now)
    }
}

Describe 'ConvertTo-CIPPAIAgentInventory' {
    Context 'Merging sources' {
        It 'returns an empty array when there is no data' {
            $Result = Invoke-Inventory
            $Result.Count | Should -Be 0
        }

        It 'merges a package into the identity it references' {
            $Package = [pscustomobject]@{ id = 'pkg-1'; displayName = 'Invoice Agent (catalog)'; agentIdentityId = 'agent-1'; publisher = 'Contoso'; type = 'external'; isBlocked = $false; governanceMetadata = 'HostedAgent' }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -Packages @($Package)

            $Result.Count | Should -Be 1
            $Result[0].source | Should -Be 'Entra Agent ID + Agent 365'
            $Result[0].packageId | Should -Be 'pkg-1'
            $Result[0].publisher | Should -Be 'Contoso'
            $Result[0].agentType | Should -Be 'HostedAgent'
            $Result[0].displayName | Should -Be 'Invoice Agent'
        }

        It 'keeps agent packages without an identity as their own record and drops non-agent apps' {
            $Packages = @(
                [pscustomobject]@{ id = 'pkg-agent'; displayName = 'Sales Agent'; supportedHosts = @('Copilot'); type = 'shared'; isBlocked = $true }
                [pscustomobject]@{ id = 'pkg-decl'; displayName = 'HR Agent'; elementTypes = @('declarativeAgent'); type = 'custom' }
                [pscustomobject]@{ id = 'pkg-addin'; displayName = 'Word add-in'; elementTypes = @('OfficeAddIns'); supportedHosts = @('Word') }
            )
            $Result = Invoke-Inventory -Packages $Packages

            $Result.id | Should -Be @('pkg-agent', 'pkg-decl')
            ($Result | Where-Object id -EQ 'pkg-agent').status | Should -Be 'Blocked'
            ($Result | Where-Object id -EQ 'pkg-decl').status | Should -Be 'Available'
            ($Result | Where-Object id -EQ 'pkg-agent').sponsorStatus | Should -Be 'Not applicable'
        }
    }

    Context 'Status and sponsors' {
        It 'reports disabled agents' {
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Enabled $false)
            $Result[0].status | Should -Be 'Disabled'
        }

        It 'treats unreadable sponsors as unknown and raises no sponsor alert' {
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Sponsors @() -SponsorsKnown $false)
            $Result[0].sponsorStatus | Should -Be 'Unknown'
            $Result[0].attention.issue | Should -Not -Contain 'No sponsor assigned'
        }

        It 'warns when a read-only agent has no sponsor' {
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Sponsors @())
            $Result[0].sponsorStatus | Should -Be 'None'
            $Result[0].attentionSeverity | Should -Be 'Warning'
            $Result[0].attention[0].issue | Should -Be 'No sponsor assigned'
        }

        It 'does not raise a sponsor alert for a disabled agent' {
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Sponsors @() -Enabled $false)
            $Result[0].attentionCount | Should -Be 0
        }

        It 'flags agents disabled by Microsoft as critical' {
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -DisabledByMicrosoft 'DisabledDueToViolationOfServicesAgreement')
            $Result[0].status | Should -Be 'Disabled by Microsoft'
            $Result[0].attentionSeverity | Should -Be 'Critical'
        }
    }

    Context 'Permissions' {
        It 'resolves application and delegated permissions and classifies read and write' {
            $Assignments = @(
                [pscustomobject]@{ principalId = 'agent-1'; resourceId = 'graph-sp'; appRoleId = 'role-user-read'; resourceDisplayName = 'Microsoft Graph' }
            )
            $Grants = @(
                [pscustomobject]@{ clientId = 'agent-1'; resourceId = 'graph-sp'; scope = ' Calendars.Read Files.ReadWrite ' }
            )
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -AppRoleAssignments $Assignments -OAuth2PermissionGrants $Grants

            $Result[0].permissionCount | Should -Be 3
            $Result[0].accessLevel | Should -Be 'Read and write'
            ($Result[0].permissions | Where-Object name -EQ 'User.Read.All').type | Should -Be 'Application'
            ($Result[0].permissions | Where-Object name -EQ 'Files.ReadWrite').access | Should -Be 'Write'
            ($Result[0].permissions | Where-Object name -EQ 'Calendars.Read').access | Should -Be 'Read'
        }

        It 'escalates a missing sponsor to critical when the agent can write' {
            $Grants = @([pscustomobject]@{ clientId = 'agent-1'; resourceId = 'graph-sp'; scope = 'Mail.ReadWrite' })
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Sponsors @()) -OAuth2PermissionGrants $Grants
            $Result[0].attention[0].severity | Should -Be 'Critical'
            $Result[0].attention[0].issue | Should -Be 'Can change data but has no sponsor'
        }

        It 'flags risky permissions using RiskyPermissions.json' {
            $Assignments = @(
                [pscustomobject]@{ principalId = 'agent-1'; resourceId = 'graph-sp'; appRoleId = 'role-mail-send' }
                [pscustomobject]@{ principalId = 'agent-1'; resourceId = 'graph-sp'; appRoleId = 'role-rolemgmt' }
            )
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -AppRoleAssignments $Assignments

            $Item = $Result[0].attention | Where-Object issue -Like 'Holds*'
            $Item.severity | Should -Be 'Critical'
            $Item.issue | Should -Be 'Holds critical-risk permission RoleManagement.ReadWrite.Directory and 1 more'
        }
    }

    Context 'Blueprint credentials, risk and requests' {
        It 'warns when the latest blueprint credential expires within 30 days' {
            $Blueprint = [pscustomobject]@{ appId = 'bp-app'; displayName = 'Contoso blueprint'; passwordCredentials = @([pscustomobject]@{ endDateTime = '2026-11-01T12:00:00Z' }); keyCredentials = @() }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -Blueprints @($Blueprint)

            $Result[0].blueprintName | Should -Be 'Contoso blueprint'
            $Result[0].attention[0].issue | Should -Be 'Blueprint credential expires in 12 days'
        }

        It 'raises critical when every blueprint credential has expired' {
            $Blueprint = [pscustomobject]@{ appId = 'bp-app'; passwordCredentials = @([pscustomobject]@{ endDateTime = '2026-01-01T00:00:00Z' }) }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -Blueprints @($Blueprint)
            $Result[0].attention[0].severity | Should -Be 'Critical'
        }

        It 'ignores credentials that are not close to expiry' {
            $Blueprint = [pscustomobject]@{ appId = 'bp-app'; passwordCredentials = @(
                    [pscustomobject]@{ endDateTime = '2026-10-25T00:00:00Z' }
                    [pscustomobject]@{ endDateTime = '2027-10-25T00:00:00Z' }
                )
            }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -Blueprints @($Blueprint)
            $Result[0].attentionCount | Should -Be 0
        }

        It 'maps Identity Protection risk to severity' {
            $Risk = [pscustomobject]@{ id = 'agent-1'; riskLevel = 'high'; riskState = 'atRisk' }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -RiskyAgents @($Risk)
            $Result[0].riskLevel | Should -Be 'high'
            $Result[0].attention[0].severity | Should -Be 'Critical'
        }

        It 'ignores risk that has been dismissed' {
            $Risk = [pscustomobject]@{ id = 'agent-1'; riskLevel = 'high'; riskState = 'dismissed' }
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity) -RiskyAgents @($Risk)
            $Result[0].attentionCount | Should -Be 0
        }

        It 'reports pending user requests as info' {
            $Package = [pscustomobject]@{ id = 'pkg-req'; displayName = 'Requested Agent'; supportedHosts = @('Copilot'); requestStatus = 'pending'; requestType = 'publish' }
            $Result = Invoke-Inventory -Packages @($Package)
            $Result[0].attention[0].severity | Should -Be 'Info'
            $Result[0].attention[0].issue | Should -Be 'User request pending to publish'
        }

        It 'sorts attention items most severe first' {
            $Risk = [pscustomobject]@{ id = 'agent-1'; riskLevel = 'medium'; riskState = 'atRisk' }
            $Assignments = @([pscustomobject]@{ principalId = 'agent-1'; resourceId = 'graph-sp'; appRoleId = 'role-rolemgmt' })
            $Result = Invoke-Inventory -AgentIdentities @(New-TestIdentity -Sponsors @()) -RiskyAgents @($Risk) -AppRoleAssignments $Assignments
            $Result[0].attention.severity | Should -Be @('Critical', 'Critical', 'Warning')
            $Result[0].attentionSeverity | Should -Be 'Critical'
        }
    }
}
