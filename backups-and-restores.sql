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
 *   9. RESTORE UTILITIES & BACKUP HISTORY MAINTENANCE
 *  10. SYSTEM DATABASE RESTORE PROCEDURES
 *  11. RESTORE SCENARIO TEMPLATES
 *  12. MANAGED BACKUP TO AZURE - DIAGNOSTICS & TROUBLESHOOTING
 *
 * Background theory (recovery models, backup types, restore phases, recovery states, RESTORE
 * options, strategy best practices) is in the CONCEPTS REFERENCE block below.
 *****************************************************************************************************/
/*****************************************************************************************************
 * !! READ BEFORE RUNNING !!
 * Do NOT execute this file end-to-end. Sections 1-8 are read-only diagnostic queries and are safe.
 * Sections 9-12 contain TEMPLATES (BACKUP / RESTORE / ALTER DATABASE / history purge / trace flags)
 * and are deliberately commented out. Copy the block you need, replace the placeholder database
 * names and paths, and run it deliberately.
 *****************************************************************************************************/

/*=====================================================================================================
  CONCEPTS REFERENCE
=======================================================================================================

C1. WRITE-AHEAD LOGGING (WAL) AND CHECKPOINTS
---------------------------------------------------------------------------------------------------
SQL Server guarantees transactional durability through Write-Ahead Logging: every data modification
is written to the transaction log on disk BEFORE the modified data page is written to the data file.

    Log Buffers : Log records are batched in memory before being flushed to disk.
    Checkpoints : Periodically flush "dirty" (modified) pages from the buffer pool to the data
                  files. This bounds crash-recovery time, since only transactions after the last
                  checkpoint must be processed on restart.


C2. RECOVERY MODELS
---------------------------------------------------------------------------------------------------
Controls how the transaction log is maintained and which restore options are available.

    SIMPLE       Log is auto-truncated after each checkpoint. No point-in-time recovery - restore
                 is only possible to the last full/differential backup. Lowest admin overhead.

    FULL         Every operation is fully logged; the log is only truncated by a log backup.
                 Supports point-in-time recovery to any moment covered by the log chain. Requires
                 periodic log backups or the log grows unbounded (Section 8 monitors this).

    BULK_LOGGED  Adjunct to FULL. Minimally logs bulk operations (BULK INSERT, SELECT INTO, index
                 rebuilds) to reduce log volume. Point-in-time recovery is DISABLED for any log
                 backup containing a minimally logged operation.
                 Pattern: backup log -> switch to BULK_LOGGED -> run bulk op -> switch back to
                 FULL -> backup log again, to keep the point-in-time gap as small as possible.


C3. CORE BACKUP TYPES
---------------------------------------------------------------------------------------------------
    Full             Complete copy of all data files, plus enough log to reach a consistent state
                     on restore. Foundation of every restore chain.
    Differential     Only the data extents changed since the last full backup. Faster to restore
                     than a long chain of log backups.
    Transaction Log  All log activity since the last log backup. Under FULL/BULK_LOGGED this is the
                     only operation that truncates the log.
    Tail-Log         Final log backup taken at the moment of failure (WITH NO_TRUNCATE if the
                     database is damaged) to capture not-yet-backed-up transactions - enables zero
                     data loss.
    Copy-Only        Out-of-band backup (WITH COPY_ONLY) that does NOT break the differential base
                     or the log backup chain.


C4. RESTORE PHASES
---------------------------------------------------------------------------------------------------
Every restore sequence (Full -> Differential -> Logs, applied in order) passes through:

    1. Data Copy  Data, log, and index pages are copied from the backup media into the target
                  database files.
    2. Redo       Committed transactions are rolled forward to the desired recovery point.
                  (Enterprise Edition Fast Recovery lets users connect once Redo completes, while
                  Undo still runs in the background.)
    3. Undo       Transactions still open at the recovery point are rolled back to guarantee
                  consistency before the database comes online.


C5. RECOVERY STATES
---------------------------------------------------------------------------------------------------
    WITH NORECOVERY  Leaves the database in RESTORING state so more backups can be applied. Use for
                     every backup in the chain except the last.
    WITH RECOVERY    Default. Completes Redo/Undo and brings the database online. Use only for the
                     final backup in the chain.
    WITH STANDBY     Completes Redo/Undo but keeps the database read-only between log restores
                     (undo actions are saved to an undo file), so it can be queried while more log
                     backups are still pending.


C6. COMMON RESTORE OPTIONS
---------------------------------------------------------------------------------------------------
    REPLACE                      Overwrite an existing database of the same name, or restore a
                                 backup onto a differently named existing database.
    MOVE 'logical' TO 'path'     Relocate data/log files, e.g. restoring to a different server or
                                 drive layout.
    STANDBY = 'undo_file'        Read-only between log restores (see C5).
    CHECKSUM                     Verify page checksums recorded in the backup.
    FILE = n                     Select a specific backup set within a media set/device holding
                                 multiple backups.
    RESTRICTED_USER              Limit access to sysadmin/db_owner/dbcreator after restore, for
                                 post-restore validation.
    KEEP_REPLICATION             Preserve replication settings when restoring a published database
                                 to a different instance.
    RESTART                      Resume an interrupted restore from where it left off.
    STATS = n                    Report progress every n percent.


C7. BACKUP STRATEGY BEST PRACTICES
---------------------------------------------------------------------------------------------------
    - Layer Full + Differential + Log backups to fit your RPO/RTO. SIMPLE recovery is only
      appropriate when data loss back to the last full/diff is acceptable.
    - Verify every backup: RESTORE VERIFYONLY plus periodic full test restores (Section 6) are the
      only way to know a backup is actually recoverable.
    - Don't neglect system databases - back up master (and msdb) regularly, especially after logins,
      linked servers, or instance-level configuration changes.
    - Store backups on separate physical devices/storage from the data and log files, and keep an
      off-site/geo-redundant copy for disaster recovery.
    - Set PAGE_VERIFY = CHECKSUM on every database so I/O-subsystem corruption is caught as early as
      possible (see database-integrity-checks.sql, Section 2.3, for the audit query and fix script).
    - Encrypt backups (BACKUP DATABASE ... WITH ENCRYPTION) and store the certificate/key separately
      from the backup files - see tde-and-encryption-status.sql for certificate expiry audits.
    - If a backup is encrypted, the certificate/asymmetric key must already exist on the destination
      instance before restoring, and the restoring login needs VIEW DEFINITION on that encryptor.

=====================================================================================================*/

