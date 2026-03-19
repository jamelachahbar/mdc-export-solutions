<#
.SYNOPSIS
    Exports Defender for Cloud findings optimized for Power BI consumption at scale.
    Supports 2 modes: CSV (immediate) and Log Analytics partitioned.

.DESCRIPTION
    At 15M+ VA findings, standard approaches hit limits:
    - ARG portal: 55K max
    - Power BI Azure Monitor connector: ~500K per query
    - CSV import: sluggish beyond 2M rows

    This script provides 2 export modes:
    Mode 1 (CSV):  Partitioned ARG export → per-resource-type CSVs → Power BI import
    Mode 2 (LA):   Partitioned Log Analytics queries → CSVs → Power BI import/dataflow

.PARAMETER Mode
    Export mode: "CSV" (default) or "LogAnalytics"

.PARAMETER SubscriptionIds
    Array of subscription IDs. Required for CSV mode.

.PARAMETER WorkspaceId
    Log Analytics workspace ID. Required for LogAnalytics mode.

.PARAMETER OutputPath
    Directory for exported files. Default: .\output\powerbi

.PARAMETER LookbackDays
    How many days of data to include. Default: 365.

.PARAMETER MaxRowsPerFile
    Maximum rows per CSV file for Power BI. Default: 500000.
    Power BI Desktop handles ~500K rows per table comfortably.

.EXAMPLE
    # Mode 1: Partitioned ARG CSV export (immediate, no CE needed)
    .\Export-ForPowerBI.ps1 -Mode CSV -SubscriptionIds @("sub-id")

.EXAMPLE
    # Mode 2: Partitioned Log Analytics export (needs CE + data)
    .\Export-ForPowerBI.ps1 -Mode LogAnalytics -WorkspaceId "workspace-id"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("CSV", "LogAnalytics")]
    [string]$Mode = "CSV",

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds = @(),

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\powerbi",

    [Parameter(Mandatory = $false)]
    [int]$LookbackDays = 365,

    [Parameter(Mandatory = $false)]
    [int]$MaxRowsPerFile = 500000
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Cyan" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "  Defender for Cloud → Power BI Export"
Write-Log "  Mode: $Mode"
Write-Log "═══════════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# MODE 1: Partitioned ARG CSV Export
# ─────────────────────────────────────────────────────────────────────────────
if ($Mode -eq "CSV") {
    $requiredModules = @("Az.Accounts", "Az.ResourceGraph")
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Log "Installing module: $mod" "WARN"
            Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $mod -ErrorAction Stop
    }

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) { Connect-AzAccount }

    # Resource types to export — one file per type to keep sizes manageable
    $resourceTypes = @(
        "microsoft.compute/virtualmachines",
        "microsoft.sql/servers",
        "microsoft.sql/managedinstances",
        "microsoft.web/sites",
        "microsoft.storage/storageaccounts",
        "microsoft.network/networksecuritygroups",
        "microsoft.keyvault/vaults",
        "microsoft.containerregistry/registries",
        "microsoft.containerservice/managedclusters"
    )

    $grandTotal = 0
    $fileManifest = @()

    foreach ($resType in $resourceTypes) {
        $typeName = ($resType -split "/")[-1]
        Write-Log "─── Exporting: $typeName ───"

        $argQuery = @"
securityresources
| where type == "microsoft.security/assessments/subassessments"
| extend 
    assessmentKey = extract(@"microsoft.security/assessments/(.+)/subassessments", 1, id),
    subAssessmentId = tostring(properties.id),
    statusCode = tostring(properties.status.code),
    severity = tostring(properties.status.severity),
    description = tostring(properties.description),
    remediation = tostring(properties.remediation),
    category = tostring(properties.category),
    resourceId = tolower(tostring(properties.resourceDetails.id)),
    nativeResourceId = tolower(tostring(properties.resourceDetails.NativeResourceId)),
    displayName = tostring(properties.displayName),
    timeGenerated = tostring(properties.timeGenerated),
    impact = tostring(properties.impact)
| extend resourceType = tolower(extract(@"/providers/([^/]+/[^/]+)", 1, nativeResourceId))
| where resourceType == "$resType"
| project 
    subscriptionId,
    resourceGroup,
    nativeResourceId,
    resourceType,
    assessmentKey,
    subAssessmentId,
    statusCode,
    severity,
    displayName,
    description,
    remediation,
    category,
    impact,
    timeGenerated
"@

        $results = [System.Collections.Generic.List[object]]::new()
        $skipToken = $null
        $batchNum = 0

        $queryParams = @{ Query = $argQuery; First = 1000 }
        if ($SubscriptionIds.Count -gt 0) {
            $queryParams["Subscription"] = $SubscriptionIds
        }

        do {
            $batchNum++
            if ($skipToken) { $queryParams["SkipToken"] = $skipToken }

            try {
                $response = Search-AzGraph @queryParams -ErrorAction Stop
                $batchCount = ($response.Data | Measure-Object).Count
                if ($batchCount -gt 0) {
                    $response.Data | ForEach-Object { $results.Add($_) }
                }
                $skipToken = $response.SkipToken
                
                if ($batchNum % 50 -eq 0) {
                    Write-Log "  $typeName — batch $batchNum, total so far: $($results.Count)"
                }
                if ($batchNum % 10 -eq 0) { Start-Sleep -Milliseconds 500 }
            }
            catch {
                Write-Log "  Error on batch $batchNum : $($_.Exception.Message)" "ERROR"
                if ($results.Count -gt 0) {
                    Write-Log "  Saving $($results.Count) records collected before error" "WARN"
                }
                break
            }
        } while ($null -ne $skipToken)

        if ($results.Count -eq 0) {
            Write-Log "  $typeName — 0 records, skipping" "WARN"
            continue
        }

        # Split into multiple files if exceeding MaxRowsPerFile
        $fileIndex = 0
        for ($i = 0; $i -lt $results.Count; $i += $MaxRowsPerFile) {
            $fileIndex++
            $chunk = $results.GetRange($i, [Math]::Min($MaxRowsPerFile, $results.Count - $i))
            $fileName = "PBI_${typeName}_${fileIndex}_${timestamp}.csv"
            $filePath = Join-Path $OutputPath $fileName
            $chunk | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8
            $fileManifest += [PSCustomObject]@{
                File         = $fileName
                ResourceType = $resType
                RowCount     = $chunk.Count
                Part         = $fileIndex
            }
            Write-Log "  → $fileName ($($chunk.Count) rows)" "SUCCESS"
        }

        $grandTotal += $results.Count
        Write-Log "  $typeName total: $($results.Count) records"
    }

    # Write manifest for Power BI folder import
    $manifestPath = Join-Path $OutputPath "manifest_${timestamp}.csv"
    $fileManifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

    Write-Log ""
    Write-Log "═══════════════════════════════════════════════════════════"
    Write-Log "  CSV EXPORT COMPLETE" "SUCCESS"
    Write-Log "═══════════════════════════════════════════════════════════"
    Write-Log "Total records : $grandTotal"
    Write-Log "Output files  : $($fileManifest.Count)"
    Write-Log "Directory     : $OutputPath"
    Write-Log ""
    Write-Log "Power BI Import Steps:" "SUCCESS"
    Write-Log "  1. Open Power BI Desktop"
    Write-Log "  2. Get Data → Folder → select '$OutputPath'"
    Write-Log "  3. Power BI will combine all CSV files automatically"
    Write-Log "  4. Or use Get Data → Text/CSV for individual files"
    Write-Log "  5. Publish to Power BI Service for scheduled refresh"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODE 2: Partitioned Log Analytics Export
