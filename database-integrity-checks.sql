-----------------------------------------------------------------------
-- DATABASE INTEGRITY CHECKS (DBCC)
-- Purpose : Validate database consistency, allocation, and catalog
--           integrity. These are essential scheduled maintenance tasks.
-- Safety  : DBCC CHECKDB is read-only by default but CPU/IO-intensive.
--           Schedule during low-activity windows. Use WITH NO_INFOMSGS
--           to suppress informational output in automated jobs.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. DBCC CHECKDB — full consistency check (current database)
--    Gold standard for detecting corruption.
-----------------------------------------------------------------------
-- Run for current database:
DBCC CHECKDB WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- To limit impact on production, use PHYSICAL_ONLY (skips logical checks
-- but catches most storage-level corruption much faster):
-- DBCC CHECKDB WITH PHYSICAL_ONLY, NO_INFOMSGS;

-----------------------------------------------------------------------
-- 2. GENERATE CHECKDB FOR ALL USER DATABASES
--    Generates one statement per database — run sequentially.
-----------------------------------------------------------------------
SELECT
    'DBCC CHECKDB (' + QUOTENAME([name]) + ') WITH NO_INFOMSGS, ALL_ERRORMSGS;' AS CheckCommand,
    [name]           AS DatabaseName,
    state_desc       AS [State],
    recovery_model_desc AS RecoveryModel
FROM sys.databases
WHERE database_id > 4          -- skip system databases (optional)
  AND state_desc = 'ONLINE'
ORDER BY [name];

-----------------------------------------------------------------------
-- 3. DBCC CHECKTABLE — check a single table
--    Useful when you suspect corruption in a specific table.
-----------------------------------------------------------------------
-- DBCC CHECKTABLE ('dbo.YourTableName') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- 4. DBCC CHECKALLOC — allocation consistency only
--    Faster than CHECKDB; verifies page and extent structures.
-----------------------------------------------------------------------
DBCC CHECKALLOC WITH NO_INFOMSGS, ALL_ERRORMSGS;

-----------------------------------------------------------------------
-- 5. DBCC CHECKCATALOG — system catalog consistency
-----------------------------------------------------------------------
DBCC CHECKCATALOG WITH NO_INFOMSGS;

-----------------------------------------------------------------------
-- 6. LAST KNOWN GOOD CHECKDB DATE
--    SQL Server stores the last successful CHECKDB date in the
--    boot page. Critical for monitoring — alert if > 7 days old.
-----------------------------------------------------------------------
SELECT
    d.[name]                                     AS DatabaseName,
    d.state_desc                                 AS [State],
    d.recovery_model_desc                        AS RecoveryModel,
    DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime')
                                                 AS LastGoodCheckDb,
    DATEDIFF(DAY,
        CAST(DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') AS DATETIME),
        GETDATE())                               AS DaysSinceLastCheck,
    CASE
        WHEN DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') = '1900-01-01'
            THEN '*** NEVER CHECKED ***'
        WHEN DATEDIFF(DAY,
                CAST(DATABASEPROPERTYEX(d.[name], 'LastGoodCheckDbTime') AS DATETIME),
                GETDATE()) > 7
            THEN '*** OVERDUE ***'
        ELSE 'OK'
    END                                          AS [Status]
FROM sys.databases d
WHERE d.state_desc = 'ONLINE'
ORDER BY DaysSinceLastCheck DESC;

-----------------------------------------------------------------------
-- 7. CHECK SUSPECT PAGES TABLE
--    sys.suspect_pages records pages where I/O errors were detected.
--    Any rows here indicate potential corruption.
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)   AS DatabaseName,
    [file_id],
    page_id,
    event_type,
    CASE event_type
        WHEN 1 THEN '823 error (I/O error)'
        WHEN 2 THEN 'Bad checksum'
        WHEN 3 THEN 'Torn page'
        WHEN 4 THEN 'Restored (after repair)'
        WHEN 5 THEN 'Repaired (DBCC)'
        WHEN 7 THEN 'Deallocated (DBCC)'
    END                    AS EventDescription,
    error_count,
    last_update_date
