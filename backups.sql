/*****************************************************************************************************
 * SQL SERVER BACKUP & RESTORE MANAGEMENT QUERIES
 * 
 * This file contains queries organized by functionality:
 *   1. BACKUP PROGRESS MONITORING
 *   2. RESTORE PROGRESS MONITORING  
 *   3. BACKUP HISTORY & REPORTING
 *   4. RESTORE HISTORY
 *   5. RECENT BACKUPS & MISSING BACKUP DETECTION
 *   6. BACKUP VERIFICATION & INTEGRITY CHECKS
 *   7. BACKUP PERFORMANCE & METRICS
 *   8. LOG BACKUP & TRANSACTION LOG MONITORING
 *****************************************************************************************************/

-----------------------------------------------------------------------
-- SECTION 1: BACKUP PROGRESS MONITORING
-----------------------------------------------------------------------
-- Purpose: Monitor running backup operations in real-time
-----------------------------------------------------------------------

-- Monitor running backup operations with detailed progress
USE master;
GO
SELECT
    session_id                   AS SPID,
    command,
    a.[text]                     AS Query,
    start_time,
    percent_complete,
    CAST(((DATEDIFF(s, start_time, GETDATE())) / 3600) AS VARCHAR) + ' hour(s), '
        + CAST((DATEDIFF(s, start_time, GETDATE()) % 3600) / 60 AS VARCHAR) + ' min, '
        + CAST((DATEDIFF(s, start_time, GETDATE()) % 60) AS VARCHAR) + ' sec'
                                 AS running_time,
    CAST((estimated_completion_time / 3600000) AS VARCHAR) + ' hour(s), '
        + CAST((estimated_completion_time % 3600000) / 60000 AS VARCHAR) + ' min, '
        + CAST((estimated_completion_time % 60000) / 1000 AS VARCHAR) + ' sec'
                                 AS est_time_to_go,
    DATEADD(SECOND,
        estimated_completion_time / 1000,
        GETDATE())               AS estimated_completion_time
FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a
WHERE r.command IN (
    'BACKUP DATABASE',
    'RESTORE DATABASE',
    'BACKUP LOG',
    'RESTORE LOG'
)
ORDER BY start_time;

/**********************************************************************************************/
-- Simplified backup progress monitoring

SELECT 
    session_id as SPID, 
    command, 
    a.text AS Query, 
    start_time, 
    percent_complete, 
    DATEADD(second, estimated_completion_time/1000, GETDATE()) as estimated_completion_time 
FROM sys.dm_exec_requests r 
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a 
WHERE r.command = 'BACKUP DATABASE'


-----------------------------------------------------------------------
-- SECTION 2: RESTORE PROGRESS MONITORING
-----------------------------------------------------------------------
-- Purpose: Monitor running restore operations and estimate completion time
-----------------------------------------------------------------------

-- Monitor ongoing RESTORE progress
SELECT 
    r.percent_complete,
    r.command,
    d.name AS database_name,
    d.state_desc,
    r.start_time,
    DATEADD(SECOND, r.estimated_completion_time/1000, GETDATE()) as estimated_completion_time
FROM 
    sys.dm_exec_requests r
CROSS APPLY 
    sys.dm_exec_sql_text(r.sql_handle) AS t
JOIN 
    sys.databases d ON t.text LIKE '%' + d.name + '%' 
WHERE 
    r.command = 'RESTORE DATABASE'
    AND d.state_desc = 'RESTORING';

/**********************************************************************************************/
-- Get detailed ETA for ongoing RESTORE by measuring progress over 10 seconds
DECLARE @ProgressTable TABLE (
    DatabaseName NVARCHAR(128),
    InitialProgress FLOAT,
    SecondProgress FLOAT,
    ProgressDifference FLOAT,
    EstimatedMinutes FLOAT
);

INSERT INTO @ProgressTable (DatabaseName, InitialProgress)
SELECT 
    d.name AS DatabaseName,
    r.percent_complete AS InitialProgress
FROM 
    sys.dm_exec_requests r
CROSS APPLY 
    sys.dm_exec_sql_text(r.sql_handle) AS t
