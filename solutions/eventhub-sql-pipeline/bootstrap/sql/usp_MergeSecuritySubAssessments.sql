-- ============================================================================
-- Stored Procedure : dbo.usp_MergeSecuritySubAssessments
-- Purpose          : Upsert / delete rows in dbo.SecuritySubAssessments from
--                    dbo.SecuritySubAssessments_Raw using the latest event per id.
--
-- Called by        : Azure Stream Analytics / Azure Function / SQL Agent job
--                    after rows have been bulk-inserted into SecuritySubAssessments_Raw.
--
-- Design notes:
--   • DEDUP: Same id can arrive on multiple Event Hub partitions (round-robin).
--     ROW_NUMBER() keeps only the LATEST event per id (EventEnqueuedUtcTime DESC)
--     to prevent the "attempted to UPDATE or DELETE the same row more than once"
--     MERGE error.
--   • ActionType is read from subAssessmentEventDataEnrichment (not
--     assessmentEventDataEnrichment).
--   • Severity: COALESCE(status.severity, additionalData.severity) because
--     sub-assessments populate either field depending on type.
--   • CE sends ARM REST API format.  Polymorphic fields (software, CVE,
--     Kubernetes, etc.) are DIRECTLY under additionalData — NOT under
--     additionalData.data (which is ARG-only).  If columns are NULL after
--     first ingestion, inspect raw data to confirm paths:
--       SELECT TOP 5 JSON_QUERY(properties, '$.additionalData')
--       FROM dbo.SecuritySubAssessments_Raw
--   • All work runs inside an explicit transaction; the caller receives a
--     meaningful error message on failure.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_MergeSecuritySubAssessments
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- auto-rollback on any error

    BEGIN TRY
        BEGIN TRANSACTION;

        MERGE dbo.SecuritySubAssessments AS target
        USING
        (
            SELECT
                r.tenantId,
                r.id,
                r.name,
                r.type,

                -- Top-level properties
                p.displayName,
                p.description,
                p.category,
                p.vulnerabilityId,
                p.impact,
                p.remediation,

                p.statusCode,
                -- Severity: COALESCE status.severity with additionalData.severity
                -- because sub-assessments use either location depending on type
                COALESCE(p.statusSeverity, p.additionalDataSeverity) AS severity,
                p.statusCause,
                p.statusDescription,
                p.timeGenerated,

                p.nativeResourceId,
                p.resourceId,
                p.resourceName,
                p.resourceType,
                p.resourceProvider,
                p.[source],

                p.assessedResourceType,

                -- Kubernetes
                p.clusterName,
                p.clusterResourceId,
                p.[namespace],
                p.controllerKind,
                p.controllerName,
                p.podName,
                p.containerName,

                -- Artifact
                p.repositoryName,
                p.registryHost,
                p.digest,
                p.artifactType,

                -- Software
                p.packageName,
                p.packageVendor,
                p.packageVersion,
                p.fixedVersion,
                p.patchable,
                p.fixStatus,
                p.[language],
                p.osPlatform,
                p.osVersion,

                -- Vulnerability
                p.cveId,
                p.vulnerabilitySeverity,
                p.publishedDate,
                p.lastModifiedDate,
                p.cvssScore,
                p.cvssVector,

                -- CPE
                p.cpeUri,
                p.cpeVendor,
                p.cpeProduct,
                p.cpeVersion,

                -- Weakness
                p.cweId,

                -- Scanner
                p.inventorySource,
                p.scanner,

                r.properties,
                r.EventEnqueuedUtcTime,
                JSON_VALUE(r.subAssessmentEventDataEnrichment, '$.action') AS ActionType

            FROM
            (
                -- Rank events per id: latest enqueue time wins across all partitions
                SELECT *,
                    ROW_NUMBER() OVER (
                        PARTITION BY id
                        ORDER BY EventEnqueuedUtcTime DESC
                    ) AS _rn
                FROM dbo.SecuritySubAssessments_Raw
            ) r

            OUTER APPLY OPENJSON(r.properties)
            WITH (
                -- Top-level sub-assessment fields (all types)
                displayName          NVARCHAR(500)  '$.displayName',
                description          NVARCHAR(MAX)  '$.description',
                category             NVARCHAR(200)  '$.category',
                vulnerabilityId      NVARCHAR(200)  '$.id',          -- properties.id = CVE/vuln ID
                impact               NVARCHAR(MAX)  '$.impact',
                remediation          NVARCHAR(MAX)  '$.remediation',

                -- Status
                statusCode           NVARCHAR(50)   '$.status.code',
                statusSeverity       NVARCHAR(50)   '$.status.severity',
                additionalDataSeverity NVARCHAR(50) '$.additionalData.severity',
                statusCause          NVARCHAR(100)  '$.status.cause',
                statusDescription    NVARCHAR(MAX)  '$.status.description',
                timeGenerated        DATETIME2      '$.timeGenerated',

                -- Resource details
                nativeResourceId     NVARCHAR(1000) '$.resourceDetails.nativeResourceId',
                resourceId           NVARCHAR(1000) '$.resourceDetails.id',
                resourceName         NVARCHAR(400)  '$.resourceDetails.resourceName',
                resourceType         NVARCHAR(400)  '$.resourceDetails.resourceType',
                resourceProvider     NVARCHAR(400)  '$.resourceDetails.resourceProvider',
                [source]             NVARCHAR(100)  '$.resourceDetails.source',

                -- Discriminator for additionalData polymorphism
                assessedResourceType NVARCHAR(200)  '$.additionalData.assessedResourceType',

                -- Kubernetes (CE ARM format: directly under additionalData, no .data wrapper)
                clusterName          NVARCHAR(200)  '$.additionalData.clusterName',
                clusterResourceId    NVARCHAR(1000) '$.additionalData.clusterResourceId',
                [namespace]          NVARCHAR(200)  '$.additionalData.namespace',
                controllerKind       NVARCHAR(200)  '$.additionalData.controllerKind',
                controllerName       NVARCHAR(200)  '$.additionalData.controllerName',
                podName              NVARCHAR(200)  '$.additionalData.podName',
                containerName        NVARCHAR(200)  '$.additionalData.containerName',

                -- Artifact (CE ARM format: directly under additionalData)
                repositoryName       NVARCHAR(400)  '$.additionalData.repositoryName',
                registryHost         NVARCHAR(400)  '$.additionalData.registryHost',
                digest               NVARCHAR(200)  '$.additionalData.digest',
                artifactType         NVARCHAR(200)  '$.additionalData.artifactType',

                -- Software (CE ARM format: additionalData.softwareDetails, no .data wrapper)
                packageName          NVARCHAR(300)  '$.additionalData.softwareDetails.packageName',
                packageVendor        NVARCHAR(300)  '$.additionalData.softwareDetails.vendor',
                packageVersion       NVARCHAR(100)  '$.additionalData.softwareDetails.version',
                fixedVersion         NVARCHAR(100)  '$.additionalData.softwareDetails.fixedVersion',
                patchable            BIT            '$.additionalData.softwareDetails.patchable',
                fixStatus            NVARCHAR(100)  '$.additionalData.softwareDetails.fixStatus',
                [language]           NVARCHAR(100)  '$.additionalData.softwareDetails.language',
                osPlatform           NVARCHAR(100)  '$.additionalData.softwareDetails.osPlatform',
                osVersion            NVARCHAR(100)  '$.additionalData.softwareDetails.osVersion',

                -- Vulnerability (CE ARM format: directly under additionalData)
                cveId                NVARCHAR(100)  '$.additionalData.cve[0].title',
                vulnerabilitySeverity NVARCHAR(50)  '$.additionalData.cveSeverity',
                publishedDate        DATETIME2      '$.additionalData.publishedDate',
                lastModifiedDate     DATETIME2      '$.additionalData.lastModifiedDate',
                cvssScore            DECIMAL(5,2)   '$.additionalData.cvss.base',
                cvssVector           NVARCHAR(200)  '$.additionalData.cvss.vector',

                -- CPE (CE ARM format: directly under additionalData)
                cpeUri               NVARCHAR(1000) '$.additionalData.cpe.uri',
                cpeVendor            NVARCHAR(300)  '$.additionalData.cpe.vendor',
                cpeProduct           NVARCHAR(300)  '$.additionalData.cpe.product',
                cpeVersion           NVARCHAR(100)  '$.additionalData.cpe.version',

                -- Weakness (CE ARM format: directly under additionalData)
                cweId                NVARCHAR(100)  '$.additionalData.weakness.cwe[0].id',

                -- Scanner (CE ARM format: directly under additionalData)
                inventorySource      NVARCHAR(200)  '$.additionalData.inventorySource',
                scanner              NVARCHAR(200)  '$.additionalData.scanner'
            ) p

            WHERE r._rn = 1   -- keep only the latest event per id
        ) AS source
        ON target.id = source.id

        -- Delete: only if we don't already have a newer state in the target
        WHEN MATCHED AND source.ActionType = 'Delete'
            AND (target.LastEnqueuedUtcTime IS NULL OR source.EventEnqueuedUtcTime >= target.LastEnqueuedUtcTime)
            THEN DELETE

        -- Update: only if the incoming event is newer than what's already stored
        WHEN MATCHED AND source.ActionType = 'Insert'
            AND (target.LastEnqueuedUtcTime IS NULL OR source.EventEnqueuedUtcTime >= target.LastEnqueuedUtcTime)
            THEN UPDATE SET
                target.displayName           = source.displayName,
                target.description           = source.description,
                target.category              = source.category,
                target.impact                = source.impact,
                target.remediation           = source.remediation,
                target.statusCode            = source.statusCode,
                target.severity              = source.severity,
                target.statusCause           = source.statusCause,
                target.statusDescription     = source.statusDescription,
                target.timeGenerated         = source.timeGenerated,
                target.nativeResourceId      = source.nativeResourceId,
                target.assessedResourceType  = source.assessedResourceType,
                target.clusterName           = source.clusterName,
                target.clusterResourceId     = source.clusterResourceId,
                target.[namespace]           = source.[namespace],
                target.controllerKind        = source.controllerKind,
                target.controllerName        = source.controllerName,
                target.podName               = source.podName,
                target.containerName         = source.containerName,
                target.packageVersion        = source.packageVersion,
                target.fixedVersion          = source.fixedVersion,
                target.patchable             = source.patchable,
                target.fixStatus             = source.fixStatus,
                target.vulnerabilitySeverity = source.vulnerabilitySeverity,
                target.lastModifiedDate      = source.lastModifiedDate,
                target.cvssScore             = source.cvssScore,
                target.cvssVector            = source.cvssVector,
                target.properties            = source.properties,
                target.LastEnqueuedUtcTime   = source.EventEnqueuedUtcTime

        WHEN NOT MATCHED AND source.ActionType = 'Insert'
            THEN INSERT
            (
                tenantId, id, name, type,
                displayName, description, category, vulnerabilityId, impact, remediation,
                statusCode, severity, statusCause, statusDescription, timeGenerated,
                nativeResourceId, resourceId, resourceName, resourceType, resourceProvider, [source],
                assessedResourceType,
                clusterName, clusterResourceId, [namespace], controllerKind, controllerName, podName, containerName,
                repositoryName, registryHost, digest, artifactType,
                packageName, packageVendor, packageVersion, fixedVersion, patchable, fixStatus, [language], osPlatform, osVersion,
                cveId, vulnerabilitySeverity, publishedDate, lastModifiedDate, cvssScore, cvssVector,
                cpeUri, cpeVendor, cpeProduct, cpeVersion,
                cweId,
                inventorySource, scanner,
                properties, LastEnqueuedUtcTime
            )
            VALUES
            (
                source.tenantId, source.id, source.name, source.type,
                source.displayName, source.description, source.category, source.vulnerabilityId, source.impact, source.remediation,
                source.statusCode, source.severity, source.statusCause, source.statusDescription, source.timeGenerated,
                source.nativeResourceId, source.resourceId, source.resourceName, source.resourceType, source.resourceProvider, source.[source],
                source.assessedResourceType,
                source.clusterName, source.clusterResourceId, source.[namespace], source.controllerKind, source.controllerName, source.podName, source.containerName,
                source.repositoryName, source.registryHost, source.digest, source.artifactType,
                source.packageName, source.packageVendor, source.packageVersion, source.fixedVersion, source.patchable, source.fixStatus, source.[language], source.osPlatform, source.osVersion,
                source.cveId, source.vulnerabilitySeverity, source.publishedDate, source.lastModifiedDate, source.cvssScore, source.cvssVector,
                source.cpeUri, source.cpeVendor, source.cpeProduct, source.cpeVersion,
                source.cweId,
                source.inventorySource, source.scanner,
                source.properties, source.EventEnqueuedUtcTime
            );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;   -- re-raise the original error to the caller
    END CATCH;
END;
GO
