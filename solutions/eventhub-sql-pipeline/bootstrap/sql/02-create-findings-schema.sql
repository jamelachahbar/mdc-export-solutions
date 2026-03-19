/*
Run against the findings database ($(FindingsDatabaseName)).
Creates raw + typed tables used by Stream Analytics ingestion and Elastic Job merge procedures.
*/

IF OBJECT_ID('dbo.SecurityAssessments_Raw', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SecurityAssessments_Raw
    (
        tenantId UNIQUEIDENTIFIER,
        type NVARCHAR(200),
        id NVARCHAR(1000),
        name NVARCHAR(200),
        location NVARCHAR(200),
        kind NVARCHAR(200),
        tags NVARCHAR(MAX),
        properties NVARCHAR(MAX),
        assessmentEventDataEnrichment NVARCHAR(MAX),
        securityEventDataEnrichment NVARCHAR(MAX),
        EventProcessedUtcTime DATETIME2(7),
        EventEnqueuedUtcTime DATETIME2(7),
        PartitionId INT,
        InsertedAtUtc DATETIME2(7) NOT NULL CONSTRAINT DF_SecurityAssessments_Raw_InsertedAtUtc DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID('dbo.SecuritySubAssessments_Raw', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SecuritySubAssessments_Raw
    (
        tenantId UNIQUEIDENTIFIER,
        type NVARCHAR(200),
        id NVARCHAR(1000),
        name NVARCHAR(200),
        location NVARCHAR(200),
        kind NVARCHAR(200),
        tags NVARCHAR(MAX),
        properties NVARCHAR(MAX),
        subAssessmentEventDataEnrichment NVARCHAR(MAX),
        securityEventDataEnrichment NVARCHAR(MAX),
        EventProcessedUtcTime DATETIME2(7),
        EventEnqueuedUtcTime DATETIME2(7),
        PartitionId INT,
        InsertedAtUtc DATETIME2(7) NOT NULL CONSTRAINT DF_SecuritySubAssessments_Raw_InsertedAtUtc DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID('dbo.SecurityAssessments', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SecurityAssessments
    (
        tenantId UNIQUEIDENTIFIER NOT NULL,
        id NVARCHAR(450) NOT NULL,
        name NVARCHAR(200) NOT NULL,
        type NVARCHAR(200) NOT NULL,
        location NVARCHAR(200),
        kind NVARCHAR(200),
        tags NVARCHAR(MAX),
        displayName NVARCHAR(500),
        description NVARCHAR(MAX),
        statusCode NVARCHAR(50),
        severity NVARCHAR(50),
        statusCause NVARCHAR(100),
        statusDescription NVARCHAR(MAX),
        policyDefinitionId NVARCHAR(1000),
        assessmentType NVARCHAR(100),
        implementationEffort NVARCHAR(100),
        userImpact NVARCHAR(200),
        categories NVARCHAR(400),
        threats NVARCHAR(400),
        resourceId NVARCHAR(1000),
        resourceName NVARCHAR(400),
        resourceType NVARCHAR(400),
        resourceProvider NVARCHAR(400),
        source NVARCHAR(100),
        riskLevel NVARCHAR(50),
        riskAttackPaths INT,
        firstEvaluationDate DATETIME2,
        statusChangeDate DATETIME2,
        timeGenerated DATETIME2,
        properties NVARCHAR(MAX),
        LastEnqueuedUtcTime DATETIME2 NOT NULL CONSTRAINT DF_SecurityAssessments_LastEnqueuedUtcTime DEFAULT SYSUTCDATETIME()
    );
END;
GO

IF OBJECT_ID('dbo.SecuritySubAssessments', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SecuritySubAssessments
    (
        tenantId UNIQUEIDENTIFIER NOT NULL,
        id NVARCHAR(450) NOT NULL,
        name NVARCHAR(200) NOT NULL,
        type NVARCHAR(200) NOT NULL,
        displayName NVARCHAR(500),
        description NVARCHAR(MAX),
        category NVARCHAR(200),
        vulnerabilityId NVARCHAR(200),
        impact NVARCHAR(MAX),
        remediation NVARCHAR(MAX),
        statusCode NVARCHAR(50),
        severity NVARCHAR(50),
        statusCause NVARCHAR(100),
        statusDescription NVARCHAR(MAX),
        timeGenerated DATETIME2,
        nativeResourceId NVARCHAR(1000),
        resourceId NVARCHAR(1000),
        resourceName NVARCHAR(400),
        resourceType NVARCHAR(400),
        resourceProvider NVARCHAR(400),
        source NVARCHAR(100),
        assessedResourceType NVARCHAR(200),
        clusterName NVARCHAR(200),
        clusterResourceId NVARCHAR(1000),
        [namespace] NVARCHAR(200),
        controllerKind NVARCHAR(200),
        controllerName NVARCHAR(200),
        podName NVARCHAR(200),
        containerName NVARCHAR(200),
        repositoryName NVARCHAR(400),
        registryHost NVARCHAR(400),
        digest NVARCHAR(200),
        artifactType NVARCHAR(200),
        packageName NVARCHAR(300),
        packageVendor NVARCHAR(300),
        packageVersion NVARCHAR(100),
        fixedVersion NVARCHAR(100),
        patchable BIT,
        fixStatus NVARCHAR(100),
        [language] NVARCHAR(100),
        osPlatform NVARCHAR(100),
        osVersion NVARCHAR(100),
        cveId NVARCHAR(100),
        vulnerabilitySeverity NVARCHAR(50),
        publishedDate DATETIME2,
        lastModifiedDate DATETIME2,
        cvssScore DECIMAL(5,2),
        cvssVector NVARCHAR(200),
        cpeUri NVARCHAR(1000),
        cpeVendor NVARCHAR(300),
        cpeProduct NVARCHAR(300),
        cpeVersion NVARCHAR(100),
        cweId NVARCHAR(100),
        inventorySource NVARCHAR(200),
        scanner NVARCHAR(200),
        properties NVARCHAR(MAX),
        LastEnqueuedUtcTime DATETIME2 NOT NULL CONSTRAINT DF_SecuritySubAssessments_LastEnqueuedUtcTime DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_SecuritySubAssessments PRIMARY KEY CLUSTERED (id)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SecurityAssessments_Raw_Id_Enqueued' AND object_id = OBJECT_ID('dbo.SecurityAssessments_Raw'))
BEGIN
    CREATE INDEX IX_SecurityAssessments_Raw_Id_Enqueued
        ON dbo.SecurityAssessments_Raw (id, EventEnqueuedUtcTime DESC);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SecuritySubAssessments_Raw_Id_Enqueued' AND object_id = OBJECT_ID('dbo.SecuritySubAssessments_Raw'))
BEGIN
    CREATE INDEX IX_SecuritySubAssessments_Raw_Id_Enqueued
        ON dbo.SecuritySubAssessments_Raw (id, EventEnqueuedUtcTime DESC);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SecurityAssessments_Id' AND object_id = OBJECT_ID('dbo.SecurityAssessments'))
BEGIN
    CREATE INDEX IX_SecurityAssessments_Id ON dbo.SecurityAssessments (id);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SecurityAssessments_LastEnqueuedUtcTime' AND object_id = OBJECT_ID('dbo.SecurityAssessments'))
BEGIN
    CREATE INDEX IX_SecurityAssessments_LastEnqueuedUtcTime ON dbo.SecurityAssessments (LastEnqueuedUtcTime);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_SecuritySubAssessments_LastEnqueuedUtcTime' AND object_id = OBJECT_ID('dbo.SecuritySubAssessments'))
BEGIN
    CREATE INDEX IX_SecuritySubAssessments_LastEnqueuedUtcTime ON dbo.SecuritySubAssessments (LastEnqueuedUtcTime);
END;
GO
