/*****************************************************************************************************
 * SQL SERVER DATABASE INTEGRITY CHECKS (DBCC)
 *
 * This file contains queries organized by functionality:
 *   1. CORE INTEGRITY CHECK COMMANDS
 *   2. INTEGRITY MONITORING AND AUDIT QUERIES
 *   3. REPAIR PROCEDURES (USE WITH EXTREME CAUTION)
 *   4. AUTOMATION AND SCHEDULING
 *   5. TRANSACTION LOG HEALTH - VLF COUNTS
 *   6. TRACE FLAGS & PAGE-LEVEL ANALYSIS
 *
 * Background theory (what CHECKDB actually validates, option semantics, snapshot behaviour,
 * corruption response order) is in the CONCEPTS REFERENCE block below.
 *
 * Related: other scripts/00-triage.sql             run this first during an incident
 *          advanced-administration-and-recovery.sql error log search, emergency recovery
 *          backups-and-restores.sql                 restore paths, backup validation
 *****************************************************************************************************/
/*****************************************************************************************************
 * !! READ BEFORE RUNNING !!
 * Do NOT execute this file end-to-end.
 *   - Sections 2 and 5 are read-only diagnostic queries and are safe to run.
 *   - Section 1 contains DBCC commands that are read-only but CPU/IO/tempdb-intensive; they are
 *     deliberately commented out. Uncomment the one you want, against the database you want.
 *   - Sections 3 and 4 are TEMPLATES (repair, ALTER DATABASE, Agent job creation) and are
 *     deliberately commented out. Copy the block you need, replace placeholders, run deliberately.
 *****************************************************************************************************/

/*=====================================================================================================
  CONCEPTS REFERENCE
=======================================================================================================

C1. WHAT DBCC CHECKDB ACTUALLY DOES
---------------------------------------------------------------------------------------------------
CHECKDB is a superset. A single CHECKDB run performs, in order:

    DBCC CHECKALLOC     Allocation structures (GAM/SGAM/PFS/IAM page linkage and extent usage).
    DBCC CHECKTABLE     Every table and indexed view in the database (page/row/index consistency,
                        index-to-base-table cross checks, off-row LOB linkage).
    DBCC CHECKCATALOG   System metadata cross-consistency.
    Plus               Service Broker validation, indexed view contents, and (by default since
                        the database was created on SQL 2005+) DATA_PURITY column value checks.

Therefore running CHECKALLOC or CHECKCATALOG *in addition to* CHECKDB is redundant. They exist for
targeted, faster investigation - not as extra steps in a maintenance plan.


C2. OPTION SEMANTICS
---------------------------------------------------------------------------------------------------
    NO_INFOMSGS             Suppress the per-index row/page counts. Always use in automated jobs -
                            without it a large DB emits thousands of lines of noise.
    ALL_ERRORMSGS           Return all errors per object rather than the first 200. Default
                            behaviour on SSMS, but be explicit.
    PHYSICAL_ONLY           Page-level physical checks + allocation only. Skips the expensive
                            logical/cross-reference checks. Typically several times faster and
                            catches the overwhelming majority of real-world corruption (which is
                            storage-induced). Common pattern: PHYSICAL_ONLY nightly, full weekly.
    DATA_PURITY             Validate column values against their datatype domain. Implicit for
                            databases created on 2005+; must be requested explicitly for databases
                            upgraded from SQL 2000. Once it passes cleanly, it becomes implicit.
    EXTENDED_LOGICAL_CHECKS Additionally validates indexed views, XML indexes and spatial indexes.
                            Significantly slower. Not for routine scheduling.
    MAXDOP = n              Overrides the instance/Resource Governor DOP for this check only
                            (SQL 2014 SP2+). Useful to cap CHECKDB's CPU footprint.
    TABLOCK                 Skips the database snapshot and takes locks instead. Faster and avoids
                            snapshot sparse-file growth, but blocks users. Do not use online.


C3. THE HIDDEN DATABASE SNAPSHOT
---------------------------------------------------------------------------------------------------
Without TABLOCK, CHECKDB creates an internal database snapshot so it can read a transactionally
consistent point in time without blocking. That snapshot's sparse files are created on the SAME
VOLUME as the data files and grow with the write volume that occurs during the check. Two practical
consequences:
    - A CHECKDB on a busy database can consume significant extra disk on the data volume.
    - Snapshots are not supported on tempdb, on read-only databases, or on FAT32/ReFS-less setups;
      in those cases CHECKDB silently falls back to TABLOCK behaviour.


C4. OFFLOADING
---------------------------------------------------------------------------------------------------
Running CHECKDB against a restored copy on another server proves the backup AND the data, and moves
the IO cost off production. Caveat: this validates the *restored copy*. It does not prove the
production files are clean - a page can corrupt on production storage after the backup was taken.
It does not update LastGoodCheckDbTime on production. Treat it as a strong control, not equivalence.


C5. RESPONSE ORDER WHEN CORRUPTION IS FOUND
---------------------------------------------------------------------------------------------------
    1. Do not restart the instance and do not detach the database. Both can turn a recoverable
       situation into an unrecoverable one.
    2. Capture the full CHECKDB output and the error log (823/824/825 entries).
    3. Restore from backup - page restore if the damage is confined to specific pages and the
       database is in FULL recovery with an unbroken log chain.
    4. Only if no viable backup exists, consider REPAIR_ALLOW_DATA_LOSS (Section 3). It is a
       last resort: it makes the database structurally consistent by deleting what it cannot fix.
    5. Find the root cause. Corruption is almost always storage/firmware/driver, and it recurs.

=====================================================================================================*/


