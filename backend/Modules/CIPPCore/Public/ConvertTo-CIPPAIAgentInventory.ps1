function ConvertTo-CIPPAIAgentInventory {
    <#
    .SYNOPSIS
        Builds normalised AI agent records from cached Entra Agent ID and Agent 365 data

    .DESCRIPTION
        Pure transformation (no Graph or table calls) so the list endpoint, the overview and future
        policy evaluation share one definition of an agent. Each record merges an Entra agent identity
        with the Agent 365 package that references it (by agentIdentityId); packages with no identity
        become their own record. Permissions are resolved from the cached app role assignments and
        delegated grants, classified as read or write, and matched against RiskyPermissions.json.
        Every record carries an attention list: issues an MSP should act on, with the fix.

    .PARAMETER AgentIdentities
        Cached AgentIdentities rows (with owners, sponsors and sponsorsKnown)

    .PARAMETER Blueprints
        Cached AgentIdentityBlueprints rows

    .PARAMETER Packages
        Cached AgentPackages rows

    .PARAMETER RiskyAgents
        Cached RiskyAgents rows

    .PARAMETER ServicePrincipals
        Cached ServicePrincipals rows, used to resolve permission names (id, displayName, appRoles)

    .PARAMETER AppRoleAssignments
        Cached AppRoleAssignments rows (application permissions granted to service principals)

    .PARAMETER OAuth2PermissionGrants
        Cached OAuth2PermissionGrants rows (delegated permissions)

    .PARAMETER RiskyPermissions
        Entries from Config/RiskyPermissions.json

    .PARAMETER Now
        Reference time for expiry checks; defaults to the current UTC time

    .PARAMETER CredentialWarningDays
        Days before a blueprint credential expires at which to warn

    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        $AgentIdentities = @(),
        $Blueprints = @(),
        $Packages = @(),
        $RiskyAgents = @(),
        $ServicePrincipals = @(),
        $AppRoleAssignments = @(),
        $OAuth2PermissionGrants = @(),
        $RiskyPermissions = @(),
        [datetime]$Now = [datetime]::UtcNow,
        [int]$CredentialWarningDays = 30
    )

    $SeverityRank = @{ Critical = 3; Warning = 2; Info = 1; None = 0 }
    $RiskRank = @{ Critical = 4; High = 3; Medium = 2; Low = 1 }
    # Scopes that let an agent change or send data rather than only read it
    $WritePattern = '(ReadWrite|\.Write|Send|Manage|FullControl|Create|Delete|Update|Invite|EnableDisable|full_access)'

    function New-AttentionItem ($Severity, $Issue, $Action) {
        [PSCustomObject]@{ severity = $Severity; issue = $Issue; action = $Action }
    }

    function ConvertTo-UtcDate ($Value) {
        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
        try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
    }

    # --- Lookups ---
    $SpById = @{}
    foreach ($Sp in @($ServicePrincipals)) { if ($Sp.id) { $SpById[[string]$Sp.id] = $Sp } }

    $BlueprintByAppId = @{}
    foreach ($Blueprint in @($Blueprints)) { if ($Blueprint.appId) { $BlueprintByAppId[[string]$Blueprint.appId] = $Blueprint } }

    $RiskById = @{}
    foreach ($Risk in @($RiskyAgents)) { if ($Risk.id) { $RiskById[[string]$Risk.id] = $Risk } }

    $RiskyPermissionByKey = @{}
    foreach ($Permission in @($RiskyPermissions)) {
        if ($Permission.name) { $RiskyPermissionByKey["$($Permission.type)|$($Permission.name)".ToLower()] = $Permission }
    }

    $AssignmentsByPrincipal = @{}
    foreach ($Assignment in @($AppRoleAssignments)) {
        if (-not $Assignment.principalId) { continue }
        $Key = [string]$Assignment.principalId
        if (-not $AssignmentsByPrincipal.ContainsKey($Key)) { $AssignmentsByPrincipal[$Key] = [System.Collections.Generic.List[object]]::new() }
        $AssignmentsByPrincipal[$Key].Add($Assignment)
    }

    $GrantsByClient = @{}
    foreach ($Grant in @($OAuth2PermissionGrants)) {
        if (-not $Grant.clientId) { continue }
        $Key = [string]$Grant.clientId
        if (-not $GrantsByClient.ContainsKey($Key)) { $GrantsByClient[$Key] = [System.Collections.Generic.List[object]]::new() }
        $GrantsByClient[$Key].Add($Grant)
    }

    function Get-AgentPermissions ($PrincipalId) {
        $Result = [System.Collections.Generic.List[object]]::new()
        if (-not $PrincipalId) { return $Result }
        $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($Assignment in @($AssignmentsByPrincipal[[string]$PrincipalId])) {
            if (-not $Assignment) { continue }
            $Resource = $SpById[[string]$Assignment.resourceId]
            $ResourceName = $Assignment.resourceDisplayName ?? $Resource.displayName ?? 'Unknown resource'
            $Role = @($Resource.appRoles) | Where-Object { $_.id -eq $Assignment.appRoleId } | Select-Object -First 1
            $Name = $Role.value ?? [string]$Assignment.appRoleId
            if ($Seen.Add("Application|$ResourceName|$Name")) {
                $Result.Add([PSCustomObject]@{ name = $Name; resource = $ResourceName; type = 'Application' })
            }
        }

        foreach ($Grant in @($GrantsByClient[[string]$PrincipalId])) {
            if (-not $Grant) { continue }
            $ResourceName = $SpById[[string]$Grant.resourceId].displayName ?? 'Unknown resource'
            foreach ($Scope in ([string]$Grant.scope -split '\s+' | Where-Object { $_ })) {
                if ($Seen.Add("Delegated|$ResourceName|$Scope")) {
                    $Result.Add([PSCustomObject]@{ name = $Scope; resource = $ResourceName; type = 'Delegated' })
                }
            }
        }

        foreach ($Permission in $Result) {
            $Access = if ($Permission.name -match $WritePattern) { 'Write' } else { 'Read' }
            $Risky = $RiskyPermissionByKey["$($Permission.type)|$($Permission.name)".ToLower()]
            $Permission | Add-Member -NotePropertyName 'access' -NotePropertyValue $Access -Force
            $Permission | Add-Member -NotePropertyName 'risk' -NotePropertyValue ($Risky.risk ?? $null) -Force
            $Permission | Add-Member -NotePropertyName 'riskReason' -NotePropertyValue ($Risky.reason ?? $null) -Force
        }
        return $Result
    }

    # Agents surface in the catalog alongside ordinary Microsoft 365 apps; keep only agent packages
    function Test-AgentPackage ($Package) {
        if ($Package.agentIdentityId) { return $true }
        if (@($Package.supportedHosts) -contains 'Copilot') { return $true }
        return [bool](@($Package.elementTypes) | Where-Object { $_ -match 'agent|bot' })
    }

    $PackageByIdentity = @{}
    $StandalonePackages = [System.Collections.Generic.List[object]]::new()
    $IdentityIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($Agent in @($AgentIdentities)) { if ($Agent.id) { [void]$IdentityIds.Add([string]$Agent.id) } }
    foreach ($Package in @($Packages)) {
        if (-not $Package -or -not (Test-AgentPackage $Package)) { continue }
        if ($Package.agentIdentityId -and $IdentityIds.Contains([string]$Package.agentIdentityId)) {
            $PackageByIdentity[[string]$Package.agentIdentityId] = $Package
        } else {
            $StandalonePackages.Add($Package)
        }
    }

    function New-AgentRecord ($Identity, $Package) {
        $Attention = [System.Collections.Generic.List[object]]::new()
        $Sources = @(if ($Identity) { 'Entra Agent ID' }; if ($Package) { 'Agent 365' })
        $Blueprint = if ($Identity.agentIdentityBlueprintId) { $BlueprintByAppId[[string]$Identity.agentIdentityBlueprintId] }
        $Risk = if ($Identity) { $RiskById[[string]$Identity.id] }
        $Permissions = @(Get-AgentPermissions -PrincipalId $Identity.id)

        $DisabledByMicrosoft = $Identity.disabledByMicrosoftStatus -and $Identity.disabledByMicrosoftStatus -ne 'NotDisabled'
        $Enabled = if ($Identity) { [bool]$Identity.accountEnabled -and -not $DisabledByMicrosoft } else { $true }
        $Blocked = [bool]$Package.isBlocked
        $Active = $Enabled -and -not $Blocked

        $Status = if ($DisabledByMicrosoft) { 'Disabled by Microsoft' }
        elseif ($Identity -and -not $Identity.accountEnabled) { 'Disabled' }
        elseif ($Blocked) { 'Blocked' }
        elseif ($Identity) { 'Enabled' }
        else { 'Available' }

        $AccessLevel = if (@($Permissions | Where-Object access -EQ 'Write').Count -gt 0) { 'Read and write' }
        elseif ($Permissions.Count -gt 0) { 'Read' }
        else { 'None' }

        $SponsorsKnown = [bool]$Identity.sponsorsKnown
        $SponsorNames = @(@($Identity.sponsors) | Where-Object { $_ } | ForEach-Object { $_.displayName ?? $_.userPrincipalName ?? $_.id })
        $SponsorStatus = if (-not $Identity) { 'Not applicable' }
        elseif (-not $SponsorsKnown) { 'Unknown' }
        elseif ($SponsorNames.Count -gt 0) { 'Assigned' }
        else { 'None' }

        # --- Attention items, most severe first once sorted ---
        if ($DisabledByMicrosoft) {
            $Attention.Add((New-AttentionItem 'Critical' "Disabled by Microsoft ($($Identity.disabledByMicrosoftStatus))" 'Review the agent and its blueprint in Microsoft Entra'))
        }

        if ($Risk -and $Risk.riskState -in @('atRisk', 'confirmedCompromised')) {
            $Severity = if ($Risk.riskState -eq 'confirmedCompromised' -or $Risk.riskLevel -eq 'high') { 'Critical' }
            elseif ($Risk.riskLevel -eq 'medium') { 'Warning' }
            else { 'Info' }
            $Attention.Add((New-AttentionItem $Severity "Identity Protection: $($Risk.riskState), $($Risk.riskLevel) risk" 'Investigate in Entra ID Protection, then disable the agent or confirm it safe'))
        }

        if ($Active -and $SponsorStatus -eq 'None') {
            if ($AccessLevel -eq 'Read and write') {
                $Attention.Add((New-AttentionItem 'Critical' 'Can change data but has no sponsor' 'Assign a sponsor who is accountable for this agent'))
            } else {
                $Attention.Add((New-AttentionItem 'Warning' 'No sponsor assigned' 'Assign a sponsor who is accountable for this agent'))
            }
        }

        if ($Active -and $Blueprint) {
            $Expiries = @(@($Blueprint.passwordCredentials) + @($Blueprint.keyCredentials) |
                    Where-Object { $_ } | ForEach-Object { ConvertTo-UtcDate $_.endDateTime } | Where-Object { $_ })
            if ($Expiries.Count -gt 0) {
                $Latest = ($Expiries | Sort-Object -Descending | Select-Object -First 1)
                $DaysLeft = [math]::Floor(($Latest - $Now).TotalDays)
                if ($Latest -le $Now) {
                    $Attention.Add((New-AttentionItem 'Critical' 'All blueprint credentials have expired' 'Rotate the blueprint credential in Microsoft Entra'))
                } elseif ($DaysLeft -le $CredentialWarningDays) {
                    $Attention.Add((New-AttentionItem 'Warning' "Blueprint credential expires in $DaysLeft days" 'Rotate the blueprint credential in Microsoft Entra'))
                }
            }
        }

        if ($Active) {
            $TopRisky = $Permissions | Where-Object { $_.risk -in @('Critical', 'High') } |
                Sort-Object -Property @{ Expression = { $RiskRank[$_.risk] }; Descending = $true } | Select-Object -First 1
            if ($TopRisky) {
                $Others = @($Permissions | Where-Object { $_.risk -in @('Critical', 'High') }).Count - 1
                $Suffix = if ($Others -gt 0) { " and $Others more" } else { '' }
                $Severity = if ($TopRisky.risk -eq 'Critical') { 'Critical' } else { 'Warning' }
                $Attention.Add((New-AttentionItem $Severity "Holds $($TopRisky.risk.ToLower())-risk permission $($TopRisky.name)$Suffix" 'Review the permissions granted to this agent'))
            }
        }

        if ($Package.requestStatus -eq 'pending') {
            $RequestType = if ($Package.requestType) { " to $($Package.requestType)" } else { '' }
            $Attention.Add((New-AttentionItem 'Info' "User request pending$RequestType" 'Approve or reject the request in the Microsoft 365 admin center'))
        }

        $SortedAttention = @($Attention | Sort-Object -Property @{ Expression = { $SeverityRank[$_.severity] }; Descending = $true })
        $TopSeverity = if ($SortedAttention.Count -gt 0) { $SortedAttention[0].severity } else { 'None' }

        [PSCustomObject]@{
            id                   = [string]($Identity.id ?? $Package.id)
            displayName          = $Identity.displayName ?? $Package.displayName
            source               = $Sources -join ' + '
            sources              = $Sources
            agentIdentityId      = $Identity.id
            packageId            = $Package.id
            appId                = $Identity.appId ?? $Package.appId
            publisher            = $Package.publisher ?? $Blueprint.publisherDomain
            agentType            = $Package.governanceMetadata ?? $(if ($Identity) { 'Agent identity' })
            packageType          = $Package.type
            description          = $Package.shortDescription
            status               = $Status
            accountEnabled       = if ($Identity) { [bool]$Identity.accountEnabled } else { $null }
            isBlocked            = if ($Package) { $Blocked } else { $null }
            availableTo          = $Package.availableTo
            deployedTo           = $Package.deployedTo
            supportedHosts       = @($Package.supportedHosts)
            blueprintAppId       = $Identity.agentIdentityBlueprintId
            blueprintName        = $Blueprint.displayName
            sponsorStatus        = $SponsorStatus
            sponsors             = $SponsorNames
            owners               = @(@($Identity.owners) | Where-Object { $_ } | ForEach-Object { $_.displayName ?? $_.userPrincipalName ?? $_.id })
            createdDateTime      = $Identity.createdDateTime ?? $Package.createdDateTime
            lastModifiedDateTime = $Package.lastModifiedDateTime
            riskLevel            = $Risk.riskLevel
            riskState            = $Risk.riskState
            accessLevel          = $AccessLevel
            permissionCount      = $Permissions.Count
            permissions          = $Permissions
            requestStatus        = $Package.requestStatus
            attentionSeverity    = $TopSeverity
            attentionCount       = $SortedAttention.Count
            attention            = $SortedAttention
        }
    }

    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Identity in @($AgentIdentities)) {
        if (-not $Identity -or -not $Identity.id) { continue }
        $Records.Add((New-AgentRecord -Identity $Identity -Package $PackageByIdentity[[string]$Identity.id]))
    }
    foreach ($Package in $StandalonePackages) {
        $Records.Add((New-AgentRecord -Identity $null -Package $Package))
    }

    return , $Records.ToArray()
}
