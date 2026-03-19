---
title: Continuous Export
description: A Defender for Cloud feature that streams security findings to Event Hub or Log Analytics in near-real-time.
---

# <img src="../assets/icons/continuous-export.svg" alt="" width="32"/> Continuous Export

**Continuous Export** is a Microsoft Defender for Cloud capability that automatically sends security assessment data (recommendations, alerts, and regulatory compliance changes) to an external destination as soon as they are generated.

> Official docs: [Continuous export](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export)

## Why it matters

Without Continuous Export, Defender for Cloud findings live only inside the Azure portal. Enabling it unlocks:

- **Near-real-time streaming** - findings arrive within minutes, not hours.
- **Custom pipelines** - route data to Event Hub, Log Analytics, or both, then transform and store it however you need.
- **Cross-subscription visibility** - aggregate findings from many subscriptions into a single downstream store.

<p align="center">
  <img src="../assets/images/flow-defender-to-ce.svg" alt="Defender for Cloud streaming findings via Continuous Export" width="600"/>
</p>

## Key details

| Property | Value |
|----------|-------|
| **Source** | Microsoft Defender for Cloud |
| **Destinations** | Azure Event Hub, Log Analytics workspace |
| **Data types** | Security assessments, sub-assessments, alerts, regulatory compliance |
| **Latency** | Minutes (near-real-time) |
| **Configuration** | Per-subscription; portal, CLI, Terraform, or [Azure Policy (recommended at scale)](Azure-Policy-Continuous-Export.md) |


## How it works

1. Defender for Cloud evaluates resources and produces findings (assessments).
2. Continuous Export picks up new or changed findings.
3. Each finding is serialized as JSON and sent to the configured destination.
4. Downstream consumers (Stream Analytics, Logic Apps, custom code) process the events.

In this repository, the [Event Hub SQL pipeline](/solutions/eventhub-sql-pipeline/) uses Continuous Export → Event Hub as the first step.

## Related

- [Azure Policy for Continuous Export](Azure-Policy-Continuous-Export.md) - deploy and enforce CE across all subscriptions at scale
- [Event Hub](Event-Hub.md) - the streaming ingestion service that receives exported findings
- [Stream Analytics](Stream-Analytics.md) - processes events from Event Hub in real time
- [Azure SQL Database](Azure-SQL-Database.md) - stores the final, deduplicated findings
- [Event Hub SQL pipeline guide](/solutions/eventhub-sql-pipeline/README.md) - full deployment walkthrough
- [Setup-ContinuousExport.ps1](/automation/Setup-ContinuousExport.ps1) - script to configure CE on subscriptions