/*-----------------------------------------------------------------------------------------------------
 OPTIONAL DIAGNOSTIC TRACE FLAGS (backup/restore verbose logging)
 WARNING: -1 makes these GLOBAL (instance-wide) and they write heavily to the ERRORLOG.
          TF 2551 + DUMPTRIGGER cause SQL Server to generate MEMORY DUMPS, which stall the
          instance while the dump is written. Enable only during a supported troubleshooting
          exercise, and disable them again as soon as the repro is captured.
 Uncomment to enable:

DBCC TRACEON(3004,-1);  -- Progress messages after key steps in restore
DBCC TRACEON(3014,-1);  -- Progress messages after each major MTF data stream
DBCC TRACEON(3110,-1);  -- Print log headers
DBCC TRACEON(3214,-1);  -- Display SQL text
DBCC TRACEON(3605,-1);  -- Send trace output to the ERRORLOG

-- Enable DUMPTRIGGER for errors 3287 / 3013 (filtered dump)
DBCC TRACEON(2551,-1);
DBCC DUMPTRIGGER('set', 3287);
DBCC DUMPTRIGGER('set', 3013);

-- Verify what is currently enabled
DBCC TRACESTATUS(-1);

-- Disable everything again after use (DUMPTRIGGER must be cleared separately -
-- TRACEOFF alone does NOT remove the registered dump triggers)
DBCC DUMPTRIGGER('clear', 3287);
DBCC DUMPTRIGGER('clear', 3013);
DBCC TRACEOFF(3004,3014,3110,3214,3605,2551,-1);

-----------------------------------------------------------------------------------------------------*/

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
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) a   -- OUTER APPLY: sql_handle can be NULL
WHERE r.command IN ('BACKUP DATABASE', 'RESTORE DATABASE', 'BACKUP LOG', 'RESTORE LOG',
                    'DBCC TABLE CHECK', 'RESTORE HEADERONLY', 'RESTORE VERIFYONLY')
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
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) a 
WHERE r.command IN ('BACKUP DATABASE', 'BACKUP LOG')
ORDER BY start_time;
GO


