[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $false)]
    [string]$JobDatabaseName = 'DefenderJobMetadata',

    [Parameter(Mandatory = $false)]
    [string]$FindingsDatabaseName = 'DefenderVulnerability',

    [Parameter(Mandatory = $true)]
    [string]$ElasticJobUmiName,

    [Parameter(Mandatory = $true, HelpMessage = 'Client ID (Application ID) of the Elastic Job UMI — needed to resolve duplicate display names')]
    [string]$ElasticJobUmiClientId,

    [Parameter(Mandatory = $true)]
    [string]$AsaAssessmentsPrincipalName,

    [Parameter(Mandatory = $true)]
    [string]$AsaSubAssessmentsPrincipalName,

    [Parameter(Mandatory = $false)]
    [string]$JobDbServiceObjective = 'GP_S_Gen5_2',

    [Parameter(Mandatory = $false)]
    [string]$FindingsDbServiceObjective = 'GP_S_Gen5_2',

    [Parameter(Mandatory = $false, HelpMessage = 'Skip database creation (use when Terraform already created them)')]
    [switch]$SkipDatabaseCreation,

    [Parameter(Mandatory = $false, HelpMessage = 'Skip master DB user for Elastic Job UMI (not needed for SqlDatabase-level targets)')]
    [switch]$SkipMasterUser,

    [Parameter(Mandatory = $false, HelpMessage = 'Skip starting Stream Analytics jobs')]
    [switch]$SkipAsaStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module SqlServer -ErrorAction Stop

# Acquire an Entra access token for Azure SQL using the current Az session
function Get-SqlAccessToken {
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if (-not $tokenObj -or -not $tokenObj.Token) {
        throw 'Failed to acquire SQL access token. Run Connect-AzAccount first.'
    }
    return $tokenObj.Token
}

function Invoke-SqlCmdFile {
    param(
        [Parameter(Mandatory = $true)][string]$Database,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][hashtable]$Variables
    )

    $token = Get-SqlAccessToken

    # Read SQL content — Invoke-Sqlcmd doesn't support :setvar, so pre-replace variables
    $sql = Get-Content -Path $FilePath -Raw

    if ($Variables) {
        foreach ($key in $Variables.Keys) {
            # Replace :setvar defaults and $(VarName) references
            $sql = $sql -replace ":setvar\s+$key\s+[^\r\n]+", ":setvar $key $($Variables[$key])"
            $sql = $sql -replace "\`$\($key\)", $Variables[$key]
        }
    }

    # Remove :setvar directives — Invoke-Sqlcmd doesn't understand them
    $sql = $sql -replace '(?m)^:setvar\s+.*$', ''

    # Split on GO batches
    $batches = $sql -split '(?m)^\s*GO\s*$' | Where-Object { $_.Trim() -ne '' }

    Write-Host "Running $(Split-Path $FilePath -Leaf) on $Database" -ForegroundColor Cyan
    foreach ($batch in $batches) {
        Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $Database `
            -AccessToken $token -Query $batch -QueryTimeout 120
    }
}

$root = Split-Path -Parent $PSScriptRoot
$sqlRoot = Join-Path $root 'sql'

# Pre-flight check: returns $true when the given SQL query returns at least one row
function Test-SqlCondition {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query
    )
    $token = Get-SqlAccessToken
    $result = Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $Database `
        -AccessToken $token -Query $Query -QueryTimeout 30 -ErrorAction SilentlyContinue
    return ($null -ne $result)
}

# Step 01 — Create databases (skip if Terraform already created them)
if ($SkipDatabaseCreation) {
    Write-Host 'Skipping 01-create-databases.sql (databases already exist via Terraform)' -ForegroundColor Yellow
} else {
    Invoke-SqlCmdFile -Database 'master' -FilePath (Join-Path $sqlRoot '01-create-databases.sql') -Variables @{
        JobDatabaseName = $JobDatabaseName
        FindingsDatabaseName = $FindingsDatabaseName
        JobDbServiceObjective = $JobDbServiceObjective
        FindingsDbServiceObjective = $FindingsDbServiceObjective
    }
}