-----------------------------------------------------------------------
-- SECTION 1: CORE INTEGRITY CHECK COMMANDS
-- NOTE: all commands below are commented out on purpose. They run
--       against the CURRENT database context and are IO-intensive.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 DBCC CHECKDB — full consistency check (current database)
--     Gold standard for detecting corruption. See C1/C2 above.
-----------------------------------------------------------------------
-- Full check of the current database:
-- DBCC CHECKDB WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Reduced-impact variant for large/production databases — skips logical
-- checks but catches most storage-level corruption much faster:
-- DBCC CHECKDB WITH PHYSICAL_ONLY, NO_INFOMSGS;

-- Cap the CPU footprint (SQL 2014 SP2+):
-- DBCC CHECKDB WITH PHYSICAL_ONLY, NO_INFOMSGS, MAXDOP = 4;

-- Databases upgraded from SQL 2000 need DATA_PURITY requested explicitly
-- until it has passed cleanly once:
-- DBCC CHECKDB WITH DATA_PURITY, NO_INFOMSGS, ALL_ERRORMSGS;

-- Deepest (and slowest) check — indexed views, XML and spatial indexes.
-- Ad-hoc investigation only, not for a maintenance schedule:
-- DBCC CHECKDB WITH EXTENDED_LOGICAL_CHECKS, NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- 1.2 GENERATE CHECKDB FOR ALL DATABASES
--     Generates one statement per database — copy the output and run
--     sequentially. Running them concurrently will saturate IO.
--
--     tempdb is excluded: it is recreated at every startup, CHECKDB
--     cannot snapshot it, and corruption there is transient by nature.
--     master and msdb ARE included — losing msdb loses your job,
--     backup and Agent history, so it needs checking like any other DB.
-----------------------------------------------------------------------
SELECT
    'DBCC CHECKDB (' + QUOTENAME(d.[name]) + ') WITH NO_INFOMSGS, ALL_ERRORMSGS;' AS CheckCommand,
    'DBCC CHECKDB (' + QUOTENAME(d.[name]) + ') WITH PHYSICAL_ONLY, NO_INFOMSGS;' AS FastCheckCommand,
    d.[name]              AS DatabaseName,
    d.database_id         AS DatabaseID,
    d.state_desc          AS [State],
    d.recovery_model_desc AS RecoveryModel,
    d.is_read_only        AS IsReadOnly,
    CAST(SUM(mf.size) * 8.0 / 1024 AS DECIMAL(18, 2)) AS SizeMB
FROM sys.databases AS d
INNER JOIN sys.master_files AS mf
        ON mf.database_id = d.database_id
WHERE d.database_id <> 2              -- exclude tempdb
  AND d.state_desc = 'ONLINE'
  AND d.source_database_id IS NULL    -- exclude database snapshots
