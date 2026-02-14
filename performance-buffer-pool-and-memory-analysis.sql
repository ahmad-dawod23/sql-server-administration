-----------------------------------------------------------------------
-- BUFFER POOL & MEMORY ANALYSIS
-- Purpose : Understand how SQL Server uses memory — per-database
--           buffer pool breakdown, object-level memory usage,
--           memory clerks, and memory grants.
-- Safety  : All queries are read-only. Some may be CPU-intensive
--           on instances with very large buffer pools.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. BUFFER POOL USAGE BY DATABASE
--    Shows how much memory each database consumes in the buffer pool.
-----------------------------------------------------------------------
SELECT
    CASE
        WHEN database_id = 32767 THEN 'Resource DB'
        ELSE DB_NAME(database_id)
    END                                           AS DatabaseName,
    COUNT(*)                                      AS PagesInMemory,
    CAST(COUNT(*) * 8.0 / 1024 AS DECIMAL(18,2)) AS BufferPoolMB,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()
         AS DECIMAL(5,2))                         AS PctOfBufferPool
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY PagesInMemory DESC;

-----------------------------------------------------------------------
-- 2. BUFFER POOL USAGE BY OBJECT (current database)
--    Identifies which tables/indexes consume the most memory.
-----------------------------------------------------------------------
SELECT TOP 50
    SCHEMA_NAME(o.[schema_id])                    AS [Schema],
    o.[name]                                      AS ObjectName,
    i.[name]                                      AS IndexName,
    i.[type_desc]                                 AS IndexType,
    COUNT(bd.page_id)                             AS PagesInMemory,
    CAST(COUNT(bd.page_id) * 8.0 / 1024
         AS DECIMAL(18,2))                        AS BufferMB,
    SUM(CAST(bd.free_space_in_bytes AS BIGINT))   AS FreeSpaceBytes,
    CAST(100.0 - (100.0 * SUM(CAST(bd.free_space_in_bytes AS BIGINT))
         / (COUNT(bd.page_id) * 8192.0))
         AS DECIMAL(5,2))                         AS PageDensityPct
FROM sys.dm_os_buffer_descriptors bd
    JOIN sys.allocation_units au
        ON bd.allocation_unit_id = au.allocation_unit_id
    JOIN sys.partitions p
        ON au.container_id = p.hobt_id
       AND au.[type] IN (1, 3)                    -- IN_ROW_DATA, ROW_OVERFLOW_DATA
    JOIN sys.objects o ON p.[object_id] = o.[object_id]
    JOIN sys.indexes i ON p.[object_id] = i.[object_id]
                       AND p.index_id = i.index_id
WHERE bd.database_id = DB_ID()
  AND o.is_ms_shipped = 0
GROUP BY o.[schema_id], o.[name], i.[name], i.[type_desc]
ORDER BY PagesInMemory DESC;

-----------------------------------------------------------------------
-- 3. MEMORY CLERKS — top consumers
--    Shows where SQL Server allocates memory beyond the buffer pool
--    (plan cache, lock manager, columnstore, etc.).
-----------------------------------------------------------------------
SELECT TOP 20
    [type]                                        AS ClerkType,
    [name],
    CAST(pages_kb / 1024.0 AS DECIMAL(18,2))     AS AllocatedMB,
    CAST(virtual_memory_reserved_kb / 1024.0
         AS DECIMAL(18,2))                        AS VirtualReservedMB,
    CAST(virtual_memory_committed_kb / 1024.0
         AS DECIMAL(18,2))                        AS VirtualCommittedMB
FROM sys.dm_os_memory_clerks
ORDER BY pages_kb DESC;

-----------------------------------------------------------------------
-- 4. PLAN CACHE MEMORY USAGE (by cache type)
-----------------------------------------------------------------------
SELECT
    cacheobjtype                                  AS CacheObjType,
    objtype                                       AS ObjType,
    COUNT(*)                                      AS PlanCount,
    CAST(SUM(size_in_bytes) / 1048576.0
         AS DECIMAL(18,2))                        AS TotalSizeMB,
    SUM(usecounts)                                AS TotalUseCounts,
    CAST(AVG(size_in_bytes) / 1024.0
         AS DECIMAL(18,2))                        AS AvgPlanSizeKB
FROM sys.dm_exec_cached_plans
GROUP BY cacheobjtype, objtype
ORDER BY TotalSizeMB DESC;

-----------------------------------------------------------------------
-- 5. PAGE LIFE EXPECTANCY (PLE)
--    How long a page stays in the buffer pool (seconds).
--    Low PLE = memory pressure. Baseline varies by buffer pool size.
--    Rule of thumb: PLE should be > (buffer pool GB × 300).
-----------------------------------------------------------------------
SELECT
    [object_name],
    instance_name,
    cntr_value                                    AS PLE_Seconds,
    CAST(cntr_value / 60.0 AS DECIMAL(10,1))     AS PLE_Minutes,
    CASE
        WHEN cntr_value < 300  THEN '*** CRITICAL ***'
        WHEN cntr_value < 1000 THEN '* Warning *'
        ELSE 'OK'
    END                                           AS [Status]
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Buffer Manager%'
  AND counter_name = 'Page life expectancy';

