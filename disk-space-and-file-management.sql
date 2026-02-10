-----------------------------------------------------------------------
-- DISK SPACE, FILE MANAGEMENT & TRANSACTION LOG HEALTH
-- Purpose : Monitor volume free space, database file sizes, autogrowth
--           events, VLF counts, and log space usage.
-- Safety  : All queries are read-only except the DBCC commands which
--           are also read-only.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. VOLUME FREE SPACE (all database files)
--    Shows free space on every volume that hosts a database file.
-----------------------------------------------------------------------
SELECT DISTINCT
    vs.volume_mount_point                        AS Drive,
    vs.logical_volume_name                       AS VolumeName,
    CAST(vs.total_bytes  / 1073741824.0 AS DECIMAL(18,2)) AS TotalGB,
    CAST(vs.available_bytes / 1073741824.0 AS DECIMAL(18,2)) AS FreeGB,
    CAST(100.0 * vs.available_bytes / vs.total_bytes AS DECIMAL(5,2)) AS FreePct,
    CASE
        WHEN 100.0 * vs.available_bytes / vs.total_bytes < 10
            THEN '*** LOW SPACE ***'
        WHEN 100.0 * vs.available_bytes / vs.total_bytes < 20
            THEN '* Warning *'
        ELSE 'OK'
    END                                          AS [Status]
FROM sys.master_files mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.[file_id]) vs
ORDER BY FreePct ASC;

-----------------------------------------------------------------------
-- 2. DATABASE FILE SIZES — all databases, all files
--    Shows current size, space used, free space, and autogrowth settings.
-----------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id)                       AS DatabaseName,
    mf.[name]                                     AS LogicalName,
    mf.type_desc                                  AS FileType,
    mf.physical_name                              AS PhysicalPath,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2))  AS CurrentSizeMB,
    CAST(FILEPROPERTY(mf.[name], 'SpaceUsed')
        * 8.0 / 1024 AS DECIMAL(18,2))           AS UsedMB,
    CAST((mf.size - FILEPROPERTY(mf.[name], 'SpaceUsed'))
        * 8.0 / 1024 AS DECIMAL(18,2))           AS FreeMB,
    CASE mf.is_percent_growth
        WHEN 1 THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
        ELSE CAST(mf.growth * 8 / 1024 AS VARCHAR(10)) + ' MB'
    END                                           AS AutoGrowth,
    CASE
        WHEN mf.max_size = -1  THEN 'Unlimited'
        WHEN mf.max_size = 0   THEN 'No growth'
        ELSE CAST(CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(20)) + ' MB'
    END                                           AS MaxSize,
    mf.is_percent_growth                          AS IsPercentGrowth
FROM sys.master_files mf
WHERE mf.database_id = DB_ID()  -- change or remove for all databases
ORDER BY mf.type_desc, mf.[name];

-----------------------------------------------------------------------
-- 3. DATABASE FILE SIZES — ALL DATABASES (via sys.master_files)
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    [name]                                        AS LogicalName,
    type_desc                                     AS FileType,
    physical_name                                 AS PhysicalPath,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS CurrentSizeMB,
    CASE is_percent_growth
        WHEN 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
        ELSE CAST(growth * 8 / 1024 AS VARCHAR(10)) + ' MB'
    END                                           AS AutoGrowth,
    CASE
        WHEN is_percent_growth = 1
            THEN '*** CHANGE TO FIXED SIZE ***'
        WHEN growth * 8 / 1024 < 64 AND type_desc = 'ROWS'
            THEN '* Consider larger growth *'
        ELSE 'OK'
    END                                           AS GrowthRecommendation
FROM sys.master_files
ORDER BY DB_NAME(database_id), type_desc;