/*****************************************************************************************************
 * SECTION 2: RESTORE PROGRESS MONITORING
 * Purpose: Monitor running restore operations and estimate completion time
 *****************************************************************************************************/

-- Query 2.1: Monitor Ongoing Restore Progress (Basic)
-- Quick view of restore operations with database state
-- CAVEAT: sys.dm_exec_requests.database_id reflects the SESSION context (usually master) during a
--         restore, not the target database, so the database name is matched heuristically against
--         the batch text. A database whose name is a substring of another name (e.g. 'Sales' vs
--         'SalesArchive') can produce extra rows - cross-check against d.state_desc = 'RESTORING'.
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

-- NOTE: the UPDATE target must be the ALIAS (p), not @ProgressTable, otherwise SQL Server raises
--       "The objects ... in the FROM clause have the same exposed names."
UPDATE p
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
    bckS.database_name,
    bckMF.device_type,
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
    CAST(bckS.backup_size / 1073741824.0
         AS DECIMAL(10, 2))                   AS backup_size_gb,
    CONVERT(DECIMAL(19,2),
        (bckS.compressed_backup_size * 1.0) / POWER(2,20)) AS compressed_backup_size_mb,
    CAST(bckS.compressed_backup_size / 1073741824.0
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
-- NOTE: striped backups have one backupmediafamily row per stripe, so a striped backup set
--       legitimately returns multiple rows here (one per physical_device_name).
-- WHERE bckS.database_name = 'YourDBName'  -- Uncomment to filter by database
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
  AND bs.backup_finish_date >= DATEADD(HOUR, -24, GETDATE())
WHERE db.name NOT IN ('msdb', 'model', 'master', 'distribution', 'tempdb') 
  AND db.source_database_id IS NULL   -- exclude database snapshots
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
 * Purpose: Inspect and verify backup media, and check backup chain completeness
 * Safety:  Every command in Query 6.1 is READ-ONLY - none of them restore data
 *****************************************************************************************************/

-- Query 6.1: Backup Media Inspection & Verification (Templates)
-- All four commands read the backup file only; none of them modify or restore a database.
--   VERIFYONLY   - validates readability, header, checksums, and backup set structure
--   HEADERONLY   - backup set metadata: type, date, server, database version, encryption
--   FILELISTONLY - logical/physical file names, types and sizes
--                  (file types: 'D' = Data, 'L' = Log, 'S' = Filestream)
--   LABELONLY    - media set / media family information
/* TEMPLATE
-- Single backup file
RESTORE VERIFYONLY   FROM DISK = N'C:\Backups\YourDB_Full.bak' WITH CHECKSUM;
RESTORE HEADERONLY   FROM DISK = N'C:\Backups\YourDB_Full.bak';
RESTORE FILELISTONLY FROM DISK = N'C:\Backups\YourDB_Full.bak';
RESTORE LABELONLY    FROM DISK = N'C:\Backups\YourDB_Full.bak';

-- Striped backup - list every stripe in the same statement
RESTORE VERIFYONLY
    FROM DISK = N'C:\Backups\YourDB_Stripe1.bak',
         DISK = N'C:\Backups\YourDB_Stripe2.bak'
    WITH CHECKSUM;

-- Specific backup set within a media set holding multiple backups
RESTORE VERIFYONLY FROM DISK = N'C:\Backups\YourDB_All.bak' WITH FILE = 3, CHECKSUM;
*/


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
-- NOTE: bs.compression_algorithm requires SQL Server 2022 (16.x) / Azure SQL MI.
--       Remove that column on SQL Server 2019 and earlier.
SELECT 
    d.[name]                             AS database_name, 
    d.recovery_model_desc                AS recovery_model, 
    d.log_reuse_wait_desc                AS log_reuse_wait_desc,
    CONVERT(DECIMAL(18,2), ds.cntr_value / 1024.0) AS total_data_file_size_mb,
    CONVERT(DECIMAL(18,2), ls.cntr_value / 1024.0) AS total_log_file_size_mb,
    CONVERT(DECIMAL(18,2), (lu.cntr_value * 100.0) / NULLIF(ls.cntr_value, 0))
                                         AS log_used_percent,
    MAX(CASE WHEN bs.[type] = 'D' THEN bs.backup_finish_date END) 
                                         AS last_full_backup,
    MAX(CASE WHEN bs.[type] = 'D' THEN CONVERT(BIGINT, bs.compressed_backup_size / 1048576) END) 
                                         AS last_full_compressed_size_mb,
    MAX(CASE WHEN bs.[type] = 'D' 
             THEN CONVERT(DECIMAL(18,2), bs.backup_size / NULLIF(bs.compressed_backup_size, 0)) END) 
                                         AS backup_compression_ratio,
    MAX(CASE WHEN bs.[type] = 'D' THEN bs.compression_algorithm END) 
                                         AS last_full_backup_compression_algorithm,
    MAX(CASE WHEN bs.[type] = 'I' THEN bs.backup_finish_date END) 
                                         AS last_differential_backup,
    MAX(CASE WHEN bs.[type] = 'L' THEN bs.backup_finish_date END) 
                                         AS last_log_backup,
    MAX(CASE WHEN bs.[type] = 'L' THEN bs.last_valid_restore_time END) 
                                         AS last_valid_restore_time,
    DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') 
                                         AS last_good_checkdb
FROM sys.databases AS d
LEFT OUTER JOIN msdb.dbo.backupset AS bs 
    ON bs.[database_name] = d.[name]
   AND bs.backup_finish_date > DATEADD(DAY, -30, GETDATE())
LEFT OUTER JOIN sys.dm_os_performance_counters AS lu 
    ON lu.instance_name = d.[name]
   AND lu.counter_name LIKE N'Log File(s) Used Size (KB)%'
   AND lu.[object_name] LIKE N'%Databases%'
LEFT OUTER JOIN sys.dm_os_performance_counters AS ls 
    ON ls.instance_name = d.[name]
   AND ls.counter_name LIKE N'Log File(s) Size (KB)%'
   AND ls.[object_name] LIKE N'%Databases%'
LEFT OUTER JOIN sys.dm_os_performance_counters AS ds 
    ON ds.instance_name = d.[name]
   AND ds.counter_name LIKE N'Data File(s) Size (KB)%'
   AND ds.[object_name] LIKE N'%Databases%'
WHERE d.[name] <> N'tempdb'
  AND d.source_database_id IS NULL      -- exclude database snapshots
GROUP BY 
    d.[name], 
    d.recovery_model_desc, 
    d.log_reuse_wait_desc, 
    ds.cntr_value,
    ls.cntr_value,
    lu.cntr_value
ORDER BY database_name;
GO




/*****************************************************************************************************
 * SECTION 9: RESTORE UTILITIES & BACKUP HISTORY MAINTENANCE
 * Purpose: Restore helpers that fall outside the standard scenario templates - marked
 *          transactions, STANDBY mode, forcing recovery, and msdb history cleanup.
 * See also: Section 6.1 for backup media inspection (HEADERONLY / FILELISTONLY / VERIFYONLY)
 *           Section 11  for the full set of restore scenario templates
 *****************************************************************************************************/

-- Query 9.1: Marked Transactions (Recovery Points)
-- Lists transaction marks available as restore targets.
-- Marks are created by the application: BEGIN TRAN UpdPrc WITH MARK 'Nightly update start';
-- To restore to (or just before) a mark, see Query 11.3.
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


-- Query 9.2: Force Database Recovery
-- If the last restore was inadvertently performed WITH NORECOVERY,
-- this command forces the database to complete recovery and come online
-- RESTORE LOG [DatabaseName] WITH RECOVERY;
GO


-- Query 9.3: Restore with STANDBY Mode (Complete Sequence)
-- STANDBY allows read-only access between log restores - useful for reporting on
-- near-current data during log shipping. See C5 for how STANDBY differs from NORECOVERY.
/* TEMPLATE
ALTER DATABASE [MarketYields] 
SET SINGLE_USER WITH ROLLBACK IMMEDIATE;

-- Full backup, with file relocation
RESTORE DATABASE [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 2,  
    MOVE N'MarketYields' TO N'D:\MKTG\MarketYields.mdf',  
    MOVE N'MarketYields_log' TO N'L:\MKTG\MarketYields_log.ldf',  
    NORECOVERY, NOUNLOAD, STATS = 5;

-- Differential backup
RESTORE DATABASE [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 5, NORECOVERY, NOUNLOAD, STATS = 5;

-- Transaction log (repeat for additional logs)
RESTORE LOG [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 6, NORECOVERY, NOUNLOAD, STATS = 5;

-- Final log with STANDBY - database becomes readable, further log restores still allowed
RESTORE LOG [MarketYields] 
FROM DISK = N'D:\MSSQLServer\MarketYields.bak' 
WITH FILE = 7,  
    STANDBY = N'L:\Log_Standby.bak',  
    NOUNLOAD, STATS = 5;

ALTER DATABASE [MarketYields] 
SET MULTI_USER;
*/
GO


-- Query 9.4: Delete Backup History
-- Removes old backup history records from msdb to manage database size
-- DESTRUCTIVE: this permanently deletes rows from msdb backup/restore history tables.
/* TEMPLATE
-- Delete all backup history prior to specified date
EXEC msdb.dbo.sp_delete_backuphistory 
    @oldest_date = '20090101';

-- Delete backup history for a specific database
EXEC msdb.dbo.sp_delete_database_backuphistory 
    @database_name = 'Market';
*/
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
 * SECTION 11: RESTORE SCENARIO TEMPLATES
 * Purpose: Copy-and-edit T-SQL patterns for each restore scenario.
 * Theory:  See CONCEPTS REFERENCE at the top of this file (C2 recovery models, C3 backup types,
 *          C4 restore phases, C5 recovery states, C6 RESTORE options, C7 best practices).
 * !! Every block below is a TEMPLATE and is commented out on purpose.
 *    Replace [YourDatabase] and the D:\Backups\... paths before running.
 *****************************************************************************************************/

-- Query 11.1: Pre-Restore Preparation - isolate, capture the tail, inspect the media
-- Media inspection commands (HEADERONLY / FILELISTONLY / LABELONLY) are detailed in Query 6.1
/* TEMPLATE
ALTER DATABASE [YourDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;

BACKUP LOG [YourDatabase]
    TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH NO_TRUNCATE, NORECOVERY;

RESTORE HEADERONLY   FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
RESTORE FILELISTONLY FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
RESTORE LABELONLY    FROM DISK = 'D:\Backups\YourDatabase_Full.bak';
*/


-- Query 11.2: Complete Database Restore - Full -> Differential -> Logs -> Tail-Log
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;

RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Diff.bak'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
*/


-- Query 11.3: Point-in-Time Restore - requires FULL or BULK_LOGGED
-- Restore a full backup taken before the target point, apply logs, then stop at:
--   STOPAT          = a datetime
--   STOPATMARK      = a named transaction mark, INCLUDING the marked transaction
--   STOPBEFOREMARK  = a named transaction mark, EXCLUDING the marked transaction
-- Available marks are listed by Query 9.1.
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY, STOPAT = '2026-07-24T14:30:00';

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY, STOPAT = '2026-07-24T14:30:00';

-- Mark-based variants - substitute for the STOPAT clause above
RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH RECOVERY, STOPATMARK = 'NightlyLoadStart';

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH RECOVERY, STOPBEFOREMARK = 'NightlyLoadStart';
*/


-- Query 11.4: File / Filegroup Restore - requires FULL or BULK_LOGGED
-- Covers restoring a single damaged data file as well as a whole read-write filegroup.
-- Log backups must be applied afterward to roll the file forward to the rest of the database.
/* TEMPLATE
BACKUP LOG [YourDatabase]
    TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH NORECOVERY;

-- Single file (use FILEGROUP = 'FG2' instead to restore an entire filegroup)
RESTORE DATABASE [YourDatabase]
    FILE = 'YourDatabase_FG2_File1'
    FROM DISK = 'D:\Backups\YourDatabase_FileGroup.bak'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
*/


-- Query 11.5: Page Restore - repairs specific corrupt 8KB pages with the database online
-- Enterprise Edition only. Not supported under SIMPLE. System pages (file headers) are excluded.
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    PAGE = '1:57, 1:58, 3:24'
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;

BACKUP LOG [YourDatabase]
    TO DISK = 'D:\Backups\YourDatabase_PostPageRestore.trn';

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_PostPageRestore.trn'
    WITH RECOVERY;
*/


-- Query 11.6: Piecemeal Restore - bring PRIMARY online first, then secondary filegroups
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    FILEGROUP = 'PRIMARY'
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH PARTIAL, NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;

RESTORE DATABASE [YourDatabase]
    FILEGROUP = 'SECONDARY'
    FROM DISK = 'D:\Backups\YourDatabase_FileGroup.bak'
    WITH NORECOVERY;

RESTORE LOG [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
    WITH RECOVERY;
*/


-- Query 11.7: Revert to a Database Snapshot
-- Breaks the log backup chain - take a new full backup afterward. Drop other snapshots first.
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    FROM DATABASE_SNAPSHOT = 'YourDatabase_Snapshot_20260724';
*/


-- Query 11.8: Restore with File Relocation and Overwrite (option reference in C6)
/* TEMPLATE
RESTORE DATABASE [YourDatabase]
    FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
    WITH REPLACE,
         MOVE 'YourDatabase'     TO 'D:\Data\YourDatabase.mdf',
         MOVE 'YourDatabase_log' TO 'L:\Log\YourDatabase_log.ldf',
         RECOVERY,
         STATS = 10;
*/


-- Query 11.9: Post-Restore Checklist
--   1. Integrity check the recovered database (template below)
--   2. Remap orphaned logins/users if moved to a new server - see logins-and-security.sql
--   3. Periodically test the whole sequence end-to-end to prove RTO/RPO - see Section 5
/* TEMPLATE
DBCC CHECKDB ('YourDatabase') WITH NO_INFOMSGS;
*/
GO


/*****************************************************************************************************
 * SECTION 12: MANAGED BACKUP TO AZURE - DIAGNOSTICS & TROUBLESHOOTING
 * Purpose: Diagnose SQL Server Managed Backup to Microsoft Azure (a.k.a. "automated backups")
 *          when scheduled backups stop running, fail, or fall behind their retention policy.
 * Scope:   SQL Server 2014+ (on-premises / IaaS). The metadata lives in msdb.
 *          Schema note: SQL Server 2014 uses msdb.smart_admin; 2016+ uses msdb.managed_backup.
 *          NOT applicable to Azure SQL Managed Instance or Azure SQL Database, whose automated
 *          backups are platform-managed (see sqlmi-specific-queries.sql).
 * Order:   Run 12.4 - 12.9 first (all read-only). Only enable the verbose logging in
 *          12.1 - 12.3 if the read-only checks are inconclusive, and revert with 12.11.
 *****************************************************************************************************/

/*
-----------------------------------------------------------------------------------------
12.0  TRACE FLAG REFERENCE (used by 12.1)
-----------------------------------------------------------------------------------------
    3004 : Adds information about file preparation, bitmaps, and instant file initialization
           (IFI avoids zeroing out files; relevant to restores, and only for data files).
    3014 : Undocumented. Detailed information about file creation, padding, and related
           activity while a backup is running.
    3051 : Enables verbose logging of SQL Server Managed Backup to Azure to a dedicated
           error log file. This is the key flag for Managed Backup troubleshooting.
    3212 : Prints "Backup stats" to the SQL Server error log.
    3605 : Sends a variety of diagnostic output to the SQL Server error log instead of to
           the user console.
-----------------------------------------------------------------------------------------
*/


-- Query 12.1: Enable Verbose Trace Flags (STATE CHANGE)
-- WARNING: -1 makes these global. They write heavily to the ERRORLOG - enable only for the
--          duration of a repro, then disable with Query 12.11.
/* TEMPLATE
DBCC TRACEON(3014, 3212, 3004, 3605, 3051, -1);
DBCC TRACESTATUS(-1);   -- confirm what is enabled
*/


-- Query 12.2: Enable Managed Backup Debug Extended Events (STATE CHANGE)
-- Turns on the extra SmartAdmin XEvent streams collected in Query 12.10
/* TEMPLATE
EXEC msdb.managed_backup.sp_set_parameter
    @parameter_name  = 'SSMBackup2WADebugXevent',
    @parameter_value = 'true';
*/


-- Query 12.3: Enable SQL Agent Verbose Logging (STATE CHANGE)
-- Level 7 = errors + warnings + information. Very noisy - revert to the default (3)
-- once the repro is captured (see Query 12.11).
/* TEMPLATE
EXEC msdb.dbo.sp_set_sqlagent_properties
    @errorlogging_level = 7;
*/


-- Query 12.4: Managed Backup Health Status
-- Primary starting point: returns the errors Managed Backup has raised over a time window.
-- Pass NULL, NULL for all history, or a start/end datetime to narrow the window.
SELECT *
FROM msdb.managed_backup.fn_get_health_status(NULL, NULL);
GO


-- Query 12.5: Managed Backup Diagnostics
-- Reads and parses the SmartAdmin XEvent files. Can be slow or memory-heavy if those
-- files are large - check their size before running on a busy instance.
EXEC msdb.managed_backup.sp_get_backup_diagnostics;
GO
-- SQL Server 2014 equivalent:
-- EXEC msdb.smart_admin.sp_get_backup_diagnostics;


-- Query 12.6: Managed Backup Configuration & Enrolled Databases
-- autoadmin_managed_databases : which databases are enrolled, retention, storage URL, state
-- autoadmin_system_flags      : instance-level Managed Backup feature flags
-- autoadmin_task_agent_metadata : task agent state (shows if the agent is wedged/disabled)
SELECT *
FROM msdb.dbo.autoadmin_managed_databases;

SELECT *
FROM msdb.dbo.autoadmin_system_flags;

SELECT *
FROM msdb.dbo.autoadmin_task_agent_metadata;
GO


-- Query 12.7: SQL Agent Job History for Managed Backup Jobs
-- Managed Backup drives its work through SQL Agent, so agent failures surface here first.
-- run_date/run_time are integers (yyyymmdd / hhmmss); run_status: 0=Failed, 1=Succeeded,
-- 2=Retry, 3=Cancelled, 4=In Progress.
SELECT TOP 500
    j.name                AS job_name,
    h.step_id,
    h.step_name,
    h.run_status,
    h.run_date,
    h.run_time,
    h.run_duration,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
-- WHERE h.run_status <> 1   -- Uncomment to show failures/retries only
ORDER BY h.run_date DESC, h.run_time DESC;
GO


-- Query 12.8: Ring Buffer Exceptions
-- Surfaces exceptions thrown inside the engine around the time of the failure.
-- Widen the results grid / use XML output so the record text is not truncated.
SELECT
    rb.timestamp,
    CAST(rb.record AS XML) AS record_xml
FROM sys.dm_os_ring_buffers rb
WHERE rb.ring_buffer_type = 'RING_BUFFER_EXCEPTION'
ORDER BY rb.timestamp DESC;
GO


-- Query 12.9: Loaded Modules
-- Used to resolve/align call stacks when analysing a dump or a filter-driver conflict
-- (antivirus, backup agents, and storage filters commonly interfere with backup I/O).
SELECT
    name,
    company,
    description,
    file_version,
    product_version
FROM sys.dm_os_loaded_modules
ORDER BY company, name;
GO


/*
-----------------------------------------------------------------------------------------
12.10  DATA COLLECTION CHECKLIST (for a support case)
-----------------------------------------------------------------------------------------
Collect the following alongside the output of Queries 12.4 - 12.9:

    - SQL Server ERRORLOG files covering the failure window
    - SQL Server Agent logs (especially with verbose logging from Query 12.3 enabled)
    - Default Managed Backup XEvent files from the instance LOG folder:
          SmartAdminEvents_Backup_*
          SmartAdminEvents__*
    - Application event log
    - System event log
    - A backup of msdb, since all Managed Backup configuration and history lives there:
          BACKUP DATABASE msdb TO DISK = 'C:\Backup\msdb.bak' WITH INIT;
    - Storage account / container details and the credential used by Managed Backup
      (name only - never share the SAS token or account key)

Common root causes worth ruling out first:
    - Expired or rotated SAS token / credential on the storage container
    - SQL Server Agent stopped, or the Managed Backup task agent disabled (Query 12.6)
    - Network or proxy blocking outbound HTTPS to the storage endpoint
    - Retention policy misconfiguration leaving no valid base full backup
    - msdb corruption or a full msdb transaction log stalling history writes
-----------------------------------------------------------------------------------------
*/


-- Query 12.11: Revert All Diagnostic Settings (run after the repro is captured)
/* TEMPLATE
DBCC TRACEOFF(3014, 3212, 3004, 3605, 3051, -1);

EXEC msdb.managed_backup.sp_set_parameter
    @parameter_name  = 'SSMBackup2WADebugXevent',
    @parameter_value = 'false';

EXEC msdb.dbo.sp_set_sqlagent_properties
    @errorlogging_level = 3;   -- default: errors + warnings
*/
GO


/*****************************************************************************************************
 * END OF FILE
 *****************************************************************************************************/