# Step 03a — Elastic Job UMI in master (only needed for server/pool-level target groups)
if ($SkipMasterUser) {
    Write-Host 'Skipping 03a-configure-elasticjob-master-user.sql (not needed for SqlDatabase targets)' -ForegroundColor Yellow
} else {
    $masterUserExists = Test-SqlCondition -Database 'master' -Query "SELECT 1 FROM sys.database_principals WHERE name = N'$ElasticJobUmiName'"
    if ($masterUserExists) {
        Write-Host 'Skipping 03a-configure-elasticjob-master-user.sql (principal already exists in master)' -ForegroundColor Yellow
    } else {
        Invoke-SqlCmdFile -Database 'master' -FilePath (Join-Path $sqlRoot '03a-configure-elasticjob-master-user.sql') -Variables @{
            ElasticJobUmiName = $ElasticJobUmiName
            ElasticJobUmiClientId = $ElasticJobUmiClientId
        }
    }
}

# Step 02 — Create findings schema (tables + indexes)
$schemaExists = Test-SqlCondition -Database $FindingsDatabaseName -Query @"
SELECT 1 WHERE EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.SecurityAssessments_Raw'))
  AND EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.SecuritySubAssessments_Raw'))
  AND EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.SecurityAssessments'))
  AND EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.SecuritySubAssessments'))
"@
if ($schemaExists) {
    Write-Host 'Skipping 02-create-findings-schema.sql (tables already exist)' -ForegroundColor Yellow
} else {
    Invoke-SqlCmdFile -Database $FindingsDatabaseName -FilePath (Join-Path $sqlRoot '02-create-findings-schema.sql')
}

# Step 02b — Stored procedures (CREATE OR ALTER, skip if already present)
$procAExists = Test-SqlCondition -Database $FindingsDatabaseName -Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.usp_MergeSecurityAssessments', 'P')"
if ($procAExists) {
    Write-Host 'Skipping usp_MergeSecurityAssessments.sql (procedure already exists)' -ForegroundColor Yellow
} else {
    Invoke-SqlCmdFile -Database $FindingsDatabaseName -FilePath (Join-Path $sqlRoot 'usp_MergeSecurityAssessments.sql')
}

$procSExists = Test-SqlCondition -Database $FindingsDatabaseName -Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID('dbo.usp_MergeSecuritySubAssessments', 'P')"
if ($procSExists) {
    Write-Host 'Skipping usp_MergeSecuritySubAssessments.sql (procedure already exists)' -ForegroundColor Yellow
} else {
    Invoke-SqlCmdFile -Database $FindingsDatabaseName -FilePath (Join-Path $sqlRoot 'usp_MergeSecuritySubAssessments.sql')
}

# Step 03 — Configure identities and permissions (skip if all principals exist)
$allPrincipalsExist = Test-SqlCondition -Database $FindingsDatabaseName -Query @"
SELECT 1 WHERE EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$ElasticJobUmiName')
  AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AsaAssessmentsPrincipalName')
  AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$AsaSubAssessmentsPrincipalName')
"@
if ($allPrincipalsExist) {
    Write-Host 'Skipping 03-configure-identities-and-permissions.sql (all principals already exist)' -ForegroundColor Yellow
} else {
    Invoke-SqlCmdFile -Database $FindingsDatabaseName -FilePath (Join-Path $sqlRoot '03-configure-identities-and-permissions.sql') -Variables @{
        ElasticJobUmiName = $ElasticJobUmiName
        ElasticJobUmiClientId = $ElasticJobUmiClientId
        AsaAssessmentsPrincipalName = $AsaAssessmentsPrincipalName
        AsaSubAssessmentsPrincipalName = $AsaSubAssessmentsPrincipalName
    }
}

Invoke-SqlCmdFile -Database $FindingsDatabaseName -FilePath (Join-Path $sqlRoot '04-validate-bootstrap.sql') -Variables @{
    ElasticJobUmiName = $ElasticJobUmiName
    AsaAssessmentsPrincipalName = $AsaAssessmentsPrincipalName
    AsaSubAssessmentsPrincipalName = $AsaSubAssessmentsPrincipalName
}

