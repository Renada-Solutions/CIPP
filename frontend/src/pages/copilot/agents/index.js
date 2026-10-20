import { Layout as DashboardLayout } from '../../../layouts/index.js'
import { CippTablePage } from '../../../components/CippComponents/CippTablePage.jsx'
import { CippDataTable } from '../../../components/CippTable/CippDataTable'
import { CippApiDialog } from '../../../components/CippComponents/CippApiDialog'
import { useDialog } from '../../../hooks/use-dialog'
import { useSettings } from '../../../hooks/use-settings'
import {
  Alert,
  Button,
  Chip,
  Divider,
  Stack,
  SvgIcon,
  Typography,
} from '@mui/material'
import { Grid } from '@mui/system'
import { ArrowPathIcon } from '@heroicons/react/24/outline'
import {
  aiAgentSyncConfirmText,
  aiAgentSyncRows,
  severityColor,
} from '../../../utils/ai-workforce'

// Row detail: what needs attention, who is accountable, and what the agent can read or change.
const AgentDetail = ({ row }) => {
  if (!row) return null
  const attention = row.attention ?? []
  const properties = [
    { label: 'Source', value: row.source },
    { label: 'Status', value: row.status },
    { label: 'Publisher', value: row.publisher },
    { label: 'Agent type', value: row.agentType },
    { label: 'Package type', value: row.packageType },
    { label: 'Blueprint', value: row.blueprintName ?? row.blueprintAppId },
    { label: 'Available to', value: row.availableTo },
    { label: 'Deployed to', value: row.deployedTo },
    {
      label: 'Created',
      value:
        row.createdDateTime && new Date(row.createdDateTime).toLocaleString(),
    },
    {
      label: 'Risk',
      value: row.riskLevel && `${row.riskLevel} (${row.riskState})`,
    },
    { label: 'Agent identity ID', value: row.agentIdentityId },
    { label: 'Package ID', value: row.packageId },
  ]

  return (
    <Stack spacing={2} sx={{ mt: 1 }}>
      {row.description && (
        <Typography variant="body2">{row.description}</Typography>
      )}

      <Typography variant="subtitle2" color="text.secondary">
        Needs attention
      </Typography>
      {attention.length === 0 ? (
        <Alert severity="success">
          Nothing needs attention for this agent.
        </Alert>
      ) : (
        attention.map((item) => (
          <Alert
            key={item.issue}
            severity={severityColor(item.severity)}
            action={
              <Typography
                variant="caption"
                sx={{ maxWidth: 260, textAlign: 'right' }}
              >
                {item.action}
              </Typography>
            }
          >
            {item.issue}
          </Alert>
        ))
      )}

      <Divider />
      <Grid container spacing={2}>
        {properties
          .filter(
            (prop) =>
              prop.value !== undefined &&
              prop.value !== null &&
              prop.value !== ''
          )
          .map((prop) => (
            <Grid size={{ md: 4, xs: 6 }} key={prop.label}>
              <Typography variant="subtitle2" color="text.secondary">
                {prop.label}
              </Typography>
              <Typography variant="body2">{String(prop.value)}</Typography>
            </Grid>
          ))}
      </Grid>

      <Divider />
      <Grid container spacing={2}>
        <Grid size={{ md: 6, xs: 12 }}>
          <Typography
            variant="subtitle2"
            color="text.secondary"
            sx={{ mb: 0.5 }}
          >
            Sponsors
          </Typography>
          {row.sponsorStatus === 'Unknown' ? (
            <Typography variant="body2" color="text.secondary">
              Unknown. Reading sponsors needs the AgentIdentity.ReadWrite.All
              application permission.
            </Typography>
          ) : (row.sponsors ?? []).length === 0 ? (
            <Typography variant="body2">None</Typography>
          ) : (
            <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
              {row.sponsors.map((name, index) => (
                <Chip
                  key={`${name}-${index}`}
                  size="small"
                  variant="outlined"
                  label={name}
                />
              ))}
            </Stack>
          )}
        </Grid>
        <Grid size={{ md: 6, xs: 12 }}>
          <Typography
            variant="subtitle2"
            color="text.secondary"
            sx={{ mb: 0.5 }}
          >
            Owners
          </Typography>
          {(row.owners ?? []).length === 0 ? (
            <Typography variant="body2">None</Typography>
          ) : (
            <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
              {row.owners.map((name, index) => (
                <Chip
                  key={`${name}-${index}`}
                  size="small"
                  variant="outlined"
                  label={name}
                />
              ))}
            </Stack>
          )}
        </Grid>
      </Grid>

      <Divider />
      <CippDataTable
        noCard={true}
        title={`Permissions (${row.accessLevel ?? 'None'})`}
        data={row.permissions ?? []}
        simpleColumns={[
          'name',
          'resource',
          'type',
          'access',
          'risk',
          'riskReason',
        ]}
      />
    </Stack>
  )
}

const Page = () => {
  const currentTenant = useSettings().currentTenant
  const syncDialog = useDialog()
  const queryKey = `ListAIAgents-${currentTenant}`

  const equalFilter = (filterName, id, value) => ({
    filterName,
    value: [{ id, value }],
    type: 'column',
    filterType: 'equal',
  })
  const filters = [
    equalFilter('Critical', 'attentionSeverity', 'Critical'),
    equalFilter('Warning', 'attentionSeverity', 'Warning'),
    equalFilter('No sponsor', 'sponsorStatus', 'None'),
    equalFilter('Can change data', 'accessLevel', 'Read and write'),
    equalFilter('Disabled', 'status', 'Disabled'),
    equalFilter('Blocked', 'status', 'Blocked'),
  ]

  const offCanvas = {
    size: 'lg',
    children: (row) => <AgentDetail row={row} />,
  }

  return (
    <>
      <CippTablePage
        title="AI Agents"
        apiUrl="/api/ListAIAgents"
        queryKey={queryKey}
        filters={filters}
        offCanvas={offCanvas}
        offCanvasOnRowClick={true}
        cardButton={
          <Button
            size="small"
            variant="outlined"
            onClick={syncDialog.handleOpen}
            startIcon={
              <SvgIcon fontSize="small">
                <ArrowPathIcon />
              </SvgIcon>
            }
          >
            Sync agent data
          </Button>
        }
        simpleColumns={[
          'displayName',
          'attentionSeverity',
          'attentionCount',
          'status',
          'source',
          'publisher',
          'agentType',
          'sponsorStatus',
          'accessLevel',
          'riskLevel',
          'createdDateTime',
        ]}
      />
      <CippApiDialog
        createDialog={syncDialog}
        title="Sync AI agent data"
        api={{
          type: 'GET',
          url: '/api/ExecCIPPDBCache',
          data: { Name: 'Name' },
          confirmText: aiAgentSyncConfirmText,
          relatedQueryKeys: [queryKey],
        }}
        row={aiAgentSyncRows}
      />
    </>
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
