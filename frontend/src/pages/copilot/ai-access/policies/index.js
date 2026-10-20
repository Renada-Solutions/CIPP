import { Layout as DashboardLayout } from '../../../../layouts/index.js'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { Button } from '@mui/material'
import { Add, Delete, Edit, Visibility } from '@mui/icons-material'
import Link from 'next/link'

const Page = () => {
  const actions = [
    {
      label: 'Edit policy',
      link: '/copilot/ai-access/policies/edit?id=[GUID]',
      icon: <Edit />,
      multiPost: false,
    },
    {
      label: 'Preview against current tenant',
      link: '/copilot/ai-access/preview?templateIds=[GUID]',
      icon: <Visibility />,
      multiPost: false,
    },
    {
      label: 'Delete policy',
      type: 'POST',
      url: '/api/RemoveAIAccessPolicyTemplate',
      data: { ID: 'GUID' },
      confirmText:
        'Delete the AI Access Policy [name]? Changes it already made in tenants stay in place.',
      icon: <Delete />,
      color: 'danger',
      multiPost: false,
    },
  ]

  return (
    <CippTablePage
      title="AI Access Policies"
      apiUrl="/api/ListAIAccessPolicyTemplates"
      queryKey="ListAIAccessPolicyTemplates"
      tenantInTitle={false}
      actions={actions}
      cardButton={
        <Button
          component={Link}
          href="/copilot/ai-access/policies/add"
          startIcon={<Add />}
        >
          Add policy
        </Button>
      }
      simpleColumns={[
        'name',
        'appliesTo',
        'licenceSummary',
        'userConsentSet',
        'approvedApps',
        'manualCount',
        'description',
      ]}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