FROM msdb.dbo.suspect_pages
ORDER BY last_update_date DESC;

-----------------------------------------------------------------------
-- 8. DBCC CHECKDB WITH REPAIR OPTIONS (reference only)
--    *** DANGER *** — REPAIR_ALLOW_DATA_LOSS can delete data.
--    Always restore from backup first if possible.
--    Database must be in SINGLE_USER mode.
-----------------------------------------------------------------------
-- -- Step 1: Set single-user
-- ALTER DATABASE [YourDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
--
-- -- Step 2: Try repair (lossless first)
-- DBCC CHECKDB ('YourDB', REPAIR_REBUILD) WITH NO_INFOMSGS;
--
-- -- Step 3: If REPAIR_REBUILD fails, only then consider:
-- -- DBCC CHECKDB ('YourDB', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS;
--
-- -- Step 4: Return to multi-user
-- ALTER DATABASE [YourDB] SET MULTI_USER;

-----------------------------------------------------------------------
-- 9. PAGE VERIFICATION SETTING AUDIT
--    All databases should use CHECKSUM for page verification.
--    NONE or TORN_PAGE_DETECTION are legacy settings.
-----------------------------------------------------------------------
SELECT
    [name]              AS DatabaseName,
    page_verify_option_desc AS PageVerifyOption,
    CASE
        WHEN page_verify_option_desc <> 'CHECKSUM'
            THEN '*** CHANGE TO CHECKSUM ***'
        ELSE 'OK'
    END                 AS Recommendation
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY page_verify_option_desc, [name];

-- Generate fix statements for non-CHECKSUM databases:
SELECT
    'ALTER DATABASE ' + QUOTENAME([name])
    + ' SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;' AS FixCommand
FROM sys.databases
WHERE page_verify_option_desc <> 'CHECKSUM'
  AND state_desc = 'ONLINE';

-----------------------------------------------------------------------
-- 10. SQL AGENT JOB TEMPLATE — Automated Weekly CHECKDB
--     Modify schedule/database list as needed.
-----------------------------------------------------------------------
/*
-- Creates a job that runs CHECKDB on all user databases weekly (Sunday 2 AM)
USE msdb;
GO

EXEC sp_add_job
    @job_name = N'DBA - Weekly CHECKDB All Databases',
    @description = N'Runs DBCC CHECKDB on all user databases.',
    @category_name = N'Database Maintenance',
    @owner_login_name = N'sa';

EXEC sp_add_jobstep
    @job_name = N'DBA - Weekly CHECKDB All Databases',
    @step_name = N'Run CHECKDB',
    @subsystem = N'TSQL',
    @command = N'
EXEC sp_MSforeachdb
    @command1 = ''IF DB_ID(''''?'''') > 4 AND DATABASEPROPERTYEX(''''?'''', ''''Status'''') = ''''ONLINE''''
BEGIN
    PRINT ''''Checking: ?''''
    DBCC CHECKDB (''''?'''') WITH NO_INFOMSGS, ALL_ERRORMSGS
END'';
    ',
    @database_name = N'master';

EXEC sp_add_schedule
    @schedule_name = N'Weekly Sunday 2AM',
    @freq_type = 8,           -- Weekly
    @freq_interval = 1,       -- Sunday
    @active_start_time = 020000;

EXEC sp_attach_schedule
    @job_name = N'DBA - Weekly CHECKDB All Databases',
    @schedule_name = N'Weekly Sunday 2AM';

EXEC sp_add_jobserver
    @job_name = N'DBA - Weekly CHECKDB All Databases';
*/



-- Get information on location, time and size of any memory dumps from SQL Server  (Query 23) (Memory Dump Info)
SELECT [filename], creation_time, size_in_bytes/1048576.0 AS [Size (MB)]
FROM sys.dm_server_memory_dumps WITH (NOLOCK) 
ORDER BY creation_time DESC OPTION (RECOMPILE);
------


-- This will not return any rows if you have 
-- not had any memory dumps (which is a good thing)