-----------------------------------------------------------------------
-- 4. AUTOGROWTH EVENTS (from default trace — on-prem only)
--    Shows recent file growth events. Frequent growths = bad sizing.
-----------------------------------------------------------------------
DECLARE @tracefile NVARCHAR(260);
SELECT @tracefile = REVERSE(
    SUBSTRING(REVERSE([path]),
        CHARINDEX(N'\', REVERSE([path])),
        260)) + N'log.trc'
FROM sys.traces
WHERE is_default = 1;

SELECT
    te.[name]                                    AS EventName,
    DB_NAME(t.DatabaseID)                        AS DatabaseName,
    t.FileName                                   AS LogicalFile,
    t.StartTime,
    t.EndTime,
    DATEDIFF(MILLISECOND, t.StartTime, t.EndTime) AS DurationMs,
    (t.IntegerData * 8.0 / 1024)                 AS GrowthMB
FROM sys.fn_trace_gettable(@tracefile, DEFAULT) t
    JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
WHERE te.[name] IN (
    'Data File Auto Grow',
    'Log File Auto Grow',
    'Data File Auto Shrink',
    'Log File Auto Shrink'
)
ORDER BY t.StartTime DESC;

-----------------------------------------------------------------------
-- 5. VLF (Virtual Log File) COUNT PER DATABASE
--    High VLF counts (> 1000) cause slow recovery and log operations.
--    Fix: shrink log, then grow in large fixed increments.
-----------------------------------------------------------------------
-- SQL Server 2016 SP2+ / 2017+:
SELECT
    DB_NAME(database_id) AS DatabaseName,
    COUNT(*)             AS VLFCount,
    CASE
        WHEN COUNT(*) > 1000 THEN '*** TOO HIGH ***'
        WHEN COUNT(*) > 500  THEN '* Warning *'
        ELSE 'OK'
    END                  AS [Status]
FROM sys.dm_db_log_info(DB_ID())
GROUP BY database_id;

-- For all databases (SQL 2017+):
SELECT
    DB_NAME(li.database_id) AS DatabaseName,
    COUNT(*)                AS VLFCount
FROM sys.databases d
    CROSS APPLY sys.dm_db_log_info(d.database_id) li
WHERE d.state_desc = 'ONLINE'
GROUP BY li.database_id
ORDER BY COUNT(*) DESC;

-----------------------------------------------------------------------
-- 6. TRANSACTION LOG SPACE USAGE
-----------------------------------------------------------------------
DBCC SQLPERF(LOGSPACE);

-- Alternative via DMV (current database):
SELECT
    DB_NAME(database_id)                              AS DatabaseName,
    CAST(total_log_size_in_bytes / 1048576.0
         AS DECIMAL(18,2))                            AS TotalLogSizeMB,
    CAST(used_log_space_in_bytes / 1048576.0
         AS DECIMAL(18,2))                            AS UsedLogSpaceMB,
    CAST(used_log_space_in_percent AS DECIMAL(5,2))   AS UsedLogPct,
    CASE
        WHEN used_log_space_in_percent > 80
            THEN '*** HIGH USAGE ***'
        WHEN used_log_space_in_percent > 60
            THEN '* Warning *'
        ELSE 'OK'
    END                                               AS [Status]
FROM sys.dm_db_log_space_usage;

-----------------------------------------------------------------------
-- 7. LOG REUSE WAIT REASON (all databases)
--    Shows what is preventing the log from being reused.
-----------------------------------------------------------------------
SELECT
    [name]                 AS DatabaseName,
    recovery_model_desc    AS RecoveryModel,
    log_reuse_wait_desc    AS LogReuseWaitReason,
    state_desc             AS DatabaseState
FROM sys.databases
WHERE state_desc = 'ONLINE'
ORDER BY
    CASE log_reuse_wait_desc
        WHEN 'NOTHING'        THEN 99
        WHEN 'LOG_BACKUP'     THEN 1
        WHEN 'ACTIVE_TRANSACTION' THEN 2
        WHEN 'REPLICATION'    THEN 3
        ELSE 10
    END;

-----------------------------------------------------------------------
-- 8. PERCENT-GROWTH FILE AUDIT
--    Percent growth is a bad practice — flag all instances.
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    [name]                                        AS LogicalName,
    type_desc                                     AS FileType,
    CAST(size * 8.0 / 1024 AS DECIMAL(18,2))     AS CurrentSizeMB,
    CAST(growth AS VARCHAR(10)) + ' %'            AS GrowthSetting,
    'ALTER DATABASE ' + QUOTENAME(DB_NAME(database_id))
        + ' MODIFY FILE (NAME = ' + QUOTENAME([name])
        + ', FILEGROWTH = 256MB);'                AS FixCommand
FROM sys.master_files
WHERE is_percent_growth = 1
  AND growth > 0
ORDER BY DB_NAME(database_id), [name];

-----------------------------------------------------------------------
-- 9. DATABASE SIZE SUMMARY (all databases)
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                            AS DatabaseName,
    CAST(SUM(CASE WHEN type_desc = 'ROWS'
                  THEN size * 8.0 / 1024 ELSE 0 END)
         AS DECIMAL(18,2))                          AS DataFileMB,
    CAST(SUM(CASE WHEN type_desc = 'LOG'
                  THEN size * 8.0 / 1024 ELSE 0 END)
         AS DECIMAL(18,2))                          AS LogFileMB,
    CAST(SUM(size * 8.0 / 1024) AS DECIMAL(18,2))  AS TotalSizeMB
FROM sys.master_files
GROUP BY database_id
ORDER BY TotalSizeMB DESC;
