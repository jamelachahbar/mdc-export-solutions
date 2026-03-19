<#
.SYNOPSIS
    Exports GeneralVulnerability sub-assessment findings from Azure Resource Graph
    with full pagination, severity ranking, and multiple output formats.

.DESCRIPTION
    Improved version of customer's original ARG vulnerability query, addressing:
    - ARG 1,000 row limit via skip-token pagination
    - Fragile ResourceGroup extraction replaced with regex
    - Case-safe field extraction with coalesce
    - Parameterized subscription and resource type filters
    - Severity ranking (High=4, Medium=3, Low=2, Informational=1)
    - Enrichment: patchable flag, CVSS score, software details, publish date, threat
    - Parent recommendation extracted from ARM ID
    - Optional recently-evaluated filter (-RecentHours)
    - Exports: full CSV, top CVEs, top resources, per-subscription splits
    - Optional upload to Azure Blob Storage or Data Lake Storage Gen2

    Supports multiple assessedResourceType values. Defaults to GeneralVulnerability
    but can be expanded to include SqlServerVulnerability, ServerVulnerabilityTvm, etc.

    STORAGE UPLOAD:
    When -StorageAccountName and -StorageContainer are provided, all exported CSVs are
    uploaded to the specified container. Authentication options:
      1. Entra ID (default) — uses your current Az context identity. Requires
         "Storage Blob Data Contributor" role on the container.
      2. SAS token — pass -StorageSasToken with a container-level SAS that has write permission.
    Files are uploaded to: <container>/<BlobPrefix><filename>.
    Works with both Blob Storage and ADLS Gen2 (hierarchical namespace enabled).

.PARAMETER SubscriptionIds
    Array of subscription IDs to query. If empty, queries all accessible subscriptions.

.PARAMETER AssessedResourceTypes
    The assessedResourceType values to include. Defaults to GeneralVulnerability.
    Common values: GeneralVulnerability, SqlServerVulnerability,
    SqlVirtualMachineVulnerability, ServerVulnerabilityTvm,
    ManagedAggregatedServerVulnerabilityTvm, DependencyCveVulnerability

.PARAMETER StatusFilter
    Which status codes to include. Default: "Unhealthy" only.
    Set to @("Unhealthy","NotApplicable") to match customer's original behaviour.

.PARAMETER OutputPath
    Folder for output files. Default: .\output\customer

.PARAMETER BatchSize
    Records per ARG API page (max 1000). Default: 1000.

.PARAMETER RecentHours
    If specified, filters to findings evaluated within this many hours (properties.timeGenerated).
    Mirrors the customer's original ago(48h) filter. Set to 0 to disable (default).
    NOTE: this filters to findings RE-EVALUATED in that window, not necessarily "new" findings.

.PARAMETER ExportPerSubscription
    If set, also exports a separate CSV per subscription.

.PARAMETER StorageAccountName
    Azure Storage account name for upload. Supports Blob Storage and ADLS Gen2.
    When set, requires -StorageContainer. Uses Entra ID auth by default.

.PARAMETER StorageContainer
    Container (or ADLS filesystem) name to upload CSVs to.

.PARAMETER StorageSasToken
    Optional SAS token for authentication (container-level, write permission).
    If omitted, uses the current Az context identity (Entra ID / managed identity).
    Must include the leading '?' character.

.PARAMETER BlobPrefix
    Optional path prefix for uploaded blobs. Default: "vulnerability-findings/<timestamp>/".
    Supports ADLS Gen2 directory-style paths (e.g., "raw/defender/2026/02/").

.EXAMPLE
    # Basic — all accessible subscriptions, GeneralVulnerability only
    .\Export-CustomerVulnerabilities.ps1

.EXAMPLE
    # Specific subscriptions + multiple resource types
    .\Export-CustomerVulnerabilities.ps1 `
        -SubscriptionIds @("1258f1cc-0960-432c-990f-da019164dca8") `
        -AssessedResourceTypes @("GeneralVulnerability","ServerVulnerabilityTvm")