JOIN 
    sys.databases d ON t.text LIKE '%' + d.name + '%'
WHERE 
    r.command = 'RESTORE DATABASE'
    AND d.state_desc = 'RESTORING';

-- Wait 10 seconds to measure progress
WAITFOR DELAY '00:00:10';

UPDATE @ProgressTable
SET 
    SecondProgress = t.SecondProgress
FROM 
    @ProgressTable p
INNER JOIN (
    SELECT 
        d.name AS DatabaseName,
        r.percent_complete AS SecondProgress
    FROM 
        sys.dm_exec_requests r
    CROSS APPLY 
        sys.dm_exec_sql_text(r.sql_handle) AS t
    JOIN 
        sys.databases d ON t.text LIKE '%' + d.name + '%'
    WHERE 
        r.command = 'RESTORE DATABASE'
        AND d.state_desc = 'RESTORING'
) t ON p.DatabaseName = t.DatabaseName;

UPDATE @ProgressTable
SET 
    ProgressDifference = SecondProgress - InitialProgress,
    EstimatedMinutes = CASE 
        WHEN (SecondProgress - InitialProgress) > 0 THEN 
            ((100 - SecondProgress) / (SecondProgress - InitialProgress)) * (10.0 / 60.0)
        ELSE 
            NULL
    END;

SELECT 
    DatabaseName,
    InitialProgress,
    SecondProgress,
    ProgressDifference,
    EstimatedMinutes AS EstimatedTimeRemainingInMinutes
FROM 
    @ProgressTable;


-----------------------------------------------------------------------
-- SECTION 3: BACKUP HISTORY & REPORTING
-----------------------------------------------------------------------
-- Purpose: View historical backup information
-----------------------------------------------------------------------

-- View complete backup history for all databases
SELECT 
    bs.media_set_id,
    bs.backup_finish_date,
    bs.type,
    bs.backup_size,
    bs.compressed_backup_size,
    mf.physical_device_name
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS mf
    ON bs.media_set_id = mf.media_set_id
-- WHERE database_name = 'YourDatabaseName'
ORDER BY backup_finish_date DESC;
GO

/**********************************************************************************************/
-- Backup history for specific database (parameterized)
-- Set @DatabaseName to '' to return all databases
DECLARE @DatabaseName NVARCHAR(255);
SET @DatabaseName = '';

SELECT 
    bs.media_set_id,
    bs.backup_finish_date,
    bs.type,
    bs.backup_size,
    bs.compressed_backup_size,
    mf.physical_device_name
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS mf
    ON bs.media_set_id = mf.media_set_id
WHERE (@DatabaseName = '' OR bs.database_name = @DatabaseName)
ORDER BY bs.backup_finish_date DESC;
GO


-----------------------------------------------------------------------
-- SECTION 4: RESTORE HISTORY
-----------------------------------------------------------------------
-- Purpose: Track when databases were restored
-----------------------------------------------------------------------

-- When was a database restored?
SELECT
    rs.destination_database_name,
    rs.restore_date,
    bmf.physical_device_name,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.database_name AS source_database_name,
    bs.user_name
FROM msdb.dbo.restorehistory rs
INNER JOIN msdb.dbo.backupset bs ON rs.backup_set_id = bs.backup_set_id
INNER JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE rs.destination_database_name = 'my_database_name'
ORDER BY rs.restore_date DESC;


-----------------------------------------------------------------------
-- SECTION 5: RECENT BACKUPS & MISSING BACKUP DETECTION
-----------------------------------------------------------------------
-- Purpose: Identify databases with missing or outdated backups
-----------------------------------------------------------------------

-- Check for any backups taken in the last 24 hours
SELECT
    db.name,
    bs.backup_finish_date,
    bs.type
FROM 
    master.sys.databases db
LEFT JOIN
    msdb.dbo.backupset AS bs
ON 
    db.name = bs.database_name
AND 
    backup_finish_date BETWEEN DATEADD(dd, -1, DATEDIFF(dd, 0, GETDATE())) 
                           AND DATEADD(dd,  0, DATEDIFF(dd, 0, GETDATE()))
