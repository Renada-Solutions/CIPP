import { useEffect, useState } from 'react'
import { useRouter } from 'next/router'
import { Alert, Chip, Container, Stack, Typography } from '@mui/material'
import { Grid } from '@mui/system'
import { useForm } from 'react-hook-form'
import { Layout as DashboardLayout } from '../../../../layouts/index.js'
import { CippHead } from '../../../../components/CippComponents/CippHead'
import { CippInfoBar } from '../../../../components/CippCards/CippInfoBar'
import { CippDataTable } from '../../../../components/CippTable/CippDataTable'
import CippFormComponent from '../../../../components/CippComponents/CippFormComponent'
import { ApiGetCall } from '../../../../api/ApiCall'
import { useSettings } from '../../../../hooks/use-settings'
import {
  CheckCircleIcon,
  ExclamationTriangleIcon,
  NoSymbolIcon,
  PencilSquareIcon,
} from '@heroicons/react/24/outline'

// Shows what the selected AI Access Policies would change in the current tenant. Read only.
const Page = () => {
  const router = useRouter()
  const currentTenant = useSettings().currentTenant
  const singleTenant = currentTenant && currentTenant !== 'AllTenants'
  const formControl = useForm({ defaultValues: { templates: [] } })
  const [templateIds, setTemplateIds] = useState('')

  const templates = ApiGetCall({
    url: '/api/ListAIAccessPolicyTemplates',
    queryKey: 'AIAccessPolicyTemplatePicker',
  })
  const templateList = Array.isArray(templates.data) ? templates.data : []

  // Preselect templates passed in the URL (from the policy list's Preview action)
  useEffect(() => {
    const requested = String(router.query.templateIds ?? '')
      .split(',')
      .filter(Boolean)
    if (
      requested.length &&
      templates.isSuccess &&
      Array.isArray(templates.data)
    ) {
      formControl.setValue(
        'templates',
        templates.data
          .filter((policy) => requested.includes(policy.GUID))
          .map((policy) => ({ label: policy.name, value: policy.GUID }))
      )
    }
  }, [
    router.query.templateIds,
    templates.isSuccess,
    templates.data,
    formControl,
  ])

  const selected = formControl.watch('templates')
  useEffect(() => {
    setTemplateIds((selected ?? []).map((item) => item.value).join(','))
  }, [selected])

  const preview = ApiGetCall({
    url: '/api/ListAIAccessPolicyPreview',
    data: { tenantFilter: currentTenant, templateIds },
    queryKey: `AIAccessPolicyPreview-${currentTenant}-${templateIds}`,
    waiting: !!singleTenant,
  })

  const plan = preview.data?.plan ?? []
  const count = (status) => plan.filter((row) => row.status === status).length
  const changes = plan.filter((row) => row.change).length

  return (
    <Container maxWidth={false} sx={{ flexGrow: 1, py: 2 }}>
      <CippHead title="AI Access Policy preview" />
      <Grid container spacing={2}>
        <Grid size={{ xs: 12 }}>
          <Typography variant="h5">
            AI Access Policy preview{singleTenant ? ` - ${currentTenant}` : ''}
          </Typography>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 0.5 }}>
            Read only. Shows each requirement, the tenant&apos;s current state,
            and the change the AI Access Policy standard would make with
            remediation enabled.
          </Typography>
        </Grid>

        {!singleTenant ? (
          <Grid size={{ xs: 12 }}>
            <Alert severity="info">
              Select a single tenant to preview AI Access Policies.
            </Alert>
          </Grid>
        ) : (
          <>
            <Grid size={{ md: 8, xs: 12 }}>
              <CippFormComponent
                type="autoComplete"
                label="Policies to preview (leave empty for the policies applied to this tenant)"
                name="templates"
                multiple={true}
                creatable={false}
                options={templateList.map((policy) => ({
                  label: policy.name,
                  value: policy.GUID,
                }))}
                formControl={formControl}
              />
            </Grid>
            <Grid size={{ xs: 12 }}>
              {preview.data?.message && (
                <Alert severity="info">{preview.data.message}</Alert>
              )}
              {preview.isError && (
                <Alert severity="error">
                  {preview.error?.response?.data?.Results ??
                    'Could not build the preview.'}
                </Alert>
              )}
              {(preview.data?.policies ?? []).length > 0 && (
                <Stack
                  direction="row"
                  spacing={1}
                  alignItems="center"
                  flexWrap="wrap"
                  useFlexGap
                >
                  <Typography variant="body2" color="text.secondary">
                    {preview.data.source === 'applied'
                      ? 'Applied policies:'
                      : 'Previewing:'}
                  </Typography>
                  {preview.data.policies.map((name) => (
                    <Chip key={name} size="small" label={name} />
                  ))}
                </Stack>
              )}
            </Grid>
            <Grid size={{ xs: 12 }}>
              <CippInfoBar
                isFetching={preview.isFetching}
                data={[
                  {
                    icon: <CheckCircleIcon />,
                    name: 'Compliant',
                    data: `${count('Compliant')}`,
                  },
                  {
                    icon: <PencilSquareIcon />,
                    name: 'Changes CIPP would make',
                    data: `${changes}`,
                    color: changes > 0 ? 'warning' : 'success',
                  },
                  {
                    icon: <ExclamationTriangleIcon />,
                    name: 'Need action outside CIPP',
                    data: `${count('NonCompliant') - changes + count('Blocked')}`,
                    color: 'error',
                  },
                  {
                    icon: <NoSymbolIcon />,
                    name: 'Not applicable',
                    data: `${count('NotApplicable')}`,
                  },
                ]}
              />
            </Grid>
            <Grid size={{ xs: 12 }}>
              <CippDataTable
                key={`preview-${currentTenant}`}
                title="Requirements"
                queryKey={`AIAccessPolicyPreviewTable-${currentTenant}-${templateIds}`}
                isFetching={preview.isFetching}
                data={plan}
                simpleColumns={[
                  'status',
                  'control',
                  'item',
                  'target',
                  'expected',
                  'current',
                  'change',
                  'detail',
                  'from',
                ]}
              />
            </Grid>
          </>
        )}
      </Grid>
    </Container>
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
