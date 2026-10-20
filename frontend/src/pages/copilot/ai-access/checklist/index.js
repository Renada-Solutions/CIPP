import { Layout as DashboardLayout } from '../../../../layouts/index.js'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { CheckCircle, Launch, RemoveCircle } from '@mui/icons-material'

// AI controls with no API: what to set, where, and who confirmed it was done.
const Page = () => {
  const currentTenant = useSettings().currentTenant
  const queryKey = `ListAIAccessChecklist-${currentTenant}`

  const actions = [
    {
      label: 'Confirm this is set',
      type: 'POST',
      url: '/api/ExecAIAccessChecklist',
      data: { id: 'id', Action: '!Confirm' },
      fields: [
        {
          type: 'textField',
          name: 'Note',
          label: 'Note (optional): what was set',
        },
      ],
      confirmText:
        'Confirm that "[title]" has been set for this tenant? Your name and the time are recorded, and a review is due in 90 days.',
      icon: <CheckCircle />,
      relatedQueryKeys: [queryKey],
      multiPost: false,
    },
    {
      label: 'Clear confirmation',
      type: 'POST',
      url: '/api/ExecAIAccessChecklist',
      data: { id: 'id', Action: '!Clear' },
      confirmText: 'Clear the confirmation for "[title]"?',
      icon: <RemoveCircle />,
      relatedQueryKeys: [queryKey],
      condition: (row) => row.status !== 'Not confirmed',
      multiPost: false,
    },
    {
      label: 'Open admin page',
      link: '[link]',
      external: true,
      target: '_blank',
      icon: <Launch />,
      multiPost: false,
    },
  ]

  const filters = [
    {
      filterName: 'Not confirmed',
      value: [{ id: 'status', value: 'Not confirmed' }],
      type: 'column',
      filterType: 'equal',
    },
    {
      filterName: 'Review due',
      value: [{ id: 'status', value: 'Review due' }],
      type: 'column',
      filterType: 'equal',
    },
  ]

  return (
    <CippTablePage
      title="AI Access checklist"
      apiUrl="/api/ListAIAccessChecklist"
      queryKey={queryKey}
      actions={actions}
      filters={filters}
      offCanvas={{
        extendedInfoFields: [
          'title',
          'area',
          'where',
          'reason',
          'status',
          'confirmedBy',
          'confirmedAt',
          'reviewBy',
          'note',
          'requiredBy',
        ],
      }}
      simpleColumns={[
        'status',
        'required',
        'area',
        'title',
        'where',
        'confirmedBy',
        'confirmedAt',
        'reviewBy',
        'requiredBy',
      ]}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