WHERE 
    db.name NOT IN ('msdb','model','master','distribution','tempdb') 
ORDER BY 
    backup_finish_date DESC;
GO

/**********************************************************************************************/
-- Check for full database backups from the last 24 hours
SELECT
    d.name,
    bs.backup_finish_date,
    mf.physical_device_name
FROM
    sys.databases d
LEFT JOIN 
    msdb.dbo.backupset bs 
ON
    d.name = bs.database_name 
AND
    bs.backup_finish_date >= DATEADD(HOUR, -24, GETDATE())
AND
    bs.type = 'D'
LEFT JOIN
    msdb.dbo.backupmediafamily AS mf
ON
    bs.media_set_id = mf.media_set_id
WHERE
    d.name <> 'tempdb'
ORDER BY 1,2

/**********************************************************************************************/
-- When was the last full backup for each database?
SELECT 
    d.name, 
    MAX(b.backup_finish_date) AS last_backup_finish_date
FROM master.sys.databases d
LEFT OUTER JOIN msdb.dbo.backupset b ON d.name = b.database_name AND b.type = 'D'
WHERE d.database_id NOT IN (2, 3) 
GROUP BY d.name
ORDER BY 2 DESC

/**********************************************************************************************/
-- Last backup of each type per database with alerts for outdated backups
SELECT
    d.[name]                                      AS DatabaseName,
    d.recovery_model_desc                         AS RecoveryModel,
    d.state_desc                                  AS DatabaseState,

    -- Last Full
    MAX(CASE WHEN bs.[type] = 'D'
             THEN bs.backup_finish_date END)      AS LastFullBackup,
    DATEDIFF(HOUR,
        MAX(CASE WHEN bs.[type] = 'D'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS HoursSinceFullBackup,

    -- Last Differential
    MAX(CASE WHEN bs.[type] = 'I'
             THEN bs.backup_finish_date END)      AS LastDiffBackup,

    -- Last Log
    MAX(CASE WHEN bs.[type] = 'L'
             THEN bs.backup_finish_date END)      AS LastLogBackup,
    DATEDIFF(MINUTE,
        MAX(CASE WHEN bs.[type] = 'L'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS MinSinceLogBackup,

    -- Alerts
    CASE
        WHEN MAX(CASE WHEN bs.[type] = 'D'
                      THEN bs.backup_finish_date END) IS NULL
            THEN '*** NO FULL BACKUP ***'
        WHEN DATEDIFF(HOUR,
                MAX(CASE WHEN bs.[type] = 'D'
                         THEN bs.backup_finish_date END),
                GETDATE()) > 168                  -- > 7 days
            THEN '*** FULL BACKUP OVERDUE ***'
        ELSE 'OK'
    END                                           AS FullBackupStatus,

    CASE
        WHEN d.recovery_model_desc = 'FULL'
         AND MAX(CASE WHEN bs.[type] = 'L'
                      THEN bs.backup_finish_date END) IS NULL
            THEN '*** NO LOG BACKUP (FULL recovery!) ***'
        WHEN d.recovery_model_desc = 'FULL'
         AND DATEDIFF(MINUTE,
                MAX(CASE WHEN bs.[type] = 'L'
                         THEN bs.backup_finish_date END),
                GETDATE()) > 60
            THEN '*** LOG BACKUP OVERDUE ***'
        ELSE 'OK'
    END                                           AS LogBackupStatus

FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs ON d.[name] = bs.database_name
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
  AND d.source_database_id IS NULL                -- exclude snapshots
GROUP BY d.[name], d.recovery_model_desc, d.state_desc
ORDER BY HoursSinceFullBackup DESC;

/**********************************************************************************************/
-- Databases in FULL recovery without recent log backups (transaction log will grow!)
SELECT
    d.[name]                  AS DatabaseName,
    d.recovery_model_desc     AS RecoveryModel,
    d.log_reuse_wait_desc     AS LogReuseWait,
    MAX(bs.backup_finish_date) AS LastLogBackup,
    DATEDIFF(MINUTE,
        MAX(bs.backup_finish_date),
        GETDATE())            AS MinutesSinceLastLog
FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset bs
        ON d.[name] = bs.database_name AND bs.[type] = 'L'
WHERE d.recovery_model_desc = 'FULL'
  AND d.database_id > 4
  AND d.state_desc = 'ONLINE'
GROUP BY d.[name], d.recovery_model_desc, d.log_reuse_wait_desc
HAVING MAX(bs.backup_finish_date) IS NULL
    OR DATEDIFF(MINUTE, MAX(bs.backup_finish_date), GETDATE()) > 60
ORDER BY MinutesSinceLastLog DESC;


-----------------------------------------------------------------------
-- SECTION 6: BACKUP VERIFICATION & INTEGRITY CHECKS
-----------------------------------------------------------------------
-- Purpose: Verify backup files, check backup chain completeness
-- Safety:  RESTORE VERIFYONLY is read-only — it does NOT restore
-----------------------------------------------------------------------

-- RESTORE VERIFYONLY — validate a backup file is readable
-- Does NOT restore — just validates header, checksums, and structure
-- Single backup file:
-- RESTORE VERIFYONLY FROM DISK = N'C:\Backups\YourDB_Full.bak' WITH CHECKSUM;

-- With multiple stripe files:
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\Backups\YourDB_Stripe1.bak',
--          DISK = N'C:\Backups\YourDB_Stripe2.bak'
--     WITH CHECKSUM;

/**********************************************************************************************/
-- Generate VERIFYONLY commands for all recent full backups
SELECT
    bs.database_name,
    bs.backup_finish_date,
    bmf.physical_device_name,
    'RESTORE VERIFYONLY FROM DISK = N'''
        + bmf.physical_device_name
        + ''' WITH CHECKSUM;'                    AS VerifyCommand
FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily bmf
        ON bs.media_set_id = bmf.media_set_id
WHERE bs.[type] = 'D'                            -- Full backups only
  AND bs.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY bs.backup_finish_date DESC;

/**********************************************************************************************/
-- Backup chain integrity check for FULL-recovery databases
-- Detects gaps in log backup chain (each log backup's first_lsn should = prior's last_lsn)
;WITH LogChain AS (
    SELECT
        database_name,
        backup_finish_date,
        first_lsn,
        last_lsn,
        LAG(last_lsn) OVER (
            PARTITION BY database_name
            ORDER BY backup_finish_date) AS prev_last_lsn
    FROM msdb.dbo.backupset
    WHERE [type] = 'L'
      AND backup_finish_date >= DATEADD(DAY, -7, GETDATE())
)
SELECT
    database_name,
    backup_finish_date,
    first_lsn,
    prev_last_lsn,
    CASE
        WHEN prev_last_lsn IS NULL THEN 'First in window'
        WHEN first_lsn = prev_last_lsn THEN 'Chain OK'
        ELSE '*** CHAIN BREAK ***'
    END AS ChainStatus
FROM LogChain
WHERE prev_last_lsn IS NOT NULL
  AND first_lsn <> prev_last_lsn
ORDER BY database_name, backup_finish_date;

/**********************************************************************************************/
-- Backup files without checksum (cannot catch silent corruption)
SELECT
    bs.database_name,
    bs.backup_finish_date,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                              AS BackupType,
    bs.has_backup_checksums,
    CASE
        WHEN bs.has_backup_checksums = 0
            THEN '*** NO CHECKSUM ***'
        ELSE 'OK'
    END                              AS ChecksumStatus,
    bmf.physical_device_name
FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily bmf
        ON bs.media_set_id = bmf.media_set_id
WHERE bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
  AND bs.has_backup_checksums = 0
ORDER BY bs.backup_finish_date DESC;

/**********************************************************************************************/
-- Inspect backup file contents (use these commands with actual file paths)
-- RESTORE HEADERONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';
-- RESTORE FILELISTONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';


-----------------------------------------------------------------------
-- SECTION 7: BACKUP PERFORMANCE & METRICS
-----------------------------------------------------------------------
-- Purpose: Analyze backup size, duration, throughput, and compression
-----------------------------------------------------------------------

-- Backup performance analysis — size, duration, throughput
SELECT TOP 50
    bs.database_name,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                                           AS BackupType,
    bs.backup_start_date,
    bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_start_date,
                     bs.backup_finish_date)       AS DurationSec,
    CAST(bs.backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS BackupSizeMB,
    CAST(bs.compressed_backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS CompressedMB,
    CAST(100.0 - (bs.compressed_backup_size * 100.0
         / NULLIF(bs.backup_size, 0))
         AS DECIMAL(5,2))                         AS CompressionPct,
    CAST(bs.backup_size / 1048576.0
         / NULLIF(DATEDIFF(SECOND,
             bs.backup_start_date,
             bs.backup_finish_date), 0)
         AS DECIMAL(18,2))                        AS ThroughputMBps,
    bs.is_encrypted,
    bs.has_backup_checksums
FROM msdb.dbo.backupset bs
ORDER BY bs.backup_finish_date DESC;

/**********************************************************************************************/
-- Detailed backup history (all backup types with complete metadata)
-- Shows device type, LSNs, encryption, compression for forensics
-- Detailed backup history (all backup types with complete metadata)
-- Shows device type, LSNs, encryption, compression for forensics
SELECT TOP 5000
    bcks.database_name,
    bckMF.device_type,
    BackD.type_desc                           AS DeviceTypeDesc,
    BackD.physical_name                       AS BackupDeviceName,
    bckS.[type]                               AS BackupTypeCode,
    CASE bckS.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Transaction Log'
    END                                       AS BackupType,
    bckS.backup_start_date,
    bckS.backup_finish_date,
    CONVERT(CHAR(8),
        DATEADD(s,
            DATEDIFF(s, bckS.backup_start_date, bckS.backup_finish_date),
            '1900-1-1'),
        8)                                    AS BackupDuration_hms,
    CONVERT(DECIMAL(19,2),
        (bckS.backup_size * 1.0) / POWER(2,20)) AS BackupSizeMB,
    CAST(bcks.backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS BackupSizeGB,
    CONVERT(DECIMAL(19,2),
        (bckS.compressed_backup_size * 1.0) / POWER(2,20))
                                              AS CompressedBackupSizeMB,
    CAST(bcks.compressed_backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS CompressedBackupSizeGB,
    software_name,
    is_compressed,
    is_copy_only,
    is_encrypted,
    physical_device_name,
    first_lsn,
    last_lsn,
    checkpoint_lsn,
    database_backup_lsn,
    user_name,
    @@SERVERNAME                              AS ServerName
FROM msdb.dbo.backupset bckS
    INNER JOIN msdb.dbo.backupmediaset bckMS
        ON bckS.media_set_id = bckMS.media_set_id
    INNER JOIN msdb.dbo.backupmediafamily bckMF
        ON bckMS.media_set_id = bckMF.media_set_id
    LEFT JOIN sys.backup_devices BackD
        ON bckMF.device_type = BackD.[type]
-- WHERE database_name = 'YourDBName'
ORDER BY bckS.backup_start_date DESC;


-----------------------------------------------------------------------
-- SECTION 8: LOG BACKUP & TRANSACTION LOG MONITORING
-----------------------------------------------------------------------
-- Purpose: Monitor log backup status and identify log-related issues
-----------------------------------------------------------------------

-- Check what's preventing a log backup from completing
SELECT 
    [name] AS database_name, 
    log_reuse_wait_desc 
FROM sys.databases 
WHERE name = 'db' -- Change to your database name

-- Last backup information by database  (Query 8) (Last Backup By Database)
SELECT ISNULL(d.[name], bs.[database_name]) AS [Database], d.recovery_model_desc AS [Recovery Model], 
    d.log_reuse_wait_desc AS [Log Reuse Wait Desc],
	CONVERT(DECIMAL(18,2), ds.cntr_value/1024.0) AS [Total Data File Size on Disk (MB)],
	CONVERT(DECIMAL(18,2), ls.cntr_value/1024.0) AS [Total Log File Size on Disk (MB)], 
	CAST(CAST(lu.cntr_value AS FLOAT) / CAST(ls.cntr_value AS FLOAT) AS DECIMAL(18,2)) * 100 AS [Log Used %],
    MAX(CASE WHEN bs.[type] = 'D' THEN bs.backup_finish_date ELSE NULL END) AS [Last Full Backup],
	MAX(CASE WHEN bs.[type] = 'D' THEN CONVERT (BIGINT, bs.compressed_backup_size / 1048576 ) ELSE NULL END) AS [Last Full Compressed Backup Size (MB)],
	MAX(CASE WHEN bs.[type] = 'D' THEN CONVERT (DECIMAL(18,2), bs.backup_size /bs.compressed_backup_size ) ELSE NULL END) AS [Backup Compression Ratio],
	MAX(CASE WHEN bs.[type] = 'D' THEN bs.compression_algorithm ELSE NULL END) AS [Last Full Backup Compression Algorithm],
    MAX(CASE WHEN bs.[type] = 'I' THEN bs.backup_finish_date ELSE NULL END) AS [Last Differential Backup],
    MAX(CASE WHEN bs.[type] = 'L' THEN bs.backup_finish_date ELSE NULL END) AS [Last Log Backup],
	MAX(CASE WHEN bs.[type] = 'L' THEN bs.last_valid_restore_time ELSE NULL END) AS [Last Valid Restore Time],
	DATABASEPROPERTYEX ((d.[name]), 'LastGoodCheckDbTime') AS [Last Good CheckDB]
FROM sys.databases AS d WITH (NOLOCK)
INNER JOIN sys.master_files as mf WITH (NOLOCK)
ON d.database_id = mf.database_id
LEFT OUTER JOIN msdb.dbo.backupset AS bs WITH (NOLOCK)
ON bs.[database_name] = d.[name]
AND bs.backup_finish_date > GETDATE()- 30
LEFT OUTER JOIN sys.dm_os_performance_counters AS lu WITH (NOLOCK)
ON d.name = lu.instance_name
LEFT OUTER JOIN sys.dm_os_performance_counters AS ls WITH (NOLOCK)
ON d.name = ls.instance_name
INNER JOIN sys.dm_os_performance_counters AS ds WITH (NOLOCK)
ON d.name = ds.instance_name
WHERE d.name <> N'tempdb'
AND lu.counter_name LIKE N'Log File(s) Used Size (KB)%' 
AND ls.counter_name LIKE N'Log File(s) Size (KB)%'
AND ds.counter_name LIKE N'Data File(s) Size (KB)%'
AND ls.cntr_value > 0 
GROUP BY ISNULL(d.[name], bs.[database_name]), d.recovery_model_desc, d.log_reuse_wait_desc, d.[name],
         CONVERT(DECIMAL(18,2), ds.cntr_value/1024.0),
	     CONVERT(DECIMAL(18,2), ls.cntr_value/1024.0), 
         CAST(CAST(lu.cntr_value AS FLOAT) / CAST(ls.cntr_value AS FLOAT) AS DECIMAL(18,2)) * 100




-- Show which indexes in the current database are most active for Reads




--- Index Read/Write stats (all tables in current DB) ordered by Writes  (Query 81) (Overall Index Usage - Writes)
SELECT SCHEMA_NAME(t.[schema_id]) AS [SchemaName],OBJECT_NAME(i.[object_id]) AS [ObjectName], 
	   i.[name] AS [IndexName], i.index_id, i.[type_desc] AS [Index Type],
	   s.user_updates AS [Writes], s.user_seeks + s.user_scans + s.user_lookups AS [Total Reads], 
	   i.fill_factor AS [Fill Factor], i.has_filter, i.filter_definition,
	   s.last_system_update, s.last_user_update, i.[allow_page_locks]
FROM sys.indexes AS i WITH (NOLOCK)
LEFT OUTER JOIN sys.dm_db_index_usage_stats AS s WITH (NOLOCK)
ON i.[object_id] = s.[object_id]
AND i.index_id = s.index_id
AND s.database_id = DB_ID()
LEFT OUTER JOIN sys.tables AS t WITH (NOLOCK)
ON t.[object_id] = i.[object_id]
WHERE OBJECTPROPERTY(i.[object_id],'IsUserTable') = 1