-----------------------------------------------------------------------
-- 6. MEMORY GRANTS PENDING & CURRENT
--    Queries waiting for memory grants indicate memory pressure.
-----------------------------------------------------------------------
-- Pending grants:
SELECT
    cntr_value AS MemoryGrantsPending
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Memory Manager%'
  AND counter_name = 'Memory Grants Pending';

-- Current granted memory:
SELECT
    session_id,
    request_time,
    grant_time,
    requested_memory_kb,
    granted_memory_kb,
    required_memory_kb,
    used_memory_kb,
    max_used_memory_kb,
    ideal_memory_kb,
    queue_id,
    wait_order,
    is_next_candidate,
    dop,
    CAST(granted_memory_kb / 1024.0 AS DECIMAL(10,2)) AS GrantedMB,
    CAST(used_memory_kb / 1024.0 AS DECIMAL(10,2))    AS UsedMB
FROM sys.dm_exec_query_memory_grants
ORDER BY granted_memory_kb DESC;

-----------------------------------------------------------------------
-- 7. MEMORY TARGETS AND CURRENT USAGE
--    Committed vs. target memory — should be close in steady state.
-----------------------------------------------------------------------
SELECT
    counter_name,
    cntr_value / 1024                             AS ValueMB
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Memory Manager%'
  AND counter_name IN (
    'Target Server Memory (KB)',
    'Total Server Memory (KB)',
    'Database Cache Memory (KB)',
    'Free Memory (KB)',
    'Stolen Server Memory (KB)',
    'Lock Memory (KB)',
    'Connection Memory (KB)',
    'Optimizer Memory (KB)'
  )
ORDER BY cntr_value DESC;

-----------------------------------------------------------------------
-- 8. PROCESS MEMORY (OS-level view)
-----------------------------------------------------------------------
SELECT
    CAST(physical_memory_in_use_kb / 1024.0
         AS DECIMAL(18,2))                        AS PhysicalMemoryInUseMB,
    CAST(locked_page_allocations_kb / 1024.0
         AS DECIMAL(18,2))                        AS LockedPagesMB,
    CAST(virtual_address_space_committed_kb / 1024.0
         AS DECIMAL(18,2))                        AS VASCommittedMB,
    CAST(available_commit_limit_kb / 1024.0
         AS DECIMAL(18,2))                        AS AvailableCommitLimitMB,
    large_page_allocations_kb,
    process_physical_memory_low,
    process_virtual_memory_low
FROM sys.dm_os_process_memory;

-----------------------------------------------------------------------
-- 9. OS MEMORY STATUS
-----------------------------------------------------------------------
SELECT
    CAST(total_physical_memory_kb / 1048576.0
         AS DECIMAL(18,2))                        AS TotalPhysicalMemoryGB,
    CAST(available_physical_memory_kb / 1048576.0
         AS DECIMAL(18,2))                        AS AvailablePhysicalMemoryGB,
    CAST(total_page_file_kb / 1048576.0
         AS DECIMAL(18,2))                        AS TotalPageFileGB,
    CAST(available_page_file_kb / 1048576.0
         AS DECIMAL(18,2))                        AS AvailablePageFileGB,
    system_memory_state_desc
FROM sys.dm_os_sys_memory;

-----------------------------------------------------------------------
-- 10. DIRTY PAGES IN BUFFER POOL
--     High dirty page count = potential I/O bottleneck during
--     checkpoints or lazy writer activity.
-----------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                          AS DatabaseName,
    SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) AS DirtyPages,
    SUM(CASE WHEN is_modified = 0 THEN 1 ELSE 0 END) AS CleanPages,
    COUNT(*)                                      AS TotalPages,
    CAST(100.0 * SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))              AS DirtyPct
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
HAVING SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) > 0
ORDER BY DirtyPages DESC;

-- SQL Server Process Address space info  (Query 6) (Process Memory)
-- (shows whether locked pages is enabled, among other things)
SELECT physical_memory_in_use_kb/1024 AS [SQL Server Memory Usage (MB)],
	   locked_page_allocations_kb/1024 AS [SQL Server Locked Pages Allocation (MB)],
       large_page_allocations_kb/1024 AS [SQL Server Large Pages Allocation (MB)], 
	   page_fault_count, memory_utilization_percentage, available_commit_limit_kb, 
	   process_physical_memory_low, process_virtual_memory_low
FROM sys.dm_os_process_memory WITH (NOLOCK) OPTION (RECOMPILE);
------