GROUP BY d.[name], d.database_id, d.state_desc, d.recovery_model_desc, d.is_read_only
ORDER BY SizeMB ASC;                  -- smallest first: fail fast, finish the easy ones

-----------------------------------------------------------------------
-- 1.3 DBCC CHECKTABLE — check a single table
--     Useful when you suspect corruption in a specific table.
-----------------------------------------------------------------------
-- DBCC CHECKTABLE ('dbo.YourTableName') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- 1.4 DBCC CHECKALLOC — allocation consistency only
--     Faster than CHECKDB; verifies page and extent structures.
--     REDUNDANT if you already run CHECKDB (see C1). Use only for
--     targeted investigation of allocation (2500-series) errors.
-----------------------------------------------------------------------
-- DBCC CHECKALLOC WITH NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- 1.5 DBCC CHECKCATALOG — system catalog consistency
--     Also REDUNDANT if you run CHECKDB. Useful standalone when you
--     suspect metadata damage but cannot afford a full CHECKDB.
-----------------------------------------------------------------------
-- DBCC CHECKCATALOG WITH NO_INFOMSGS;

-----------------------------------------------------------------------
-- 1.6 DBCC CHECKFILEGROUP — check one filegroup
--     Lets you split a very large database across several maintenance
--     windows, one filegroup per night.
-----------------------------------------------------------------------
-- DBCC CHECKFILEGROUP ('PRIMARY') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- SECTION 2: INTEGRITY MONITORING AND AUDIT QUERIES
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 LAST KNOWN GOOD CHECKDB DATE
--     SQL Server stores the last successful CHECKDB date on the boot
--     page (dbi_dbccLastKnownGood). Critical for monitoring — alert if
--     the value is older than your CHECKDB frequency, or missing.
--
--     Caveats:
--       - '1900-01-01' means never checked on this instance. The value
--         does NOT survive a restore to another server, and is not set
--         by CHECKDB run against a restored copy elsewhere.
--       - Only updated when CHECKDB completes with NO errors.
--       - PHYSICAL_ONLY runs DO update it, despite being a lesser check.
-----------------------------------------------------------------------
SELECT
    d.[name]              AS DatabaseName,
    d.state_desc          AS [State],
    d.recovery_model_desc AS RecoveryModel,
    lg.LastGoodCheckDb,
    CASE WHEN lg.LastGoodCheckDb > '1900-01-01'
         THEN DATEDIFF(DAY, lg.LastGoodCheckDb, GETDATE())
    END                   AS DaysSinceLastCheck,
    CASE
        WHEN lg.LastGoodCheckDb IS NULL                                 THEN 'UNKNOWN (not readable)'
        WHEN lg.LastGoodCheckDb <= '1900-01-01'                         THEN '*** NEVER CHECKED ***'
        WHEN DATEDIFF(DAY, lg.LastGoodCheckDb, GETDATE()) > 7           THEN '*** OVERDUE ***'
        WHEN DATEDIFF(DAY, lg.LastGoodCheckDb, GETDATE()) > 3           THEN 'WARN'
        ELSE 'OK'
    END                   AS [Status]
