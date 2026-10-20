# Policies

This page lists AI Access Policy templates. Policies are global: deploy them to tenants with the **AI Access Policy** standard.

## Action Buttons

<details>

<summary>Add policy</summary>

Opens the policy editor.

</details>

## Policy settings

| Setting | Description |
| --- | --- |
| Policy name, Description | How the policy appears in CIPP and in the standard. |
| Applies to | All users (a baseline), or a group by display name. Licence and approved app rules need a group. |
| Copilot licence for this group | Not managed; Grant (assign the Copilot SKUs to the group); or Deny (remove group-based Copilot from the group). Licences assigned directly to users are not changed. Deny acts only on this group: a user who is also in another group that grants Copilot keeps it. |
| Copilot SKUs | Which SKUs the rule covers. Leave empty for all Microsoft 365 Copilot SKUs; SKUs a tenant does not subscribe to are skipped. |
| Block users from consenting to apps themselves | Tenant-wide. Removes user self-consent policies; the CIPP consent policy from the "Require admin consent" standard counts as compliant. |
| Approved AI apps for this group | One per line: application ID, display name. CIPP assigns the group to each app, then requires assignment. |
| Manual controls | Controls with no API that this policy requires; tracked on the checklist. |

When policies overlap, the stricter setting wins: block beats not managed, deny beats grant, and an approved app is assigned to every group that approves it.

## Table Actions

<table><thead><tr><th>Action</th><th>Description</th><th data-type="checkbox">Bulk Action Available</th></tr></thead><tbody><tr><td>Edit policy</td><td>Opens the policy in the editor</td><td>false</td></tr><tr><td>Preview against current tenant</td><td>Opens the preview for this policy and the selected tenant</td><td>false</td></tr><tr><td>Delete policy</td><td>Deletes the template; changes already made in tenants stay in place</td><td>false</td></tr></tbody></table>

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