-- Good basic information about OS memory amounts and state  (Query 14) (System Memory)
SELECT total_physical_memory_kb/1024 AS [Physical Memory (MB)], 
       available_physical_memory_kb/1024 AS [Available Memory (MB)], 
       total_page_file_kb/1024 AS [Page File Commit Limit (MB)],
	   total_page_file_kb/1024 - total_physical_memory_kb/1024 AS [Physical Page File Size (MB)],
	   available_page_file_kb/1024 AS [Available Page File (MB)], 
	   system_cache_kb/1024 AS [System Cache (MB)],
       system_memory_state_desc AS [System Memory State]
FROM sys.dm_os_sys_memory WITH (NOLOCK) OPTION (RECOMPILE);
------



-- sys.dm_io_virtual_file_stats (Transact-SQL)
-- https://bit.ly/3bRWUc0




-- Look for I/O requests taking longer than 15 seconds in the six most recent SQL Server Error Logs (Query 33) (IO Warnings)
DROP TABLE IF EXISTS #IOWarningResults;
CREATE TABLE #IOWarningResults(LogDate datetime, ProcessInfo sysname, LogText nvarchar(1000));


	INSERT INTO #IOWarningResults 
	EXEC xp_readerrorlog 0, 1, N'taking longer than 15 seconds';

-- sys.dm_db_log_info (Transact-SQL)
-- https://bit.ly/3jpmqsd


-- sys.databases (Transact-SQL)
-- https://bit.ly/2G5wqaX


-- SQL Server Transaction Log Architecture and Management Guide
-- https://bit.ly/2JjmQRZ


-- VLF Growth Formula (SQL Server 2022)
-- If the log growth increment is less than 1/8th the current size of the log

-- Sustained values above 1 suggest further investigation in that area
-- High Avg Runnable Task Counts are a good sign of CPU pressure
-- High Avg Pending DiskIO Counts are a sign of disk pressure


-- How to Do Some Very Basic SQL Server Monitoring
-- https://bit.ly/30IRla0





-- Detect blocking (run multiple times)  (Query 45) (Detect Blocking)
SELECT t1.resource_type AS [lock type], DB_NAME(resource_database_id) AS [database],
t1.resource_associated_entity_id AS [blk object],t1.request_mode AS [lock req],  -- lock requested
t1.request_session_id AS [waiter sid], t2.wait_duration_ms AS [wait time],       -- spid of waiter  
(SELECT [text] FROM sys.dm_exec_requests AS r WITH (NOLOCK)                      -- get sql for waiter
CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) 
WHERE r.session_id = t1.request_session_id) AS [waiter_batch],
(SELECT SUBSTRING(qt.[text],r.statement_start_offset/2, 
    (CASE WHEN r.statement_end_offset = -1 
    THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
    ELSE r.statement_end_offset END - r.statement_start_offset)/2) 
FROM sys.dm_exec_requests AS r WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
WHERE r.session_id = t1.request_session_id) AS [waiter_stmt],					-- statement blocked



-- Helps troubleshoot blocking and deadlocking issues
-- The results will change from second to second on a busy system
-- You should run this query multiple times when you see signs of blocking




-- Memory Clerk Usage for instance  (Query 51) (Memory Clerk Usage)
-- Look for high value for CACHESTORE_SQLCP (Ad-hoc query plans)
SELECT TOP(10) mc.[type] AS [Memory Clerk Type], 
       CAST((SUM(mc.pages_kb)/1024.0) AS DECIMAL (15,2)) AS [Memory Usage (MB)] 
FROM sys.dm_os_memory_clerks AS mc WITH (NOLOCK)
GROUP BY mc.[type]  
ORDER BY SUM(mc.pages_kb) DESC OPTION (RECOMPILE);
------





-- Top Cached SPs By Total Logical Writes (Query 68) (SP Logical Writes)
-- Logical writes relate to both memory and disk I/O pressure 
SELECT TOP(25) CONCAT(SCHEMA_NAME(p.schema_id), '.', p.name) AS [SP Name], qs.total_logical_writes AS [TotalLogicalWrites], 
qs.total_logical_writes/qs.execution_count AS [AvgLogicalWrites], qs.execution_count,
ISNULL(qs.execution_count/DATEDIFF(Minute, qs.cached_time, GETDATE()), 0) AS [Calls/Minute],
qs.total_elapsed_time, qs.total_elapsed_time/qs.execution_count AS [avg_elapsed_time],
CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2 LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index], 
CONVERT(nvarchar(25), qs.last_execution_time, 20) AS [Last Execution Time],
CONVERT(nvarchar(25), qs.cached_time, 20) AS [Plan Cached Time]
-- ,qp.query_plan AS [Query Plan] -- Uncomment if you want the Query Plan 
FROM sys.procedures AS p WITH (NOLOCK)
INNER JOIN sys.dm_exec_procedure_stats AS qs WITH (NOLOCK)
ON p.[object_id] = qs.[object_id]
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.database_id = DB_ID()
AND qs.total_logical_writes > 0
AND DATEDIFF(Minute, qs.cached_time, GETDATE()) > 0
ORDER BY qs.total_logical_writes DESC OPTION (RECOMPILE);
------

