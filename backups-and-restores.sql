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
 *   9. RESTORE OPERATIONS & VERIFICATION
 *  10. SYSTEM DATABASE RESTORE PROCEDURES
 *  11. BACKUP & RESTORE ARCHITECTURE CONCEPTS AND RESTORE SCENARIO REFERENCE
 *****************************************************************************************************/
--trace flags for backup and restore monitoring, historical reporting, integrity checks, performance analysis, and restore operations. Each section contains multiple queries with comments explaining their purpose and usage. Use these queries as templates for managing SQL Server backups and restores effectively.

DBCC TRACEON(3004,-1) -- Prints progress messages after key steps in restore
go
DBCC TRACEON(3014,-1) -- Prints progress messages after each major MTF data stream
go
DBCC TRACEON(3110,-1) -- Print log headers 
go
DBCC TRACEON(3214,-1) -- Display Sql Text
go
DBCC TRACEON(3605,-1) -- Send trace output to the errorlog
go
 
--Enable DUMPTRIGGER for error 3287 with filter dump  
DBCC TRACEON(2551,-1) 
GO 
DBCC DUMPTRIGGER('set', 3287) 
GO 
DBCC DUMPTRIGGER('set', 3013) 
GO 
--Disable trace flags after use
DBCC TRACEOFF (3004,3014,3110,3214,3605,-1)

/*****************************************************************************************************
 * SECTION 1: BACKUP PROGRESS MONITORING
 * Purpose: Monitor running backup operations in real-time
 *****************************************************************************************************/

-- Query 1.1: Monitor All Running Backup/Restore Operations (Detailed)
-- Shows progress, elapsed time, estimated time remaining, and completion time
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
WHERE r.command IN ('BACKUP DATABASE', 'RESTORE DATABASE', 'BACKUP LOG', 'RESTORE LOG')
ORDER BY start_time;
GO


-- Query 1.2: Monitor Backup Progress (Simplified)
-- Quick view of backup progress with estimated completion time
SELECT 
    session_id               AS SPID, 
    command, 
    a.text                   AS Query, 
    start_time, 
    percent_complete, 
    DATEADD(second, estimated_completion_time/1000, GETDATE()) AS estimated_completion_time 
FROM sys.dm_exec_requests r 
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a 
WHERE r.command = 'BACKUP DATABASE'
ORDER BY start_time;
GO


/*****************************************************************************************************
 * SECTION 2: RESTORE PROGRESS MONITORING
 * Purpose: Monitor running restore operations and estimate completion time
 *****************************************************************************************************/

-- Query 2.1: Monitor Ongoing Restore Progress (Basic)
-- Quick view of restore operations with database state
SELECT 
    r.session_id             AS SPID,
    r.percent_complete,
    r.command,
    d.name                   AS database_name,
    d.state_desc,
    r.start_time,
    DATEADD(SECOND, r.estimated_completion_time/1000, GETDATE()) AS estimated_completion_time
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
JOIN sys.databases d ON t.text LIKE '%' + d.name + '%' 
WHERE r.command = 'RESTORE DATABASE'
  AND d.state_desc = 'RESTORING'
ORDER BY r.start_time;
GO


-- Query 2.2: Detailed Restore ETA (Progress Measurement Over 10 Seconds)
-- Measures actual progress rate to provide more accurate completion estimate
DECLARE @ProgressTable TABLE (
    DatabaseName NVARCHAR(128),
    InitialProgress FLOAT,
    SecondProgress FLOAT,
    ProgressDifference FLOAT,
    EstimatedMinutes FLOAT
);

INSERT INTO @ProgressTable (DatabaseName, InitialProgress)
SELECT 
    d.name                   AS DatabaseName,
    r.percent_complete       AS InitialProgress
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
JOIN sys.databases d ON t.text LIKE '%' + d.name + '%'
WHERE r.command = 'RESTORE DATABASE'
  AND d.state_desc = 'RESTORING';

-- Wait 10 seconds to measure actual progress
WAITFOR DELAY '00:00:10';

UPDATE @ProgressTable
SET SecondProgress = t.SecondProgress
FROM @ProgressTable p
INNER JOIN (
    SELECT 
        d.name               AS DatabaseName,
        r.percent_complete   AS SecondProgress
    FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
    JOIN sys.databases d ON t.text LIKE '%' + d.name + '%'
    WHERE r.command = 'RESTORE DATABASE'
      AND d.state_desc = 'RESTORING'
) t ON p.DatabaseName = t.DatabaseName;

UPDATE @ProgressTable
SET ProgressDifference = SecondProgress - InitialProgress,
    EstimatedMinutes = CASE 
        WHEN (SecondProgress - InitialProgress) > 0 
        THEN ((100 - SecondProgress) / (SecondProgress - InitialProgress)) * (10.0 / 60.0)
        ELSE NULL
    END;

SELECT 
    DatabaseName,
    InitialProgress,
    SecondProgress,
    ProgressDifference,
    EstimatedMinutes         AS EstimatedTimeRemainingInMinutes
FROM @ProgressTable;
GO


/*****************************************************************************************************
 * SECTION 3: BACKUP HISTORY & REPORTING
 * Purpose: View historical backup information and metadata
 *****************************************************************************************************/