# ─────────────────────────────────────────────────────────────────────────────
elseif ($Mode -eq "LogAnalytics") {
    if ([string]::IsNullOrEmpty($WorkspaceId)) {
        throw "WorkspaceId is required for LogAnalytics mode. Use -WorkspaceId 'your-workspace-id'"
    }

    $requiredModules = @("Az.Accounts", "Az.OperationalInsights")
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $mod -ErrorAction Stop
    }

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) { Connect-AzAccount }

    # Partitioned queries — each stays under 500K rows for Power BI
    $queries = [ordered]@{
        "RecommendationAging" = @"
SecurityRecommendation
| where TimeGenerated > ago(${LookbackDays}d)
| summarize arg_max(TimeGenerated, *) by RecommendationId, AssessedResourceId
| where RecommendationState == "Unhealthy"
| where isnotempty(FirstEvaluationDate)
| extend 
    AgingDays             = datetime_diff('day', now(), FirstEvaluationDate),
    DaysSinceStatusChange = datetime_diff('day', now(), StatusChangeDate),
    ResourceType          = extract(@"/providers/([^/]+/[^/]+)", 1, AssessedResourceId),
    SubscriptionId        = extract(@"/subscriptions/([^/]+)", 1, AssessedResourceId)
| project 
    AgingDays, DaysSinceStatusChange, FirstEvaluationDate, StatusChangeDate,
    RecommendationSeverity, RecommendationDisplayName, RecommendationId,
    ResourceType, SubscriptionId, AssessedResourceId, RecommendationState
"@
        "RecommendationHistory" = @"
SecurityRecommendation
| where TimeGenerated > ago(${LookbackDays}d)
| extend 
    ResourceType   = extract(@"/providers/([^/]+/[^/]+)", 1, AssessedResourceId),
    SubscriptionId = extract(@"/subscriptions/([^/]+)", 1, AssessedResourceId)
| project 
    TimeGenerated, RecommendationState, RecommendationSeverity,
    RecommendationDisplayName, RecommendationId,
    ResourceType, SubscriptionId, AssessedResourceId,
    FirstEvaluationDate, StatusChangeDate
"@
        "SubAssessmentAging" = @"
SecurityNestedRecommendation
| where TimeGenerated > ago(${LookbackDays}d)
| summarize 
    FirstDetected = min(TimeGenerated),
    LatestSeen    = max(TimeGenerated),
    arg_max(TimeGenerated, RecommendationState, Description, AssessedResourceId, 
            RecommendationSeverity, Category, RecommendationName, VulnerabilityId)
    by Id
| where RecommendationState == "Unhealthy"
| extend 
    AgingDays    = datetime_diff('day', now(), FirstDetected),
    ResourceType = extract(@"/providers/([^/]+/[^/]+)", 1, AssessedResourceId),
    SubscriptionId = extract(@"/subscriptions/([^/]+)", 1, AssessedResourceId)
| project 
    AgingDays, FirstDetected, LatestSeen,
    RecommendationSeverity, Description, RecommendationName,
    VulnerabilityId, Category, ResourceType, SubscriptionId,
    AssessedResourceId, Id, RecommendationState
"@
        "SubAssessmentReoccurrence" = @"
SecurityNestedRecommendation
| where TimeGenerated > ago(${LookbackDays}d)
| project TimeGenerated, Id, RecommendationState, Description, AssessedResourceId, 
          RecommendationSeverity, Category, RecommendationName
| order by Id asc, TimeGenerated asc
| serialize
| extend PrevState = prev(RecommendationState), PrevId = prev(Id)
| where Id == PrevId
| where RecommendationState == "Unhealthy" and PrevState == "Healthy"
| summarize 
    ReoccurrenceCount = count(),
    LastReoccurrence  = max(TimeGenerated),
    FirstReoccurrence = min(TimeGenerated)
    by Id, Description, AssessedResourceId, RecommendationSeverity, Category
| extend 
    ResourceType   = extract(@"/providers/([^/]+/[^/]+)", 1, AssessedResourceId),
    SubscriptionId = extract(@"/subscriptions/([^/]+)", 1, AssessedResourceId)
| project 
    ReoccurrenceCount, LastReoccurrence, FirstReoccurrence,
    RecommendationSeverity, Description, Category,
    ResourceType, SubscriptionId, AssessedResourceId, Id
"@
    }

    $fileManifest = @()

    foreach ($queryName in $queries.Keys) {
        Write-Log "─── Running: $queryName ───"
        $query = $queries[$queryName]

        try {
            $result = Invoke-AzOperationalInsightsQuery `
                -WorkspaceId $WorkspaceId `
                -Query $query `
                -Timespan (New-TimeSpan -Days $LookbackDays) `
                -ErrorAction Stop

            $data = $result.Results
            $rowCount = ($data | Measure-Object).Count

            if ($rowCount -eq 0) {
                Write-Log "  $queryName — 0 rows returned" "WARN"
                continue
            }

            # Split if needed
            $dataArray = @($data)
            $fileIndex = 0
            for ($i = 0; $i -lt $dataArray.Count; $i += $MaxRowsPerFile) {
                $fileIndex++
                $end = [Math]::Min($i + $MaxRowsPerFile, $dataArray.Count)
                $chunk = $dataArray[$i..($end - 1)]
                $fileName = "PBI_${queryName}_${fileIndex}_${timestamp}.csv"
                $filePath = Join-Path $OutputPath $fileName
                $chunk | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8
                $fileManifest += [PSCustomObject]@{
                    File      = $fileName
                    Query     = $queryName
                    RowCount  = $chunk.Count
                    Part      = $fileIndex
                }
                Write-Log "  → $fileName ($($chunk.Count) rows)" "SUCCESS"
            }
        }
        catch {
            Write-Log "  Error running $queryName : $($_.Exception.Message)" "ERROR"
        }
    }

    $manifestPath = Join-Path $OutputPath "manifest_${timestamp}.csv"
    $fileManifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

    Write-Log ""
    Write-Log "═══════════════════════════════════════════════════════════"
    Write-Log "  LOG ANALYTICS EXPORT COMPLETE" "SUCCESS"
    Write-Log "═══════════════════════════════════════════════════════════"
    Write-Log "Output files : $($fileManifest.Count)"
    Write-Log "Directory    : $OutputPath"
    Write-Log ""
    Write-Log "Power BI Import Steps:" "SUCCESS"
    Write-Log "  1. Open Power BI Desktop"
    Write-Log "  2. Get Data → Folder → select '$OutputPath'"
    Write-Log "  3. Each query becomes a separate table in your data model"
    Write-Log "  4. Create relationships: RecommendationId, AssessedResourceId"
}
