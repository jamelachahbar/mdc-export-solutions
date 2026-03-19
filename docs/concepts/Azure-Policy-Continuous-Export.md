---
title: Azure Policy for Continuous Export
description: Deploy and enforce Continuous Export settings across all subscriptions at scale using a built-in Azure Policy.
---

# <img src="../assets/icons/azure-policy.svg" alt="" width="32"/> Azure Policy for Continuous Export

Configuring [Continuous Export](Continuous-Export.md) manually on each subscription works - but it doesn't scale. Azure Policy lets you deploy and enforce Continuous Export settings across all current and future subscriptions automatically.

> Official docs: [Set up Continuous Export at scale using Azure Policy](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export-azure-policy)

## Why it matters

Continuous Export is configured per subscription. In environments with dozens or hundreds of subscriptions, manual setup is:

- **Time-consuming** - every subscription needs identical configuration
- **Drift-prone** - new subscriptions or re-created resources lose CE settings silently
- **Audit-unfriendly** - no central view of which subscriptions are compliant

Azure Policy solves all three by making Continuous Export a policy-enforced standard.

## How it works

Microsoft provides a built-in policy definition for Continuous Export:

| Property | Value |
|----------|-------|
| **Policy name** | *Deploy export to Event Hub for Microsoft Defender for Cloud data* |
| **Effect** | `DeployIfNotExists` |
| **Scope** | Management group or subscription |
| **What it does** | Creates or updates the `default` Continuous Export configuration on every in-scope subscription |
| **Remediation** | Managed identity auto-creates the export setting; existing settings are updated to match |

There is a matching policy for Log Analytics destinations as well.

### Assignment flow

1. **Select the built-in policy** - in the Azure Portal, navigate to *Microsoft Defender for Cloud > Environment settings > Continuous export > Deploy with Azure Policy*.
2. **Set parameters** - choose the destination (Event Hub or Log Analytics), resource group, data types to export (assessments, sub-assessments, alerts, compliance).
3. **Assign at scale** - assign the policy to a management group to cover all child subscriptions, or to individual subscriptions.
4. **Create a remediation task** - this applies the policy to existing subscriptions that are already deployed.
5. **Verify compliance** - the policy compliance dashboard shows which subscriptions have Continuous Export configured.

### What gets exported

The policy parameters match the manual Continuous Export settings:

| Data type | Description |
|-----------|-------------|
| Security assessments | Recommendations and their status |
| Sub-assessments | Vulnerability findings (e.g., Qualys, MDVM) |
| Security alerts | Threat detection alerts |
| Regulatory compliance | Compliance assessment changes |

## Key benefits over manual setup

| Manual CE | Azure Policy CE |
|-----------|----------------|
| Configure each subscription individually | Assign once at management group level |
| New subscriptions need manual setup | New subscriptions auto-inherit the policy |
| No visibility into missing configurations | Compliance dashboard shows non-compliant subscriptions |
| Risk of configuration drift | Policy continuously remediates drift |

## When to use

- You have more than a handful of subscriptions
- You need to guarantee every subscription exports Defender data
- You want a compliance audit trail for Continuous Export configuration
- You are setting up the [Event Hub SQL pipeline](/solutions/eventhub-sql-pipeline/) across an organization

For single-subscription or proof-of-concept deployments, [manual configuration](Continuous-Export.md) or the [Setup-ContinuousExport.ps1](/automation/Setup-ContinuousExport.ps1) script is simpler.

## Related

- [Continuous Export](Continuous-Export.md) - the underlying feature that Policy automates
- [Event Hub](Event-Hub.md) - the destination for streamed findings
- [Event Hub SQL pipeline](/solutions/eventhub-sql-pipeline/README.md) - full deployment walkthrough
- [Setup-ContinuousExport.ps1](/automation/Setup-ContinuousExport.ps1) - script for single-subscription CE setup
