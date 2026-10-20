# Agents

This page lists every AI agent in the selected tenant, or across all clients. An Entra agent identity and the Agent 365 package that references it are shown as one row.

## Action Buttons

<details>

<summary>Sync agent data</summary>

Queues a refresh of the cached data the list is built from. The list updates once the sync completes.

</details>

## Table Details

| Column             | Description                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------- |
| Display Name       | The agent's name.                                                                            |
| Attention Severity | The most severe open attention item: Critical, Warning, Info or None.                       |
| Attention Count    | How many attention items are open for the agent.                                             |
| Status             | Enabled, Disabled, Disabled by Microsoft, Blocked, or Available (catalog agent with no identity). |
| Source             | Entra Agent ID, Agent 365, or both.                                                          |
| Publisher          | The package publisher, or the blueprint's publisher domain.                                  |
| Agent Type         | The Agent 365 classification (for example HostedAgent or PromptAgent), or Agent identity.    |
| Sponsor Status     | Assigned, None, Unknown (sponsors could not be read) or Not applicable.                      |
| Access Level       | None, Read, or Read and write, based on the agent's granted permissions.                     |
| Risk Level         | The Identity Protection risk level, if any.                                                  |
| Created Date Time  | When the agent identity or package was created.                                              |

## Table Filters

Critical, Warning, No sponsor, Can change data, Disabled and Blocked.

## Extended Info

Selecting a row opens a panel with the agent's attention items and their fixes, its properties, sponsors and owners, and every permission it holds with its resource, type (application or delegated), read or write access and risk.

***

{% include "../../../../.gitbook/includes/feature-request.md" %}
