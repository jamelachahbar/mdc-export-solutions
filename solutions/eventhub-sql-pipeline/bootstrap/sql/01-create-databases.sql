/*
Run against master database on the target logical SQL server.
Compatible with sqlcmd variables.
*/

:setvar JobDatabaseName DefenderJobMetadata
:setvar FindingsDatabaseName DefenderVulnerability
:setvar JobDbServiceObjective GP_S_Gen5_2
:setvar FindingsDbServiceObjective GP_S_Gen5_2

IF DB_ID('$(JobDatabaseName)') IS NULL
BEGIN
    DECLARE @sqlCreateJobDb nvarchar(max) =
        N'CREATE DATABASE [' + REPLACE('$(JobDatabaseName)', ']', ']]') + N']';
    EXEC (@sqlCreateJobDb);
END;
GO

IF DB_ID('$(FindingsDatabaseName)') IS NULL
BEGIN
    DECLARE @sqlCreateFindingsDb nvarchar(max) =
        N'CREATE DATABASE [' + REPLACE('$(FindingsDatabaseName)', ']', ']]') + N']';
    EXEC (@sqlCreateFindingsDb);
END;
GO

/* Optional: set performance tier after creation */
DECLARE @jobDb sysname = N'$(JobDatabaseName)';
DECLARE @findingsDb sysname = N'$(FindingsDatabaseName)';
DECLARE @jobObj nvarchar(128) = N'$(JobDbServiceObjective)';
DECLARE @findingsObj nvarchar(128) = N'$(FindingsDbServiceObjective)';

IF DB_ID(@jobDb) IS NOT NULL AND @jobObj <> N''
BEGIN
    DECLARE @sqlAlterJob nvarchar(max) =
        N'ALTER DATABASE [' + REPLACE(@jobDb, ']', ']]') + N'] MODIFY ( SERVICE_OBJECTIVE = ''' + REPLACE(@jobObj, '''', '''''') + N''' )';
    EXEC (@sqlAlterJob);
END;

IF DB_ID(@findingsDb) IS NOT NULL AND @findingsObj <> N''
BEGIN
    DECLARE @sqlAlterFindings nvarchar(max) =
        N'ALTER DATABASE [' + REPLACE(@findingsDb, ']', ']]') + N'] MODIFY ( SERVICE_OBJECTIVE = ''' + REPLACE(@findingsObj, '''', '''''') + N''' )';
    EXEC (@sqlAlterFindings);
END;
GO
