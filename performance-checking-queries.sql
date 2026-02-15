-----------------------------------------------------------------------
-- DEADLOCK & QUERY STORE INVESTIGATION
-- Purpose : Deadlock analysis (trace flags + XE), Query Store-based
--           query investigation, and parameter sniffing detection.
-- Safety  : All queries are read-only except DBCC TRACEON (commented).
-- Applies to : On-prem / Azure SQL MI / Both
--
-- NOTE: Queries for CPU by database, I/O by database, buffer pool,
--       PLE, memory grants, file sizes, log space, VLFs, statistics,
--       and index fragmentation have been moved to their dedicated files:
--         - performance-cpu.sql
--         - performance-io-latency.sql
--         - performance-buffer-pool-and-memory-analysis.sql
--         - disk-space-and-file-management.sql
--         - performance-index-and-statistics-maintenance.sql
--         - performance-wait-stats.sql
--         - performance-tempdb.sql
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. TRACE FLAGS FOR DEADLOCK LOGGING (on-prem)
--    Enables detailed deadlock information in the SQL Server error log.
--    1204 = deadlock info by node
--    1222 = deadlock info by process and resource (recommended)
--    *** UNCOMMENT TO ENABLE — persists until service restart ***
-----------------------------------------------------------------------
-- Show currently active trace flags
DBCC TRACESTATUS;

-- Enable deadlock trace flags (uncomment to run):
-- DBCC TRACEON (1204, 1222, -1);  -- -1 makes it global


-----------------------------------------------------------------------
-- 2. DEADLOCK ANALYSIS — AZURE SQL MI
--    Reads deadlock events from the MI telemetry XE target.
--    On-prem: Use the system_health XE session instead (see section 3).
-----------------------------------------------------------------------
WITH CTE AS (
    SELECT CAST(event_data AS XML) AS [target_data_XML]
    FROM sys.fn_xe_telemetry_blob_target_read_file('dl', NULL, NULL, NULL)
)
SELECT
    target_data_XML.value('(/event/@timestamp)[1]', 'DateTime2')   AS Timestamp,
    target_data_XML.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_xml,
    target_data_XML.query('/event/data[@name=''database_name'']/value')
        .value('(/value)[1]', 'nvarchar(100)')                     AS db_name
FROM CTE
ORDER BY Timestamp DESC;


-----------------------------------------------------------------------
-- 3. DEADLOCK ANALYSIS — ON-PREM (system_health XE session)
--    Extracts deadlock graphs from the default system_health session.
--    Works on SQL Server 2012+ without any additional configuration.
-----------------------------------------------------------------------
WITH DeadlockEvents AS (
    SELECT
        xdr.value('@timestamp', 'datetime2')       AS DeadlockTime,
        xdr.query('.')                              AS DeadlockGraph
    FROM (
        SELECT CAST(target_data AS XML) AS TargetData
        FROM sys.dm_xe_session_targets AS st
        INNER JOIN sys.dm_xe_sessions AS s
            ON s.[address] = st.event_session_address
        WHERE s.[name] = N'system_health'
          AND st.target_name = N'ring_buffer'
    ) AS Data
    CROSS APPLY TargetData.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(xdr)
)
SELECT TOP 20
    DeadlockTime,
    DeadlockGraph
FROM DeadlockEvents
ORDER BY DeadlockTime DESC;


