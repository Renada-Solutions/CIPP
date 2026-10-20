# Preview

This page shows, for the selected tenant, every requirement of the chosen AI Access Policies, the tenant's current state, and the change the AI Access Policy standard would make with remediation enabled. It never changes anything.

Leave the policy selector empty to preview the policies the standard already applies to the tenant.

## Info Cards

* Compliant: requirements already met.
* Changes CIPP would make: requirements CIPP can fix.
* Need action outside CIPP: blocked requirements (for example a missing group) and manual controls not yet confirmed.
* Not applicable: for example an approved app not added to this tenant, or a Copilot SKU the tenant does not buy.

## Table Details

| Column | Description |
| --- | --- |
| Status | Compliant, NonCompliant, Blocked or NotApplicable. |
| Control | UserConsent, CopilotLicence, ApprovedAiApp or Manual. |
| Item | The SKU, app or manual control. |
| Target | The group, or All users. |
| Expected / Current | The policy's requirement and what the tenant has now. |
| Change | The change CIPP would make, if any. |
| Detail | Why, in a sentence. |
| From | The policies that asked for this requirement. |

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
