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
 * END OF FILE
 *****************************************************************************************************/