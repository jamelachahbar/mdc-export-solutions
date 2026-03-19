---
title: Azure SQL Database
description: A fully managed relational database service that stores and queries the final, deduplicated Defender for Cloud findings.
---

# <img src="../assets/icons/sql-database.svg" alt="" width="32"/> Azure SQL Database

**Azure SQL Database** is a fully managed relational database engine based on the latest stable version of Microsoft SQL Server. It handles patching, backups, high availability, and scaling automatically.

> Official docs: [Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/)

## Why it matters

Azure SQL Database is the final destination in the streaming pipeline. It provides:

- **Structured storage** - findings are parsed from JSON into typed columns, enabling efficient queries and joins.
- **Deduplication** - the MERGE pattern ensures each finding appears exactly once, updated with the latest state.
- **Power BI integration** - direct SQL connectivity makes it simple to build dashboards and reports.
- **Serverless tier** - auto-pause reduces resource usage during quiet periods.

## Key details

| Property | Value |
|----------|-------|
| **Service** | Azure SQL Database |
| **Compute tier** | General Purpose Serverless (GP_S_Gen5_2) for findings DB |
| **Auto-pause** | After 60 minutes of inactivity |
| **Max vCores** | 2 (scales down to 0.5) |
| **Authentication** | Entra ID only - no SQL authentication |
| **Job metadata DB** | Separate S0 database for Elastic Job Agent |

## Staging → typed table pattern

The streaming pipeline uses a two-stage approach:

| Stage | Table | Purpose |
|-------|-------|---------|
| **Raw** | `SecurityAssessments_Raw` | Stream Analytics writes full JSON events here |
| **Raw** | `SecuritySubAssessments_Raw` | Stream Analytics writes sub-assessment JSON here |
| **Typed** | `SecurityAssessments` | Parsed, deduplicated findings with typed columns |
| **Typed** | `SecuritySubAssessments` | Parsed, deduplicated sub-assessment findings |

The transformation from raw to typed happens via **MERGE stored procedures** (`usp_MergeSecurityAssessments`, `usp_MergeSecuritySubAssessments`) executed on a 10-minute schedule by Elastic Job Agent.

## MERGE pattern

```sql
-- Simplified: CTE deduplicates, MERGE upserts
WITH Deduped AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY id
        ORDER BY EventEnqueuedUtcTime DESC
    ) AS rn
    FROM SecurityAssessments_Raw
)
MERGE SecurityAssessments AS target
USING (SELECT * FROM Deduped WHERE rn = 1) AS source
ON target.id = source.id
WHEN MATCHED AND source.EventEnqueuedUtcTime >= target.LastEnqueuedUtcTime
    THEN UPDATE SET ...
WHEN NOT MATCHED
    THEN INSERT ...;
```

Key safeguards:
- **Deduplication** via `ROW_NUMBER()` keeps only the latest event per finding ID.
- **Timestamp guard** (`EventEnqueuedUtcTime >= LastEnqueuedUtcTime`) prevents stale events from overwriting newer data.
- **`OPENJSON ... WITH`** extracts ARM resource fields - no string manipulation.

## Related

- [Stream Analytics](Stream-Analytics.md) - writes raw events into the staging tables
- [Event Hub](Event-Hub.md) - the upstream buffer that feeds Stream Analytics
- [Continuous Export](Continuous-Export.md) - the original source of findings from Defender for Cloud
- [Event Hub SQL pipeline guide](/solutions/eventhub-sql-pipeline/README.md) - full deployment walkthrough
- [Bootstrap scripts](/solutions/eventhub-sql-pipeline/bootstrap/README.md) - creates schema, stored procs, and Elastic Job schedule
