# Stream Analytics → SQL Database Pipeline

Deep-dive reference for the Defender for Cloud ingestion pipeline. For the deployment guide and schema reference, see [Setup-Guide-Automated.md](Setup-Guide-Automated.md).

**TABLE OF CONTENTS**
- [Continuous Export](#continuous-export)
- [Event Hubs](#event-hubs)
- [1. Stream Analytics Job Configuration](#1-stream-analytics-job-configuration)
- [2. Raw Staging Tables](#2-raw-staging-tables)
- [3. MERGE Process (Raw → Cleaned)](#3-merge-process-raw--cleaned)
- [4. Implementation Status](#4-implementation-status)
- [5. Recommended Approach Summary](#5-recommended-approach-summary)
- [6. File Reference](#6-file-reference)


## Continuous Export

Continuous Export (CE) is the built-in Defender for Cloud mechanism that streams security findings to an Event Hub in real time. It is the entry point for this pipeline.

Enable **both** data types and **both** export frequencies:

| Data type           | Content                                                                        | Frequency                                     |
|---------------------|--------------------------------------------------------------------------------|-----------------------------------------------|
| **Assessments**     | Recommendation-level compliance status per resource                            | Streaming (on state change) + weekly snapshot |
| **Sub-assessments** | Individual vulnerability findings — CVEs, misconfigs, container image findings | Streaming (on state change) + weekly snapshot |

Streaming fires only when a resource's health state changes; the weekly snapshot guarantees a full state dump even during quiet periods. Without snapshots, resources that never change state will never appear in the pipeline.
**CE sends events in ARM REST API format** — not the Log Analytics column format most documentation shows.  
Example field paths:

| Field                      | ARM JSON path                                                            |
|----------------------------|--------------------------------------------------------------------------|
| Status                     | `properties.status.code` — `"Unhealthy"`, `"Healthy"`, `"NotApplicable"` |
| Severity (assessments)     | `properties.metadata.severity`                                           |
| Severity (sub-assessments) | `properties.status.severity`                                             |
| Resource ID                | `properties.resourceDetails.id` (lowercase `i`)                          |
| First evaluation           | `properties.status.firstEvaluationDate`                                  |

Stream Analytics lands this JSON as-is into the `_Raw` tables.

**Authentication**: CE uses SAS connection strings by default. `disableLocalAuth` must be `false` on the Event Hub namespace, or CE silently delivers zero events with no error. If your environment enforces Entra-only auth via policy, enable trusted service mode (`isTrustedServiceEnabled = true` in the CE automation body) and assign the *Azure Event Hubs Data Sender* role to the *Windows Azure Security Resource Provider* service principal on each hub.

**Official documentation**:
- [Continuous export overview](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export)
- [Stream to Event Hub](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export-event-hub)
- [Export behind a firewall / trusted service mode](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export-event-hub-firewall)
- [Automations REST API](https://learn.microsoft.com/en-us/rest/api/defenderforcloud/automations/create-or-update) (`api-version=2023-12-01-preview`)

### Event Hubs

Two Event Hubs are required — one per data type — so each CE automation gets its own connection string and consumer:

| Hub                    | CE data type                | ASA input                    |
|------------------------|-----------------------------|------------------------------|
| `defender-findings`    | Assessments + snapshots     | `defender-findings-input`    |
| `defender-subfindings` | Sub-assessments + snapshots | `defender-subfindings-input` |

Basic SKU is sufficient for this pipeline. Basic only supports the `$Default` consumer group — use that for the ASA inputs. Standard SKU is required if you need custom consumer groups (e.g., a second consumer alongside ASA).

**Official documentation**:
- [Azure Event Hubs overview](https://learn.microsoft.com/en-us/azure/event-hubs/event-hubs-about)
- [Event Hubs tiers (Basic vs Standard vs Premium)](https://learn.microsoft.com/en-us/azure/event-hubs/compare-tiers)


---
## 1. Stream Analytics Job Configuration

Stream Analytics acts as a **passthrough writer**: it reads Event Hub messages and inserts
all columns directly into the `_Raw` staging tables without any transformation.
Transformation happens later in the MERGE step inside SQL.

### Input (Event Hub)

| Setting        | Value                                                     |
|----------------|-----------------------------------------------------------|
| Source         | Event Hub (consumer group: `$Default` or a dedicated one) |
| Serialization  | JSON, UTF-8                                               |
| Event Hub name | `defender-findings` / `defender-subfindings`              |
| Auth           | Managed Identity or SAS with Listen permission            |

### Output (Azure SQL)

| Setting    | Value                                                            |                                                                        |
|------------|------------------------------------------------------------------|------------------------------------------------------------------------|
| Database   | Your Azure SQL Database                                          |                                                                        |
| Table      | `dbo.SecurityAssessments_Raw` / `dbo.SecuritySubAssessments_Raw` |                                                                        |
| Auth       | Managed Identity (recommended) or SQL login                      | // Managed Identity is more secure but doesn't seem to work in Preview |
| Batch size | Default (100 rows) is fine; increase to 1000 for high-throughput |                                                                        |

### Stream Analytics Query — Assessments

```sql
SELECT
    tenantId,
    type,
    id,
    name,
    location,
    kind,
    tags,
    properties,
    assessmentEventDataEnrichment,
    securityEventDataEnrichment,
    System.Timestamp()     AS EventProcessedUtcTime,
    EventEnqueuedUtcTime,
    PartitionId
INTO [sql-assessments-output]
FROM [defender-findings-input]
```

### Stream Analytics Query — SubAssessments

```sql
SELECT
    tenantId,
    type,
    id,
    name,
    location,
    kind,
    tags,
    properties,
    subAssessmentEventDataEnrichment,
    securityEventDataEnrichment,
    System.Timestamp()     AS EventProcessedUtcTime,
    EventEnqueuedUtcTime,
    PartitionId
INTO [sql-subassessments-output]
FROM [defender-subfindings-input]
```

> **Note**: Stream Analytics does not set `InsertedAtUtc` — the SQL table default
> `SYSUTCDATETIME()` fills this automatically on insert.

---

## 2. Raw Staging Tables

Defined in `bootstrap/sql/02-create-findings-schema.sql`.

Every Event Hub message lands as one row. Key columns:

| Column                          | Source             | Purpose                               |
|---------------------------------|--------------------|---------------------------------------|
| `id`                            | ARM resource path  | Natural unique key for dedup          |
| `properties`                    | Nested JSON blob   | Parsed by MERGE via `OPENJSON`        |
| `assessmentEventDataEnrichment` | CE envelope        | Holds `action` = `Insert` or `Delete` |
| `EventEnqueuedUtcTime`          | Event Hub metadata | Ordering tiebreaker across partitions |
| `PartitionId`                   | Event Hub metadata | Diagnostic only                       |
| `InsertedAtUtc`                 | `SYSUTCDATETIME()` | When the row arrived in SQL           |

---

## 3. MERGE Process (Raw → Cleaned)

The MERGE logic is already written in the SQL files. It handles three concerns:

### 3a. Deduplication

CE does not set an Event Hub partition key — events round-robin across partitions.
The same `id` may appear multiple times in `_Raw` from different partitions.
A `ROW_NUMBER()` CTE picks only the latest event per `id` (by `EventEnqueuedUtcTime`)
before the MERGE runs.

### 3b. JSON Field Extraction

`OPENJSON ... WITH` extracts all columns from the `properties` JSON blob into typed
SQL columns using the CE ARM format paths (e.g., `$.status.code` → `statusCode`).

### 3c. Upsert / Delete Logic

| MERGE Action | Trigger                                              | Outcome                      |
|--------------|------------------------------------------------------|------------------------------|
| `INSERT`     | New `id` + `action = 'Insert'`                       | Row created in typed table   |
| `UPDATE`     | Existing `id` + `action = 'Insert'` + event is newer | Mutable columns updated      |
| `DELETE`     | Existing `id` + `action = 'Delete'` + event is newer | Row removed from typed table |

A `SnapshotDate` timestamp guard on the typed table (set to `EventEnqueuedUtcTime` of
the last processed event) prevents older batched events from overwriting newer state
already stored.

---

## 4. Implementation Status

The stored procedures and scheduling described below are **already implemented** in this repo.

### 4a. Stored Procedures (Implemented)

The MERGE logic is wrapped in dedicated stored procedures:

- `bootstrap/sql/usp_MergeSecurityAssessments.sql` — MERGE for assessments
- `bootstrap/sql/usp_MergeSecuritySubAssessments.sql` — MERGE for sub-assessments

Each procedure:
1. Extracts typed columns from raw ARM JSON via `OPENJSON WITH (...)`
2. Deduplicates via `ROW_NUMBER()` (latest event per `id` wins)
3. MERGEs into the typed table with a `LastEnqueuedUtcTime` timestamp guard
4. Handles `ActionType = 'Delete'` (resource removed)
5. Truncates the `_Raw` staging table on success

The bootstrap script (`Initialize-Bootstrap.ps1`) deploys these to the findings database.

### 4b. Scheduling (Implemented via Elastic Jobs)

The bootstrap script creates an **Elastic Job** (`MergeDefenderData`) that runs every 10 minutes:

- **Target group**: `DefenderSqlTargets` → findings database
- **Step 1**: `EXEC dbo.usp_MergeSecurityAssessments`
- **Step 2**: `EXEC dbo.usp_MergeSecuritySubAssessments`
- **Auth**: User-Assigned Managed Identity (no passwords/credentials needed)

To customize the schedule:

```sql
-- Run on the Job Metadata Database
EXEC jobs.sp_update_job
    @job_name                = 'MergeDefenderData',
    @schedule_interval_type  = 'Minutes',   -- 'Minutes' | 'Hours' | 'Days' | 'Weeks' | 'Months'
    @schedule_interval_count = 10;
```

For manual setup or reference, see `sql/Setup-ElasticJobScheduler.sql`.

### Alternative Scheduling Options

If Elastic Jobs are not suitable, these alternatives work:

#### Alternative 1 — Azure Data Factory (best if already in use / complex orchestration)

Use ADF if you already have it deployed or need dependency chains (e.g., wait for a
Stream Analytics flush, send failure alerts via Logic App).

**Recommended pipeline structure:**

```
Trigger: Tumbling Window (15 min)
    │
    ▼
Activity: Stored Procedure
    │  Linked service: Azure SQL Database
    │  Stored procedure: dbo.usp_ProcessDefenderFindings
    │
    ▼
Activity: Web / Logic App (on failure — send alert)
```

**Pros**: Rich monitoring, retry policies, integration with Azure Monitor alerts,
reuse if ADF is already present.  
**Cons**: Additional service overhead if not already deployed.

---

#### Alternative 2 — Azure Functions Timer Trigger (lightweight / code-driven)

A small Azure Function on a Consumption plan calls the stored procedure on a timer.

```csharp
[FunctionName("ProcessDefenderFindings")]
public static async Task Run(
    [TimerTrigger("0 */15 * * * *")] TimerInfo timer,   // every 15 min
    ILogger log)
{
    using var conn = new SqlConnection(
        Environment.GetEnvironmentVariable("SQL_CONN"));
    await conn.OpenAsync();

    using var cmd = new SqlCommand(
        "EXEC dbo.usp_ProcessDefenderFindings", conn);
    cmd.CommandTimeout = 300;
    await cmd.ExecuteNonQueryAsync();

    log.LogInformation("Defender findings merge completed at {Time}",
        DateTime.UtcNow);
}
```

**Pros**: No extra Azure resources, Consumption plan is effectively free at 15-minute
cadence, easy to deploy via GitHub Actions.  
**Cons**: Cold-start latency; transient SQL errors require manual retry logic (add Polly
or similar); monitoring is less rich than ADF or Elastic Jobs.

---

#### Alternative 3 — SQL Agent (SQL Server IaaS or Managed Instance only)

If the database is on SQL Server IaaS or Azure SQL Managed Instance (not applicable
to Azure SQL Database Serverless/DTU), SQL Agent is the simplest path.

```sql
USE msdb;
EXEC sp_add_job
    @job_name = 'ProcessDefenderFindings';

EXEC sp_add_jobstep
    @job_name  = 'ProcessDefenderFindings',
    @step_name = 'Merge',
    @command   = 'EXEC DefenderDB.dbo.usp_ProcessDefenderFindings;';

EXEC sp_add_schedule
    @schedule_name        = 'Every15Min',
    @freq_type            = 4,   -- daily recurring
    @freq_interval        = 1,
    @freq_subday_type     = 4,   -- minutes
    @freq_subday_interval = 15;

EXEC sp_attach_schedule
    @job_name      = 'ProcessDefenderFindings',
    @schedule_name = 'Every15Min';

EXEC sp_add_jobserver
    @job_name = 'ProcessDefenderFindings';
```

---

### 4c. Monitoring and Alerting

Add an audit table to track MERGE run history regardless of scheduling method:

```sql
CREATE TABLE dbo.MergeAudit
(
    RunId                    INT IDENTITY PRIMARY KEY,
    RunAtUtc                 DATETIME2 DEFAULT SYSUTCDATETIME(),
    AssessmentsInserted      INT,
    AssessmentsUpdated       INT,
    AssessmentsDeleted       INT,
    SubAssessmentsInserted   INT,
    SubAssessmentsUpdated    INT,
    SubAssessmentsDeleted    INT,
    DurationMs               INT,
    ErrorMessage             NVARCHAR(MAX)
);
```

Capture row counts using `OUTPUT ... INTO @changes` after each MERGE clause and insert
a summary row into `dbo.MergeAudit` at the end of `usp_ProcessDefenderFindings`.

**Azure Monitor alerts to configure:**

| Alert                        | Threshold                        | Action                                       |
|------------------------------|----------------------------------|----------------------------------------------|
| SQL DTU / CPU                | > 80% sustained for 5 min        | Scale up or investigate large snapshot batch |
| Failed Elastic Job execution | Any failure                      | Email / Teams webhook                        |
| `_Raw` table row count       | > 500k rows after MERGE (stuck?) | Investigate Stream Analytics output          |

---

## 5. Recommended Approach Summary

| Concern                | Recommendation                                                           |
|------------------------|--------------------------------------------------------------------------|
| Scheduling engine      | **Elastic Jobs** (implemented — bootstrap creates schedule automatically) |
| Lightweight / no-frills| Azure Functions timer trigger on Consumption plan                        |
| Complex orchestration  | ADF if already deployed                                                  |
| MERGE frequency        | Every 15 min for standard reporting; every 5 min for near-real-time      |
| Raw table retention    | TRUNCATE after each successful MERGE                                     |
| Error handling         | Wrap both MERGEs + both TRUNCATEs in a single TRY/CATCH transaction      |
| Stale event protection | `SnapshotDate` timestamp guard already in MERGE — no extra action needed |

---

## 6. File Reference

| File                                      | Purpose                                                  |
|-------------------------------------------|----------------------------------------------------------|
| `sql/SecurityAssessments.sql`             | Raw table DDL, typed table DDL, and Assessments MERGE    |
| `sql/SecuritySubAssessments.sql`          | Raw table DDL, typed table DDL, and SubAssessments MERGE |
| `sql/usp_MergeSecurityAssessments.sql`    | Stored procedure: MERGE assessments                      |
| `sql/usp_MergeSecuritySubAssessments.sql` | Stored procedure: MERGE sub-assessments                  |
| `sql/Setup-ElasticJobScheduler.sql`       | Elastic Job setup reference (bootstrap automates this)   |
| `bootstrap/`                              | Automated SQL bootstrapping (PowerShell + SQL)           |
| `Setup-Guide-Automated.md`                | Deployment guide, schema reference, troubleshooting      |
