# SQL Bootstrap Package

Repeatable, idempotent bootstrap for initializing the SQL pipeline databases. For full deployment context, see [Setup-Guide-Automated.md](../Setup-Guide-Automated.md).

## What It Creates

- **Findings schema**: `SecurityAssessments_Raw`, `SecuritySubAssessments_Raw`, `SecurityAssessments`, `SecuritySubAssessments`, plus indexes
- **MERGE stored procedures**: `usp_MergeSecurityAssessments`, `usp_MergeSecuritySubAssessments`
- **MI permissions**: Elastic Job UMI (`CONNECT` + `EXECUTE`), ASA MIs (`CONNECT` + `SELECT, INSERT`)
- **Elastic Job schedule**: Target group `DefenderSqlTargets`, job `MergeDefenderData` (every 10 min), two merge steps
- **Databases** (optional): `DefenderJobMetadata` + `DefenderVulnerability` (skip with `-SkipDatabaseCreation` if Terraform created them)
- **ASA job start** (optional): Auto-discovers and starts both Stream Analytics jobs (skip with `-SkipAsaStart`)

## Usage

```powershell
./Initialize-Bootstrap.ps1 `
  -SqlServerFqdn          "<server>.database.windows.net" `
  -ElasticJobUmiName      "<elastic-job-umi-name>" `
  -ElasticJobUmiClientId  "<elastic-job-umi-client-id>" `
  -AsaAssessmentsPrincipalName    "<asa-assessments-job-name>" `
  -AsaSubAssessmentsPrincipalName "<asa-subassessments-job-name>" `
  -SkipDatabaseCreation `
  -SkipMasterUser
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SqlServerFqdn` | Yes | — | SQL server FQDN (e.g., `defender-sql-server.database.windows.net`) |
| `ElasticJobUmiName` | Yes | — | Display name of the Elastic Job User-Assigned Managed Identity |
| `ElasticJobUmiClientId` | Yes | — | Client ID (Application ID) of the UMI |
| `AsaAssessmentsPrincipalName` | Yes | — | Name of the ASA assessments job (used as SQL contained user) |
| `AsaSubAssessmentsPrincipalName` | Yes | — | Name of the ASA sub-assessments job |
| `JobDatabaseName` | No | `DefenderJobMetadata` | Name of the job metadata database |
| `FindingsDatabaseName` | No | `DefenderVulnerability` | Name of the findings database |
| `SkipDatabaseCreation` | No | `$false` | Skip database creation (use when Terraform created them) |
| `SkipMasterUser` | No | `$false` | Skip master DB user for Elastic Job UMI (not needed for database-level targets) |
| `SkipAsaStart` | No | `$false` | Skip starting Stream Analytics jobs (jobs are auto-discovered via `Get-AzResource`) |

## Files

| File | Purpose |
|------|---------|
| `scripts/Initialize-Bootstrap.ps1` | PowerShell orchestrator |
| `sql/01-create-databases.sql` | Database creation (optional) |
| `sql/02-create-findings-schema.sql` | Tables + indexes |
| `sql/03-configure-identities-and-permissions.sql` | MI users + grants |
| `sql/03a-configure-elasticjob-master-user.sql` | Master DB user (optional) |
| `sql/04-validate-bootstrap.sql` | Post-bootstrap validation |

## Notes

- Scripts are safe to re-run (all steps are idempotent, including Elastic Job schedule creation).
- Requires `Connect-AzAccount` for Entra token acquisition.
