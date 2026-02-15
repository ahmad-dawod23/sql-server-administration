/*==============================================================================
  DISK SPACE, FILE MANAGEMENT & TRANSACTION LOG HEALTH
  
  Purpose : Monitor volume free space, database file sizes, autogrowth
            events, VLF counts, and log space usage.
  Safety  : All queries are read-only except the DBCC commands which
            are also read-only.
  
  TABLE OF CONTENTS:
  ==================
  SECTION A: DISK & VOLUME SPACE MONITORING
    A1. Volume Free Space (All Database Files)
  
  SECTION B: DATABASE FILE MANAGEMENT
    B1. Database File Sizes - Current Database
    B2. Database File Sizes - All Databases
    B3. Database File Sizes with Growth Recommendations
    B4. Database Filenames and Paths (All Databases)
    B5. Database Size Summary (All Databases)
    B6. Percent-Growth File Audit
    B7. Autogrowth Events (from Default Trace)
  
  SECTION C: TEMPDB FILE MANAGEMENT
    C1. TempDB Data Files Count (from Error Log)
  
  SECTION D: TRANSACTION LOG MANAGEMENT
    D1. Transaction Log Space Usage
    D2. Transaction Log Space Usage (DMV Alternative)
    D3. Log Reuse Wait Reason (All Databases)
    D4. VLF Count Per Database
    D5. VLF Count All Databases
  
  SECTION E: UNRELATED QUERIES (Move to appropriate files)
==============================================================================*/


/*==============================================================================
  SECTION A: DISK & VOLUME SPACE MONITORING
==============================================================================*/

-----------------------------------------------------------------------
-- A1. VOLUME FREE SPACE (all database files)
--     Shows free space on every volume that hosts a database file.
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


/*==============================================================================
  SECTION B: DATABASE FILE MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- B1. DATABASE FILE SIZES — Current Database
--     Shows current size, space used, free space, and autogrowth settings.
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
-- B2. DATABASE FILE SIZES — All Databases
--     Basic file information for all databases via sys.master_files
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
    END                                           AS AutoGrowth
FROM sys.master_files
ORDER BY DB_NAME(database_id), type_desc;

-----------------------------------------------------------------------
-- B3. DATABASE FILE SIZES — All Databases with Growth Recommendations
--     Identifies percent growth and small fixed growth settings
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
-- B4. DATABASE FILENAMES AND PATHS — All Databases
--     Complete file information with growth and size details
--     Things to look at:
--       - Are data files and log files on different drives?
--       - Is everything on the C: drive?
--       - Is tempdb on dedicated drives?
--       - Is there only one tempdb data file?
--       - Are all of the tempdb data files the same size?
--       - Are there multiple data files for user databases?
--       - Is percent growth enabled for any files (which is bad)?
-----------------------------------------------------------------------
SELECT 
    DB_NAME([database_id])                        AS [Database Name], 
    [file_id], 
    [name], 
    physical_name, 
    [type_desc], 
    state_desc,
    is_percent_growth, 
    growth, 
    CONVERT(bigint, growth/128.0)                 AS [Growth in MB], 
    CONVERT(bigint, size/128.0)                   AS [Total Size in MB], 
    max_size
FROM sys.master_files WITH (NOLOCK)
ORDER BY DB_NAME([database_id]), [file_id] OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- B5. DATABASE SIZE SUMMARY — All Databases
--     Aggregated view of data file vs log file sizes
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

-----------------------------------------------------------------------
-- B6. PERCENT-GROWTH FILE AUDIT
--     Percent growth is a bad practice — flag all instances
--     Includes fix commands to convert to fixed size growth
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
-- B7. AUTOGROWTH EVENTS (from default trace — on-prem only)
--     Shows recent file growth events. Frequent growths = bad sizing.
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


/*==============================================================================
  SECTION C: TEMPDB FILE MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- C1. TEMPDB DATA FILES COUNT (from Error Log)
--     Shows the number of data files in the tempdb database
--     
--     Best Practice: 4-8 data files that are all the same size
--     All tempdb data files should have the same initial size and 
--     autogrowth settings
--     
--     Note: This query will return no results if your error log has 
--     been recycled since the instance was last started
--     
--     KB3170020 - Informational messages added for tempdb configuration 
--     in the SQL Server error log in SQL Server 2012 and 2014
--     https://bit.ly/3IsR8jh
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'The tempdb database has';


/*==============================================================================
  SECTION D: TRANSACTION LOG MANAGEMENT
==============================================================================*/

-----------------------------------------------------------------------
-- D1. TRANSACTION LOG SPACE USAGE (DBCC Method)
--     Shows log space usage for all databases
-----------------------------------------------------------------------
DBCC SQLPERF(LOGSPACE);

-----------------------------------------------------------------------
-- D2. TRANSACTION LOG SPACE USAGE (DMV Alternative - Current Database)
--     More detailed log space information with status alerts
-----------------------------------------------------------------------
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
-- D3. LOG REUSE WAIT REASON (All Databases)
--     Shows what is preventing the log from being reused.
--     Common reasons: NOTHING, LOG_BACKUP, ACTIVE_TRANSACTION, REPLICATION
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
-- D4. VLF (Virtual Log File) COUNT - Current Database
--     High VLF counts (> 1000) cause slow recovery and log operations.
--     Fix: shrink log, then grow in large fixed increments.
--     Requires SQL Server 2016 SP2+ / 2017+
-----------------------------------------------------------------------
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

-----------------------------------------------------------------------
-- D5. VLF COUNT - All Databases
--     Shows VLF count for all online databases
--     Requires SQL Server 2017+
-----------------------------------------------------------------------
SELECT
    DB_NAME(li.database_id) AS DatabaseName,
    COUNT(*)                AS VLFCount
FROM sys.databases d
    CROSS APPLY sys.dm_db_log_info(d.database_id) li
WHERE d.state_desc = 'ONLINE'
GROUP BY li.database_id
ORDER BY COUNT(*) DESC;