FROM sys.databases AS d
CROSS APPLY (
    SELECT CAST(DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') AS DATETIME) AS LastGoodCheckDb
) AS lg
WHERE d.state_desc = 'ONLINE'
  AND d.database_id <> 2            -- tempdb is never checked
  AND d.source_database_id IS NULL  -- exclude database snapshots
ORDER BY
    CASE WHEN lg.LastGoodCheckDb IS NULL THEN 0
         WHEN lg.LastGoodCheckDb <= '1900-01-01' THEN 1
         ELSE 2 END,
    lg.LastGoodCheckDb ASC;

-----------------------------------------------------------------------
-- 2.2 SUSPECT PAGES
--     msdb.dbo.suspect_pages records pages where an 823/824/825 error
--     was detected. Ideally this returns NOTHING.
--
--     The table is capped at 1000 rows and is NOT self-maintaining —
--     once full, new corruption events are silently NOT recorded. Purge
--     resolved rows as part of routine maintenance (see 2.3).
--     Reference: https://learn.microsoft.com/sql/relational-databases/backup-restore/manage-the-suspect-pages-table-sql-server
-----------------------------------------------------------------------
SELECT
    DB_NAME(sp.database_id) AS DatabaseName,
    sp.[file_id],
    mf.[name]               AS LogicalFileName,
    mf.physical_name        AS FilePath,
    sp.page_id,
    sp.event_type,
    CASE sp.event_type
        WHEN 1 THEN '823 (OS CRC error) or 824 other than bad checksum / torn page'
        WHEN 2 THEN 'Bad checksum'
        WHEN 3 THEN 'Torn page'
        WHEN 4 THEN 'Restored (page restored after being marked bad)'
        WHEN 5 THEN 'Repaired (DBCC repaired the page)'
        WHEN 7 THEN 'Deallocated by DBCC'
        ELSE        'Unknown event_type'
    END                     AS EventDescription,
    CASE WHEN sp.event_type IN (1, 2, 3)
         THEN '*** ACTIVE CORRUPTION — INVESTIGATE ***'
         ELSE 'Resolved — safe to purge'
    END                     AS Assessment,
    sp.error_count,
    sp.last_update_date
FROM msdb.dbo.suspect_pages AS sp
LEFT JOIN sys.master_files AS mf
       ON mf.database_id = sp.database_id
      AND mf.[file_id]   = sp.[file_id]
ORDER BY sp.last_update_date DESC;

-- Row count vs the 1000-row cap. At 1000, logging of new events stops.
SELECT
    COUNT(*)                                            AS SuspectPageRows,
    1000 - COUNT(*)                                     AS RemainingCapacity,
    SUM(CASE WHEN event_type IN (1, 2, 3) THEN 1 ELSE 0 END) AS UnresolvedRows
FROM msdb.dbo.suspect_pages;

-----------------------------------------------------------------------
-- 2.3 PURGE RESOLVED SUSPECT PAGE ROWS (template)
--     Only ever delete rows you have confirmed as restored/repaired.
-----------------------------------------------------------------------
-- DELETE FROM msdb.dbo.suspect_pages
-- WHERE event_type IN (4, 5, 7);   -- restored / repaired / deallocated


-----------------------------------------------------------------------
-- 2.4 PAGE VERIFICATION SETTING AUDIT
--     All databases should use CHECKSUM for page verification.
--     NONE or TORN_PAGE_DETECTION are legacy settings — with them,
--     storage corruption goes undetected until CHECKDB or a read.
--     Note: CHECKSUM only protects pages WRITTEN after the change;
--     existing pages are only covered once they are next modified.
-----------------------------------------------------------------------
SELECT
    [name]                  AS DatabaseName,
    page_verify_option_desc AS PageVerifyOption,
    CASE
        WHEN page_verify_option_desc <> 'CHECKSUM'
            THEN '*** CHANGE TO CHECKSUM ***'
        ELSE 'OK'
    END                     AS Recommendation
FROM sys.databases
WHERE state_desc = 'ONLINE'
  AND source_database_id IS NULL
ORDER BY page_verify_option_desc, [name];

-- Generate fix statements for non-CHECKSUM databases:
SELECT
    'ALTER DATABASE ' + QUOTENAME([name])
    + ' SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;' AS FixCommand
FROM sys.databases
WHERE page_verify_option_desc <> 'CHECKSUM'
  AND state_desc = 'ONLINE'
  AND database_id <> 2
  AND source_database_id IS NULL;

-----------------------------------------------------------------------
-- 2.5 IO ERROR HISTORY IN THE ERROR LOG (823 / 824 / 825)
--     825 ("read-retry succeeded") is the early warning nobody watches:
--     it means storage failed the read and only succeeded on retry.
--     Only covers logs still on disk (see sp_cycle_errorlog retention).
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'823';
EXEC sys.xp_readerrorlog 0, 1, N'824';
EXEC sys.xp_readerrorlog 0, 1, N'825';
EXEC sys.xp_readerrorlog 0, 1, N'CHECKDB found';


-----------------------------------------------------------------------
-- SECTION 3: REPAIR PROCEDURES (USE WITH EXTREME CAUTION)
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 DBCC CHECKDB WITH REPAIR OPTIONS (reference only)
--     *** DANGER *** — REPAIR_ALLOW_DATA_LOSS makes the database
--     structurally consistent by DELETING what it cannot fix. It does
--     not recover data, it discards it, and it does not respect foreign
--     keys — you can be left consistent but logically wrong.
--
--     Restore from backup FIRST if any viable backup exists (3.2/3.3).
--     Database must be in SINGLE_USER mode.
-----------------------------------------------------------------------
-- -- Step 0: Take a tail-log backup / copy the files before touching anything.
-- --         Repair is not reversible.
--
-- -- Step 1: Set single-user
-- ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
--
-- -- Step 2: Try repair (lossless first)
-- DBCC CHECKDB ('YourDB', REPAIR_REBUILD) WITH NO_INFOMSGS, ALL_ERRORMSGS;
--
-- -- Step 3: If REPAIR_REBUILD fails, only then consider the destructive option.
-- --         Wrap it in a transaction so you can roll back after inspecting the output.
-- -- BEGIN TRANSACTION;
-- -- DBCC CHECKDB ('YourDB', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS, ALL_ERRORMSGS;
-- -- ROLLBACK TRANSACTION;   -- or COMMIT once you accept the reported losses
--
-- -- Step 4: Re-run a clean CHECKDB to confirm, then return to multi-user
-- DBCC CHECKDB ('YourDB') WITH NO_INFOMSGS, ALL_ERRORMSGS;
-- ALTER DATABASE [YourDB] SET MULTI_USER;

-----------------------------------------------------------------------
-- 3.2 PAGE-LEVEL RESTORE (preferred over repair)
--     Requires FULL recovery model and an unbroken log chain. Fixes the
--     damaged pages only, with zero data loss, and can run ONLINE on
--     Enterprise edition. Page IDs come from the CHECKDB output or
--     msdb.dbo.suspect_pages (2.2).
-----------------------------------------------------------------------
-- RESTORE DATABASE [YourDB] PAGE = '1:1472, 1:1473'
--     FROM DISK = N'D:\Backups\YourDB_FULL.bak' WITH NORECOVERY;
-- RESTORE LOG [YourDB] FROM DISK = N'D:\Backups\YourDB_LOG_1.trn' WITH NORECOVERY;
-- -- ... all subsequent log backups ...
-- BACKUP LOG [YourDB] TO DISK = N'D:\Backups\YourDB_TAIL.trn' WITH NORECOVERY;
-- RESTORE LOG [YourDB] FROM DISK = N'D:\Backups\YourDB_TAIL.trn' WITH RECOVERY;

-----------------------------------------------------------------------
-- 3.3 VERIFY YOUR BACKUPS ARE USABLE BEFORE DECIDING
--     RESTORE VERIFYONLY validates the backup is readable and its
--     checksums are intact. It does NOT validate the data pages inside
--     unless the backup was taken WITH CHECKSUM.
-----------------------------------------------------------------------
-- RESTORE VERIFYONLY FROM DISK = N'D:\Backups\YourDB_FULL.bak' WITH CHECKSUM;

-----------------------------------------------------------------------
-- 3.4 EMERGENCY MODE — recovering a SUSPECT / RECOVERY_PENDING database
--     *** LAST RESORT — CAN CAUSE DATA LOSS ***
--
--     EMERGENCY mode marks the database READ_ONLY, disables logging and
--     restricts access to sysadmin. Its purpose is to let you read data
--     out of a database that will not recover — export what you can
--     BEFORE attempting repair, because repair may delete it.
--
--     Running CHECKDB with REPAIR_ALLOW_DATA_LOSS while in EMERGENCY mode
--     triggers "emergency mode repair": SQL Server rebuilds the
--     transaction log if it is unusable. This is irreversible and
--     abandons any transactional consistency the log would have provided.
--     Copy the .mdf/.ldf files first.
-----------------------------------------------------------------------
-- ALTER DATABASE [YourDB] SET EMERGENCY;
-- ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
--
-- -- Export anything you can reach before repairing.
--
-- DBCC CHECKDB ('YourDB', REPAIR_ALLOW_DATA_LOSS) WITH ALL_ERRORMSGS;
--
-- ALTER DATABASE [YourDB] SET MULTI_USER;
-- ALTER DATABASE [YourDB] SET ONLINE;

-----------------------------------------------------------------------
-- 3.5 REPAIR A FILESTREAM DATABASE IN RECOVERY_PENDING
--     Last-resort procedure for a FileStream-enabled database that enters
--     RECOVERY_PENDING after Windows patching. The usual cause is that
--     the FILESTREAM access level was reset by the patch, so the engine
--     cannot open the FILESTREAM container during recovery — check
--     'filestream access level' BEFORE assuming corruption.
--     *** CAN CAUSE DATA LOSS ***
--     Source: https://github.com/DavidSchanzer/Sql-Server-DBA-Toolbox
-----------------------------------------------------------------------
-- Check the current setting first (read-only) — if this is 0 or 1 and the
-- database uses FILESTREAM, restoring the setting may be the entire fix.
SELECT
    c.name,
    c.value        AS ConfiguredValue,
    c.value_in_use AS RunningValue
FROM sys.configurations AS c
WHERE c.name = 'filestream access level';

/*
-- Replace every <DBName> placeholder with the affected database name.

USE [master];
GO

EXEC sys.sp_configure @configname = 'filestream access level', @configvalue = 2;
RECONFIGURE WITH OVERRIDE;
GO

ALTER DATABASE <DBName> SET EMERGENCY;
GO

ALTER DATABASE <DBName> SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

DBCC CHECKDB (<DBName>, REPAIR_ALLOW_DATA_LOSS) WITH ALL_ERRORMSGS;
GO

ALTER DATABASE <DBName> SET MULTI_USER;
GO
*/

-----------------------------------------------------------------------
-- SECTION 4: AUTOMATION AND SCHEDULING
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 SQL AGENT JOB TEMPLATE — Automated Weekly CHECKDB
--     Uses an explicit cursor, NOT sp_MSforeachdb. sp_MSforeachdb is
--     undocumented, unsupported, and is known to silently SKIP
--     databases — unacceptable for the one job whose whole purpose is
--     to check every database.
--
--     Consider Ola Hallengren's IntegrityCheck solution instead; it
--     handles AG secondaries, time limits, and logging out of the box.
--     https://ola.hallengren.com
-----------------------------------------------------------------------
/*
USE msdb;
GO

EXEC dbo.sp_add_job
    @job_name         = N'DBA - Weekly CHECKDB All Databases',
    @description      = N'Runs DBCC CHECKDB on all online databases except tempdb.',
    @category_name    = N'Database Maintenance',
    @owner_login_name = N'sa';

EXEC dbo.sp_add_jobstep
    @job_name      = N'DBA - Weekly CHECKDB All Databases',
    @step_name     = N'Run CHECKDB',
    @subsystem     = N'TSQL',
    @database_name = N'master',
    @on_fail_action = 2,   -- quit with failure
    @command       = N'
SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME,
        @SQL          NVARCHAR(MAX),
        @StartTime    DATETIME2(0),
        @Elapsed      INT,
        @ErrorMsg     NVARCHAR(2048),
        @Failures     INT = 0;

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.[name]
    FROM sys.databases AS d
    WHERE d.database_id <> 2            -- tempdb
      AND d.state_desc = ''ONLINE''
      AND d.source_database_id IS NULL  -- snapshots
      AND d.is_read_only = 0
      -- Skip AG databases that are not the preferred backup/check replica:
      AND (d.replica_id IS NULL
           OR sys.fn_hadr_backup_is_preferred_replica(d.[name]) = 1)
    ORDER BY d.[name];

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @StartTime = SYSDATETIME();
    SET @SQL = N''DBCC CHECKDB (''
             + QUOTENAME(@DatabaseName, CHAR(39))
             + N'') WITH NO_INFOMSGS, ALL_ERRORMSGS;'';

    RAISERROR(''Checking: %s'', 0, 1, @DatabaseName) WITH NOWAIT;

    BEGIN TRY
        EXEC sys.sp_executesql @SQL;
        SET @Elapsed = DATEDIFF(SECOND, @StartTime, SYSDATETIME());
        RAISERROR(''  OK (%d sec)'', 0, 1, @Elapsed) WITH NOWAIT;
    END TRY
    BEGIN CATCH
        SET @Failures += 1;
        SET @ErrorMsg = ERROR_MESSAGE();
        RAISERROR(''  *** FAILED on %s: %s'', 0, 1, @DatabaseName, @ErrorMsg) WITH NOWAIT;
    END CATCH;

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

IF @Failures > 0
    RAISERROR(''CHECKDB reported problems on %d database(s). Investigate immediately.'',
              16, 1, @Failures);
';

EXEC dbo.sp_add_schedule
    @schedule_name     = N'Weekly Sunday 2AM',
    @freq_type         = 8,        -- Weekly
    @freq_interval     = 1,        -- Sunday
    @freq_recurrence_factor = 1,
    @active_start_time = 020000;

EXEC dbo.sp_attach_schedule
    @job_name      = N'DBA - Weekly CHECKDB All Databases',
    @schedule_name = N'Weekly Sunday 2AM';

EXEC dbo.sp_add_jobserver
    @job_name = N'DBA - Weekly CHECKDB All Databases';
GO
*/

-----------------------------------------------------------------------
-- 4.2 ALERTS FOR CORRUPTION SEVERITY LEVELS (template)
--     A CHECKDB schedule with no alerting is a logging exercise.
--     Severity 21-25 and errors 823/824/825 must page someone.
--     Requires Database Mail and an operator (see database-mail.sql).
-----------------------------------------------------------------------
/*
USE msdb;
GO

-- Severity 19-25 alerts
DECLARE @Severity  INT = 19,
        @AlertName SYSNAME;

WHILE @Severity <= 25
BEGIN
    SET @AlertName = N'Severity ' + CAST(@Severity AS NVARCHAR(2));

    EXEC dbo.sp_add_alert
        @name                 = @AlertName,
        @severity             = @Severity,
        @notification_message = N'Severity error detected - investigate immediately.',
        @include_event_description_in = 1;

    EXEC dbo.sp_add_notification
        @alert_name          = @AlertName,
        @operator_name       = N'DBA Team',
        @notification_method = 1;   -- email

    SET @Severity += 1;
END

-- IO / corruption specific error numbers
EXEC dbo.sp_add_alert @name = N'Error 823 - IO error',        @message_id = 823, @severity = 0;
EXEC dbo.sp_add_alert @name = N'Error 824 - Logical IO error', @message_id = 824, @severity = 0;
EXEC dbo.sp_add_alert @name = N'Error 825 - Read retry',       @message_id = 825, @severity = 0;
GO
*/


-----------------------------------------------------------------------
-- SECTION 5: TRANSACTION LOG HEALTH — VLF COUNTS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 GET VLF COUNTS FOR ALL DATABASES
--     Virtual Log Files (VLFs) are subunits of the transaction log.
--     Too many VLFs can cause performance issues during recovery,
--     transaction log backups, or growth operations.
--
--     Recommendations:
--       < 50 VLFs     = Excellent
--       50-200 VLFs   = Good
--       200-500 VLFs  = Monitor
--       > 500 VLFs    = Consider log file maintenance
--
--     Requires SQL Server 2016 SP2+ / 2017+ for sys.dm_db_log_info.
--     The state filter is REQUIRED — the DMF raises an error for
--     databases that are not readable (OFFLINE, RESTORING, RECOVERY
--     PENDING, or a non-readable AG secondary), which aborts the
--     whole result set.
-----------------------------------------------------------------------
SELECT
    db.[name]        AS [Database Name],
    li.[file_id]     AS [Log File ID],
    li.[VLF Count],
    CASE
        WHEN li.[VLF Count] < 50  THEN 'Excellent'
        WHEN li.[VLF Count] < 200 THEN 'Good'
        WHEN li.[VLF Count] < 500 THEN 'Monitor'
        ELSE '*** Consider log file maintenance ***'
    END              AS Assessment
FROM sys.databases AS db
CROSS APPLY (
    SELECT [file_id], COUNT(*) AS [VLF Count]
    FROM sys.dm_db_log_info(db.database_id)
    GROUP BY [file_id]
) AS li
WHERE db.state = 0                            -- ONLINE only
  AND db.source_database_id IS NULL           -- exclude snapshots
  AND DATABASEPROPERTYEX(db.[name], 'Collation') IS NOT NULL  -- readable
ORDER BY li.[VLF Count] DESC
OPTION (RECOMPILE);
GO

-- Fix for a high VLF count (template). Shrinking then regrowing the log
-- in a few large chunks produces far fewer VLFs than many small growths.
-- Take a log backup first if in FULL recovery, or the shrink will do nothing.
-- USE [YourDB];
-- GO
-- BACKUP LOG [YourDB] TO DISK = N'D:\Backups\YourDB_LOG.trn';
-- DBCC SHRINKFILE (N'YourDB_log', 0, TRUNCATEONLY);
-- ALTER DATABASE [YourDB] MODIFY FILE (NAME = N'YourDB_log', SIZE = 8GB);
-- GO

-- Also review the log autogrowth increment — small increments are the
-- root cause of VLF sprawl.
SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.[name]               AS LogicalFileName,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18, 2)) AS CurrentSizeMB,
    CASE mf.is_percent_growth
        WHEN 1 THEN CAST(mf.growth AS VARCHAR(10)) + ' %  *** use a fixed size instead ***'
        ELSE CAST(CAST(mf.growth * 8.0 / 1024 AS DECIMAL(18, 2)) AS VARCHAR(20)) + ' MB'
    END                     AS Autogrowth
