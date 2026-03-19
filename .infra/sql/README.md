# Terraform - Streaming SQL Pipeline Infrastructure

Terraform configuration for the **CE → Event Hub → Stream Analytics → Azure SQL** streaming pipeline.

For the full deployment guide, schema reference, and troubleshooting, see [eventhub-sql-pipeline/README.md](../../solutions/eventhub-sql-pipeline/README.md).

## What Terraform Creates

| # | Resource | Purpose |
|---|---------|---------|
| 1 | Resource Group | Container for all pipeline resources |
| 2 | Event Hub Namespace + 2 Hubs | CE event ingestion (AVM module) |
| 3 | RBAC: CE → EH Data Sender | Trusted service auth for CE |
| 4 | RBAC: ASA → EH Data Receiver | MI auth for ASA inputs |
| 5 | SQL Server (Entra-only) | Logical SQL server |
| 6 | Findings Database (GP_S_Gen5_2) | Raw staging + typed tables |
| 7 | Job Metadata Database (S0) | Elastic Job Agent metadata |
| 8 | User-Assigned Managed Identity | Elastic Job Agent auth |
| 9 | Elastic Job Agent | Scheduled MERGE execution |
| 10 | Stream Analytics × 2 | Event Hub → SQL _Raw passthrough |
| 11 | CE Automations × 2 | Defender → Event Hub export |

## What Terraform Does NOT Create

Handled by the **bootstrap scripts** (`solutions/eventhub-sql-pipeline/bootstrap/`):

- SQL schema (raw tables, typed tables, indexes)
- Stored procedures (`usp_MergeSecurityAssessments`, `usp_MergeSecuritySubAssessments`)
- SQL permissions (ASA MI users, Elastic Job UMI permissions)
- Elastic Job target group, job, and steps

## File Structure

```
.infra/sql/
├── providers.tf               # azurerm ~4.0 provider config
├── variables.tf               # All input variables with defaults
├── main.tf                    # All resources (~15 resource types)
├── outputs.tf                 # Resource IDs, FQDNs, pipeline summary
├── terraform.tfvars.example   # Example variable values
└── README.md                  # This file
```
