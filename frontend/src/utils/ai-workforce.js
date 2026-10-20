// Shared helpers for the Copilot & AI > AI Workforce pages.

export const severityColor = (severity) => {
  switch (String(severity).toLowerCase()) {
    case 'critical':
      return 'error'
    case 'warning':
      return 'warning'
    case 'info':
      return 'info'
    default:
      return 'success'
  }
}

// Datasets in the CIPP reporting database the AI agent inventory is built from.
export const aiAgentSyncRows = [
  { Name: 'AgentIdentities' },
  { Name: 'AgentIdentityBlueprints' },
  { Name: 'AgentPackages' },
  { Name: 'RiskyAgents' },
  { Name: 'ServicePrincipals' },
  { Name: 'AppRoleAssignments' },
  { Name: 'OAuth2PermissionGrants' },
]

export const aiAgentSyncConfirmText =
  'Queue a refresh of the cached agent identities, Agent 365 packages, risky agents and app permissions? The pages update once the sync completes.'
