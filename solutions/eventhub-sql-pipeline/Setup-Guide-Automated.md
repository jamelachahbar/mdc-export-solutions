# Setup Guide - Automated (Terraform + Bootstrap)

Deploy the Defender for Cloud **CE → Event Hub → Stream Analytics → Azure SQL** pipeline using Terraform for infrastructure and PowerShell bootstrap scripts for SQL schema.

For the solution overview, see the [README](README.md). For a manual walkthrough (Portal + SQL), see [Setup-Guide-Manual.md](Setup-Guide-Manual.md).

---

**TABLE OF CONTENTS**

- [Architecture](#architecture)
- [What Gets Deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
  - [Step 1 — Deploy Infrastructure (Terraform)](#step-1--deploy-infrastructure-terraform)
  - [Step 2 — Run Bootstrap Scripts](#step-2--run-bootstrap-scripts)
  - [Step 3 — Configure Elastic Job Schedule](#step-3--configure-elastic-job-schedule)
  - [Step 4 — Start Stream Analytics Jobs](#step-4--start-stream-analytics-jobs)
  - [Step 5 — Wait for Data and Verify](#step-5--wait-for-data-and-verify)
- [Data Flow](#data-flow)
- [Unique Key](#unique-key)
- [Event Hub Partition Dedup Problem](#event-hub-partition-dedup-problem)
- [Timestamp Guard (Stale Event Protection)](#timestamp-guard-stale-event-protection)
- [Assessments — Schema Detail](#assessments--schema-detail)
- [Sub-Assessments — Schema Detail](#sub-assessments--schema-detail)
- [Troubleshooting](#troubleshooting)
- [Diagnostic Queries](#diagnostic-queries)
- [Scheduling](#scheduling)
- [Operational Notes](#operational-notes)
- [Files](#files)
- [Related Documentation](#related-documentation)


## Architecture

```
Defender for Cloud
    │
    │  Continuous Export (Streaming + Weekly Snapshots)
    ▼
Event Hub (2+ partitions, round-robin)
    │
    │  Azure Stream Analytics (passthrough)
    ▼
┌──────────────────────────┐
│  _Raw staging tables     │  ← land JSON as-is, one row per event
│  (SecurityAssessments_Raw│
│   SecuritySubAssess…_Raw)│
└──────────┬───────────────┘
           │  MERGE (Elastic Job, every 10 min)
           ▼
┌──────────────────────────┐
│  Typed tables            │  ← parsed columns, one row per unique id
│  (SecurityAssessments    │
│   SecuritySubAssessments)│
└──────────────────────────┘
```


## What Gets Deployed

| # | Resource | Created by | Purpose |
|---|----------|-----------|---------|
| 1 | Resource Group | Terraform | Container for all resources |
| 2 | Event Hub Namespace + 2 Hubs | Terraform | Receive CE events |
| 3 | RBAC: CE → EH Data Sender | Terraform | Trusted service auth for CE |
| 4 | RBAC: ASA → EH Data Receiver | Terraform | MI auth for ASA inputs |
| 5 | SQL Server (Entra-only) | Terraform | Logical SQL server |
| 6 | Findings Database (GP_S_Gen5_2) | Terraform | Raw + typed tables |
| 7 | Job Metadata Database (S0) | Terraform | Elastic Job Agent metadata |
| 8 | User-Assigned Managed Identity | Terraform | Elastic Job Agent auth |
| 9 | Elastic Job Agent + UMI | Terraform + azapi | Scheduled MERGE execution |
| 10 | Stream Analytics Jobs × 2 | Terraform | Event Hub → SQL passthrough |
| 11 | CE Automations × 2 | Terraform | Defender → Event Hub export |
| 12 | Raw + typed tables, indexes | Bootstrap | SQL schema |
| 13 | MERGE stored procedures | Bootstrap | OPENJSON + dedup + upsert |
| 14 | SQL MI permissions | Bootstrap | ASA + Elastic Job agent users |
| 15 | Elastic Job schedule | Bootstrap | Target group + job + steps |


## Prerequisites

- **Terraform** >= 1.9
- **Azure CLI** authenticated (`az login`)
- **PowerShell 7+** with the `SqlServer` module
- **Az PowerShell modules**: `Az.Accounts` (for Entra token acquisition)
- **Permissions**: Owner or Contributor + User Access Administrator on the target subscription
- **Entra ID**: You must be able to create SQL Entra admin and lookup service principals

```powershell
Install-Module Az.Accounts, SqlServer -Scope CurrentUser -Force
Connect-AzAccount
az login
```

---


## Deployment

### Step 1 — Deploy Infrastructure (Terraform)

```bash
cd .infra/sql/
cp terraform.tfvars.example terraform.tfvars   # edit with your values
```

Required variables in `terraform.tfvars`:

```hcl
subscription_id = "00000000-0000-0000-0000-000000000000"

# Optional — override defaults if needed
resource_group_name     = "rg-defender-sql-pipeline"
location                = "uksouth"
eventhub_namespace_name = "defender-sql-eventhub"    # must be globally unique
sql_server_name         = "defender-sql-server"      # must be globally unique
```

Deploy:

```bash
terraform init
terraform plan    # Review — expect ~15 resources
terraform apply
```

Save outputs for the next step:

```bash
terraform output sql_server_fqdn
terraform output elastic_job_umi_name
terraform output elastic_job_umi_client_id
terraform output asa_assessments_principal_id
terraform output asa_subassessments_principal_id
```

For Terraform variable/output details, see [.infra/sql/README.md](../.infra/sql/README.md).


### Step 2 — Run Bootstrap Scripts

The bootstrap creates SQL schema, stored procedures, and MI permissions. Terraform does not manage SQL DDL — this is intentional.

```powershell
cd solutions/eventhub-sql-pipeline/bootstrap/scripts/

./Initialize-Bootstrap.ps1 `
    -SqlServerFqdn          "defender-sql-server.database.windows.net" `
    -ElasticJobUmiName      "mi-elastic-job-agent" `
    -ElasticJobUmiClientId  "12345678-abcd-..." `
    -AsaAssessmentsPrincipalName    "asa-defender-assessments" `
    -AsaSubAssessmentsPrincipalName "asa-defender-subassessments" `
    -SkipDatabaseCreation `
    -SkipMasterUser
```

> Use `-SkipDatabaseCreation` because Terraform already created both databases.
> Use `-SkipMasterUser` unless you need server-level Elastic Job targets.
> Use `-SkipAsaStart` to skip starting Stream Analytics jobs (e.g., if no data is expected yet).

For the full parameter reference, see [bootstrap/README.md](bootstrap/README.md).


### Step 3 — Configure Elastic Job Schedule

> **Automated**: The bootstrap script creates the Elastic Job schedule automatically as its final step — target group, job (every 10 minutes), and both merge steps.
>
> No manual action needed unless you want to customize the schedule:

```sql
-- Run on the Job Metadata Database
EXEC jobs.sp_update_job
    @job_name                = 'MergeDefenderData',
    @schedule_interval_type  = 'Minutes',
    @schedule_interval_count = 10;          -- change to desired interval
```

Verify:

```sql
SELECT job_name, enabled, schedule_interval_type, schedule_interval_count
FROM   jobs.jobs
WHERE  job_name = 'MergeDefenderData';
-- Expected: MergeDefenderData | 1 | Minutes | 10
```


### Step 4 — Start Stream Analytics Jobs

> **Automated**: The bootstrap script automatically discovers and starts ASA jobs via `Get-AzResource`. Skip this step unless you used `-SkipAsaStart`.
>
> To start them manually, or if you used `-SkipAsaStart`:

```bash
az stream-analytics job start \
    --resource-group "rg-defender-sql-pipeline" \
    --name "asa-defender-assessments" \
    --output-start-mode "JobStartTime"

az stream-analytics job start \
    --resource-group "rg-defender-sql-pipeline" \
    --name "asa-defender-subassessments" \
    --output-start-mode "JobStartTime"
```


### Step 5 — Wait for Data and Verify

| Event type | When to expect |
|------------|---------------|
| Streaming events | When a resource's health state changes (minutes to days) |
| Snapshot events | Full state dump once per week per subscription |
| First snapshot | Up to 24 hours after CE is created |

**Verification checklist:**

| What to check | Where | Expected |
|---------------|-------|----------|
| CE automations enabled | Portal → Defender → Continuous export | Both show "On" |
| Event Hub incoming messages | Portal → EH Namespace → Metrics | > 0 (may take hours) |
| ASA jobs running | Portal → ASA jobs → Overview | Status = "Running" |
| ASA input/output errors | ASA job → Monitoring → Errors | No errors |
| `_Raw` tables have data | `SELECT COUNT(*) FROM dbo.SecurityAssessments_Raw` | > 0 |
| Typed tables have data | `SELECT COUNT(*) FROM dbo.SecurityAssessments` | > 0 after Elastic Job runs |
| Elastic Job executing | `SELECT TOP 5 * FROM jobs.job_executions ORDER BY start_time DESC` | `lifecycle = 'Succeeded'` |

```sql
-- Quick row-count check (run on Findings Database)
SELECT 'Assessments_Raw' AS [Table], COUNT(*) AS [Rows] FROM dbo.SecurityAssessments_Raw
UNION ALL
SELECT 'SubAssessments_Raw', COUNT(*) FROM dbo.SecuritySubAssessments_Raw
UNION ALL
SELECT 'Assessments', COUNT(*) FROM dbo.SecurityAssessments
UNION ALL
SELECT 'SubAssessments', COUNT(*) FROM dbo.SecuritySubAssessments;

-- Manually trigger MERGE if impatient
EXEC dbo.usp_MergeSecurityAssessments;
EXEC dbo.usp_MergeSecuritySubAssessments;
```

For a **manual deployment** (Portal + SQL, no Terraform), see [Setup-Guide-Manual.md](Setup-Guide-Manual.md). For the solution overview, see [README.md](README.md).

---


## Data Flow

### 1. Continuous Export delivers events to Event Hub

CE sends events in **ARM REST API format** (not Log Analytics format). Two frequencies:

| Event Source | Frequency | Behaviour |
|---|---|---|
| `Assessments` / `SubAssessments` | Streaming | Sent when a resource's health state changes |
| `AssessmentsSnapshot` / `SubAssessmentsSnapshot` | Snapshot | Full state dump once per week per subscription |

### 2. Events land in `_Raw` staging tables

Stream Analytics writes raw JSON into the staging table. Every column from the Event Hub envelope is preserved:

| Column | Source | Purpose |
|---|---|---|
| `id` | ARM resource path | Natural unique key |
| `properties` | Nested JSON | Parsed by MERGE via `OPENJSON` |
| `assessmentEventDataEnrichment` | CE envelope | Contains `action` (Insert/Delete) |
| `EventEnqueuedUtcTime` | Event Hub metadata | Ordering tiebreaker for dedup |
| `PartitionId` | Event Hub metadata | Diagnostic — which partition delivered this event |
| `InsertedAtUtc` | `SYSUTCDATETIME()` | When the row landed in SQL |

### 3. MERGE upserts into typed tables

Run the MERGE on a schedule (default: every 10 minutes via Elastic Job). It handles three scenarios:

| MERGE Action | Trigger | Behaviour |
|---|---|---|
| **INSERT** | New `id` + `action = 'Insert'` | First time we see this assessment — insert all columns |
| **UPDATE** | Existing `id` + `action = 'Insert'` | Re-evaluation — update mutable columns only |
| **DELETE** | Existing `id` + `action = 'Delete'` | Resource deleted or recommendation deprecated — remove row |

### 4. Truncate `_Raw` after successful MERGE

After the MERGE completes, the stored procedure truncates the staging table to prevent reprocessing.


## Unique Key

The `id` field is the **natural unique key** — the full ARM resource path:

```
/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/vm1/providers/Microsoft.Security/assessments/{guid}
```

- **`id` is unique per assessment+resource pair** — different resources with the same recommendation get different `id` values
- **`name` (the GUID) is NOT unique** — the same recommendation GUID appears for every resource it evaluates
- The same `id` appears multiple times in the stream (re-evaluations, snapshots) — the MERGE handles this as an upsert

### Primary Key Considerations

`id` can be up to ~1000 characters. SQL Server's clustered index key limit is 900 bytes. Options:

| Approach | Pros | Cons |
|---|---|---|
| No PK constraint | Simplest, MERGE works fine | No uniqueness enforcement at DB level |
| `UNIQUE NONCLUSTERED` on `id` | Enforces uniqueness | May exceed 900-byte limit on long ARM paths |
| Computed hash PK | `HASHBYTES('SHA2_256', id)` as `BINARY(32)` PK | Compact, fits within limits |

The SubAssessments table uses `CONSTRAINT PK_SecuritySubAssessments PRIMARY KEY (id)` — sub-assessment ARM paths typically stay within the 900-byte limit.


## Event Hub Partition Dedup Problem

**Problem**: CE does not set a partition key. Event Hub distributes events via round-robin. The same assessment `id` can land on **different partitions** across evaluation cycles:

```
Monday    → Partition 0: id=".../assessments/abc" (Unhealthy)
Wednesday → Partition 1: id=".../assessments/abc" (Healthy)
Friday    → Partition 0: id=".../assessments/abc" (snapshot, Healthy)
```

All three rows end up in `_Raw`. Without dedup, the MERGE fails:

> *The MERGE statement attempted to UPDATE or DELETE the same row more than once.*

**Solution**: `ROW_NUMBER()` in the MERGE source CTE keeps only the latest event per `id`:

```sql
SELECT *,
    ROW_NUMBER() OVER (
        PARTITION BY id
        ORDER BY EventEnqueuedUtcTime DESC
    ) AS _rn
FROM dbo.SecurityAssessments_Raw
...
WHERE r._rn = 1
```


## Timestamp Guard (Stale Event Protection)

Even after dedup within one batch, a **previous batch** might have already processed a newer event. The `LastEnqueuedUtcTime` column on the typed table tracks the `EventEnqueuedUtcTime` of the last processed event for each row.

The MERGE UPDATE/DELETE clauses include a guard:

```sql
WHEN MATCHED AND source.ActionType = 'Insert'
    AND (target.LastEnqueuedUtcTime IS NULL OR source.EventEnqueuedUtcTime >= target.LastEnqueuedUtcTime)
    THEN UPDATE SET ...
```

This prevents an older event from overwriting a newer state.

---

## Assessments — Schema Detail

An assessment is a recommendation applied to a resource — e.g., "MFA should be enabled on your subscription". One per resource per recommendation (aligns with `SecurityRecommendation` in Log Analytics).

### Unique Key

```
/subscriptions/{sub}/resourceGroups/{rg}/providers/.../providers/Microsoft.Security/assessments/{assessmentGuid}
```

One row per **recommendation + resource** combination.

### Typed Table Schema

https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/securityrecommendation

| Column | Type | Source | Mutable | Description |
|---|---|---|---|---|
| `tenantId` | `UNIQUEIDENTIFIER` | Envelope | No | Azure AD tenant |
| `id` | `NVARCHAR(1000)` | Envelope | No | **Unique key** — full ARM path |
| `name` | `NVARCHAR(200)` | Envelope | No | Assessment GUID (NOT unique alone) |
| `type` | `NVARCHAR(200)` | Envelope | No | `Microsoft.Security/assessments` |
| `location` | `NVARCHAR(200)` | Envelope | No | Resource location |
| `kind` | `NVARCHAR(200)` | Envelope | No | Resource kind |
| `tags` | `NVARCHAR(MAX)` | Envelope | No | Resource tags JSON |
| `displayName` | `NVARCHAR(500)` | `$.displayName` | No | Recommendation name |
| `description` | `NVARCHAR(MAX)` | `$.description` | No | Recommendation description |
| `statusCode` | `NVARCHAR(50)` | `$.status.code` | **Yes** | `Healthy`, `Unhealthy`, `NotApplicable` |
| `severity` | `NVARCHAR(50)` | `$.status.severity` | **Yes** | `High`, `Medium`, `Low` |
| `statusCause` | `NVARCHAR(100)` | `$.status.cause` | **Yes** | Programmatic cause |
| `statusDescription` | `NVARCHAR(MAX)` | `$.status.description` | **Yes** | Human-readable status |
| `policyDefinitionId` | `NVARCHAR(1000)` | `$.metadata.policyDefinitionId` | No | Backing Azure Policy ARM ID |
| `assessmentType` | `NVARCHAR(100)` | `$.metadata.assessmentType` | No | `BuiltIn`, `CustomPolicy` |
| `implementationEffort` | `NVARCHAR(100)` | `$.metadata.implementationEffort` | No | `Low`, `Moderate`, `High` |
| `userImpact` | `NVARCHAR(200)` | `$.metadata.userImpact` | No | `Low`, `Moderate`, `High` |
| `categories` | `NVARCHAR(400)` | `$.metadata.categories` | No | `Compute`, `Networking`, `Data`, etc. |
| `threats` | `NVARCHAR(400)` | `$.metadata.threats` | No | `dataExfiltration`, `denialOfService`, etc. |
| `resourceId` | `NVARCHAR(1000)` | `$.resourceDetails.id` | No | Assessed resource ARM ID |
| `resourceName` | `NVARCHAR(400)` | `$.resourceDetails.resourceName` | No | Resource display name |
| `resourceType` | `NVARCHAR(400)` | `$.resourceDetails.resourceType` | No | e.g., `Microsoft.Compute/virtualMachines` |
| `resourceProvider` | `NVARCHAR(400)` | `$.resourceDetails.resourceProvider` | No | e.g., `Microsoft.Compute` |
| `source` | `NVARCHAR(100)` | `$.resourceDetails.source` | No | `Azure`, `OnPremise`, `OnPremiseSql` |
| `riskLevel` | `NVARCHAR(50)` | `$.risk.level` | **Yes** | `Critical`, `High`, `Medium`, `Low` |
| `riskAttackPaths` | `INT` | `$.risk.attackPathsReferences` | **Yes** | Number of attack paths |
| `firstEvaluationDate` | `DATETIME2` | `$.status.firstEvaluationDate` | No | When Defender first evaluated |
| `statusChangeDate` | `DATETIME2` | `$.status.statusChangeDate` | **Yes** | Last compliance state change |
| `timeGenerated` | `DATETIME2` | `$.timeGenerated` | **Yes** | Event timestamp |
| `properties` | `NVARCHAR(MAX)` | Raw JSON | **Yes** | Full properties backup |
| `LastEnqueuedUtcTime` | `DATETIME2` | `EventEnqueuedUtcTime` | **Yes** | Watermark — last processed event time |

### MERGE Update Strategy

**Updated on re-evaluation (mutable):** `statusCode`, `severity`, `statusCause`, `statusDescription`, `riskLevel`, `riskAttackPaths`, `statusChangeDate`, `timeGenerated`, `properties`, `LastEnqueuedUtcTime`

**Set once on INSERT (immutable):** `tenantId`, `id`, `name`, `type`, `location`, `kind`, `tags`, `displayName`, `description`, `policyDefinitionId`, `assessmentType`, `implementationEffort`, `userImpact`, `categories`, `threats`, `resourceId`, `resourceName`, `resourceType`, `resourceProvider`, `source`, `firstEvaluationDate`

### ActionType (from envelope)

| Value | Meaning | MERGE Behaviour |
|---|---|---|
| `Insert` | Assessment created or re-evaluated | INSERT new row, or UPDATE mutable columns |
| `Delete` | Resource deleted or recommendation deprecated | DELETE the row |

Source: `JSON_VALUE(assessmentEventDataEnrichment, '$.action')`

---

## Sub-Assessments — Schema Detail

A sub-assessment is a granular finding under a parent recommendation — e.g., a specific CVE on a specific container image. One per individual finding (`SecurityNestedRecommendation` in Log Analytics).

### Unique Key

```
/subscriptions/{sub}/.../assessments/{assessmentGuid}/subAssessments/{subAssessmentGuid}
```

One row per **individual finding on a specific resource under a specific recommendation**.

### Relationship to Assessments

```
Assessment (parent)
  └─ id: .../assessments/{assessmentGuid}                    ← 1 row in SecurityAssessments
     ├─ SubAssessment: .../subAssessments/{subGuid1}         ← 1 row in SecuritySubAssessments
     ├─ SubAssessment: .../subAssessments/{subGuid2}
     └─ SubAssessment: .../subAssessments/{subGuid3}
```

Join back to the parent:

```sql
SELECT sa.displayName AS RecommendationName, ssa.*
FROM dbo.SecuritySubAssessments ssa
INNER JOIN dbo.SecurityAssessments sa
    ON sa.id = LEFT(ssa.id, CHARINDEX('/subAssessments/', ssa.id) - 1);
```

### Typed Table Schema — Core

https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/securitynestedrecommendation

| Column | Type | Source | Mutable | Description |
|---|---|---|---|---|
| `tenantId` | `UNIQUEIDENTIFIER` | Envelope | No | Azure AD tenant |
| `id` | `NVARCHAR(1000)` | Envelope | No | **Unique key** — full ARM path |
| `name` | `NVARCHAR(200)` | Envelope | No | Sub-assessment GUID |
| `type` | `NVARCHAR(200)` | Envelope | No | `Microsoft.Security/assessments/subAssessments` |

### Typed Table Schema — Status

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `statusCode` | `NVARCHAR(50)` | `$.status.code` | **Yes** | `Healthy`, `Unhealthy`, `NotApplicable` |
| `severity` | `NVARCHAR(50)` | `$.status.severity` | **Yes** | Finding-level severity |
| `statusCause` | `NVARCHAR(100)` | `$.status.cause` | **Yes** | Programmatic cause |
| `statusDescription` | `NVARCHAR(MAX)` | `$.status.description` | **Yes** | Human-readable status detail |
| `timeGenerated` | `DATETIME2` | `$.timeGenerated` | **Yes** | Event timestamp |

### Typed Table Schema — Resource Details

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `nativeResourceId` | `NVARCHAR(1000)` | `$.resourceDetails.nativeResourceId` | **Yes** | E.g., container image SHA |
| `resourceId` | `NVARCHAR(1000)` | `$.resourceDetails.id` | No | Assessed resource ARM ID |
| `resourceName` | `NVARCHAR(400)` | `$.resourceDetails.resourceName` | No | Resource display name |
| `resourceType` | `NVARCHAR(400)` | `$.resourceDetails.resourceType` | No | ARM resource type |
| `resourceProvider` | `NVARCHAR(400)` | `$.resourceDetails.resourceProvider` | No | ARM resource provider |
| `source` | `NVARCHAR(100)` | `$.resourceDetails.source` | No | `Azure`, `OnPremise` |

### Typed Table Schema — Assessed Resource Type

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `assessedResourceType` | `NVARCHAR(200)` | `$.additionalData.assessedResourceType` | **Yes** | Discriminator for the `additionalData.data` shape |

Values: `ServerVulnerabilityAssessment`, `ContainerRegistryVulnerability`, `SqlServerVulnerability`, etc.

### Typed Table Schema — Kubernetes / Container

Populated when `assessedResourceType` involves container workloads:

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `clusterName` | `NVARCHAR(200)` | `$.additionalData.data.clusterName` | **Yes** | AKS cluster name |
| `clusterResourceId` | `NVARCHAR(1000)` | `$.additionalData.data.clusterResourceId` | **Yes** | AKS cluster ARM ID |
| `namespace` | `NVARCHAR(200)` | `$.additionalData.data.namespace` | **Yes** | K8s namespace |
| `controllerKind` | `NVARCHAR(200)` | `$.additionalData.data.controllerKind` | **Yes** | `Deployment`, `DaemonSet`, `ReplicaSet` |
| `controllerName` | `NVARCHAR(200)` | `$.additionalData.data.controllerName` | **Yes** | Controller name |
| `podName` | `NVARCHAR(200)` | `$.additionalData.data.podName` | **Yes** | Pod name |
| `containerName` | `NVARCHAR(200)` | `$.additionalData.data.containerName` | **Yes** | Container name within the pod |

### Typed Table Schema — Container Artifact (Image)

Populated for container registry vulnerability findings:

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `repositoryName` | `NVARCHAR(400)` | `$.additionalData.data.repositoryName` | No | Image repository |
| `registryHost` | `NVARCHAR(400)` | `$.additionalData.data.registryHost` | No | Registry FQDN |
| `digest` | `NVARCHAR(200)` | `$.additionalData.data.digest` | No | Image SHA digest |
| `artifactType` | `NVARCHAR(200)` | `$.additionalData.data.artifactType` | No | `ContainerImage` |

### Typed Table Schema — Software Details

Populated for OS/package vulnerability findings:

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `packageName` | `NVARCHAR(300)` | `$.additionalData.data.softwareDetails.packageName` | No | Affected package |
| `packageVendor` | `NVARCHAR(300)` | `$.additionalData.data.softwareDetails.vendor` | No | Package vendor |
| `packageVersion` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.version` | **Yes** | Currently installed version |
| `fixedVersion` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.fixedVersion` | **Yes** | Version that fixes the vuln |
| `patchable` | `BIT` | `$.additionalData.data.softwareDetails.patchable` | **Yes** | `1` = fix available |
| `fixStatus` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.fixStatus` | **Yes** | `FixAvailable`, `NoFix`, `WontFix` |
| `language` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.language` | No | Programming language (if app-level) |
| `osPlatform` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.osPlatform` | No | `Linux`, `Windows` |
| `osVersion` | `NVARCHAR(100)` | `$.additionalData.data.softwareDetails.osVersion` | No | e.g., `Ubuntu 22.04` |

### Typed Table Schema — Vulnerability (CVE)

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `cveId` | `NVARCHAR(100)` | `$.additionalData.data.cve[0].title` | No | CVE identifier |
| `vulnerabilitySeverity` | `NVARCHAR(50)` | `$.additionalData.data.cveSeverity` | **Yes** | CVE-level severity |
| `publishedDate` | `DATETIME2` | `$.additionalData.data.publishedDate` | No | When the CVE was published |
| `lastModifiedDate` | `DATETIME2` | `$.additionalData.data.lastModifiedDate` | **Yes** | When CVE record was last updated |
| `cvssScore` | `DECIMAL(5,2)` | `$.additionalData.data.cvss.base` | **Yes** | CVSS v3 base score (0.0–10.0) |
| `cvssVector` | `NVARCHAR(200)` | `$.additionalData.data.cvss.vector` | **Yes** | CVSS vector string |

> `cve` is a JSON array. We extract `cve[0].title` — the primary CVE. Query the raw `properties` column for multiple CVEs.

### Typed Table Schema — CPE (Common Platform Enumeration)

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `cpeUri` | `NVARCHAR(1000)` | `$.additionalData.data.cpe.uri` | No | Full CPE URI |
| `cpeVendor` | `NVARCHAR(300)` | `$.additionalData.data.cpe.vendor` | No | e.g., `microsoft`, `apache` |
| `cpeProduct` | `NVARCHAR(300)` | `$.additionalData.data.cpe.product` | No | e.g., `windows_server`, `httpd` |
| `cpeVersion` | `NVARCHAR(100)` | `$.additionalData.data.cpe.version` | No | CPE version component |

### Typed Table Schema — Weakness & Scanner

| Column | Type | JSON Path | Mutable | Description |
|---|---|---|---|---|
| `cweId` | `NVARCHAR(100)` | `$.additionalData.data.weakness.cwe[0].id` | No | CWE identifier |
| `inventorySource` | `NVARCHAR(200)` | `$.additionalData.data.inventorySource` | No | How the asset was discovered |
| `scanner` | `NVARCHAR(200)` | `$.additionalData.data.scanner` | No | Scanner that produced the finding |

### Typed Table Schema — System

| Column | Type | Source | Mutable | Description |
|---|---|---|---|---|
| `properties` | `NVARCHAR(MAX)` | Raw JSON | **Yes** | Full `properties` backup for ad-hoc queries |
| `LastEnqueuedUtcTime` | `DATETIME2` | `EventEnqueuedUtcTime` | **Yes** | Watermark — last processed event time |

### MERGE Update Strategy

**Updated on re-evaluation (mutable):** `statusCode`, `severity`, `statusCause`, `statusDescription`, `timeGenerated`, `nativeResourceId`, `assessedResourceType`, all Kubernetes fields, `packageVersion`, `fixedVersion`, `patchable`, `fixStatus`, `vulnerabilitySeverity`, `lastModifiedDate`, `cvssScore`, `cvssVector`, `properties`, `LastEnqueuedUtcTime`

**Set once on INSERT (immutable):** `tenantId`, `id`, `name`, `type`, `resourceId`, `resourceName`, `resourceType`, `resourceProvider`, `source`, all Container Artifact fields, `packageName`, `packageVendor`, `language`, `osPlatform`, `osVersion`, `cveId`, `publishedDate`, all CPE fields, `cweId`, `inventorySource`, `scanner`

### ActionType (from envelope)

| Value | Meaning | MERGE Behaviour |
|---|---|---|
| `Insert` | Finding created or re-evaluated | INSERT new row, or UPDATE mutable columns |
| `Delete` | Finding resolved, resource deleted, or image no longer in scope | DELETE the row |

Source: `JSON_VALUE(subAssessmentEventDataEnrichment, '$.action')` (note: `subAssessmentEventDataEnrichment`, not `assessmentEventDataEnrichment`)

### JSON Structure Overview

```
properties
├── status.code / .severity / .cause / .description
├── resourceDetails.id / .resourceName / .resourceType / .source / .nativeResourceId
├── additionalData
│   ├── assessedResourceType          ← discriminator
│   └── data
│       ├── clusterName / clusterResourceId / namespace    ┐ Kubernetes
│       ├── controllerKind / controllerName                │ (AKS workloads)
│       ├── podName / containerName                        ┘
│       ├── repositoryName / registryHost                  ┐ Container Artifact
│       ├── digest / artifactType                          ┘ (ACR images)
│       ├── softwareDetails                                ┐ Software
│       │   ├── packageName / vendor / version             │ (OS & app packages)
│       │   └── fixedVersion / patchable / fixStatus       ┘
│       ├── cve[].title / cveSeverity                      ┐ Vulnerability
│       ├── cvss.base / .vector / publishedDate            ┘ (CVE details)
│       ├── cpe.uri / vendor / product                     ← CPE
│       ├── weakness.cwe[].id                              ← CWE
│       └── scanner / inventorySource                      ← Scanner
└── timeGenerated
```

### Which Columns Are Populated Per Finding Type

| Column Group | Server Vuln | Container Registry | AKS Runtime | SQL Vuln |
|---|---|---|---|---|
| Kubernetes fields | — | — | ✓ | — |
| Artifact fields | — | ✓ | ✓ | — |
| Software fields | ✓ | ✓ | ✓ | — |
| CVE / CVSS | ✓ | ✓ | ✓ | ✓ |
| CPE | ✓ | ✓ | ✓ | — |
| CWE | sometimes | sometimes | sometimes | sometimes |

Unpopulated columns are `NULL` — this is normal and expected.

---


## Troubleshooting

### CE enabled but zero events in Event Hub

1. **Check `disableLocalAuth`** — Terraform sets `local_authentication_enabled = false` and uses trusted service mode. If using SAS mode instead, `disableLocalAuth` must be `false`.
2. **Verify RBAC** — "Windows Azure Security Resource Provider" needs "Azure Event Hubs Data Sender" on each hub.
3. **Check CE automation status** — Portal → Defender → Continuous export. Both should show "On".
4. **Wait** — First snapshot can take 4–24 hours. Streaming only fires on state changes.

### ASA running but `_Raw` tables empty

1. **Event Hub has messages?** — Check incoming messages metric. If zero, the problem is CE, not ASA.
2. **ASA errors** — Portal → ASA job → Monitoring → Errors.
3. **SQL tables exist?** — `SELECT OBJECT_ID('dbo.SecurityAssessments_Raw')` should not be NULL.
4. **ASA MI permissions** — The bootstrap grants SELECT + INSERT on `_Raw` tables.

### Typed tables empty but `_Raw` has data

1. **MERGE procs exist?** — `SELECT OBJECT_ID('dbo.usp_MergeSecurityAssessments')` should not be NULL.
2. **Elastic Job running?** — Check `jobs.job_executions` in the Job Metadata DB. Look for `lifecycle = 'Failed'`.
3. **Test manually** — Run `EXEC dbo.usp_MergeSecurityAssessments` directly.

### Terraform state drift (auth rules deleted by policy)

```bash
terraform taint azurerm_eventhub_authorization_rule.ce_send_assessments
terraform taint azurerm_eventhub_authorization_rule.ce_send_subassessments
terraform apply
```


## Diagnostic Queries

```sql
-- Check which assessed resource types are in the data
SELECT assessedResourceType, COUNT(*) AS cnt
FROM dbo.SecuritySubAssessments
GROUP BY assessedResourceType
ORDER BY cnt DESC;

-- Find findings with available fixes
SELECT cveId, packageName, packageVersion, fixedVersion, resourceId
FROM dbo.SecuritySubAssessments
WHERE patchable = 1 AND statusCode = 'Unhealthy'
ORDER BY cvssScore DESC;

-- Top CVEs by affected resource count
SELECT cveId, cvssScore, vulnerabilitySeverity, COUNT(DISTINCT resourceId) AS affectedResources
FROM dbo.SecuritySubAssessments
WHERE statusCode = 'Unhealthy'
GROUP BY cveId, cvssScore, vulnerabilitySeverity
ORDER BY affectedResources DESC;

-- Kubernetes: findings per cluster/namespace
SELECT clusterName, namespace, COUNT(*) AS findings,
       SUM(CASE WHEN patchable = 1 THEN 1 ELSE 0 END) AS fixable
FROM dbo.SecuritySubAssessments
WHERE clusterName IS NOT NULL AND statusCode = 'Unhealthy'
GROUP BY clusterName, namespace
ORDER BY findings DESC;

-- Join sub-assessments to parent recommendation name
SELECT sa.displayName AS RecommendationName, ssa.cveId, ssa.packageName,
       ssa.cvssScore, ssa.statusCode, ssa.resourceId
FROM dbo.SecuritySubAssessments ssa
INNER JOIN dbo.SecurityAssessments sa
    ON sa.id = LEFT(ssa.id, CHARINDEX('/subAssessments/', ssa.id) - 1)
WHERE ssa.statusCode = 'Unhealthy'
ORDER BY ssa.cvssScore DESC;
```


## Scheduling

The Elastic Job runs every 10 minutes by default. To change:

| Frequency | Use Case |
|---|---|
| Every 5 min | Near-real-time dashboards |
| Every 15 min | Standard operational reporting |
| Every 1 hour | Batch reporting |

For alternative scheduling options (ADF, Azure Functions, SQL Agent), see [Stream-Analytics-SQL-Pipeline.md](Stream-Analytics-SQL-Pipeline.md#alternative-scheduling-options).


## Operational Notes

1. **Event Hub local auth** — Terraform disables local auth and uses trusted service mode. If policies re-enable SAS, CE continues to work. If using SAS manually, `disableLocalAuth` must be `false`.

2. **Weekly snapshots** — Even if nothing changed, the full state is sent every ~7 days per subscription. The dedup + timestamp guard handles this gracefully.

3. **JSON paths are case-sensitive** — CE uses `resourceDetails.id` (lowercase `i`). If columns are NULL but `_Raw` has data, inspect the raw JSON.

4. **`_Raw` table growth** — With many subscriptions and weekly snapshots, staging tables grow. The MERGE proc truncates after success. Consider partitioning `_Raw` by `InsertedAtUtc` for large environments.

5. **Schema discovery** — CE JSON can include fields not documented here (newer API versions). Keep the raw `properties` column as a fallback.


## Files

| File | Purpose |
|---|---|
| `bootstrap/sql/usp_MergeSecurityAssessments.sql` | Stored procedure: MERGE assessments |
| `bootstrap/sql/usp_MergeSecuritySubAssessments.sql` | Stored procedure: MERGE sub-assessments |
| `bootstrap/` | Automated SQL bootstrapping — [bootstrap/README.md](bootstrap/README.md) |
| `Setup-Guide-Manual.md` | Manual deployment walkthrough (Portal + SQL) |
| `Stream-Analytics-SQL-Pipeline.md` | Deep-dive: CE format, ASA queries, MERGE internals, scheduling alternatives |


## Related Documentation

- [.infra/sql/README.md](../.infra/sql/README.md) — Terraform variables, outputs
- [Stream-Analytics-SQL-Pipeline.md](Stream-Analytics-SQL-Pipeline.md) — CE details, ASA query syntax, MERGE process deep-dive, alternative scheduling
- [Setup-Guide-Manual.md](Setup-Guide-Manual.md) — Portal-based manual deployment walkthrough
- [bootstrap/README.md](bootstrap/README.md) — Bootstrap script parameter reference
