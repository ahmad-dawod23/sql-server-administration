
-----------------------------------------------------------------------
-- MISPLACED QUERIES - THESE BELONG IN OTHER FILES
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- BLOCKING DETECTION QUERY
-- ** This query should be in: performance-blocking.sql **
-----------------------------------------------------------------------

-- Detect blocking (run multiple times)
SELECT
    t1.resource_type                                AS [lock type],
    DB_NAME(resource_database_id)                   AS [database],
    t1.resource_associated_entity_id                AS [blk object],
    t1.request_mode                                 AS [lock req],
    t1.request_session_id                           AS [waiter sid],
    t2.wait_duration_ms                             AS [wait time],
    (SELECT [text] FROM sys.dm_exec_requests AS r WITH (NOLOCK)
     CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle])
     WHERE r.session_id = t1.request_session_id)    AS [waiter_batch],
    (SELECT SUBSTRING(qt.[text], r.statement_start_offset/2,
        (CASE WHEN r.statement_end_offset = -1
         THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2
         ELSE r.statement_end_offset END - r.statement_start_offset)/2)
     FROM sys.dm_exec_requests AS r WITH (NOLOCK)
     CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
     WHERE r.session_id = t1.request_session_id)    AS [waiter_stmt]
FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
    JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
        ON t1.lock_owner_address = t2.resource_address;


-----------------------------------------------------------------------
-- STORED PROCEDURE LOGICAL WRITES QUERY
-- ** This query should be in: performance-checking-queries.sql **
-----------------------------------------------------------------------

-- Top Cached SPs By Total Logical Writes
-- Logical writes relate to both memory and disk I/O pressure
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


-----------------------------------------------------------------------
-- I/O WARNING DETECTION FROM ERROR LOG
-- ** This query should be in: performance-io-latency.sql **
-----------------------------------------------------------------------

-- Look for I/O requests taking longer than 15 seconds in error logs
DROP TABLE IF EXISTS #IOWarningResults;
CREATE TABLE #IOWarningResults(LogDate datetime, ProcessInfo sysname, LogText nvarchar(1000));
INSERT INTO #IOWarningResults
EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';
SELECT * FROM #IOWarningResults;
DROP TABLE #IOWarningResults;





-----------------------------------------------------------------------
-- QUERY: Memory Dump Information
-- RECOMMENDATION: Move to performance-buffer-pool-and-memory-analysis.sql
-- REASON: This query is about memory dumps, not database integrity checks
-----------------------------------------------------------------------
-- Get information on location, time and size of any memory dumps from SQL Server  (Query 23) (Memory Dump Info)

SELECT [filename], creation_time, size_in_bytes/1048576.0 AS [Size (MB)]

FROM sys.dm_server_memory_dumps WITH (NOLOCK) 

ORDER BY creation_time DESC OPTION (RECOMPILE);

------





/*==============================================================================
  SECTION E: UNRELATED QUERIES
  
  The following queries are NOT related to disk space, file management, or
  transaction logs. They should be moved to more appropriate files as indicated.
==============================================================================*/

-----------------------------------------------------------------------
-- UNRELATED QUERY #1: Ad hoc Single-Use Plan Cache Queries
-- ** SHOULD BE MOVED TO: performance-plan-cache-analysis.sql **
-- 
-- Purpose: Find single-use, ad-hoc and prepared queries bloating the 
--          plan cache
-- Reference: https://bit.ly/2EfYOkl
-----------------------------------------------------------------------
SELECT TOP(50) DB_NAME(t.[dbid]) AS [Database Name],
REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text], 
cp.objtype AS [Object Type], 
cp.cacheobjtype AS [Cache Object Type],  
cp.size_in_bytes/1024 AS [Plan Size in KB],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
    LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index]
--,t.[text] AS [Query Text], qp.query_plan AS [Query Plan] -- uncomment out these columns if not copying results to Excel
FROM sys.dm_exec_cached_plans AS cp WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp
WHERE cp.cacheobjtype = N'Compiled Plan' 
AND cp.objtype IN (N'Adhoc', N'Prepared') 
AND cp.usecounts = 1
ORDER BY cp.size_in_bytes DESC OPTION (RECOMPILE);

-----------------------------------------------------------------------
-- UNRELATED QUERY #2: Top Logical Reads Queries
-- ** SHOULD BE MOVED TO: performance-checking-queries.sql **
--
-- Purpose: Get top total logical reads queries for entire instance
--          Helps identify queries that read lots of pages from buffer pool
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

-----------------------------------------------------------------------
-- UNRELATED QUERY #3: Stored Procedures with Missing Indexes
-- ** SHOULD BE MOVED TO: performance-index-and-statistics-maintenance.sql **
--
-- Purpose: Find cached stored procedures that have missing index 
--          recommendations in their execution plans
-----------------------------------------------------------------------
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], 
qs.execution_count AS [Execution Count],
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
AND CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 
    LIKE N'%<MissingIndexes>%'
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);




-----------------------------------------------------------------------
-- SECTION 5: UNRELATED QUERIES (SUGGESTED FOR RELOCATION)
-----------------------------------------------------------------------
/*
The following queries are not directly related to IOPS and storage performance
and should be moved to more appropriate files:

1. VLF Counts Query
   → SUGGESTED FILE: database-integrity-checks.sql
   → REASON: Virtual Log File management is related to transaction log health

2. Buffer Pool Scan Query
   → SUGGESTED FILE: performance-buffer-pool-and-memory-analysis.sql
   → REASON: Directly related to buffer pool operations

3. Query Execution Counts
   → SUGGESTED FILE: performance-checking-queries.sql
   → REASON: General query performance monitoring

4. Stored Procedure Performance (incomplete)
   → SUGGESTED FILE: performance-checking-queries.sql
   → REASON: General stored procedure performance monitoring
*/


-- UNRELATED QUERY 1: Get VLF Counts for all databases
-- → Move to: database-integrity-checks.sql
------
SELECT 
    [name] AS [Database Name], 
    [VLF Count]
FROM sys.databases AS db WITH (NOLOCK)
CROSS APPLY (
    SELECT file_id, COUNT(*) AS [VLF Count]
    FROM sys.dm_db_log_info(db.database_id)
    GROUP BY file_id
) AS li
ORDER BY [VLF Count] DESC OPTION (RECOMPILE);
------


-- UNRELATED QUERY 2: Look for long duration buffer pool scans
-- → Move to: performance-buffer-pool-and-memory-analysis.sql
-- Finds buffer pool scans that took more than 10 seconds in the current SQL Server Error log
-- This should happen much less often in SQL Server 2022
------
EXEC sys.xp_readerrorlog 0, 1, N'Buffer pool scan took';
------


-- UNRELATED QUERY 3: Most frequently executed queries for current database
-- → Move to: performance-checking-queries.sql
-- Tells you which cached queries are called the most often
-- This helps you characterize and baseline your workload
-- It also helps you find possible caching opportunities
------
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
------


-- UNRELATED QUERY 4: Top Cached Stored Procedures by Average Elapsed Time
-- → Move to: performance-checking-queries.sql
-- Tells you which cached stored procedures have the highest average elapsed time
-- This helps identify slow-running stored procedures
-- NOTE: This query was incomplete in the original file and has been completed below
------
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
------