FROM sys.master_files AS mf
WHERE mf.[type_desc] = 'LOG'
  AND mf.database_id <> 2
ORDER BY DatabaseName;
GO


/*******************************************************************************
   SECTION 6: TRACE FLAGS & PAGE-LEVEL ANALYSIS
*******************************************************************************/

-----------------------------------------------------------------------
-- 6.1 DBCC Trace Status
--      View current trace flag settings
-----------------------------------------------------------------------
-- View all trace flags applying to the connection
DBCC TRACESTATUS(-1);
GO

-- View specific trace flag (3604 - enables output to console)
-- DBCC TRACESTATUS(3604);
-- GO

-- Trace flags relevant to integrity checking:
--   2549  (pre-2016) treat each database file as on a unique disk during CHECKDB
--   2562  (pre-2016) run CHECKDB in a single batch — faster, more tempdb
--   3023  make BACKUP default to WITH CHECKSUM (superseded by the
--         'backup checksum default' sp_configure option on 2014+)
--   3604  direct DBCC output to the client instead of the error log

-----------------------------------------------------------------------
-- 6.2 Enable DBCC Output
--      Enable trace flag 3604 to show hidden DBCC output
-----------------------------------------------------------------------
-- DBCC TRACEON(3604);
-- GO

-----------------------------------------------------------------------
-- 6.3 DBCC PAGE - Analyze Page Data
--      Format: DBCC PAGE(database_id, file_id, page_number, output_option)
--      Output Options: 0=header only, 1=header+hex, 2=header+detailed, 3=all
--      Undocumented and unsupported — diagnostic use only. Requires
--      trace flag 3604 (6.2) or the output goes to the error log.
-----------------------------------------------------------------------
-- Example: View page 1472 from file 1 in database ID 8
-- DBCC PAGE(8, 1, 1472, 3);
-- GO

