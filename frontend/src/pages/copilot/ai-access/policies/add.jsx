import { Box } from '@mui/material'
import { useForm } from 'react-hook-form'
import CippFormPage from '../../../../components/CippFormPages/CippFormPage'
import CippAIAccessPolicyForm from '../../../../components/CippFormPages/CippAIAccessPolicyForm'
import { Layout as DashboardLayout } from '../../../../layouts/index.js'
import { aiAccessPolicyDefaults } from '../../../../utils/ai-workforce'

const Page = () => {
  const formControl = useForm({
    mode: 'onChange',
    defaultValues: aiAccessPolicyDefaults,
  })

  return (
    <CippFormPage
      formControl={formControl}
      queryKey="ListAIAccessPolicyTemplates"
      title="AI Access Policy"
      backButtonTitle="AI Access Policies"
      backUrl="/copilot/ai-access/policies"
      postUrl="/api/AddAIAccessPolicyTemplate"
    >
      <Box sx={{ my: 2 }}>
        <CippAIAccessPolicyForm formControl={formControl} />
      </Box>
    </CippFormPage>
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
