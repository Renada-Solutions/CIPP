import { Layout as DashboardLayout } from '../../../layouts/index.js'
import { CippInfoBar } from '../../../components/CippCards/CippInfoBar'
import { CippDataTable } from '../../../components/CippTable/CippDataTable'
import { CippApiDialog } from '../../../components/CippComponents/CippApiDialog'
import { CippHead } from '../../../components/CippComponents/CippHead'
import { useDialog } from '../../../hooks/use-dialog'
import { ApiGetCall } from '../../../api/ApiCall'
import { useSettings } from '../../../hooks/use-settings'
import {
  aiAgentSyncConfirmText,
  aiAgentSyncRows,
} from '../../../utils/ai-workforce'
import {
  Alert,
  Button,
  Container,
  Stack,
  SvgIcon,
  Typography,
} from '@mui/material'
import { Grid } from '@mui/system'
import {
  ArrowPathIcon,
  CpuChipIcon,
  ExclamationTriangleIcon,
  PencilSquareIcon,
  UserMinusIcon,
} from '@heroicons/react/24/outline'
import { Visibility } from '@mui/icons-material'

const Page = () => {
  const currentTenant = useSettings().currentTenant
  const syncDialog = useDialog()
  const allTenants = currentTenant === 'AllTenants'
  const queryKey = `ListAIWorkforceSummary-${currentTenant}`

  const summary = ApiGetCall({
    url: '/api/ListAIWorkforceSummary',
    data: { tenantFilter: currentTenant },
    queryKey: queryKey,
    waiting: !!currentTenant,
  })

  const data = summary.data ?? {}
  const totals = data.totals ?? {}
  const tenants = data.tenants ?? []
  const dataStatus = data.dataStatus ?? []
  const notCollected = allTenants
    ? summary.isSuccess && tenants.length === 0
    : summary.isSuccess && !dataStatus.some((source) => source.collected)

  const viewAgentsAction = {
    label: 'View agents',
    link: '/copilot/agents?tenantFilter=[Tenant]',
    icon: <Visibility />,
    multiPost: false,
  }

  const severityFilters = ['Critical', 'Warning', 'Info'].map((severity) => ({
    filterName: severity,
    value: [{ id: 'severity', value: severity }],
    type: 'column',
    filterType: 'equal',
  }))

  return (
    <Container maxWidth={false} sx={{ flexGrow: 1, py: 2 }}>
      <CippHead title="AI Workforce" />
      <Grid container spacing={2}>
        <Grid size={{ md: 12, xs: 12 }}>
          <Stack
            direction="row"
            alignItems="center"
            justifyContent="space-between"
            sx={{ mb: 1 }}
          >
            <Typography variant="h5">
              AI Workforce
              {currentTenant && !allTenants ? ` - ${currentTenant}` : ''}
            </Typography>
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
          </Stack>
          {notCollected && (
            <Alert severity="info">
              No AI agent data has been collected
              {allTenants ? ' for any tenant' : ' for this tenant'} yet. It is
              collected nightly, or click &quot;Sync agent data&quot; to collect
              it now.
            </Alert>
          )}
          {summary.isError && (
            <Alert severity="error">
              Could not load the AI workforce summary.
            </Alert>
          )}
        </Grid>

        <Grid size={{ md: 12, xs: 12 }}>
          <CippInfoBar
            isFetching={summary.isFetching}
            data={[
              {
                icon: <CpuChipIcon />,
                name: 'Agents',
                data: allTenants
                  ? `${totals.agents ?? 0} across ${totals.tenants ?? 0} clients`
                  : `${totals.agents ?? 0} (${totals.active ?? 0} active)`,
              },
              {
                icon: <ExclamationTriangleIcon />,
                name: 'Need attention',
                data: `${totals.needAttention ?? 0} (${totals.critical ?? 0} critical)`,
                color: (totals.critical ?? 0) > 0 ? 'error' : 'warning',
              },
              {
                icon: <UserMinusIcon />,
                name: 'No sponsor',
                data: `${totals.noSponsor ?? 0}`,
                color: 'warning',
              },
              {
                icon: <PencilSquareIcon />,
                name: 'Can change data',
                data: `${totals.writeAccess ?? 0}`,
              },
            ]}
          />
        </Grid>

        <Grid size={{ md: 12, xs: 12 }}>
          <CippDataTable
            key={`attention-${currentTenant}`}
            title="Needs attention"
            queryKey={`${queryKey}-attention`}
            isFetching={summary.isFetching}
            data={data.attention ?? []}
            filters={severityFilters}
            actions={[viewAgentsAction]}
            simpleColumns={[
              'severity',
              'displayName',
              'issue',
              'action',
              'source',
            ]}
          />
        </Grid>

        {allTenants ? (
          <Grid size={{ md: 12, xs: 12 }}>
            <CippDataTable
              key={`tenants-${currentTenant}`}
              title="Clients"
              queryKey={`${queryKey}-tenants`}
              isFetching={summary.isFetching}
              data={tenants}
              actions={[viewAgentsAction]}
              simpleColumns={[
                'Tenant',
                'agents',
                'active',
                'needAttention',
                'critical',
                'noSponsor',
                'writeAccess',
                'agent365Synced',
                'lastRefresh',
              ]}
            />
          </Grid>
        ) : (
          <Grid size={{ md: 12, xs: 12 }}>
            <CippDataTable
              key={`sources-${currentTenant}`}
              title="Data sources"
              queryKey={`${queryKey}-sources`}
              isFetching={summary.isFetching}
              data={dataStatus}
              simpleColumns={['source', 'collected', 'count', 'lastRefresh']}
            />
          </Grid>
        )}
      </Grid>

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
    </Container>
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
