---
title: Stream Analytics
description: A real-time analytics service that processes streaming data from Event Hub and writes results to downstream stores like SQL.
---

# <img src="../assets/icons/stream-analytics.svg" alt="" width="32"/> Stream Analytics

**Azure Stream Analytics** (ASA) is a fully managed, real-time analytics service. It uses a SQL-like query language to read from streaming inputs, transform data on the fly, and write to one or more outputs.

> Official docs: [Azure Stream Analytics](https://learn.microsoft.com/en-us/azure/stream-analytics/)

## Why it matters

Stream Analytics sits between Event Hub and Azure SQL Database in the streaming pipeline. It provides:

- **Real-time processing** - events are processed as they arrive, not in batch.
- **No infrastructure management** - fully managed PaaS; no VMs, no clusters.
- **SQL-like queries** - familiar syntax for filtering, projecting, and windowing.
- **Exactly-once delivery** - when writing to SQL, ASA guarantees no duplicates at the output level.

## Key details

| Property | Value |
|----------|-------|
| **Service** | Azure Stream Analytics |
| **Query language** | Stream Analytics Query Language (SQL-like) |
| **Input sources** | Event Hub, IoT Hub, Blob Storage |
| **Output sinks** | SQL Database, Blob Storage, Power BI, Cosmos DB, and more |
| **Processing model** | Event-at-a-time or windowed (tumbling, hopping, sliding, session) |
| **Scaling unit** | Streaming Unit (SU) - 1 SU = blended measure of CPU, memory, throughput |
| **Authentication** | Managed identity (Entra ID) for both input and output |

## Passthrough vs. transform

The streaming pipeline uses **passthrough queries** - the ASA jobs simply read the full JSON event from Event Hub and write it as-is into `_Raw` staging tables in SQL:

```sql
SELECT *
INTO [sql-output]
FROM [eventhub-input]
```

The actual transformation (JSON parsing, deduplication, MERGE) happens downstream in SQL stored procedures, which provides:

- Easier debugging (raw events are preserved).
- Decoupling of ingestion speed from transformation complexity.
- Ability to replay raw data if MERGE logic changes.

## Role in the streaming pipeline

| ASA Job | Input | Output |
|---------|-------|--------|
| `asa-defender-assessments` | Event Hub `assessments` | `SecurityAssessments_Raw` table |
| `asa-defender-subassessments` | Event Hub `subassessments` | `SecuritySubAssessments_Raw` table |

Both jobs authenticate to Event Hub and SQL via **managed identity** - no connection strings or passwords.

## Related

- [Event Hub](Event-Hub.md) - the upstream streaming input for ASA
- [Azure SQL Database](Azure-SQL-Database.md) - the downstream output where ASA writes raw events
- [Continuous Export](Continuous-Export.md) - the original source of the events
- [Stream Analytics deep-dive](/solutions/eventhub-sql-pipeline/Stream-Analytics-SQL-Pipeline.md) - CE format, ASA queries, MERGE internals
- [Event Hub SQL pipeline guide](/solutions/eventhub-sql-pipeline/README.md) - full deployment walkthrough
