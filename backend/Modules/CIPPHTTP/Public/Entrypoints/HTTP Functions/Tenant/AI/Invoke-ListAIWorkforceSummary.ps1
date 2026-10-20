function Invoke-ListAIWorkforceSummary {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.AI.Read
    .DESCRIPTION
        Summarises the AI agent workforce for a tenant (or all tenants): headline totals, one row per
        tenant with agent and attention counts, every open attention item across those tenants (most
        severe first), and which data sources have been collected. Reads CACHED data only.
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = 'ListAIWorkforceSummary'
    $TenantFilter = $Request.Query.tenantFilter ?? $Request.Body.tenantFilter
    $SeverityRank = @{ Critical = 3; Warning = 2; Info = 1 }

    try {
        $TenantRows = [System.Collections.Generic.List[object]]::new()
        $AttentionRows = [System.Collections.Generic.List[object]]::new()
        $DataStatus = @()

        foreach ($Tenant in @(Get-CIPPAIAgentTenants -TenantFilter $TenantFilter)) {
            try {
                $Inventory = Get-CIPPAIAgentInventory -TenantFilter $Tenant
            } catch {
                if ($TenantFilter -ne 'AllTenants') { throw }
                Write-LogMessage -API $APIName -tenant $Tenant -message "Failed to build AI agent inventory: $($_.Exception.Message)" -sev Warning
                continue
            }
            $Agents = @($Inventory.Agents)
            if ($TenantFilter -ne 'AllTenants') { $DataStatus = $Inventory.DataStatus }

            foreach ($Agent in $Agents) {
                foreach ($Item in @($Agent.attention)) {
                    $AttentionRows.Add([PSCustomObject]@{
                            Tenant      = $Tenant
                            agentId     = $Agent.id
                            displayName = $Agent.displayName
                            source      = $Agent.source
                            severity    = $Item.severity
                            issue       = $Item.issue
                            action      = $Item.action
                        })
                }
            }

            $PackagesStatus = $Inventory.DataStatus | Where-Object type -EQ 'AgentPackages'
            $Refreshed = @($Inventory.DataStatus | Where-Object lastRefresh | ForEach-Object { $_.lastRefresh })
            $TenantRows.Add([PSCustomObject]@{
                    Tenant          = $Tenant
                    agents          = $Agents.Count
                    active          = @($Agents | Where-Object { $_.status -in @('Enabled', 'Available') }).Count
                    inactive        = @($Agents | Where-Object { $_.status -notin @('Enabled', 'Available') }).Count
                    needAttention   = @($Agents | Where-Object attentionCount -GT 0).Count
                    critical        = @($Agents | Where-Object attentionSeverity -EQ 'Critical').Count
                    warning         = @($Agents | Where-Object attentionSeverity -EQ 'Warning').Count
                    noSponsor       = @($Agents | Where-Object sponsorStatus -EQ 'None').Count
                    writeAccess     = @($Agents | Where-Object accessLevel -EQ 'Read and write').Count
                    agent365Synced  = [bool]$PackagesStatus.collected
                    lastRefresh     = if ($Refreshed.Count -gt 0) { $Refreshed | Sort-Object | Select-Object -First 1 } else { $null }
                })
        }

        $Body = [PSCustomObject]@{
            totals     = [PSCustomObject]@{
                tenants       = $TenantRows.Count
                agents        = [int](($TenantRows | Measure-Object -Property agents -Sum).Sum ?? 0)
                active        = [int](($TenantRows | Measure-Object -Property active -Sum).Sum ?? 0)
                needAttention = [int](($TenantRows | Measure-Object -Property needAttention -Sum).Sum ?? 0)
                critical      = [int](($TenantRows | Measure-Object -Property critical -Sum).Sum ?? 0)
                noSponsor     = [int](($TenantRows | Measure-Object -Property noSponsor -Sum).Sum ?? 0)
                writeAccess   = [int](($TenantRows | Measure-Object -Property writeAccess -Sum).Sum ?? 0)
            }
            tenants    = @($TenantRows | Sort-Object -Property @{ Expression = 'critical'; Descending = $true }, @{ Expression = 'needAttention'; Descending = $true }, 'Tenant')
            attention  = @($AttentionRows | Sort-Object -Property @{ Expression = { $SeverityRank[$_.severity] }; Descending = $true }, 'Tenant', 'displayName')
            dataStatus = @($DataStatus)
        }
        $StatusCode = [HttpStatusCode]::OK
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        Write-LogMessage -headers $Request.Headers -API $APIName -tenant $TenantFilter -message "Failed to summarise AI workforce: $($ErrorMessage.NormalizedError)" -sev Error -LogData $ErrorMessage
        $Body = @{ Results = "Failed to summarise AI workforce: $($ErrorMessage.NormalizedError)" }
        $StatusCode = [HttpStatusCode]::InternalServerError
    }

    return ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Body
        })
}
