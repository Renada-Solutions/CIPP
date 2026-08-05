import { Layout as DashboardLayout } from '../../../layouts/index.js'
import { TabbedLayout } from '../../../layouts/TabbedLayout'
import { SchedulerTable } from '../../../components/CippComponents/SchedulerTable'
import tabOptions from './tabOptions'

/**
 * Planned tasks that would fail if they ran right now, most often because a licence they need has been
 * consumed since the task was booked. Flagged ahead of time by Start-CIPPTaskPreflightCheck so they can
 * be fixed before the scheduled time rather than after.
 */
const Page = () => {
  return (
    <SchedulerTable
      title="Pending with Issues"
      apiParams={{ AtRisk: true }}
      queryKeyPrefix="ListScheduledItems-atrisk"
      simpleColumns={[
        'ScheduledTime',
        'TaskState',
        'AtRiskReason',
        'Tenant',
        'Name',
        'Command',
        'Parameters',
        'Recurrence',
      ]}
    />
  )
}

Page.getLayout = (page) => (
  <DashboardLayout>
    <TabbedLayout tabOptions={tabOptions}>{page}</TabbedLayout>
  </DashboardLayout>
)

export default Page