# Step 05 — Elastic Job Schedule (target group + job + steps on Job DB)
# Replaces the manual "Step 3" from the Setup Guide.
# Uses IF NOT EXISTS guards so the step is idempotent on re-run.
$elasticJobSql = @"
-- Target group (idempotent)
IF NOT EXISTS (SELECT 1 FROM jobs.target_groups WHERE target_group_name = N'DefenderSqlTargets')
BEGIN
    EXEC jobs.sp_add_target_group @target_group_name = N'DefenderSqlTargets';

    EXEC jobs.sp_add_target_group_member
        @target_group_name = N'DefenderSqlTargets',
        @target_type       = N'SqlDatabase',
        @server_name       = N'$SqlServerFqdn',
        @database_name     = N'$FindingsDatabaseName';
END

-- Job with schedule (idempotent)
IF NOT EXISTS (SELECT 1 FROM jobs.jobs WHERE job_name = N'MergeDefenderData')
BEGIN
    EXEC jobs.sp_add_job
        @job_name                = N'MergeDefenderData',
        @description             = N'Merge of SecurityAssessments and SubAssessments from raw tables',
        @enabled                 = 1,
        @schedule_interval_type  = N'Minutes',
        @schedule_interval_count = 10;

    -- Step 1: Merge Assessments
    EXEC jobs.sp_add_jobstep
        @job_name          = N'MergeDefenderData',
        @step_name         = N'MergeAssessments',
        @target_group_name = N'DefenderSqlTargets',
        @command           = N'EXEC dbo.usp_MergeSecurityAssessments';

    -- Step 2: Merge SubAssessments
    EXEC jobs.sp_add_jobstep
        @job_name          = N'MergeDefenderData',
        @step_name         = N'MergeSubAssessments',
        @target_group_name = N'DefenderSqlTargets',
        @command           = N'EXEC dbo.usp_MergeSecuritySubAssessments';
END
ELSE
    PRINT 'Elastic Job MergeDefenderData already exists — skipping.';
"@

$token = Get-SqlAccessToken
Write-Host "Configuring Elastic Job schedule on $JobDatabaseName" -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $JobDatabaseName `
    -AccessToken $token -Query $elasticJobSql -QueryTimeout 120

# Step 06 — Start Stream Analytics jobs (auto-discovers resource group via Get-AzResource)
if ($SkipAsaStart) {
    Write-Host 'Skipping ASA job start (-SkipAsaStart specified)' -ForegroundColor Yellow
} else {
    Write-Host '' -ForegroundColor Cyan
    Write-Host 'Checking Stream Analytics jobs...' -ForegroundColor Cyan

    foreach ($jobName in @($AsaAssessmentsPrincipalName, $AsaSubAssessmentsPrincipalName)) {
        $asaResource = Get-AzResource -Name $jobName -ResourceType 'Microsoft.StreamAnalytics/streamingjobs' -ErrorAction SilentlyContinue
        if (-not $asaResource) {
            Write-Warning "ASA job '$jobName' not found in current subscription — skip."
            continue
        }

        # Get current job state
        $detail = Get-AzResource -ResourceId $asaResource.ResourceId -ExpandProperties
        $state = $detail.Properties.jobState

        if ($state -eq 'Running') {
            Write-Host "  Skipping $jobName (already running)" -ForegroundColor Yellow
            continue
        }

        Write-Host "  Starting $jobName (state: $state)..." -ForegroundColor Cyan
        $apiVersion = '2021-10-01-preview'
        $startResult = Invoke-AzRestMethod -Path "$($asaResource.ResourceId)/start?api-version=$apiVersion" -Method POST

        if ($startResult.StatusCode -ge 200 -and $startResult.StatusCode -lt 300) {
            Write-Host "  Started $jobName (async)" -ForegroundColor Green
        } else {
            Write-Warning "Failed to start ASA job '$jobName' (HTTP $($startResult.StatusCode)): $($startResult.Content)"
        }
    }
}

Write-Host ''
Write-Host 'Bootstrap completed successfully.' -ForegroundColor Green
Write-Host "Job DB      : $JobDatabaseName"
Write-Host "Findings DB : $FindingsDatabaseName"