.EXAMPLE
    # Include NotApplicable (match customer's original filter) + 48h recent filter
    .\Export-CustomerVulnerabilities.ps1 -StatusFilter @("Unhealthy","NotApplicable") -RecentHours 48

.EXAMPLE
    # Upload to Blob Storage using Entra ID auth
    .\Export-CustomerVulnerabilities.ps1 `
        -StorageAccountName "mystorage" `
        -StorageContainer "defender-exports"

.EXAMPLE
    # Upload to ADLS Gen2 with SAS token and custom path prefix
    .\Export-CustomerVulnerabilities.ps1 `
        -StorageAccountName "mydatalake" `
        -StorageContainer "security" `
        -StorageSasToken "?sv=2023-11-03&ss=b&srt=co&sp=rwac&se=...&sig=..." `
        -BlobPrefix "raw/defender/vulnerabilities/"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$AssessedResourceTypes = @("GeneralVulnerability"),

    [Parameter(Mandatory = $false)]
    [ValidateSet("Unhealthy", "Healthy", "NotApplicable")]
    [string[]]$StatusFilter = @("Unhealthy"),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\output\customer",

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 1000)]
    [int]$BatchSize = 1000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 8760)]
    [int]$RecentHours = 0,

    [Parameter(Mandatory = $false)]
    [switch]$ExportPerSubscription,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$StorageContainer,

    [Parameter(Mandatory = $false)]
    [string]$StorageSasToken,

    [Parameter(Mandatory = $false)]
    [string]$BlobPrefix
)

$ErrorActionPreference = "Stop"

# Timestamp for filenames and blob prefix — set early so storage validation can use it
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
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
# Validate storage parameters
# ─────────────────────────────────────────────────────────────────────────────
$uploadToStorage = $false
if ($StorageAccountName -or $StorageContainer) {
    if (-not $StorageAccountName -or -not $StorageContainer) {
        throw "Both -StorageAccountName and -StorageContainer must be specified together."
    }
    $uploadToStorage = $true
    # Default blob prefix: vulnerability-findings/<timestamp>/
    if (-not $BlobPrefix) {
        $BlobPrefix = "vulnerability-findings/$timestamp/"
    }
    # Ensure prefix ends with /
    if ($BlobPrefix -and -not $BlobPrefix.EndsWith('/')) {
        $BlobPrefix = "$BlobPrefix/"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
$requiredModules = @("Az.Accounts", "Az.ResourceGraph")
if ($uploadToStorage) {
    $requiredModules += "Az.Storage"
}
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Log "Installing module: $mod" "WARN"
        Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $mod -ErrorAction Stop
}

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount
}

