# Setup Guide — Manual Walkthrough

Step-by-step manual deployment of the **CE → Event Hub → Stream Analytics → Azure SQL → Elastic Jobs** pipeline without Terraform. Use this guide when deploying through the Azure Portal and SQL tooling directly.

For the automated (Terraform + Bootstrap) approach, see [Setup-Guide-Automated.md](Setup-Guide-Automated.md).

## Prerequisites

- **Azure subscription** with Microsoft Defender for Cloud enabled
- **Permissions**: Owner or Contributor + User Access Administrator on the subscription
- **SQL client**: Azure Data Studio, SSMS, or sqlcmd
- **PowerShell 7+** with `Az.Accounts` and `SqlServer` modules (for bootstrap scripts, optional)

---

## Step 1 — Create Event Hub Namespace and Hubs

### 1a. Create the Event Hub Namespace

1. Azure Portal → **Event Hubs** → **+ Create**
2. Configure:
   - **Resource group**: Create new or use existing (e.g., `rg-defender-sql-pipeline`)
   - **Namespace name**: Choose a globally unique name (e.g., `defender-sql-eventhub-<suffix>`)
   - **Location**: Choose your preferred region (e.g., `UK South`)
   - **Pricing tier**: **Basic** (sufficient for this pipeline)
3. Click **Review + create** → **Create**

### 1b. Create the Event Hubs

Create two Event Hubs inside the namespace:

| Hub name | Purpose |
|----------|---------|
| `defender-findings` | Receives Assessments + AssessmentsSnapshot events |
| `defender-subfindings` | Receives SubAssessments + SubAssessmentsSnapshot events |

For each hub:
1. Open the namespace → **+ Event Hub**
2. **Name**: `defender-findings` (then repeat for `defender-subfindings`)
3. **Partition Count**: `2`
4. **Message Retention**: `1` day
5. Click **Create**

### 1c. Create SAS Authorization Rules (for CE)

CE needs **Send** permission on each hub. For each hub:

1. Open the Event Hub → **Shared access policies** → **+ Add**
2. **Policy name**: `DefenderCESend`
3. **Claims**: Check **Send** only
4. Click **Create**
5. Copy the **Connection string–primary key** — you'll need it in Step 2

> **If your environment enforces `disableLocalAuth`**: Skip SAS rules. Instead, use trusted service mode — see the "Trusted Service Mode" section at the end of this guide.

---

## Step 2 — Configure Continuous Export

### 2a. Portal Setup

1. Azure Portal → **Microsoft Defender for Cloud** → **Environment settings**
2. Select your subscription → **Continuous export**
3. Choose the **Event Hub** tab

### 2b. Create Assessments Export

1. **Export target**: Event Hub
2. **Event Hub namespace**: Select the namespace from Step 1
3. **Event Hub name**: `defender-findings`
4. **Event Hub policy name**: `DefenderCESend`
5. **Exported data types**: Check both:
   - ✅ **Security recommendations** (Assessments streaming)
   - ✅ Enable **snapshot exports** (AssessmentsSnapshot — weekly full dump)
6. **Export frequency**: Select both streaming and snapshot
7. Click **Save**

### 2c. Create SubAssessments Export

Repeat the above, but:
- **Event Hub name**: `defender-subfindings`
- **Exported data types**: Check both:
  - ✅ **Sub-assessments** (streaming)
  - ✅ Enable **snapshot exports** (weekly)

> **Data arrival timing**: Streaming events fire only when a resource's health state changes. Snapshots deliver a full state dump once per week. The first snapshot after enabling CE can take up to 24 hours.

### 2d. Verify CE Status

Azure Portal → Defender for Cloud → **Environment settings** → Subscription → **Continuous export**

Both exports should show as enabled. You can also validate via the REST API:

```
GET /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Security/automations?api-version=2023-12-01-preview
```

**Official docs**: [Continuous export overview](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export) | [Export to Event Hub](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export-event-hub)

---

## Step 3 — Create Azure SQL Server and Databases

### 3a. Create SQL Server

