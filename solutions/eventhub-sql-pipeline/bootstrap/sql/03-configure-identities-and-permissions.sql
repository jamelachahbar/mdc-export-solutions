/*
Run against the findings database.
Creates contained users for:
- Elastic Job User-Assigned Managed Identity (UMI)
- Stream Analytics Assessments job (system-assigned MI)
- Stream Analytics SubAssessments job (system-assigned MI)

All grants are idempotent and safe to rerun.
*/

:setvar ElasticJobUmiName mi-elastic-job-agent
:setvar ElasticJobUmiClientId 00000000-0000-0000-0000-000000000000
:setvar AsaAssessmentsPrincipalName asa-defender-assessments
:setvar AsaSubAssessmentsPrincipalName asa-defender-subassessments

DECLARE @elasticUser sysname = N'$(ElasticJobUmiName)';
DECLARE @elasticClientId uniqueidentifier = CAST('$(ElasticJobUmiClientId)' AS uniqueidentifier);
DECLARE @asaAssessments sysname = N'$(AsaAssessmentsPrincipalName)';
DECLARE @asaSubAssessments sysname = N'$(AsaSubAssessmentsPrincipalName)';

IF @elasticUser IS NOT NULL AND @elasticUser <> N''
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @elasticUser)
    BEGIN
        -- Use SID + TYPE = E to avoid ambiguity when multiple principals share the same display name
        DECLARE @createElastic nvarchar(max) = N'CREATE USER [' + REPLACE(@elasticUser, ']', ']]') + N'] WITH SID = ' + CONVERT(nvarchar(max), CAST(@elasticClientId AS varbinary(16)), 1) + N', TYPE = E;';
        EXEC (@createElastic);
    END;

    DECLARE @grantElasticConnect nvarchar(max) = N'GRANT CONNECT TO [' + REPLACE(@elasticUser, ']', ']]') + N'];';
    EXEC (@grantElasticConnect);

    DECLARE @grantElasticExecA nvarchar(max) = N'GRANT EXECUTE ON OBJECT::dbo.usp_MergeSecurityAssessments TO [' + REPLACE(@elasticUser, ']', ']]') + N'];';
    EXEC (@grantElasticExecA);

    DECLARE @grantElasticExecS nvarchar(max) = N'GRANT EXECUTE ON OBJECT::dbo.usp_MergeSecuritySubAssessments TO [' + REPLACE(@elasticUser, ']', ']]') + N'];';
    EXEC (@grantElasticExecS);
END;

-- ASA Assessments job → SecurityAssessments_Raw
IF @asaAssessments IS NOT NULL AND @asaAssessments <> N''
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @asaAssessments)
    BEGIN
        DECLARE @createAsaA nvarchar(max) = N'CREATE USER [' + REPLACE(@asaAssessments, ']', ']]') + N'] FROM EXTERNAL PROVIDER;';
        EXEC (@createAsaA);
    END;

    DECLARE @grantAsaAConnect nvarchar(max) = N'GRANT CONNECT TO [' + REPLACE(@asaAssessments, ']', ']]') + N'];';
    EXEC (@grantAsaAConnect);

    DECLARE @grantAsaATable nvarchar(max) = N'GRANT SELECT, INSERT ON OBJECT::dbo.SecurityAssessments_Raw TO [' + REPLACE(@asaAssessments, ']', ']]') + N'];';
    EXEC (@grantAsaATable);
END;

-- ASA SubAssessments job → SecuritySubAssessments_Raw
IF @asaSubAssessments IS NOT NULL AND @asaSubAssessments <> N''
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @asaSubAssessments)
    BEGIN
        DECLARE @createAsaS nvarchar(max) = N'CREATE USER [' + REPLACE(@asaSubAssessments, ']', ']]') + N'] FROM EXTERNAL PROVIDER;';
        EXEC (@createAsaS);
    END;

    DECLARE @grantAsaSConnect nvarchar(max) = N'GRANT CONNECT TO [' + REPLACE(@asaSubAssessments, ']', ']]') + N'];';
    EXEC (@grantAsaSConnect);

    DECLARE @grantAsaSTable nvarchar(max) = N'GRANT SELECT, INSERT ON OBJECT::dbo.SecuritySubAssessments_Raw TO [' + REPLACE(@asaSubAssessments, ']', ']]') + N'];';
    EXEC (@grantAsaSTable);
END;
GO

SELECT
    dp.name,
    dp.type_desc,
    dp.authentication_type_desc
FROM sys.database_principals dp
WHERE dp.name IN (N'$(ElasticJobUmiName)', N'$(AsaAssessmentsPrincipalName)', N'$(AsaSubAssessmentsPrincipalName)');
GO
