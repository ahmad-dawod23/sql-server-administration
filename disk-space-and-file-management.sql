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





-- Get number of data files in tempdb database (Query 26) (TempDB Data Files)
EXEC sys.xp_readerrorlog 0, 1, N'The tempdb database has';
------


-- Get the number of data files in the tempdb database
-- 4-8 data files that are all the same size is a good starting point

-- You want this query to return no results
-- All of your tempdb data files should have the same initial size and autogrowth settings 
-- This query will also return no results if your error log has been recycled since the instance was last started
-- KB3170020 - Informational messages added for tempdb configuration in the SQL Server error log in SQL Server 2012 and 2014
-- https://bit.ly/3IsR8jh




-- File names and paths for all user and system databases on instance  (Query 28) (Database Filenames and Paths)
SELECT DB_NAME([database_id]) AS [Database Name], 
       [file_id], [name], physical_name, [type_desc], state_desc,
	   is_percent_growth, growth, 
	   CONVERT(bigint, growth/128.0) AS [Growth in MB], 
       CONVERT(bigint, size/128.0) AS [Total Size in MB], max_size
FROM sys.master_files WITH (NOLOCK)
ORDER BY DB_NAME([database_id]), [file_id] OPTION (RECOMPILE);
------


-- Things to look at:
-- Are data files and log files on different drives?
-- Is everything on the C: drive?
-- Is tempdb on dedicated drives?
-- Is there only one tempdb data file?
-- Are all of the tempdb data files the same size?
-- Are there multiple data files for user databases?
-- Is percent growth enabled for any files (which is bad)?



-- sys.dm_os_performance_counters (Transact-SQL)
-- https://bit.ly/3kEO2JR


-- sys.dm_database_encryption_keys (Transact-SQL)
-- https://bit.ly/3mE7kkx





-- sys.dm_os_memory_clerks (Transact-SQL)
-- https://bit.ly/2H31xDR






-- Find single-use, ad-hoc and prepared queries that are bloating the plan cache  (Query 52) (Ad hoc Queries)
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name],
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text], 
cp.objtype AS [Object Type], cp.cacheobjtype AS [Cache Object Type],  
cp.size_in_bytes/1024 AS [Plan Size in KB],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index]
--,t.[text] AS [Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_cached_plans AS cp WITH (NOLOCK)

-- Plan cache, adhoc workloads and clearing the single-use plan cache bloat
-- https://bit.ly/2EfYOkl




-- Get top total logical reads queries for entire instance (Query 53) (Top Logical Reads Queries)
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name],
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text], 
qs.total_logical_reads AS [Total Logical Reads],
qs.min_logical_reads AS [Min Logical Reads],
qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],
qs.max_logical_reads AS [Max Logical Reads],   
qs.min_worker_time AS [Min Worker Time],
qs.total_worker_time/qs.execution_count AS [Avg Worker Time], 

-- Get top total logical reads queries for entire instance (Query 53) (Top Logical Reads Queries)
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name],
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text], 
qs.total_logical_reads AS [Total Logical Reads],
qs.min_logical_reads AS [Min Logical Reads],
qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],
qs.max_logical_reads AS [Max Logical Reads],   
qs.min_worker_time AS [Min Worker Time],
qs.total_worker_time/qs.execution_count AS [Avg Worker Time], 
qs.max_worker_time AS [Max Worker Time], 
qs.min_elapsed_time AS [Min Elapsed Time], 
qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time], 
qs.max_elapsed_time AS [Max Elapsed Time],
qs.execution_count AS [Execution Count], 
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
qs.creation_time AS [Creation Time]
--,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
ORDER BY qs.total_logical_reads DESC OPTION (RECOMPILE);
------





-- Cached SPs Missing Indexes by Execution Count (Query 69) (SP Missing Index)
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.execution_count AS [Execution Count],
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
qs.total_worker_time/qs.execution_count AS [Avg Worker Time],    
qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
AND CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%'
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);
------