-----------------------------------------------------------------------
-- 6.4 sys.dm_db_page_info — supported alternative (SQL 2019+)
--      Returns page header information as a relational result set, so
--      it can be joined and filtered. Prefer this over DBCC PAGE.
-----------------------------------------------------------------------
-- SELECT * FROM sys.dm_db_page_info(8, 1, 1472, 'DETAILED');

-- Identify which object a page belongs to (e.g. a page_id from 2.2):
-- SELECT pi.object_id, OBJECT_NAME(pi.object_id) AS ObjectName,
--        pi.index_id, pi.partition_id, pi.page_type_desc
-- FROM sys.dm_db_page_info(DB_ID('YourDB'), 1, 1472, 'DETAILED') AS pi;

-- Resolve the pages currently causing waits / IO stalls to their objects:
-- SELECT er.session_id, er.wait_type, er.wait_resource,
--        OBJECT_NAME(pi.object_id, pi.database_id) AS ObjectName, pi.index_id
-- FROM sys.dm_exec_requests AS er
-- CROSS APPLY sys.fn_PageResCracker(er.page_resource) AS pc
-- CROSS APPLY sys.dm_db_page_info(pc.db_id, pc.file_id, pc.page_id, 'DETAILED') AS pi
-- WHERE er.page_resource IS NOT NULL;