1. Azure Portal → **SQL servers** → **+ Create**
2. Configure:
   - **Resource group**: Same as above
   - **Server name**: Globally unique (e.g., `defender-sql-server-<suffix>`)
   - **Location**: Same region as Event Hub namespace
   - **Authentication method**: **Use Microsoft Entra-only authentication**
   - **Set Entra admin**: Select your user or a group
3. **Networking**: Enable **Allow Azure services and resources to access this server**
4. Click **Review + create** → **Create**

### 3b. Create Findings Database

1. Open the SQL server → **+ Create database**
2. Configure:
   - **Database name**: `DefenderVulnerability`
   - **Compute + storage**: **General Purpose — Serverless, Gen5, 2 vCores** (GP_S_Gen5_2)
   - **Auto-pause delay**: 60 minutes
   - **Max size**: 32 GB
3. Click **Review + create** → **Create**

### 3c. Create Job Metadata Database

1. Open the SQL server → **+ Create database**
2. Configure:
   - **Database name**: `DefenderJobMetadata`
   - **Compute + storage**: **Standard S0** (required for Elastic Job Agent — serverless is NOT supported)
   - **Max size**: 2 GB
3. Click **Review + create** → **Create**

> **Why S0?**: The Elastic Job Agent requires a Standard-tier or higher database for its metadata store. Serverless SKUs (GP_S_*) will fail.

---

## Step 4 — Create SQL Schema and Stored Procedures

Connect to the **Findings Database** (`DefenderVulnerability`) using an Entra-authenticated SQL client.

### Option A: Use the Bootstrap Script (recommended)

If you have PowerShell 7+ and the `SqlServer` module:

```powershell
cd solutions/eventhub-sql-pipeline/bootstrap/scripts/

# This creates tables, stored procedures, and permissions in one go
./Initialize-Bootstrap.ps1 `
    -SqlServerFqdn "defender-sql-server-<suffix>.database.windows.net" `
    -ElasticJobUmiName "mi-elastic-job-agent" `
    -ElasticJobUmiClientId "<UMI-client-id>" `
    -AsaAssessmentsPrincipalName "asa-defender-assessments" `
    -AsaSubAssessmentsPrincipalName "asa-defender-subassessments" `
    -SkipDatabaseCreation
```

> Use `-SkipDatabaseCreation` since you already created the databases manually. Then skip to Step 5.

### Option B: Run SQL Scripts Manually

Run the following SQL files against the **Findings Database** in order:

#### 4a. Create raw and typed tables

Open and execute: `bootstrap/sql/02-create-findings-schema.sql`

This creates four tables:
- `SecurityAssessments_Raw` — Staging table for ASA output (raw ARM JSON)
- `SecuritySubAssessments_Raw` — Staging table for ASA output
- `SecurityAssessments` — Typed table with extracted/parsed columns
- `SecuritySubAssessments` — Typed table with extracted/parsed columns

Plus clustered indexes on the typed tables.

#### 4b. Create MERGE stored procedures

Execute these two files:
- `bootstrap/sql/usp_MergeSecurityAssessments.sql`
- `bootstrap/sql/usp_MergeSecuritySubAssessments.sql`

These stored procedures:
1. Extract typed columns from the raw ARM JSON using `OPENJSON WITH (...)`
2. Deduplicate using `ROW_NUMBER()` (latest event per resource wins)
3. MERGE (upsert) into the typed tables with a `LastEnqueuedUtcTime` timestamp guard
4. Handle `ActionType = 'Delete'` (when a finding is removed)

---

## Step 5 — Create Stream Analytics Jobs

You need **two ASA jobs** — one for assessments, one for sub-assessments.

### 5a. Create Assessments ASA Job

1. Azure Portal → **Stream Analytics jobs** → **+ Create**
2. Configure:
   - **Job name**: `asa-defender-assessments`
   - **Resource group**: Same as above
   - **Location**: Same region
   - **Streaming units**: `1` (sufficient for CE workloads)
   - **Identity**: Enable **System assigned managed identity**
3. Click **Create**

#### Add Input (Event Hub)

