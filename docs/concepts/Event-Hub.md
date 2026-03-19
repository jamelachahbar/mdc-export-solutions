---
title: Event Hub
description: A fully managed streaming ingestion service that buffers millions of events per second for downstream processing.
---

# <img src="../assets/icons/event-hub.svg" alt="" width="32"/> Event Hub

**Azure Event Hubs** is a big-data streaming platform and event ingestion service. It acts as the "front door" for an event pipeline, decoupling event producers from consumers.

> Official docs: [Azure Event Hubs](https://learn.microsoft.com/en-us/azure/event-hubs/)

## Why it matters

In the Defender for Cloud export pipeline, Event Hub is the buffer between Continuous Export and Stream Analytics. It provides:

- **Decoupling** - Defender writes events independently of how fast (or slow) the consumer processes them.
- **Partitioning** - events are distributed across partitions for parallel processing.
- **Durability** - events are retained for a configurable period (1-90 days), so consumers can replay if needed.
- **Multiple consumers** - different consumer groups can read the same stream independently.

## Key details

| Property | Value |
|----------|-------|
| **Service** | Azure Event Hubs |
| **Protocol** | AMQP 1.0, HTTPS, Kafka |
| **Partitions** | 2-32 per hub (streaming pipeline uses 2) |
| **Retention** | 1–90 days (Basic/Standard), up to unlimited (Premium/Dedicated) |
| **Throughput** | 1 MB/s in, 2 MB/s out per throughput unit (Standard tier) |
| **Authentication** | Entra ID (managed identity), SAS - this repo uses Entra ID only |
| **Pricing tier used** | Basic |

## Role in the streaming pipeline

The streaming SQL pipeline deploys **two Event Hubs** inside a single namespace:

| Hub | Purpose |
|-----|---------|
| `assessments` | Receives security assessment findings |
| `subassessments` | Receives sub-assessment (vulnerability) findings |

Continuous Export publishes to these hubs. Stream Analytics reads from them using dedicated consumer groups.

```
Defender for Cloud
    ↓ Continuous Export
Event Hub (assessments)      Event Hub (subassessments)
    ↓                            ↓
Stream Analytics Job ×2
```

## Related

- [Continuous Export](Continuous-Export.md) - the upstream producer that writes events to Event Hub
- [Stream Analytics](Stream-Analytics.md) - the downstream consumer that reads and routes events to SQL
- [Azure SQL Database](Azure-SQL-Database.md) - final destination for processed findings
- [Event Hub SQL pipeline guide](/solutions/eventhub-sql-pipeline/README.md) - full deployment walkthrough
