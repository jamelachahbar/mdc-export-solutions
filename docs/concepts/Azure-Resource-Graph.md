---
title: Azure Resource Graph
description: A cross-subscription query service that lets you explore Azure resources at scale using KQL - no streaming infrastructure required.
---

# <img src="../assets/icons/resource-graph.svg" alt="" width="32"/> Azure Resource Graph

**Azure Resource Graph** (ARG) is an Azure service that provides efficient, cross-subscription resource exploration. It uses Kusto Query Language (KQL) to query resource metadata and properties indexed by Azure Resource Manager.

> Official docs: [Azure Resource Graph](https://learn.microsoft.com/en-us/azure/governance/resource-graph/)

## Why it matters

Azure Resource Graph is the simplest way to get Defender for Cloud findings out of Azure - no Event Hub, no Stream Analytics, no SQL. It provides:

- **Zero infrastructure** - nothing to deploy; just run a query.
- **Cross-subscription** - query findings across all subscriptions you have access to in a single call.
- **KQL power** - filter, join, summarize, and project results using a familiar query language.
- **Point-in-time snapshots** - get the current state of all findings right now.

The tradeoff: ARG gives you the **current state**, not a historical stream. If you need trend analysis or real-time alerting, use the [Event Hub SQL pipeline](/solutions/eventhub-sql-pipeline/) instead.

## Key details

| Property | Value |
|----------|-------|
| **Service** | Azure Resource Graph |
| **Query language** | Kusto Query Language (KQL) |
| **Scope** | Cross-subscription (all subscriptions the caller can access) |
| **Row limit** | 1,000 rows per page (use `$skipToken` for pagination) |
| **Latency** | Seconds (resource index is near-real-time but not streaming) |
| **Authentication** | Entra ID (Azure CLI, managed identity, service principal) |


## Streaming vs. point-in-time

| | Streaming Pipeline | Resource Graph Export |
|-|----------------------|---------------------------|
| **Data freshness** | Near-real-time (minutes) | Point-in-time (current state) |
| **History** | Full event history in SQL | No historical data |
| **Infrastructure** | Event Hub + ASA + SQL | None |

| **Best for** | Dashboards, trend analysis, alerting | Ad-hoc queries, CSV exports, audits |

## Example query

```kql
securityresources
| where type == "microsoft.security/assessments"
| where properties.status.code == "Unhealthy"
| extend
    assessmentName = properties.displayName,
    severity = properties.status.severity,
    resourceId = properties.resourceDetails.Id
| project assessmentName, severity, resourceId
| order by severity desc
```

## Pagination in scripts

ARG returns a maximum of 1,000 rows per request. The `Export-ArgFindings.ps1` script handles this automatically:

```powershell
do {
    $result = Search-AzGraph -Query $query -First $BatchSize -SkipToken $skipToken
    $allResults += $result.Data
    $skipToken = $result.SkipToken
} while ($skipToken)
```

## Related

- [Continuous Export](Continuous-Export.md) - the streaming alternative through Defender for Cloud
- [Event Hub](Event-Hub.md) - used in the streaming pipeline but not needed for ARG
- [Resource Graph export scripts](/solutions/resource-graph-export/) - ARG export scripts and KQL queries
- [Event Hub SQL pipeline guide](/solutions/eventhub-sql-pipeline/README.md) - the full streaming alternative
