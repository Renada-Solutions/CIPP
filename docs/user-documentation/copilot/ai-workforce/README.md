# AI Workforce

AI Workforce gives you one view of the AI agents running across your clients: Microsoft Entra Agent ID agent identities and the Microsoft Agent 365 / Copilot catalog agents that reference them. It highlights the agents that need attention, such as agents without a sponsor or agents holding high-risk permissions, so you can act before they become a problem.

The pages read from the CIPP reporting database. Agent data is collected nightly with the rest of the reporting data, or on demand with the **Sync agent data** button.

{% hint style="info" %}
Microsoft Entra Agent ID is available to all tenants. The Agent 365 catalog needs a Microsoft Agent 365 licence, and risky agents come from Microsoft Entra ID Protection (preview). Sources that a tenant is not licensed for are skipped, and the **Data sources** table on the overview shows which ones were collected.
{% endhint %}

## Permissions

* Viewing the pages needs the `Tenant.AI.Read` CIPP permission. The built-in readonly, editor and admin roles include it.
* Reading agent sponsors uses the `AgentIdentity.ReadWrite.All` application permission, because Microsoft does not offer a read-only permission for sponsors. Until it has been consented for a tenant, sponsors show as **Unknown** and no sponsor alerts are raised for that tenant.

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
