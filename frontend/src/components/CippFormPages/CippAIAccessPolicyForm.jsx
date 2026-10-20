import { Alert, Divider, Typography } from '@mui/material'
import { Grid } from '@mui/system'
import CippFormComponent from '../CippComponents/CippFormComponent'
import { CippFormCondition } from '../CippComponents/CippFormCondition'
import manualControls from '../../data/AIAccessManualControls.json'
import {
  aiAccessLicenceModes,
  aiAccessManualControlOptions,
  copilotSkuOptions,
} from '../../utils/ai-workforce'

// Form for an AI Access Policy template. The backend (ConvertTo-CIPPAIAccessPolicy) validates and
// normalises what this posts, so field names here match its form input.
const CippAIAccessPolicyForm = ({ formControl }) => (
  <Grid container spacing={2}>
    <CippFormComponent type="hidden" name="GUID" formControl={formControl} />

    <Grid size={{ md: 6, xs: 12 }}>
      <CippFormComponent
        type="textField"
        label="Policy name"
        name="name"
        disableVariables
        required
        formControl={formControl}
        validators={{ required: 'A policy name is required' }}
        fullWidth
      />
    </Grid>
    <Grid size={{ md: 6, xs: 12 }}>
      <CippFormComponent
        type="textField"
        label="Description"
        name="description"
        disableVariables
        formControl={formControl}
        fullWidth
      />
    </Grid>

    <Grid size={{ xs: 12 }}>
      <Divider />
      <Typography variant="h6" sx={{ mt: 2 }}>
        Who this policy applies to
      </Typography>
    </Grid>
    <Grid size={{ xs: 12 }}>
      <CippFormComponent
        type="radio"
        name="targetType"
        formControl={formControl}
        options={[
          { label: 'All users (baseline)', value: 'allUsers' },
          { label: 'A group', value: 'group' },
        ]}
      />
    </Grid>
    <CippFormCondition
      formControl={formControl}
      field="targetType"
      compareType="is"
      compareValue="group"
    >
      <Grid size={{ md: 6, xs: 12 }}>
        <CippFormComponent
          type="textField"
          label="Group display name"
          name="groupName"
          disableVariables
          placeholder="For example: AI - Finance users"
          helperText="Matched by name in each tenant, so the same group name targets the same team everywhere."
          formControl={formControl}
          validators={{
            required: 'A group name is required for a group policy',
          }}
          fullWidth
        />
      </Grid>
    </CippFormCondition>

    <Grid size={{ xs: 12 }}>
      <Divider />
      <Typography variant="h6" sx={{ mt: 2 }}>
        Microsoft 365 Copilot
      </Typography>
    </Grid>
    <CippFormCondition
      formControl={formControl}
      field="targetType"
      compareType="is"
      compareValue="allUsers"
    >
      <Grid size={{ xs: 12 }}>
        <Alert severity="info">
          Copilot licences are assigned to groups. Choose a group target to
          manage licences.
        </Alert>
      </Grid>
    </CippFormCondition>
    <CippFormCondition
      formControl={formControl}
      field="targetType"
      compareType="is"
      compareValue="group"
    >
      <Grid size={{ md: 6, xs: 12 }}>
        <CippFormComponent
          type="autoComplete"
          label="Copilot licence for this group"
          name="copilotLicenceMode"
          multiple={false}
          creatable={false}
          options={aiAccessLicenceModes}
          formControl={formControl}
        />
      </Grid>
      <Grid size={{ md: 6, xs: 12 }}>
        <CippFormComponent
          type="autoComplete"
          label="Copilot SKUs (defaults to all Microsoft 365 Copilot SKUs)"
          name="copilotSkus"
          multiple={true}
          creatable={true}
          options={copilotSkuOptions}
          formControl={formControl}
        />
      </Grid>
    </CippFormCondition>

    <Grid size={{ xs: 12 }}>
      <Divider />
      <Typography variant="h6" sx={{ mt: 2 }}>
        Third-party and enterprise AI apps
      </Typography>
    </Grid>
    <Grid size={{ xs: 12 }}>
      <CippFormComponent
        type="switch"
        label="Block users from consenting to apps themselves (applies to the whole tenant)"
        name="userConsent"
        formControl={formControl}
      />
    </Grid>
    <CippFormCondition
      formControl={formControl}
      field="targetType"
      compareType="is"
      compareValue="group"
    >
      <Grid size={{ xs: 12 }}>
        <CippFormComponent
          type="textField"
          label="Approved AI apps for this group"
          name="approvedAiApps"
          disableVariables
          placeholder={
            'One per line: application ID, display name\n11111111-1111-1111-1111-111111111111, ChatGPT Enterprise'
          }
          helperText="CIPP assigns this group to each app, then requires assignment so only assigned users and groups can sign in. Apps not added to a tenant are skipped."
          formControl={formControl}
          multiline
          rows={4}
          fullWidth
        />
      </Grid>
    </CippFormCondition>

    <Grid size={{ xs: 12 }}>
      <Divider />
      <Typography variant="h6" sx={{ mt: 2 }}>
        Manual controls
      </Typography>
      <Typography variant="body2" color="text.secondary">
        These have no Microsoft or vendor API. CIPP lists them on the AI Access
        checklist for each tenant and records who confirmed them; a review is
        due every 90 days.
      </Typography>
    </Grid>
    <Grid size={{ xs: 12 }}>
      <CippFormComponent
        type="autoComplete"
        label="Manual controls this policy requires"
        name="manualControls"
        multiple={true}
        creatable={false}
        options={aiAccessManualControlOptions(manualControls)}
        formControl={formControl}
      />
    </Grid>
  </Grid>
)

export default CippAIAccessPolicyForm
