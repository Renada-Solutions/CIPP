# Overview

This page summarises the AI agent workforce for the selected tenant, or for every client when **All Tenants** is selected.

## Action Buttons

<details>

<summary>Sync agent data</summary>

Queues a refresh of the cached agent identities, blueprints, Agent 365 packages, risky agents, service principals, app role assignments and delegated permission grants. The page updates once the sync completes.

</details>

## Info Cards

* Agents: the number of agents, with how many are active (or, for All Tenants, how many clients have agents).
* Need attention: agents with at least one open attention item, and how many of those are critical.
* No sponsor: enabled agents with no accountable sponsor assigned.
* Can change data: agents holding at least one permission that can write, send or delete data.

## Needs attention

Every open attention item, most severe first, with the action that fixes it.

| Issue                                   | Severity           | What to do                                                          |
| --------------------------------------- | ------------------ | ------------------------------------------------------------------- |
| Disabled by Microsoft                   | Critical           | Review the agent and its blueprint in Microsoft Entra.              |
| Identity Protection risk                | By risk level      | Investigate in Entra ID Protection, then disable or confirm safe.   |
| Can change data but has no sponsor      | Critical           | Assign a sponsor who is accountable for the agent.                  |
| No sponsor assigned                     | Warning            | Assign a sponsor who is accountable for the agent.                  |
| All blueprint credentials have expired  | Critical           | Rotate the blueprint credential in Microsoft Entra.                 |
| Blueprint credential expires in N days  | Warning (30 days)  | Rotate the blueprint credential in Microsoft Entra.                 |
| Holds a high or critical-risk permission | Warning / Critical | Review the permissions granted to the agent.                       |
| User request pending                    | Info               | Approve or reject the request in the Microsoft 365 admin center.    |

Permission risk uses the same catalogue as the rest of CIPP (`RiskyPermissions.json`). Disabled and blocked agents only raise the Microsoft, risk and request items.

## Clients (All Tenants)

One row per client with agent counts, attention counts and when the data was last refreshed. **View agents** opens the agent list for that client.

## Data sources (single tenant)

Shows whether each data source has been collected for the tenant, how many items it returned and when.

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
