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

// --- AI Access Policy ---

export const aiAccessLicenceModes = [
  { label: 'Not managed by this policy', value: 'notManaged' },
  { label: 'Grant: assign Copilot to this group', value: 'grant' },
  { label: 'Deny: remove group-based Copilot from this group', value: 'deny' },
]

export const copilotSkuOptions = [
  { label: 'Microsoft 365 Copilot', value: 'Microsoft_365_Copilot' },
  { label: 'Microsoft 365 Copilot (M365_Copilot)', value: 'M365_Copilot' },
  {
    label: 'Microsoft 365 Copilot (Education Faculty)',
    value: 'Microsoft_365_Copilot_EDU',
  },
]

export const aiAccessManualControlOptions = (catalog) =>
  (catalog ?? []).map((control) => ({
    label: `${control.area}: ${control.title}`,
    value: control.id,
  }))

// Turns a stored (normalised) policy back into the values the policy form edits.
export const aiAccessPolicyToFormValues = (policy, catalog) => {
  const option = (options, value) =>
    options.find((item) => item.value === value) ?? null
  return {
    GUID: policy.GUID,
    name: policy.name ?? '',
    description: policy.description ?? '',
    targetType: policy.target?.type ?? 'allUsers',
    groupName: policy.target?.groupName ?? '',
    copilotLicenceMode: option(
      aiAccessLicenceModes,
      policy.copilotLicence?.mode ?? 'notManaged'
    ),
    copilotSkus: (policy.copilotLicence?.skuPartNumbers ?? []).map(
      (sku) => option(copilotSkuOptions, sku) ?? { label: sku, value: sku }
    ),
    userConsent: policy.userConsent === 'block',
    approvedAiApps: (policy.approvedAiApps ?? [])
      .map((app) =>
        app.displayName ? `${app.appId}, ${app.displayName}` : app.appId
      )
      .join('\n'),
    manualControls: (policy.manualControls ?? []).map(
      (id) =>
        option(aiAccessManualControlOptions(catalog), id) ?? {
          label: id,
          value: id,
        }
    ),
  }
}

export const aiAccessPolicyDefaults = {
  targetType: 'allUsers',
  copilotLicenceMode: aiAccessLicenceModes[0],
  copilotSkus: [],
  userConsent: false,
  approvedAiApps: '',
  manualControls: [],
}