# Output setup
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Build ARG query
# ─────────────────────────────────────────────────────────────────────────────
# Build the assessedResourceType filter as a KQL in() list
$typeFilterList = ($AssessedResourceTypes | ForEach-Object { "`"$_`"" }) -join ", "
$statusFilterList = ($StatusFilter | ForEach-Object { "`"$_`"" }) -join ", "

# Build optional recently-evaluated filter
$recentFilter = ""
if ($RecentHours -gt 0) {
    $recentFilter = "| where todatetime(properties.timeGenerated) >= ago(${RecentHours}h)"
}

$argQuery = @"
securityresources
| where type =~ "microsoft.security/assessments/subassessments"
| where tostring(properties.additionalData.assessedResourceType) in ($typeFilterList)
| extend statusCode = tostring(properties.status.code)
| where statusCode in ($statusFilterList)
$recentFilter
| extend ResourceId = tolower(coalesce(
    tostring(properties.resourceDetails.id),
    tostring(properties.resourceDetails.Id)))
| extend ResourceGroup = extract(@"(?i)/resourcegroups/([^/]+)", 1, ResourceId)
| extend ResourceName  = extract(@"([^/]+)$", 1, ResourceId)
| extend Severity = coalesce(
    tostring(properties.status.severity),
    tostring(properties.additionalData.severity))
| extend SeverityRank = case(
    Severity =~ "High",          4,
    Severity =~ "Medium",        3,
    Severity =~ "Low",           2,
    Severity =~ "Informational" or Severity =~ "Info", 1,
    0)
| extend timeGenerated = todatetime(properties.timeGenerated)
| extend Patchable       = tostring(properties.additionalData.patchable)
| extend CvssScore       = toreal(properties.additionalData.cvss.base)
| extend SoftwareVendor  = tostring(properties.additionalData.softwareVendor)
| extend SoftwareName    = tostring(properties.additionalData.softwareName)
| extend SoftwareVersion = tostring(properties.additionalData.softwareVersion)
| extend PublishedDate    = todatetime(properties.additionalData.publishedTime)
| extend Threat           = tostring(properties.additionalData.threat)
| extend ParentRecommendation = extract(@"microsoft.security/assessments/([^/]+)/subassessments", 1, tolower(id))
| summarize arg_max(timeGenerated, *) by ResourceId, tostring(properties.id)
| project
    ResourceId,
    id,
    subscriptionId,
    CVE              = tostring(properties.id),
    ResourceGroup,
    ResourceName,
    ResourceType     = tostring(properties.additionalData.assessedResourceType),
    Severity,
    SeverityRank,
    CvssScore,
    Patchable,
    Vulnerability    = tostring(properties.displayName),
    timeGenerated,
    PublishedDate,
    SoftwareVendor,
    SoftwareName,
    SoftwareVersion,
    Description      = tostring(properties.status.description),
    Impact           = tostring(properties.impact),
    Remediation      = tostring(properties.remediation),
    Category         = tostring(properties.category),
    Threat,
    ParentRecommendation,
    Status           = statusCode
| order by SeverityRank desc, CvssScore desc, timeGenerated desc
"@

# ─────────────────────────────────────────────────────────────────────────────
# Paginated extraction (bypass ARG limit)
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "  Customer Vulnerability Export — ARG Paginated"
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "Assessed resource types : $($AssessedResourceTypes -join ', ')"
Write-Log "Status filter           : $($StatusFilter -join ', ')"
if ($RecentHours -gt 0) {
    Write-Log "Recent filter           : Last ${RecentHours}h only"
} else {
    Write-Log "Recent filter           : Disabled (all active findings)"
}
Write-Log "Batch size              : $BatchSize"
if ($SubscriptionIds.Count -gt 0) {
    Write-Log "Subscriptions           : $($SubscriptionIds -join ', ')"
} else {
    Write-Log "Subscriptions           : All accessible"
}
Write-Log ""

$allResults = [System.Collections.Generic.List[object]]::new()
$skipToken = $null
$batchNumber = 0
$totalFetched = 0

# Build Search-AzGraph parameters
$queryParams = @{
    Query = $argQuery
    First = $BatchSize
}
if ($SubscriptionIds.Count -gt 0) {
    $queryParams["Subscription"] = $SubscriptionIds
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

do {
    $batchNumber++

    if ($skipToken) {
        $queryParams["SkipToken"] = $skipToken
    }

    try {
        $response = Search-AzGraph @queryParams -ErrorAction Stop

        $batchCount = ($response.Data | Measure-Object).Count
        if ($batchCount -eq 0 -and $batchNumber -eq 1) {
            Write-Log "No results returned. Check subscription access and resource types." "WARN"
            Write-Log "Tip: Run the query in section 6 of vulnerability-findings.kql to see available assessedResourceType values." "WARN"
            break
        }

        $response.Data | ForEach-Object { $allResults.Add($_) }
        $totalFetched += $batchCount
        $skipToken = $response.SkipToken

        Write-Log "Batch $batchNumber : $batchCount records (total: $totalFetched)"

        # Throttle protection — pause every 10 batches
        if ($batchNumber % 10 -eq 0) {
            Write-Log "Pausing 2s for throttle protection..."
            Start-Sleep -Seconds 2
        }
    }
    catch {
        Write-Log "Error on batch ${batchNumber}: $($_.Exception.Message)" "ERROR"
        if ($batchNumber -gt 1) {
            Write-Log "Saving $totalFetched records collected so far..." "WARN"
            break
        }
        throw
    }

} while ($null -ne $skipToken)

$stopwatch.Stop()
Write-Log ""
Write-Log "Extraction complete: $totalFetched records in $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s"

# ─────────────────────────────────────────────────────────────────────────────
# Export results
# ─────────────────────────────────────────────────────────────────────────────
if ($allResults.Count -eq 0) {
    Write-Log "No findings to export." "WARN"
    return
}

# 1. Full export
$fullCsv = Join-Path $OutputPath "CustomerVulnerabilities_Full_$timestamp.csv"
$allResults | Export-Csv -Path $fullCsv -NoTypeInformation -Encoding UTF8
Write-Log "Exported full dataset  : $fullCsv" "SUCCESS"

# 2. Severity breakdown summary
Write-Log ""
Write-Log "─── Severity Breakdown ───"
$severityBreakdown = $allResults |
    Group-Object -Property Severity |
    Select-Object @{N='Severity'; E={$_.Name}}, Count |
    Sort-Object Count -Descending

$severityBreakdown | ForEach-Object {
    Write-Log "  $($_.Severity): $($_.Count)"
}

# 3. Patchable summary
$patchableCount = ($allResults | Where-Object { $_.Patchable -eq 'true' } | Measure-Object).Count
$totalCount = $allResults.Count
Write-Log ""
Write-Log "─── Patchable Status ───"
Write-Log "  Patchable (fix available): $patchableCount / $totalCount ($([math]::Round(100.0 * $patchableCount / [math]::Max($totalCount, 1), 1))%)"

# 4. Top 20 CVEs by affected resource count
Write-Log ""
Write-Log "─── Top 20 CVEs (by affected resources) ───"
$topCVEs = $allResults |
    Group-Object -Property CVE |
    Select-Object @{N='CVE'; E={$_.Name}},
                  @{N='AffectedResources'; E={$_.Count}},
                  @{N='Severity'; E={($_.Group | Select-Object -First 1).Severity}},
                  @{N='CvssScore'; E={($_.Group | Select-Object -First 1).CvssScore}},
                  @{N='Patchable'; E={($_.Group | Select-Object -First 1).Patchable}},
                  @{N='Vulnerability'; E={($_.Group | Select-Object -First 1).Vulnerability}} |
    Sort-Object AffectedResources -Descending |
    Select-Object -First 20

$topCVEs | ForEach-Object {
    $patch = if ($_.Patchable -eq 'true') { ' [PATCHABLE]' } else { '' }
    $cvss  = if ($_.CvssScore) { " CVSS:$($_.CvssScore)" } else { '' }
    Write-Log "  $($_.CVE) [$($_.Severity)$cvss]$patch — $($_.AffectedResources) resources — $($_.Vulnerability)"
}

$topCvesCsv = Join-Path $OutputPath "CustomerVulnerabilities_TopCVEs_$timestamp.csv"
$topCVEs | Export-Csv -Path $topCvesCsv -NoTypeInformation -Encoding UTF8

# 4. Top 20 most affected resources
Write-Log ""
Write-Log "─── Top 20 Affected Resources ───"
$topResources = $allResults |
    Group-Object -Property ResourceId |
    Select-Object @{N='ResourceId'; E={$_.Name}},
                  @{N='ResourceName'; E={($_.Group | Select-Object -First 1).ResourceName}},
                  @{N='ResourceGroup'; E={($_.Group | Select-Object -First 1).ResourceGroup}},
                  @{N='TotalFindings'; E={$_.Count}},
                  @{N='HighCount'; E={($_.Group | Where-Object { $_.Severity -eq 'High' } | Measure-Object).Count}} |
    Sort-Object @{Expression='HighCount'; Descending=$true}, @{Expression='TotalFindings'; Descending=$true} |
    Select-Object -First 20

$topResources | ForEach-Object {
    Write-Log "  $($_.ResourceName) [$($_.ResourceGroup)] — $($_.TotalFindings) findings ($($_.HighCount) High)"
}

$topResourcesCsv = Join-Path $OutputPath "CustomerVulnerabilities_TopResources_$timestamp.csv"
$topResources | Export-Csv -Path $topResourcesCsv -NoTypeInformation -Encoding UTF8

# 5. Per-subscription export (optional)
if ($ExportPerSubscription) {
    Write-Log ""
    Write-Log "─── Per-Subscription Exports ───"
    $bySub = $allResults | Group-Object -Property subscriptionId
    foreach ($group in $bySub) {
        $subCsv = Join-Path $OutputPath "CustomerVulnerabilities_$($group.Name)_$timestamp.csv"
        $group.Group | Export-Csv -Path $subCsv -NoTypeInformation -Encoding UTF8
        Write-Log "  Subscription $($group.Name): $($group.Count) findings → $subCsv"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Upload to Azure Storage (Blob / ADLS Gen2)
# ─────────────────────────────────────────────────────────────────────────────
$uploadedFiles = @()
if ($uploadToStorage) {
    Write-Log ""
    Write-Log "─── Uploading to Azure Storage ───"
    Write-Log "Account   : $StorageAccountName"
    Write-Log "Container : $StorageContainer"
    Write-Log "Prefix    : $BlobPrefix"
    $authMethod = if ($StorageSasToken) { "SAS token" } else { "Entra ID (Az context)" }
    Write-Log "Auth      : $authMethod"

    try {
        # Build storage context
        if ($StorageSasToken) {
            $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $StorageSasToken
        } else {
            # Entra ID / OAuth — requires Storage Blob Data Contributor on the container
            $storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
        }

        # Collect all CSV files from OutputPath that match this run's timestamp
        $csvFiles = Get-ChildItem -Path $OutputPath -Filter "*$timestamp*.csv" -File

        foreach ($csvFile in $csvFiles) {
            $blobName = "$BlobPrefix$($csvFile.Name)"
            try {
                Set-AzStorageBlobContent `
                    -File $csvFile.FullName `
                    -Container $StorageContainer `
                    -Blob $blobName `
                    -Context $storageCtx `
                    -Force `
                    -ErrorAction Stop | Out-Null

                $uploadedFiles += $blobName
                Write-Log "  Uploaded: $blobName" "SUCCESS"
            }
            catch {
                Write-Log "  Failed to upload $($csvFile.Name): $($_.Exception.Message)" "ERROR"
            }
        }

        Write-Log "Uploaded $($uploadedFiles.Count) / $($csvFiles.Count) files" "SUCCESS"
    }
    catch {
        Write-Log "Storage connection failed: $($_.Exception.Message)" "ERROR"
        Write-Log "Local CSV files are still available in: $OutputPath" "WARN"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Log ""
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "  EXPORT COMPLETE" "SUCCESS"
Write-Log "═══════════════════════════════════════════════════════════"
Write-Log "Output directory  : $OutputPath"
Write-Log "Total findings    : $totalFetched"
Write-Log "Unique CVEs       : $(($allResults | Select-Object -Property CVE -Unique | Measure-Object).Count)"
Write-Log "Unique resources  : $(($allResults | Select-Object -Property ResourceId -Unique | Measure-Object).Count)"
Write-Log "Subscriptions     : $(($allResults | Select-Object -Property subscriptionId -Unique | Measure-Object).Count)"
if ($uploadToStorage) {
    Write-Log "Blobs uploaded    : $($uploadedFiles.Count)"
}
Write-Log "Elapsed time      : $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s"