-- Query 3.1: Complete Backup History (All Databases)
-- View all backup history with file locations
SELECT 
    bs.database_name,
    bs.backup_finish_date,
    bs.type                  AS backup_type_code,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                      AS backup_type,
    bs.backup_size,
    bs.compressed_backup_size,
    mf.physical_device_name
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS mf ON bs.media_set_id = mf.media_set_id
-- WHERE bs.database_name = 'YourDatabaseName'  -- Uncomment to filter by database
ORDER BY bs.backup_finish_date DESC;
GO


-- Query 3.2: Backup History for Specific Database (Parameterized)
-- Set @DatabaseName to '' to return all databases, or specify a specific database name
DECLARE @DatabaseName NVARCHAR(255);
SET @DatabaseName = '';  -- Set to specific database name or leave empty for all

SELECT 
    bs.database_name,
    bs.backup_finish_date,
    bs.type                  AS backup_type_code,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                      AS backup_type,
    bs.backup_size,
    bs.compressed_backup_size,
    mf.physical_device_name
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS mf ON bs.media_set_id = mf.media_set_id
WHERE (@DatabaseName = '' OR bs.database_name = @DatabaseName)
ORDER BY bs.backup_finish_date DESC;
GO


-- Query 3.3: Detailed Backup History (Complete Metadata)
-- Comprehensive backup metadata including LSNs, encryption, compression, device info
-- Useful for forensics and detailed analysis
SELECT TOP 5000
    bcks.database_name,
    bckMF.device_type,
    BackD.type_desc                           AS device_type_desc,
    BackD.physical_name                       AS backup_device_name,
    bckS.[type]                               AS backup_type_code,
    CASE bckS.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Transaction Log'
    END                                       AS backup_type,
    bckS.backup_start_date,
    bckS.backup_finish_date,
    CONVERT(CHAR(8),
        DATEADD(s, DATEDIFF(s, bckS.backup_start_date, bckS.backup_finish_date), '1900-1-1'),
        8)                                    AS backup_duration_hms,
    CONVERT(DECIMAL(19,2),
        (bckS.backup_size * 1.0) / POWER(2,20))        AS backup_size_mb,
    CAST(bcks.backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS backup_size_gb,
    CONVERT(DECIMAL(19,2),
        (bckS.compressed_backup_size * 1.0) / POWER(2,20)) AS compressed_backup_size_mb,
    CAST(bcks.compressed_backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS compressed_backup_size_gb,
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
    @@SERVERNAME                              AS server_name
FROM msdb.dbo.backupset bckS
INNER JOIN msdb.dbo.backupmediaset bckMS ON bckS.media_set_id = bckMS.media_set_id
INNER JOIN msdb.dbo.backupmediafamily bckMF ON bckMS.media_set_id = bckMF.media_set_id
LEFT JOIN sys.backup_devices BackD ON bckMF.device_type = BackD.[type]
-- WHERE bcks.database_name = 'YourDBName'  -- Uncomment to filter by database
ORDER BY bckS.backup_start_date DESC;
GO


/*****************************************************************************************************
 * SECTION 4: RESTORE HISTORY
 * Purpose: Track when databases were restored
 *****************************************************************************************************/

-- Query 4.1: When Was a Database Restored?
-- Shows restore history with source database and backup details
SELECT
    rs.destination_database_name,
    rs.restore_date,
    bmf.physical_device_name,
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.database_name         AS source_database_name,
    bs.user_name
FROM msdb.dbo.restorehistory rs
INNER JOIN msdb.dbo.backupset bs ON rs.backup_set_id = bs.backup_set_id
INNER JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
-- WHERE rs.destination_database_name = 'my_database_name'  -- Uncomment and specify database
ORDER BY rs.restore_date DESC;
GO


/*****************************************************************************************************
 * SECTION 5: RECENT BACKUPS & MISSING BACKUP DETECTION
 * Purpose: Identify databases with missing or outdated backups
 *****************************************************************************************************/

-- Query 5.1: All Backups from Last 24 Hours
-- Quick check for any backup activity in the past day
SELECT
    db.name                  AS database_name,
    bs.backup_finish_date,
    bs.type                  AS backup_type_code,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                      AS backup_type
FROM master.sys.databases db
LEFT JOIN msdb.dbo.backupset AS bs ON db.name = bs.database_name
  AND bs.backup_finish_date BETWEEN DATEADD(dd, -1, DATEDIFF(dd, 0, GETDATE())) 
                                AND DATEADD(dd, 0, DATEDIFF(dd, 0, GETDATE()))
WHERE db.name NOT IN ('msdb', 'model', 'master', 'distribution', 'tempdb') 
ORDER BY bs.backup_finish_date DESC;
GO


-- Query 5.2: Full Backups from Last 24 Hours
-- Focus on full database backups only
SELECT
    d.name                   AS database_name,
    bs.backup_finish_date,
    mf.physical_device_name
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON d.name = bs.database_name 
  AND bs.backup_finish_date >= DATEADD(HOUR, -24, GETDATE())
  AND bs.type = 'D'
LEFT JOIN msdb.dbo.backupmediafamily AS mf ON bs.media_set_id = mf.media_set_id
WHERE d.name <> 'tempdb'
ORDER BY d.name, bs.backup_finish_date;
GO


-- Query 5.3: Last Full Backup for Each Database
-- Quick summary of last full backup per database
SELECT 
    d.name                   AS database_name, 
    MAX(b.backup_finish_date) AS last_backup_finish_date
FROM master.sys.databases d
LEFT OUTER JOIN msdb.dbo.backupset b ON d.name = b.database_name AND b.type = 'D'
WHERE d.database_id NOT IN (2, 3)  -- Exclude tempdb and model
GROUP BY d.name
ORDER BY last_backup_finish_date DESC;
GO


-- Query 5.4: Last Backup of Each Type Per Database with Status Alerts
-- Comprehensive backup status with alerts for overdue backups
SELECT
    d.[name]                                      AS database_name,
    d.recovery_model_desc                         AS recovery_model,
    d.state_desc                                  AS database_state,

    -- Last Full Backup
    MAX(CASE WHEN bs.[type] = 'D'
             THEN bs.backup_finish_date END)      AS last_full_backup,
    DATEDIFF(HOUR,
        MAX(CASE WHEN bs.[type] = 'D'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS hours_since_full_backup,

    -- Last Differential Backup
    MAX(CASE WHEN bs.[type] = 'I'
             THEN bs.backup_finish_date END)      AS last_diff_backup,

    -- Last Log Backup
    MAX(CASE WHEN bs.[type] = 'L'
             THEN bs.backup_finish_date END)      AS last_log_backup,
    DATEDIFF(MINUTE,
        MAX(CASE WHEN bs.[type] = 'L'
                 THEN bs.backup_finish_date END),
        GETDATE())                                AS min_since_log_backup,

    -- Full Backup Status Alert
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
    END                                           AS full_backup_status,

    -- Log Backup Status Alert
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
    END                                           AS log_backup_status

FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON d.[name] = bs.database_name
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
  AND d.source_database_id IS NULL  -- Exclude database snapshots
GROUP BY d.[name], d.recovery_model_desc, d.state_desc
ORDER BY hours_since_full_backup DESC;
GO


-- Query 5.5: Databases in FULL Recovery Without Recent Log Backups
-- Critical alert: databases at risk of transaction log growth
SELECT
    d.[name]                  AS database_name,
    d.recovery_model_desc     AS recovery_model,
    d.log_reuse_wait_desc     AS log_reuse_wait,
    MAX(bs.backup_finish_date) AS last_log_backup,
    DATEDIFF(MINUTE,
        MAX(bs.backup_finish_date),
        GETDATE())            AS minutes_since_last_log
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON d.[name] = bs.database_name AND bs.[type] = 'L'
WHERE d.recovery_model_desc = 'FULL'
  AND d.database_id > 4
  AND d.state_desc = 'ONLINE'
GROUP BY d.[name], d.recovery_model_desc, d.log_reuse_wait_desc
HAVING MAX(bs.backup_finish_date) IS NULL
    OR DATEDIFF(MINUTE, MAX(bs.backup_finish_date), GETDATE()) > 60
ORDER BY minutes_since_last_log DESC;
GO


/*****************************************************************************************************
 * SECTION 6: BACKUP VERIFICATION & INTEGRITY CHECKS
 * Purpose: Verify backup files, check backup chain completeness
 * Safety:  RESTORE VERIFYONLY is read-only — it does NOT restore data
 *****************************************************************************************************/

-- Query 6.1: Manual RESTORE VERIFYONLY Template
-- Validates backup file readability without restoring
-- Does NOT restore — just validates header, checksums, and structure

-- Single backup file:
-- RESTORE VERIFYONLY FROM DISK = N'C:\Backups\YourDB_Full.bak' WITH CHECKSUM;

-- Multiple stripe files:
-- RESTORE VERIFYONLY
--     FROM DISK = N'C:\Backups\YourDB_Stripe1.bak',
--          DISK = N'C:\Backups\YourDB_Stripe2.bak'
--     WITH CHECKSUM;


-- Query 6.2: Generate VERIFYONLY Commands for Recent Full Backups
-- Generates verification commands for all recent full backups
SELECT
    bs.database_name,
    bs.backup_finish_date,
    bmf.physical_device_name,
    'RESTORE VERIFYONLY FROM DISK = N'''
        + bmf.physical_device_name
        + ''' WITH CHECKSUM;'                    AS verify_command
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.[type] = 'D'  -- Full backups only
  AND bs.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY bs.backup_finish_date DESC;
GO


-- Query 6.3: Backup Chain Integrity Check for FULL Recovery Databases
-- Detects gaps in log backup chain
-- Each log backup's first_lsn should equal the prior log backup's last_lsn
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
    END AS chain_status
FROM LogChain
WHERE prev_last_lsn IS NOT NULL
  AND first_lsn <> prev_last_lsn
ORDER BY database_name, backup_finish_date;
GO


-- Query 6.4: Backup Files Without Checksum
-- Identifies backups taken without checksums (cannot detect silent corruption)
SELECT
    bs.database_name,
    bs.backup_finish_date,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                              AS backup_type,
    bs.has_backup_checksums,
    CASE
        WHEN bs.has_backup_checksums = 0
            THEN '*** NO CHECKSUM ***'
        ELSE 'OK'
    END                              AS checksum_status,
    bmf.physical_device_name
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
  AND bs.has_backup_checksums = 0
ORDER BY bs.backup_finish_date DESC;
GO


-- Query 6.5: Inspect Backup File Contents (Templates)
-- Use these commands to examine backup file headers and file lists
-- RESTORE HEADERONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';
-- RESTORE FILELISTONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';
GO


/*****************************************************************************************************
 * SECTION 7: BACKUP PERFORMANCE & METRICS
 * Purpose: Analyze backup size, duration, throughput, and compression
 *****************************************************************************************************/

-- Query 7.1: Backup Performance Analysis (Summary)
-- Shows size, duration, compression ratio, and throughput for recent backups
SELECT TOP 50
    bs.database_name,
    CASE bs.[type]
        WHEN 'D' THEN 'Full'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
    END                                           AS backup_type,
    bs.backup_start_date,
    bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_start_date,
                     bs.backup_finish_date)       AS duration_sec,
    CAST(bs.backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS backup_size_mb,
    CAST(bs.compressed_backup_size / 1048576.0
         AS DECIMAL(18,2))                        AS compressed_mb,
    CAST(100.0 - (bs.compressed_backup_size * 100.0
         / NULLIF(bs.backup_size, 0))
         AS DECIMAL(5,2))                         AS compression_pct,
    CAST(bs.backup_size / 1048576.0
         / NULLIF(DATEDIFF(SECOND,
             bs.backup_start_date,
             bs.backup_finish_date), 0)
         AS DECIMAL(18,2))                        AS throughput_mbps,
    bs.is_encrypted,
    bs.has_backup_checksums
FROM msdb.dbo.backupset bs
ORDER BY bs.backup_finish_date DESC;
GO


/*****************************************************************************************************
 * SECTION 8: LOG BACKUP & TRANSACTION LOG MONITORING
 * Purpose: Monitor log backup status and identify log-related issues
 *****************************************************************************************************/

-- Query 8.1: Check What's Preventing Log Backup Completion
-- Identifies the log reuse wait condition for a specific database
SELECT 
    [name]                   AS database_name, 
    log_reuse_wait_desc 
FROM sys.databases 
WHERE name = 'db'  -- Change to your database name
ORDER BY [name];
GO


-- Query 8.2: Comprehensive Database Backup Status with Log Information
-- Shows recovery model, log size, log usage, and last backup of each type
-- Includes backup compression details and last good CheckDB time
SELECT 
    ISNULL(d.[name], bs.[database_name]) AS database_name, 
    d.recovery_model_desc                AS recovery_model, 
    d.log_reuse_wait_desc                AS log_reuse_wait_desc,
    CONVERT(DECIMAL(18,2), ds.cntr_value/1024.0) AS total_data_file_size_mb,
    CONVERT(DECIMAL(18,2), ls.cntr_value/1024.0) AS total_log_file_size_mb,
    CAST(CAST(lu.cntr_value AS FLOAT) / CAST(ls.cntr_value AS FLOAT) AS DECIMAL(18,2)) * 100 
                                         AS log_used_percent,
    MAX(CASE WHEN bs.[type] = 'D' THEN bs.backup_finish_date ELSE NULL END) 
                                         AS last_full_backup,
    MAX(CASE WHEN bs.[type] = 'D' THEN CONVERT(BIGINT, bs.compressed_backup_size / 1048576) ELSE NULL END) 
                                         AS last_full_compressed_size_mb,
    MAX(CASE WHEN bs.[type] = 'D' THEN CONVERT(DECIMAL(18,2), bs.backup_size / bs.compressed_backup_size) ELSE NULL END) 
                                         AS backup_compression_ratio,
    MAX(CASE WHEN bs.[type] = 'D' THEN bs.compression_algorithm ELSE NULL END) 
                                         AS last_full_backup_compression_algorithm,
    MAX(CASE WHEN bs.[type] = 'I' THEN bs.backup_finish_date ELSE NULL END) 
                                         AS last_differential_backup,
    MAX(CASE WHEN bs.[type] = 'L' THEN bs.backup_finish_date ELSE NULL END) 
                                         AS last_log_backup,
    MAX(CASE WHEN bs.[type] = 'L' THEN bs.last_valid_restore_time ELSE NULL END) 
                                         AS last_valid_restore_time,
    DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') 
                                         AS last_good_checkdb
FROM sys.databases AS d WITH (NOLOCK)
INNER JOIN sys.master_files AS mf WITH (NOLOCK) ON d.database_id = mf.database_id
LEFT OUTER JOIN msdb.dbo.backupset AS bs WITH (NOLOCK) ON bs.[database_name] = d.[name]
    AND bs.backup_finish_date > GETDATE() - 30
LEFT OUTER JOIN sys.dm_os_performance_counters AS lu WITH (NOLOCK) ON d.name = lu.instance_name
LEFT OUTER JOIN sys.dm_os_performance_counters AS ls WITH (NOLOCK) ON d.name = ls.instance_name
INNER JOIN sys.dm_os_performance_counters AS ds WITH (NOLOCK) ON d.name = ds.instance_name
WHERE d.name <> N'tempdb'
  AND lu.counter_name LIKE N'Log File(s) Used Size (KB)%' 
  AND ls.counter_name LIKE N'Log File(s) Size (KB)%'
  AND ds.counter_name LIKE N'Data File(s) Size (KB)%'
  AND ls.cntr_value > 0 
GROUP BY 
    ISNULL(d.[name], bs.[database_name]), 
    d.recovery_model_desc, 
    d.log_reuse_wait_desc, 
    d.[name],
    CONVERT(DECIMAL(18,2), ds.cntr_value/1024.0),
    CONVERT(DECIMAL(18,2), ls.cntr_value/1024.0), 
    CAST(CAST(lu.cntr_value AS FLOAT) / CAST(ls.cntr_value AS FLOAT) AS DECIMAL(18,2)) * 100
ORDER BY database_name;
GO




/*****************************************************************************************************
 * SECTION 9: RESTORE OPERATIONS & VERIFICATION
 * Purpose: Backup file inspection, database restore scenarios, and backup history management
 *****************************************************************************************************/

-- Query 9.1: Inspect Backup File Header Information
-- Retrieves backup set metadata from a backup file
-- Shows backup type, date, server name, database version, and encryption details
RESTORE HEADERONLY 
FROM DISK = 'D:\MSSQLServer\Adv.bak';
GO


-- Query 9.2: List Files Contained in Backup
-- Shows logical and physical file names, file types, and sizes
-- File types: 'D' = Data, 'L' = Log, 'S' = Filestream
RESTORE FILELISTONLY 
FROM DISK = 'D:\MSSQLServer\Adv.bak';
GO


-- Query 9.3: Verify Backup Integrity
-- Checks backup file validity without restoring it
-- Verifies readability, checksums, and backup set integrity
RESTORE VERIFYONLY 
FROM DISK = 'D:\MSSQLServer\Adv.bak';
GO


-- Query 9.4: Single File Restore (Complete Sequence)
-- Used when only a specific data file needs to be restored
-- Step 1: Perform tail-log backup to capture recent transactions
BACKUP LOG FTest
    TO DISK = 'D:\MSSQLServer\FTest.trn'
    WITH INIT, CONTINUE_AFTER_ERROR;
GO

-- Step 2: Restore only the damaged/missing file
RESTORE DATABASE FTest
    FILE = 'FTest1'
    FROM DISK = 'D:\MSSQLServer\FTest_full.bak'
    WITH NORECOVERY;
GO

-- Step 3: Restore the tail-log backup and bring database online
RESTORE LOG FTest
    FROM DISK = 'D:\MSSQLServer\FTest.trn'
    WITH RECOVERY;
GO


-- Query 9.5: Point-in-Time Restore Using Marked Transactions
-- Allows restoration to a specific transaction mark

-- Example: Mark a transaction for potential recovery point
-- BEGIN TRAN UpdPrc WITH MARK 'Start of nightly update process';

-- Query marked transactions to find recovery points
SELECT 
    database_name,
    mark_name,
    description,
    user_name,
    lsn,
    mark_time
FROM msdb.dbo.logmarkhistory
ORDER BY mark_time DESC;
GO


-- Query 9.6: Force Database Recovery
-- If the last restore was inadvertently performed WITH NORECOVERY,
-- this command forces the database to complete recovery and come online
-- RESTORE LOG [DatabaseName] WITH RECOVERY;
GO


-- Query 9.7: Restore to Point Before Transaction Mark
-- Restores database to state immediately before the specified mark
-- Useful to exclude a problematic transaction
RESTORE LOG RTest
    FROM DISK = 'D:\MSSQLServer\RTest.trn'
    WITH RECOVERY, STOPBEFOREMARK = 'PriorToInsert';
GO


-- Query 9.8: Restore to Specific Transaction Mark
-- Restores database including the marked transaction
-- Useful to restore to a known good state
RESTORE LOG RTest
    FROM DISK = 'D:\MSSQLServer\RTest.trn'
    WITH RECOVERY, STOPATMARK = 'PriorToInsert';
GO


-- Query 9.9: Restore with STANDBY Mode (Complete Sequence)
-- STANDBY allows read-only access between log restores
-- Useful for reporting on near-current data during log shipping

-- Step 1: Set database to single-user mode
ALTER DATABASE [MarketYields] 
SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

-- Step 2: Restore full backup with file relocation
RESTORE DATABASE [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 2,  
    MOVE N'MarketYields' TO N'D:\MKTG\MarketYields.mdf',  
    MOVE N'MarketYields_log' TO N'L:\MKTG\MarketYields_log.ldf',  
    NORECOVERY,  
    NOUNLOAD,  
    STATS = 5;
GO

-- Step 3: Restore differential backup
RESTORE DATABASE [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 5,  
    NORECOVERY,  
    NOUNLOAD,  
    STATS = 5;
GO

-- Step 4: Restore transaction log (can repeat for additional logs)
RESTORE LOG [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 6,  
    NORECOVERY,  
    NOUNLOAD,  
    STATS = 5;
GO

-- Step 5: Restore final log with STANDBY mode
-- Database will be readable but can accept additional log restores
RESTORE LOG [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 7,  
    STANDBY = N'L:\Log_Standby.bak',  
    NOUNLOAD,  
    STATS = 5;
GO

-- Step 6: Set database back to multi-user mode
ALTER DATABASE [MarketYields] 
SET MULTI_USER;
GO


-- Query 9.10: Delete Backup History
-- Removes old backup history records from msdb to manage database size

-- Delete all backup history prior to specified date
EXEC sp_delete_backuphistory 
    @oldest_date = '20090101';
GO

-- Delete backup history for a specific database
EXEC sp_delete_database_backuphistory 
    @database_name = 'Market';
GO


/*****************************************************************************************************
 * SECTION 10: SYSTEM DATABASE RESTORE PROCEDURES
 * Purpose: Guidance for restoring SQL Server system databases
 *****************************************************************************************************/

/*
-----------------------------------------------------------------------------------------
MODEL DATABASE
-----------------------------------------------------------------------------------------
Description: Template for all new databases
Restore Procedure: 
    1. Start SQL Server instance with the -T3608 trace flag (only starts master)
    2. Restore model database using the normal RESTORE DATABASE command
    3. Remove trace flag and restart normally

-----------------------------------------------------------------------------------------
MSDB DATABASE
-----------------------------------------------------------------------------------------
Description: Used by SQL Server Agent for scheduling alerts and jobs, and for 
             recording details of operations. Also contains backup/restore history tables.
Restore Procedure:
    - Can be restored like any user database using RESTORE DATABASE command
    - If corrupt, SQL Server Agent will not start
    - Database can still function normally even if msdb is unavailable

-----------------------------------------------------------------------------------------
RESOURCE DATABASE
-----------------------------------------------------------------------------------------
Description: Read-only hidden database that contains copies of all system objects
Restore Procedure:
    - Cannot use RESTORE DATABASE command
    - Must use file-level restore in Windows Explorer (copy mssqlsystemresource.mdf/ldf)
    - Alternative: Run SQL Server setup program to rebuild system databases
    - Located in MSSQL\Binn folder

-----------------------------------------------------------------------------------------
TEMPDB DATABASE
-----------------------------------------------------------------------------------------
Description: Workspace for holding temporary tables and intermediate result sets
Restore Procedure:
    - NO backup operations can be performed on tempdb
    - NO restore needed - automatically re-created every time SQL Server starts
    - If experiencing issues, restart SQL Server instance

-----------------------------------------------------------------------------------------
MASTER DATABASE
-----------------------------------------------------------------------------------------
Description: Holds all system-level configurations, logins, endpoints, linked servers,
             and metadata about all other databases
Restore Procedure:

    STEP 1: Ensure a master database exists
    ----------------------------------------
    If master is corrupt/missing, SQL Server will not start. Obtain a temporary master 
    database using one of these methods:
    
    a) Run SQL Server setup program (e.g., SQL Server\110\Setup\Bootstrap\SQL11\setup.exe)
       WARNING: Setup program will overwrite ALL system databases
    
    b) Use file-level backup of master.mdf/master.ldf 
       (must be taken when SQL Server was offline or via VSS service)
    
    c) Copy master.mdf from the Templates folder in MSSQL\Binn for the instance
    
    STEP 2: Restore the correct master database
    --------------------------------------------
    1. Start SQL Server instance in single-user mode using -m startup parameter:
       sqlservr.exe -m
       
    2. Connect using sqlcmd utility:
       sqlcmd -S ServerName -E
       
    3. Execute RESTORE DATABASE command:
       RESTORE DATABASE [master] 
       FROM DISK = 'C:\Backups\master.bak' 
       WITH REPLACE;
       
    4. After restore completes, SQL Server instance will automatically shut down
    
    5. Remove the single-user parameter (-m) from startup configuration
    
    6. Restart SQL Server normally
    
    7. Verify all databases and logins are accessible

-----------------------------------------------------------------------------------------
*/


/*****************************************************************************************************
 * SECTION 11: BACKUP & RESTORE ARCHITECTURE CONCEPTS AND RESTORE SCENARIO REFERENCE
 * Purpose: Conceptual reference covering the internal backup/restore architecture, recovery
 *          models, restore phases, and step-by-step T-SQL patterns for every restore scenario
 *          (complements the operational queries in Sections 6 and 9)
 *****************************************************************************************************/

/*
-----------------------------------------------------------------------------------------
11.1  INTERNAL MECHANICS: WRITE-AHEAD LOGGING (WAL) AND CHECKPOINTS
-----------------------------------------------------------------------------------------
SQL Server guarantees transactional durability through Write-Ahead Logging. Every data
modification is written to the transaction log on disk BEFORE the modified data page is
written to the physical data file.

    - Log Buffers  : Log records are batched in memory (log buffers) before being
                      flushed to disk.
    - Checkpoints  : Periodically flush all "dirty" (modified) pages from the buffer pool
                      to the data files. This bounds crash-recovery time, since only
                      transactions after the last checkpoint must be processed on restart.

-----------------------------------------------------------------------------------------
11.2  RECOVERY MODELS
-----------------------------------------------------------------------------------------
The recovery model controls how the transaction log is maintained and which restore
options are available.

    SIMPLE
        - Log is auto-truncated after each checkpoint.
        - No point-in-time recovery; restore is only possible to the point of the last
          full/differential backup.
        - Lowest administrative overhead; relies solely on full and differential backups.

    FULL
        - Every operation is fully logged; the log is only truncated by a log backup.
        - Supports point-in-time recovery to any moment covered by the log chain.
        - Requires periodic transaction log backups, or the log will grow unbounded
          (see Section 8 for log-backup monitoring queries).

    BULK_LOGGED
        - Adjunct to FULL; minimally logs bulk operations (BULK INSERT, SELECT INTO,
          index rebuilds) to reduce log volume and improve throughput.
        - Point-in-time recovery is DISABLED for any log backup that contains a
          minimally logged operation.
        - Recommended pattern: backup log -> switch to BULK_LOGGED -> run bulk operation
          -> switch back to FULL -> backup log again, to keep the point-in-time gap as
          small as possible.

-----------------------------------------------------------------------------------------
11.3  CORE BACKUP TYPES
-----------------------------------------------------------------------------------------
    Full            : Complete copy of all data files, plus enough of the log to bring
                       the database to a consistent state on restore. Foundation of every
                       restore chain.
    Differential    : Captures only the data extents changed since the last full backup.
                       Faster to restore than a long chain of log backups.
    Transaction Log : Captures all log activity since the last log backup. In FULL/
                       BULK_LOGGED models, this is the only operation that truncates the
                       log.
    Tail-Log        : A final log backup taken at the moment of failure (WITH NO_TRUNCATE
                       if the database is damaged) to capture any not-yet-backed-up
                       transactions, enabling zero data loss.
    Copy-Only       : An out-of-band backup (WITH COPY_ONLY) that does NOT break the
                       differential base or the log backup chain.

-----------------------------------------------------------------------------------------
11.4  RESTORE PHASES
-----------------------------------------------------------------------------------------
Every restore sequence (Full -> Differential -> Logs, applied in order) passes through
three phases:

    1. Data Copy Phase : Data, log, and index pages are copied from the backup media into
                          the target database files.
    2. Redo Phase      : Committed transactions from the transaction log(s) are rolled
                          forward to bring the database to the desired recovery point.
                          (Enterprise Edition Fast Recovery lets users connect once Redo
                          completes, while Undo still runs in the background.)
    3. Undo Phase      : Transactions that were still open (uncommitted) at the recovery
                          point are rolled back to guarantee consistency before the
                          database comes online.

-----------------------------------------------------------------------------------------
11.5  RECOVERY STATES
-----------------------------------------------------------------------------------------
    WITH NORECOVERY : Leaves the database in the RESTORING state so more backups can be
                       applied. Use for every backup in the chain except the last.
    WITH RECOVERY   : Default. Completes Redo/Undo and brings the database online.
                       Use only for the final backup in the chain.
    WITH STANDBY    : Completes Redo/Undo but keeps the database read-only between log
                       restores (undo actions are saved to an undo file), so it can be
                       queried while more log backups are pending.

-----------------------------------------------------------------------------------------
11.6  BACKUP STRATEGY BEST PRACTICES
-----------------------------------------------------------------------------------------
    - Layer Full + Differential + Log backups to fit your RPO/RTO; SIMPLE recovery is
      only appropriate when some data loss (back to the last full/diff) is acceptable.
    - Verify every backup: RESTORE VERIFYONLY plus periodic full test restores (Section 6)
      are the only way to know a backup is actually recoverable.
    - Don't neglect system databases - back up master (and msdb) regularly, especially
      after logins, linked servers, or instance-level configuration changes.
    - Store backups on separate physical devices/storage from the data and log files,
      and keep an off-site/geo-redundant copy for disaster recovery.
    - Set PAGE_VERIFY = CHECKSUM on every database so I/O-subsystem corruption is caught
      as early as possible (see database-integrity-checks.sql, Section 2.3, for the audit
      query and fix-it script).
    - Encrypt backups (BACKUP DATABASE ... WITH ENCRYPTION) and store the certificate/key
      used separately from the backup files themselves - see tde-and-encryption-status.sql
      for certificate expiry and encryption-state audits.
-----------------------------------------------------------------------------------------
*/


-- Query 11.1: Essential Pre-Restore Preparations
-- Step 1: Isolate the database - required before a full restore, since SQL Server
-- effectively drops and re-creates the database, which cannot happen with active
-- connections in place
ALTER DATABASE [YourDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

-- Step 2: Take a tail-log backup to capture any transactions not yet backed up
-- (WITH NO_TRUNCATE allows this even if the database is damaged or inaccessible)
BACKUP LOG [YourDatabase]
    TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH NO_TRUNCATE, NORECOVERY;
GO

-- Step 3: Inspect available backup sets before restoring (see also Section 9.1/9.2)
RESTORE HEADERONLY   FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
RESTORE FILELISTONLY FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
RESTORE LABELONLY    FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
GO

-- Note: If the backup is encrypted, the certificate/asymmetric key used to encrypt it
-- must already exist on the destination instance, and the restoring login needs
-- VIEW DEFINITION permission on that encryptor.


-- Query 11.2: Complete (Full) Database Restore - Full -> Differential -> Logs -> Tail-Log
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;
GO

RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Diff.bak'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
GO


-- Query 11.3: Point-in-Time Restore Using STOPAT
-- Requires FULL or BULK_LOGGED recovery model. Restore a full backup taken before the
-- target time, then apply subsequent log backups, stopping log application at STOPAT.
-- (See also Section 9.5/9.7/9.8 for STOPATMARK / STOPBEFOREMARK named-transaction restores.)
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY, STOPAT = '2026-07-24T14:30:00';
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY, STOPAT = '2026-07-24T14:30:00';
GO


-- Query 11.4: File/Filegroup Restore (read-write filegroup - requires FULL/BULK_LOGGED,
-- since transaction log backups must be applied afterward)
BACKUP LOG [YourDatabase]
    TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH NORECOVERY;
GO

RESTORE DATABASE [YourDatabase]
    FILE = 'YourDatabase_FG2_File1'
    FROM DISK = 'D:\Backups\YourDatabase_FileGroup.bak'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
GO


-- Query 11.5: Page Restore (Enterprise Edition only; NOT supported under SIMPLE recovery;
-- system pages such as file headers cannot be restored this way)
-- Repairs specific corrupted 8KB pages without taking the whole database offline
RESTORE DATABASE [YourDatabase]
    PAGE = '1:57, 1:58, 3:24'
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;
GO

-- Take a fresh log backup to capture the restored page(s), then recover
BACKUP LOG [YourDatabase] TO DISK = 'D:\Backups\YourDatabase_PostPageRestore.trn';
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_PostPageRestore.trn'
    WITH RECOVERY;
GO


-- Query 11.6: Piecemeal Restore - bring the PRIMARY filegroup online first, then
-- restore remaining filegroups individually while the database is partially available
RESTORE DATABASE [YourDatabase]
    FILEGROUP = 'PRIMARY'
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH PARTIAL, NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
GO

-- Remaining (secondary) filegroups can be restored afterward, individually, while
-- PRIMARY is already online and serving queries
RESTORE DATABASE [YourDatabase]
    FILEGROUP = 'SECONDARY'
    FROM DISK = 'D:\Backups\YourDatabase_FileGroup.bak'
    WITH NORECOVERY;
GO

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
GO


-- Query 11.7: Revert to a Database Snapshot
-- Fast way to return to a known-good state; breaks the log backup chain, so a new full
-- backup is required afterward to resume log backups. Drop other snapshots first if
-- reverting to a point before they were created.
RESTORE DATABASE [YourDatabase]
    FROM DATABASE_SNAPSHOT = 'YourDatabase_Snapshot_20260724';
GO


-- Query 11.8: Restore with File Relocation and Overwrite (General Options Reference)
-- WITH REPLACE                          : Overwrite an existing database of the same
--                                          name, or restore a backup onto a differently
--                                          named existing database
-- WITH MOVE 'logical' TO 'physical_path' : Relocate data/log files, e.g. when restoring
--                                          to a different server or drive layout
-- WITH STANDBY = 'undo_file'            : Read-only between log restores (see 11.5)
-- WITH CHECKSUM                         : Verify page checksums recorded in the backup
-- WITH FILE = n                         : Select a specific backup set within a media
--                                          set/device that holds multiple backups
-- WITH RESTRICTED_USER                  : Limit access to sysadmin/db_owner/dbcreator
--                                          after restore, for post-restore validation
-- WITH KEEP_REPLICATION                 : Preserve replication settings when restoring a
--                                          published database to a different instance
-- WITH RESTART                          : Resume an interrupted restore from where it
--                                          left off, skipping completed work
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH REPLACE,
         MOVE 'YourDatabase'     TO 'D:\Data\YourDatabase.mdf',
         MOVE 'YourDatabase_log' TO 'L:\Log\YourDatabase_log.ldf',
         RECOVERY,
         STATS = 10;
GO


-- Query 11.9: Post-Restore Checklist
-- 1. Integrity check on the recovered database
DBCC CHECKDB ('YourDatabase') WITH NO_INFOMSGS;
GO

-- 2. If the database was moved to a new server, remap orphaned logins/users so
--    applications can connect (see logins-and-security.sql for orphaned-user repair)

-- 3. Periodically test the full restore sequence end-to-end to validate that RTO/RPO
--    targets are actually met (see Section 5 for backup-recency/overdue alerts)


/*
Troubleshooting Steps for Managed / Automated Backups
*/

-- 1. Enable trace flags
DBCC TRACEON(3014, 3212, 3004, 3605, 3051, -1);


--trace functionality:

--3004: Trace flag 3004 adds information to the output about file preparation, bitmaps, and instant file initialization (instant file initialization, which avoids the costly operation about zeroing out files, is only relevant for restore operations, and only for restoring data files).

--3014: This is one of the undocumented Trace flags in SQL Server, which basically gives a detailed information(Well, This might not be useful in most of the cases) regarding File Creation, Padding and much more related Info while you are taking a Backup of your Database

--3212: Prints “Backup stats” to the SQL log

--3213: Logs Output buffer info for backups to ERRORLOG

--3605: Sends a variety of types of information to the SQL Server error log instead of to the user consol


-- 2. Re-enable extended debug events
EXEC msdb.managed_backup.sp_set_parameter
    @parameter_name = 'SSMBackup2WADebugXevent',
    @parameter_value = 'true';

-- 3. Re-enable SQL Agent verbose logging
EXEC msdb.dbo.sp_set_sqlagent_properties
    @errorlogging_level = 7;

-- 4. Capture Managed Backup health status
SELECT *
FROM managed_backup.fn_get_health_status(NULL, NULL);

-- 5. Run Managed Backup diagnostics
EXEC managed_backup.sp_get_backup_diagnostics;

-- 6. Take backup of msdb (execute separately, example below)
-- BACKUP DATABASE msdb TO DISK = 'C:\Backup\msdb.bak' WITH INIT;


/*
7. Data Collection for Troubleshooting
*/

-- Collect the following:

-- SQL Server Agent logs (especially if verbose logging is enabled)

-- Default XEvent files:
--   SmartAdminEvents_Backup_*
--   SmartAdminEvents__*

-- Application logs

-- System event logs

-- Managed Backup diagnostics (reads XEvent files; avoid if files are huge)
EXEC msdb.smart_admin.sp_get_backup_diagnostics;

-- Managed database metadata
SELECT *
FROM msdb.dbo.autoadmin_managed_databases;

SELECT *
FROM msdb.dbo.autoadmin_system_flags;

SELECT *
FROM msdb.dbo.autoadmin_task_agent_metadata;

-- SQL Agent job history
SELECT *
FROM msdb.dbo.sysjobhistory;

-- Ring buffer exceptions (ensure full text is not truncated)
SELECT *
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = 'RING_BUFFER_EXCEPTION';

-- Loaded modules (for stack alignment)
SELECT *
FROM sys.dm_os_loaded_modules;
``



/*****************************************************************************************************
 * END OF FILE
 *****************************************************************************************************/