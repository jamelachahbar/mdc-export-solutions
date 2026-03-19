/*
Run against findings DB to validate the bootstrap state.
*/

SELECT name AS TableName
FROM sys.tables
WHERE name IN (
    'SecurityAssessments_Raw',
    'SecuritySubAssessments_Raw',
    'SecurityAssessments',
    'SecuritySubAssessments'
)
ORDER BY name;
GO

SELECT name AS ProcedureName
FROM sys.procedures
WHERE name IN (
    'usp_MergeSecurityAssessments',
    'usp_MergeSecuritySubAssessments'
)
ORDER BY name;
GO

SELECT
    dbprin.name,
    dbperm.permission_name,
    dbperm.state_desc,
    dbperm.class_desc,
    OBJECT_NAME(dbperm.major_id) AS ObjectName
FROM sys.database_principals dbprin
LEFT JOIN sys.database_permissions dbperm
    ON dbperm.grantee_principal_id = dbprin.principal_id
WHERE dbprin.name IN ('$(ElasticJobUmiName)', '$(AsaAssessmentsPrincipalName)', '$(AsaSubAssessmentsPrincipalName)')
ORDER BY dbprin.name, dbperm.permission_name, ObjectName;
GO
