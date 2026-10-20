import { useEffect } from 'react'
import { Box } from '@mui/material'
import { useForm } from 'react-hook-form'
import { useRouter } from 'next/router'
import CippFormPage from '../../../../components/CippFormPages/CippFormPage'
import CippAIAccessPolicyForm from '../../../../components/CippFormPages/CippAIAccessPolicyForm'
import { Layout as DashboardLayout } from '../../../../layouts/index.js'
import { ApiGetCall } from '../../../../api/ApiCall'
import manualControls from '../../../../data/AIAccessManualControls.json'
import {
  aiAccessPolicyDefaults,
  aiAccessPolicyToFormValues,
} from '../../../../utils/ai-workforce'

const Page = () => {
  const router = useRouter()
  const { id } = router.query
  const formControl = useForm({
    mode: 'onChange',
    defaultValues: aiAccessPolicyDefaults,
  })

  const template = ApiGetCall({
    url: `/api/ListAIAccessPolicyTemplates?ID=${id}`,
    queryKey: `AIAccessPolicyTemplate-${id}`,
    waiting: !!id,
  })

  useEffect(() => {
    const policy = template.data?.[0]
    if (template.isSuccess && policy) {
      formControl.reset(aiAccessPolicyToFormValues(policy, manualControls))
      formControl.trigger()
    }
  }, [template.isSuccess, template.data, formControl])

  return (
    <CippFormPage
      formControl={formControl}
      queryKey={['ListAIAccessPolicyTemplates', `AIAccessPolicyTemplate-${id}`]}
      formPageType="Edit"
      title="AI Access Policy"
      backButtonTitle="AI Access Policies"
      backUrl="/copilot/ai-access/policies"
      postUrl="/api/AddAIAccessPolicyTemplate"
      isFetching={template.isFetching}
    >
      <Box sx={{ my: 2 }}>
        <CippAIAccessPolicyForm formControl={formControl} />
      </Box>
    </CippFormPage>
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