-----------------------------------------------------------------------
-- 4. QUERY STORE — INVESTIGATE BY QUERY HASH
--    Find all plans and execution stats for a specific query hash.
--    Update the query_hash value in the WHERE clause.
--
--    What to look for:
--      Multiple plan_hashes for same query_hash = plan regression
--      High avg_cpu_time with low count = occasional expensive plan
--      Compare avg_physical_io_reads across plans for sniffing
-----------------------------------------------------------------------
WITH query_ids AS (
    SELECT
        q.query_hash,
        q.query_id,
        p.query_plan_hash,
        SUM(qrs.count_executions) * AVG(qrs.avg_cpu_time) / 1000.  AS total_cpu_time_ms,
        SUM(qrs.count_executions)                                   AS sum_executions,
        AVG(qrs.avg_cpu_time) / 1000.                               AS avg_cpu_time_ms,
        AVG(qrs.avg_logical_io_reads) / 1000.                       AS avg_logical_io_reads_ms,
        AVG(qrs.avg_physical_io_reads) / 1000.                      AS avg_physical_io_reads_ms
    FROM sys.query_store_query q
    JOIN sys.query_store_plan p ON q.query_id = p.query_id
    JOIN sys.query_store_runtime_stats qrs ON p.plan_id = qrs.plan_id
    JOIN sys.query_store_runtime_stats_interval qrsi
        ON qrs.runtime_stats_interval_id = qrsi.runtime_stats_interval_id
    WHERE q.query_hash IN (0x0000000000000000)  -- *** UPDATE WITH YOUR QUERY HASH ***
    GROUP BY q.query_id, q.query_hash, p.query_plan_hash
)
SELECT
    qid.*,
    p.count_compiles,
    qt.query_sql_text,
    TRY_CAST(p.query_plan AS XML)                                   AS query_plan
FROM query_ids AS qid
JOIN sys.query_store_query AS q ON qid.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p
    ON qid.query_id = p.query_id AND qid.query_plan_hash = p.query_plan_hash
    /* Optional filters: */
    -- WHERE qt.query_sql_text LIKE '%YourSearchText%'
    -- WHERE OBJECT_NAME(q.object_id) = 'YourStoredProcName'
ORDER BY avg_physical_io_reads_ms DESC;
GO


-----------------------------------------------------------------------
-- 5. QUERY STORE — SEARCH BY SQL TEXT OR QUERY HASH
--    Find a specific query by text pattern or hash.
--    Update the WHERE clause with your search criteria.
-----------------------------------------------------------------------
-- USE [YourDatabaseName];  -- switch to the target database first
-- GO
SELECT
    qt.query_sql_text,
    CAST(p.query_plan AS XML)                                       AS ExecutionPlan,
    rs.last_execution_time,
    rs.count_executions,
    rs.avg_cpu_time,
    rs.avg_logical_io_reads,
    rs.avg_physical_io_reads
FROM sys.query_store_query_text AS qt
JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan AS p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
WHERE qt.query_sql_text LIKE '%YourSearchText%'
   -- OR q.query_hash IN (0x0000000000000000)  -- *** UPDATE WITH YOUR QUERY HASH ***
ORDER BY rs.last_execution_time DESC;


-----------------------------------------------------------------------
-- 6. QUERY STORE — TOP RESOURCE-CONSUMING QUERIES (last 24 hours)
--    Quick overview of the most expensive queries in the recent window.
-----------------------------------------------------------------------
SELECT TOP 25
    q.query_id,
    qt.query_sql_text,
    SUM(rs.count_executions)                                        AS TotalExecutions,
    SUM(rs.count_executions * rs.avg_cpu_time) / 1000.              AS TotalCpuMs,
    AVG(rs.avg_cpu_time) / 1000.                                    AS AvgCpuMs,
    AVG(rs.avg_logical_io_reads)                                    AS AvgLogicalReads,
    AVG(rs.avg_physical_io_reads)                                   AS AvgPhysicalReads,
    AVG(rs.avg_duration) / 1000.                                    AS AvgDurationMs,
    COUNT(DISTINCT p.plan_id)                                       AS PlanCount,
    -- If PlanCount > 1, this query may have plan instability
    CASE
        WHEN COUNT(DISTINCT p.plan_id) > 1
        THEN '* Multiple plans — possible parameter sniffing *'
        ELSE ''
    END                                                             AS PlanStabilityNote
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -24, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY TotalCpuMs DESC;


-----------------------------------------------------------------------
-- 7. TOP CACHED STORED PROCEDURES BY TOTAL LOGICAL WRITES
--    Logical writes relate to both memory and disk I/O pressure.
--    High logical writes indicate heavy data modification or scanning.
-----------------------------------------------------------------------
SELECT TOP(25)
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name],
    qs.total_logical_writes                        AS [TotalLogicalWrites],
    qs.total_logical_writes/qs.execution_count     AS [AvgLogicalWrites],
    qs.execution_count,
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
    qs.total_elapsed_time,
    qs.total_elapsed_time/qs.execution_count       AS [avg_elapsed_time],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
         LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    CONVERT(nvarchar(25), qs.cached_time, 20)      AS [Plan Cached Time]
    -- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan
