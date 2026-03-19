# Resource Graph Export

Point-in-time export of **Microsoft Defender for Cloud** findings using Azure Resource Graph queries. No infrastructure to deploy - just run the scripts.

<p align="center">
  <img src="../../docs/assets/images/flow-resource-graph-export.svg" alt="Resource Graph Export data flow" width="700"/>
</p>

## How it works

Azure Resource Graph lets you query security findings across all subscriptions using KQL. The scripts in this folder run those queries and export results to CSV for reporting or Power BI.

## Key concepts

| Concept | Role in this solution |
|---------|----------------------|
| [Azure Resource Graph](../../docs/concepts/Azure-Resource-Graph.md) | Cross-subscription KQL queries against security findings |

## Scripts

| File | Description |
|------|-------------|
| [Export-ArgFindings.ps1](Export-ArgFindings.ps1) | Export ARG security findings to CSV |
| [Export-ForPowerBI.ps1](Export-ForPowerBI.ps1) | Export findings for Power BI (CSV & Log Analytics modes) |
| [resourcegraph.kql](resourcegraph.kql) | KQL queries used by the export scripts |

## When to use this

- You need a **point-in-time snapshot**, not continuous streaming
- You want **zero infrastructure** - no Event Hub, no SQL, no Terraform
- You need findings across **multiple subscriptions** in a single query
