# Microsoft Defender for Cloud - Export Solutions

**Get your security findings out of the portal and into places where they become actionable.**

<p align="center">
  <img src="docs/assets/images/flow-defender-to-ce.svg" alt="Defender for Cloud → Continuous Export data flow" width="600"/>
</p>

## Why export Defender for Cloud data?

Microsoft Defender for Cloud continuously evaluates your Azure resources against security recommendations, vulnerability scans, and compliance benchmarks. That data is powerful and can be enhanced if you can use it beyond the portal.

- **See everything at once** - Query findings across all subscriptions in a single view instead of clicking through one subscription at a time
- **Track trends over time** - Build a historical record to answer "are we getting healthier?" and produce compliance reports with actual trend lines
- **Build custom dashboards** - Power BI, Grafana, or any BI tool connected to SQL - tailored for CISOs, platform teams, or app owners
- **Automate responses** - Trigger workflows when posture changes - create tickets, send alerts, feed into SIEM/SOAR
- **Own your data** - Control retention, indexing, and query performance instead of depending on Log Analytics limits

---

## Choose your approach

| | [Event Hub SQL Pipeline](solutions/eventhub-sql-pipeline/) | [Resource Graph Export](solutions/resource-graph-export/) |
|---|---|---|
| **Pattern** | Continuous streaming | Point-in-time snapshot |
| **Data flow** | Defender → Event Hub → Stream Analytics → SQL | Resource Graph → PowerShell → CSV |
| **Infrastructure** | Event Hub, SQL, Stream Analytics, Elastic Jobs | None - just run a script |
| **Best for** | Dashboards, trend analysis, automated workflows | Ad-hoc reporting, quick audits, Power BI |
| **Update frequency** | Real-time + weekly snapshots | On-demand |
| **Multi-subscription** | Per-subscription CE setup (automate via [Azure Policy](docs/concepts/Azure-Policy-Continuous-Export.md)) | Single query across all subscriptions |
| **Get started** | [View solution →](solutions/eventhub-sql-pipeline/) | [View solution →](solutions/resource-graph-export/) |

---

## Quick start

### Option A - Streaming pipeline (Terraform + bootstrap)

```bash
# 1. Deploy infrastructure
cd .infra/sql/
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init && terraform apply

# 2. Run bootstrap (schema + permissions + Elastic Job schedule)
cd ../../solutions/eventhub-sql-pipeline/bootstrap/scripts/
./Initialize-Bootstrap.ps1 `
    -SqlServerFqdn          "$(terraform -chdir=../../.infra/sql output -raw sql_server_fqdn)" `
    -ElasticJobUmiName      "$(terraform -chdir=../../.infra/sql output -raw elastic_job_umi_name)" `
    -ElasticJobUmiClientId  "$(terraform -chdir=../../.infra/sql output -raw elastic_job_umi_client_id)" `
    -AsaAssessmentsPrincipalName    "asa-defender-assessments" `
    -AsaSubAssessmentsPrincipalName "asa-defender-subassessments" `
    -SkipDatabaseCreation -SkipMasterUser
```

Full guide: [Setup Guide - Automated](solutions/eventhub-sql-pipeline/Setup-Guide-Automated.md) | [Setup Guide - Manual](solutions/eventhub-sql-pipeline/Setup-Guide-Manual.md)

### Option B - Point-in-time export (zero infrastructure)

```powershell
cd solutions/resource-graph-export/
./Export-ArgFindings.ps1
```

Full guide: [Resource Graph Export](solutions/resource-graph-export/)

---

<details>
<summary><strong>📂 Repository structure</strong></summary>

```
├── .infra/sql/                               # Terraform for streaming pipeline infrastructure
├── automation/                               # Legacy Continuous Export setup scripts
├── docs/
│   ├── concepts/                             # What is X? - quick reference definitions
│   ├── guides/                               # How-to articles
│   └── principles/                           # Decision-shaping insights
└── solutions/
    ├── eventhub-sql-pipeline/                # Streaming: CE → Event Hub → SQL
    │   ├── README.md                         # Solution overview
    │   ├── Setup-Guide-Automated.md          # Deploy with Terraform + bootstrap
    │   ├── Setup-Guide-Manual.md             # Deploy via Azure Portal
    │   ├── Stream-Analytics-SQL-Pipeline.md  # Technical deep-dive
    │   └── bootstrap/                        # SQL bootstrapping scripts
    └── resource-graph-export/                # Snapshot: ARG → CSV / Power BI
        ├── Export-ArgFindings.ps1
        ├── Export-ForPowerBI.ps1
        └── resourcegraph.kql
```

</details>

<details>
<summary><strong>📖 Concepts</strong></summary>

New to the Azure services in this pipeline? Start here.

| Concept | What it does |
|---------|-------------|
| [Continuous Export](docs/concepts/Continuous-Export.md) | Streams Defender findings to Event Hub or Log Analytics in near-real-time |
| [Event Hub](docs/concepts/Event-Hub.md) | Buffers streaming events with partitioning and consumer groups |
| [Stream Analytics](docs/concepts/Stream-Analytics.md) | Processes events in real time using SQL-like queries |
| [Azure SQL Database](docs/concepts/Azure-SQL-Database.md) | Stores deduplicated findings in typed tables |
| [Azure Policy (Continuous Export)](docs/concepts/Azure-Policy-Continuous-Export.md) | Deploys Continuous Export at scale across subscriptions using built-in policy |
| [Azure Resource Graph](docs/concepts/Azure-Resource-Graph.md) | Cross-subscription KQL queries - zero infrastructure required |

</details>

## Security

All solutions follow these principles:

- **Entra ID only** - no SQL auth, no SAS keys, no hardcoded credentials
- **Managed Identity** for all service-to-service authentication
- **Least-privilege RBAC** - specific permissions, not broad roles
- **TLS 1.2 minimum** on all services