FROM sys.procedures AS p WITH (NOLOCK)
    INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
        ON p.[object_id] = qs.[object_id]
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
  AND qs.total_logical_writes > 0
  AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY qs.total_logical_writes DESC OPTION (RECOMPILE);
GO


-----------------------------------------------------------------------
-- 8. TOP TOTAL LOGICAL READS QUERIES (Instance-Wide)
--    Get top total logical reads queries for entire instance.
--    Helps identify queries that read lots of pages from buffer pool.
-----------------------------------------------------------------------
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
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
    LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
qs.creation_time AS [Creation Time]
--,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
ORDER BY qs.total_logical_reads DESC OPTION (RECOMPILE);
GO


-----------------------------------------------------------------------
-- 9. MOST FREQUENTLY EXECUTED QUERIES (Current Database)
--    Tells you which cached queries are called the most often.
--    This helps you characterize and baseline your workload.
--    It also helps you find possible caching opportunities.
-----------------------------------------------------------------------
SELECT TOP(50) 
    LEFT(t.[text], 50) AS [Short Query Text], 
    qs.execution_count AS [Execution Count],
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.creation_time, GETDATE()), 0) AS [Calls/Minute],
    qs.total_logical_reads AS [Total Logical Reads],
    qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads],
    qs.total_worker_time AS [Total Worker Time],
    qs.total_worker_time/qs.execution_count AS [Avg Worker Time], 
    qs.total_elapsed_time AS [Total Elapsed Time],
    qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index], 
    qs.last_execution_time AS [Last Execution Time], 
    qs.creation_time AS [Creation Time]
    --,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
WHERE t.dbid = DB_ID()
    AND DATEDIFF(Minute, qs.creation_time, GETDATE()) > 0
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);
GO


-----------------------------------------------------------------------
-- 10. TOP CACHED STORED PROCEDURES BY AVERAGE ELAPSED TIME
--     Tells you which cached stored procedures have the highest average elapsed time.
--     This helps identify slow-running stored procedures.
-----------------------------------------------------------------------
SELECT TOP(25) 
    CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], 
    qs.min_elapsed_time, 
    qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time], 
    qs.max_elapsed_time, 
    qs.last_elapsed_time, 
    qs.total_elapsed_time, 
    qs.execution_count, 
    ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute], 
    qs.total_worker_time/qs.execution_count AS [AvgWorkerTime], 
    qs.total_worker_time AS [TotalWorkerTime],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
    CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
    qs.cached_time AS [Plan Cached Time]
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
    ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
    AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY avg_elapsed_time DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 11. TOP I/O STATEMENTS
-----------------------------------------------------------------------

-- Lists the top statements by average input/output usage for the current database  (Query 70) (Top IO Statements)
SELECT TOP(50) OBJECT_NAME(qt.objectid, dbid) AS [SP Name],
(qs.total_logical_reads + qs.total_logical_writes) /qs.execution_count AS [Avg IO], 
qs.execution_count AS [Execution Count],
SUBSTRING(qt.[text],qs.statement_start_offset/2, 
    (CASE 
        WHEN qs.statement_end_offset = -1 
     THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
        ELSE qs.statement_end_offset 
     END - qs.statement_start_offset)/2) AS [Query Text]    
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qt.[dbid] = DB_ID()
ORDER BY [Avg IO] DESC OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- 12. TOP AVERAGE ELAPSED TIME QUERIES
-----------------------------------------------------------------------

-- Get top average elapsed time queries for entire instance (Query 54) (Top Avg Elapsed Time Queries)
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name], 
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text],  
qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
qs.min_elapsed_time, qs.max_elapsed_time, qs.last_elapsed_time,
qs.execution_count AS [Execution Count],  
qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads], 
qs.total_physical_reads/qs.execution_count AS [Avg Physical Reads], 
qs.total_worker_time/qs.execution_count AS [Avg Worker Time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
qs.creation_time AS [Creation Time]
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_elapsed_time/qs.execution_count DESC OPTION (RECOMPILE);