1. Open the ASA job → **Inputs** → **+ Add stream input** → **Event Hub**
2. Configure:
   - **Input alias**: `ehinput`
   - **Event Hub namespace**: Select your namespace
   - **Event Hub name**: `defender-findings`
   - **Consumer group**: `$Default`
   - **Authentication mode**: **Managed Identity** (if available, otherwise use the SAS connection string)
   - **Event serialization format**: JSON, UTF-8
3. Click **Save**

#### Add Output (SQL Database)

1. Open the ASA job → **Outputs** → **+ Add** → **SQL Database**
2. Configure:
   - **Output alias**: `sqloutput`
   - **Database**: `DefenderVulnerability`
   - **Table**: `SecurityAssessments_Raw`
   - **Authentication mode**: **Managed Identity**
3. Click **Save**

#### Set the Query

Open the ASA job → **Query** → Replace with:

```sql
SELECT
    tenantId,
    [type],
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
INTO [sqloutput]
FROM [ehinput]
```

Click **Save query**.

### 5b. Create SubAssessments ASA Job

Repeat the above with these differences:

| Setting | Value |
|---------|-------|
| Job name | `asa-defender-subassessments` |
| Input Event Hub name | `defender-subfindings` |
| Output table | `SecuritySubAssessments_Raw` |

Query for sub-assessments (note `subAssessmentEventDataEnrichment` instead of `assessmentEventDataEnrichment`):

```sql
SELECT
    tenantId,
    [type],
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
INTO [sqloutput]
FROM [ehinput]
```

---

## Step 6 — Grant SQL Permissions to ASA and Elastic Job Identities

### Option A: Use the Bootstrap Script

If you used the bootstrap script in Step 4 (Option A), permissions are already configured. Skip to Step 7.

### Option B: Run Manually

Connect to the **Findings Database** and run `bootstrap/sql/03-configure-identities-and-permissions.sql`.

Update the `:setvar` values at the top of the file with your actual names:

```sql
:setvar ElasticJobUmiName mi-elastic-job-agent
:setvar ElasticJobUmiClientId <your-UMI-client-id>
:setvar AsaAssessmentsPrincipalName asa-defender-assessments
:setvar AsaSubAssessmentsPrincipalName asa-defender-subassessments
```

This script creates contained database users and grants:
- **ASA assessments MI** → `SELECT, INSERT` on `SecurityAssessments_Raw`
- **ASA sub-assessments MI** → `SELECT, INSERT` on `SecuritySubAssessments_Raw`
- **Elastic Job UMI** → `EXECUTE` on both MERGE stored procedures

> **Note**: If your SQL client doesn't support `:setvar`, manually replace `$(VarName)` references in the script with your actual values.

---

## Step 7 — Create Elastic Job Agent and Schedule

### 7a. Create User-Assigned Managed Identity

1. Azure Portal → **Managed Identities** → **+ Create**
2. **Name**: `mi-elastic-job-agent`
3. **Resource group**: Same as above
4. Click **Review + create** → **Create**
5. Note the **Client ID** from the overview page

### 7b. Create Elastic Job Agent

1. Azure Portal → **Elastic Job agents** → **+ Create**
2. Configure:
   - **Name**: `defender-elastic-agent`
   - **Database**: Select `DefenderJobMetadata` (S0)
3. Click **Create**
4. After creation: Open the agent → **Identity** → **User assigned** → **+ Add** → Select `mi-elastic-job-agent`

### 7c. Configure the Job Schedule

> **If using the bootstrap script**: `Initialize-Bootstrap.ps1` now creates the Elastic Job target group, job (every 10 minutes), and both merge steps automatically. Skip this section and go to Step 8.

**Manual setup**: Connect to the **Job Metadata Database** (`DefenderJobMetadata`) using an Entra-authenticated SQL client.

The bootstrap script now automates Elastic Job creation. For manual setup, run the following SQL against the **Job Metadata Database**:

```sql
DECLARE @umiName        NVARCHAR(200) = 'mi-elastic-job-agent';
DECLARE @targetServer   NVARCHAR(200) = '<your-server>.database.windows.net';
DECLARE @targetDatabase NVARCHAR(200) = 'DefenderVulnerability';
```

Execute the sections in order:

