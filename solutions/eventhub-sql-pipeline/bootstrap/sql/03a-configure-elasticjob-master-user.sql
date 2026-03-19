/*
Run against master database on the target logical SQL server.

Purpose:
- Create the Elastic Job UMI principal in master when Elastic Job target groups
  use SqlServer or SqlElasticPool scope (server/pool expansion).

Safe to rerun.
*/

:setvar ElasticJobUmiName mi-elastic-job-agent
:setvar ElasticJobUmiClientId 00000000-0000-0000-0000-000000000000

DECLARE @elasticUser sysname = N'$(ElasticJobUmiName)';
DECLARE @elasticClientId uniqueidentifier = CAST('$(ElasticJobUmiClientId)' AS uniqueidentifier);

IF @elasticUser IS NOT NULL AND @elasticUser <> N''
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @elasticUser)
    BEGIN
        -- Use SID + TYPE = E to avoid ambiguity when multiple principals share the same display name
        DECLARE @createElasticMaster nvarchar(max) = N'CREATE USER [' + REPLACE(@elasticUser, ']', ']]') + N'] WITH SID = ' + CONVERT(nvarchar(max), CAST(@elasticClientId AS varbinary(16)), 1) + N', TYPE = E;';
        EXEC (@createElasticMaster);
    END;

    DECLARE @grantElasticMasterConnect nvarchar(max) = N'GRANT CONNECT TO [' + REPLACE(@elasticUser, ']', ']]') + N'];';
    EXEC (@grantElasticMasterConnect);
END;
GO

SELECT
    dp.name,
    dp.type_desc,
    dp.authentication_type_desc
FROM sys.database_principals dp
WHERE dp.name = N'$(ElasticJobUmiName)';
GO
