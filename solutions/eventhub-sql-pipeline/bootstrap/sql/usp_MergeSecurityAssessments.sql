-- ============================================================================
-- Stored Procedure : dbo.usp_MergeSecurityAssessments
-- Purpose          : Upsert / delete rows in dbo.SecurityAssessments from
--                    dbo.SecurityAssessments_Raw using the latest event per id.
--
-- Called by        : Azure Stream Analytics / Azure Function / SQL Agent job
--                    after rows have been bulk-inserted into SecurityAssessments_Raw.
--
-- Design notes:
--   • DEDUP: Same id can arrive on multiple Event Hub partitions (round-robin).
--     ROW_NUMBER() keeps only the LATEST event per id (EventEnqueuedUtcTime DESC)
--     to prevent the "attempted to UPDATE or DELETE the same row more than once"
--     MERGE error.
--   • ActionType 'Delete' removes the row only when the incoming event is at
--     least as recent as the row already stored (LastEnqueuedUtcTime).
--   • ActionType 'Insert' updates mutable fields only when the event is newer.
--   • All work runs inside an explicit transaction; the caller receives a
--     meaningful error message on failure.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_MergeSecurityAssessments
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- auto-rollback on any error

    BEGIN TRY
        BEGIN TRANSACTION;

        MERGE dbo.SecurityAssessments AS target
        USING
        (
            SELECT
                r.tenantId,
                r.id,
                r.name,
                r.type,
                r.location,
                r.kind,
                r.tags,

                p.displayName,
                p.description,
                p.statusCode,
                p.severity,
                p.statusCause,
                p.statusDescription,
                p.policyDefinitionId,
                p.assessmentType,
                p.implementationEffort,
                p.userImpact,
                p.categories,
                p.threats,
                p.resourceId,
                p.resourceName,
                p.resourceType,
                p.resourceProvider,
                p.source,
                p.riskLevel,
                p.riskAttackPaths,
                p.firstEvaluationDate,
                p.statusChangeDate,
                p.timeGenerated,

                r.properties,
                r.EventEnqueuedUtcTime,
                JSON_VALUE(r.assessmentEventDataEnrichment, '$.action') AS ActionType

            FROM
            (
                -- Rank events per id: latest enqueue time wins across all partitions
                SELECT *,
                    ROW_NUMBER() OVER (
                        PARTITION BY id
                        ORDER BY EventEnqueuedUtcTime DESC
                    ) AS _rn
                FROM dbo.SecurityAssessments_Raw
            ) r

            OUTER APPLY OPENJSON(r.properties)
            WITH (
                displayName          NVARCHAR(500)  '$.displayName',
                description          NVARCHAR(MAX)  '$.description',

                statusCode           NVARCHAR(50)   '$.status.code',
                severity             NVARCHAR(50)   '$.status.severity',
                statusCause          NVARCHAR(100)  '$.status.cause',
                statusDescription    NVARCHAR(MAX)  '$.status.description',

                policyDefinitionId   NVARCHAR(1000) '$.metadata.policyDefinitionId',
                assessmentType       NVARCHAR(100)  '$.metadata.assessmentType',
                implementationEffort NVARCHAR(100)  '$.metadata.implementationEffort',
                userImpact           NVARCHAR(200)  '$.metadata.userImpact',
                categories           NVARCHAR(400)  '$.metadata.categories',
                threats              NVARCHAR(400)  '$.metadata.threats',

                resourceId           NVARCHAR(1000) '$.resourceDetails.id',
                resourceName         NVARCHAR(400)  '$.resourceDetails.resourceName',
                resourceType         NVARCHAR(400)  '$.resourceDetails.resourceType',
                resourceProvider     NVARCHAR(400)  '$.resourceDetails.resourceProvider',
                source               NVARCHAR(100)  '$.resourceDetails.source',

                riskLevel            NVARCHAR(50)   '$.risk.level',
                riskAttackPaths      INT            '$.risk.attackPathsReferences',

                firstEvaluationDate  DATETIME2      '$.status.firstEvaluationDate',
                statusChangeDate     DATETIME2      '$.status.statusChangeDate',
                timeGenerated        DATETIME2      '$.timeGenerated'
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
                target.severity          = source.severity,
                target.statusCode        = source.statusCode,
                target.statusCause       = source.statusCause,
                target.statusDescription = source.statusDescription,
                target.riskLevel         = source.riskLevel,
                target.statusChangeDate  = source.statusChangeDate,
                target.timeGenerated     = source.timeGenerated,
                target.properties        = source.properties,
                target.LastEnqueuedUtcTime = source.EventEnqueuedUtcTime

        WHEN NOT MATCHED AND source.ActionType = 'Insert'
            THEN INSERT
            (
                tenantId,
                id,
                name,
                type,
                location,
                kind,
                tags,
                displayName,
                description,
                statusCode,
                severity,
                statusCause,
                statusDescription,
                policyDefinitionId,
                assessmentType,
                implementationEffort,
                userImpact,
                categories,
                threats,
                resourceId,
                resourceName,
                resourceType,
                resourceProvider,
                source,
                riskLevel,
                riskAttackPaths,
                firstEvaluationDate,
                statusChangeDate,
                timeGenerated,
                properties
            )
            VALUES
            (
                source.tenantId,
                source.id,
                source.name,
                source.type,
                source.location,
                source.kind,
                source.tags,
                source.displayName,
                source.description,
                source.statusCode,
                source.severity,
                source.statusCause,
                source.statusDescription,
                source.policyDefinitionId,
                source.assessmentType,
                source.implementationEffort,
                source.userImpact,
                source.categories,
                source.threats,
                source.resourceId,
                source.resourceName,
                source.resourceType,
                source.resourceProvider,
                source.source,
                source.riskLevel,
                source.riskAttackPaths,
                source.firstEvaluationDate,
                source.statusChangeDate,
                source.timeGenerated,
                source.properties
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