1. **Section 2** (on Job DB) — Creates the target group pointing to your findings database
2. **Section 3** (on Job DB) — Creates the `MergeDefenderData` job running every 10 minutes with two steps:
   - Step 1: `EXEC dbo.usp_MergeSecurityAssessments`
   - Step 2: `EXEC dbo.usp_MergeSecuritySubAssessments`
3. **Section 5** (on Job DB) — Tests by firing the job immediately

> **Section 1** (creating the UMI user + grants on the target DB) is needed if you skipped the bootstrap in Step 4/6. Uncomment and execute it on the **Findings Database**.

### Schedule options

The default schedule is every 10 minutes. To change it, update these variables before executing Section 3:

| Interval | `@scheduleIntervalType` | `@scheduleIntervalCount` | Portal equivalent |
|----------|------------------------|--------------------------|-------------------|
| Every 10 min | `'Minutes'` | `10` | `PT10M` |
| Every 30 min | `'Minutes'` | `30` | `PT30M` |
| Every hour | `'Hours'` | `1` | `PT1H` |
| Every 6 hours | `'Hours'` | `6` | `PT6H` |
| Once a day | `'Days'` | `1` | `P1D` |

---

## Step 8 — Start ASA Jobs and Verify

### 8a. Start Stream Analytics Jobs

For each ASA job:
1. Azure Portal → **Stream Analytics jobs** → Select the job
2. Click **▶ Start** → **Job output start time**: Now → **Start**

Or via CLI:

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

### 8b. Verify the Full Pipeline

See the [Verification checklist](Setup-Guide-Automated.md#step-5--wait-for-data-and-verify) in the automated setup guide for expected data arrival timings, SQL verification queries, and troubleshooting steps.

---

## Key Gotchas

| Issue | Detail |
|-------|--------|
| **CE delivers zero events** | Check that `disableLocalAuth` is `false` on the Event Hub namespace (for SAS mode), or that trusted service mode is configured with proper RBAC. |
| **Job Metadata DB must be S0+** | Elastic Job Agent does not support serverless SKUs. Use Standard S0. |
| **ASA enrichment column differs** | Assessments use `assessmentEventDataEnrichment`, sub-assessments use `subAssessmentEventDataEnrichment`. Using the wrong column name causes ASA to error or drop data. |
| **CE JSON is ARM format** | CE sends `properties.status.code`, not `RecommendationState`. The MERGE procs handle this transformation. Don't try to map CE fields directly to typed column names. |
| **KQL property access is case-sensitive** | CE uses `resourceDetails.id` (lowercase `i`). The MERGE procs use `OPENJSON` with explicit paths. |
| **Basic EH = $Default only** | Basic SKU only supports the `$Default` consumer group. Both ASA jobs share it, which works fine. |
| **ASA MI needs SQL permissions** | ASA's managed identity must be an external user in SQL with `SELECT, INSERT` on the `_Raw` table. Without this, ASA starts but writes zero rows. |

---

## Trusted Service Mode (for environments with `disableLocalAuth`)

If your environment enforces `disableLocalAuth = true` on Event Hub namespaces via Azure Policy, SAS connection strings won't work. Use trusted service mode instead:

1. **Enable trusted service on CE**: When configuring CE via the REST API (`Microsoft.Security/automations`), add `"isTrustedServiceEnabled": true` to the Event Hub action body.

2. **Assign RBAC**: Grant **"Azure Event Hubs Data Sender"** to the **"Windows Azure Security Resource Provider"** service principal on each Event Hub.

3. **ASA**: ASA already supports managed identity auth for Event Hub inputs. Set the authentication mode to **Managed Identity** and assign **"Azure Event Hubs Data Receiver"** to the ASA system-assigned MI on each hub.

See: [Continuous export behind a firewall](https://learn.microsoft.com/en-us/azure/defender-for-cloud/continuous-export-event-hub-firewall)

---

## Related Documentation

- [Setup-Guide-Automated.md](Setup-Guide-Automated.md) — Automated deployment with Terraform + bootstrap
- [Stream-Analytics-SQL-Pipeline.md](Stream-Analytics-SQL-Pipeline.md) — Architecture deep-dive, ASA queries, MERGE logic
- [.infra/sql/README.md](../../.infra/sql/README.md) — Terraform deployment reference
