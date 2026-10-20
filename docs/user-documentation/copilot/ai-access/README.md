# AI Access

AI Access lets you decide who can use which AI in each client tenant, write those rules once as **AI Access Policies**, and have CIPP apply them through the Microsoft controls that enforce them.

A policy applies to all users (a baseline) or to one group, matched by name in every tenant. Policies layer: when several apply to a tenant, the stricter setting wins. They are deployed with the **AI Access Policy** standard, which supports report, alert and remediate like any other standard.

What a policy can control today:

| Setting | Enforced by | Needs |
| --- | --- | --- |
| Copilot licence for a group (grant or deny) | Group-based licensing | A Microsoft 365 Copilot subscription |
| Users consenting to apps themselves | The tenant's app consent policy | Nothing extra |
| Approved enterprise AI apps (for example ChatGPT Enterprise, Claude Enterprise) | Assignment required on the enterprise app, with the policy's group assigned | The app already added to the tenant; Entra ID P1 for Conditional Access on top |
| Manual controls | The AI Access checklist | A person confirming each one |

Some AI controls have no Microsoft or vendor API, for example scoping AI model providers or limiting who can build agents. A policy can still require them: they appear on the [checklist](checklist.md), where a technician confirms they were set.

{% hint style="warning" %}
Always [preview](preview.md) a policy against a tenant before enabling remediation. Requiring assignment on an AI app stops everyone outside the assigned groups from signing in to it.
{% endhint %}

## Permissions

The pages need the `Tenant.AI.Read` CIPP permission to view and `Tenant.AI.ReadWrite` to change policies or confirm checklist items. The built-in readonly, editor and admin roles include them.

## Layering policies across standards templates

The standard takes a list of policies. If a client has its own standards template as well as an all-tenants one, select every policy that should apply in the client's template, including the baseline: a tenant-specific standard replaces the all-tenants one rather than adding to it.

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
