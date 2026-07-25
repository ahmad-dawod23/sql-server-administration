-----------------------------------------------------------------------
-- BUFFER POOL & MEMORY ANALYSIS
-- Purpose : Understand how SQL Server uses memory — per-database
--           buffer pool breakdown, object-level memory usage,
--           memory clerks, and memory grants.
-- Safety  : All queries are read-only. Some may be CPU-intensive
--           on instances with very large buffer pools.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- OVERVIEW: MEMORY PRESSURE — CONCEPTS & TRIAGE WORKFLOW
-----------------------------------------------------------------------
-- Memory issues are best diagnosed holistically — hardware/OS metrics
-- and internal SQL Server memory structures should all be reviewed.
-- Pressure here often surfaces as secondary bottlenecks in I/O
-- (paging) or CPU (management overhead).
--
-- Types of memory pressure:
--   * External — the OS or other processes (SSIS, SSRS, antivirus,
--     etc.) compete for physical RAM, signaling SQL Server to trim
--     its usage.
--   * Internal — SQL Server components (plan cache, query memory
--     grants) compete for space within the buffer pool itself.
--
-- Key indicators, and where to find them below:
--   * Page Life Expectancy (PLE)                  -> Section 5
--   * Buffer Cache Hit Ratio (>=90%, ideally 99%)  -> 1.4
--   * Target vs. Total Server Memory               -> 4.1
--   * OS memory state / Available Physical Memory  -> 4.2
--   * RESOURCE_SEMAPHORE / CMEMTHREAD waits         -> Section 6
--   * Error 17890 "paged out" in the error log      -> 10.2
--
-- Suggested triage order:
--   1. Rule out OS-level pressure (4.2) — low available memory means
--      another process may be starving SQL Server of RAM.
--   2. Check RESOURCE_SEMAPHORE waits (6.1); if elevated, find the
--      expensive queries driving memory grants (3.4).
--   3. Check plan cache bloat via CACHESTORE_SQLCP (2.1/2.3) — ad hoc,
--      non-parameterized workloads can consume large amounts of memory.
--   4. Look for poorly indexed queries causing large scans that flush
--      the buffer pool and drive down PLE — missing indexes often
--      "fix" a perceived memory problem more than adding RAM does.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: BUFFER POOL USAGE
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 BUFFER POOL USAGE BY DATABASE
--     Shows how much memory each database consumes in the buffer pool.
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
-- 1.2 BUFFER POOL USAGE BY OBJECT (current database)
--     Identifies which tables/indexes consume the most memory.
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
-- 1.3 DIRTY PAGES IN BUFFER POOL
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

-----------------------------------------------------------------------
-- 1.4 BUFFER CACHE HIT RATIO
--     How often SQL Server finds data pages in buffer cache.
--     Target: As close to 100 as possible.
--     Low ratio may indicate memory pressure.
-----------------------------------------------------------------------
SELECT
    [counter_name]   = RTRIM([counter_name]),
    [cntr_value],
    [instance_name],
    CASE
        WHEN [counter_name] = 'Buffer cache hit ratio' 
        THEN CAST([cntr_value] AS VARCHAR(10)) + ' %'
        ELSE CAST([cntr_value] AS VARCHAR(10))
    END AS FormattedValue
FROM sys.dm_os_performance_counters
WHERE [counter_name] IN ('Page life expectancy', 'Buffer cache hit ratio', 'Buffer cache hit ratio base')
  AND [object_name] NOT LIKE '%Partition%'
  AND [object_name] NOT LIKE '%Node%';

-----------------------------------------------------------------------
-- SECTION 2: MEMORY CLERKS & ALLOCATIONS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 MEMORY CLERKS — top consumers
--     Shows where SQL Server allocates memory beyond the buffer pool
--     (plan cache, lock manager, columnstore, etc.).
--     Look for high CACHESTORE_SQLCP = Ad-hoc query plan issue.
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
-- 2.2 PLAN CACHE MEMORY USAGE (by cache type)
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
-- 2.3 AD HOC PLAN CACHE BLOAT CHECK
--     High memory/plan count under CACHESTORE_SQLCP with mostly
--     single-use plans indicates non-parameterized ad hoc queries
--     are bloating the plan cache. Consider enabling
--     'Optimize for Ad Hoc Workloads'.
-----------------------------------------------------------------------
SELECT
    CAST(SUM(size_in_bytes) / 1048576.0 AS DECIMAL(18,2)) AS AdHocPlanCacheMB,
    COUNT(*)                                              AS AdHocPlanCount,
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)        AS SingleUsePlans,
    CAST(100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                      AS SingleUsePct
FROM sys.dm_exec_cached_plans
WHERE cacheobjtype = 'Compiled Plan'
  AND objtype = 'Adhoc';

SELECT
    [name],
    value_in_use                                          AS OptimizeForAdHocWorkloadsEnabled
FROM sys.configurations
WHERE [name] = 'optimize for ad hoc workloads';

-----------------------------------------------------------------------
-- SECTION 3: MEMORY GRANTS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 MEMORY GRANTS PENDING
--     Queries waiting for memory grants indicate memory pressure.
-----------------------------------------------------------------------
SELECT
    cntr_value AS MemoryGrantsPending
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Memory Manager%'
  AND counter_name = 'Memory Grants Pending';

-----------------------------------------------------------------------
-- 3.2 CURRENT MEMORY GRANTS
--     Shows granted memory for active queries.
--     Useful for identifying queries with large memory grants.
-----------------------------------------------------------------------
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
-- 3.3 MEMORY GRANTS WITH QUERY TEXT
--     Shows waiting or recently granted memory with query details.
--     Run multiple times to identify patterns.
-----------------------------------------------------------------------
SELECT
    DB_NAME(st.dbid)         AS DatabaseName,
    mg.requested_memory_kb,
    mg.ideal_memory_kb,
    mg.request_time,
    mg.grant_time,
    mg.query_cost,
    mg.dop,
    st.[text]                AS QueryText
FROM sys.dm_exec_query_memory_grants AS mg
    CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS st
WHERE mg.request_time < COALESCE(grant_time, '99991231')
ORDER BY mg.requested_memory_kb DESC;

-----------------------------------------------------------------------
-- 3.4 TOP QUERIES BY MEMORY GRANT (historical, from plan cache)
--     Identifies cached queries with the largest memory grants —
--     useful when RESOURCE_SEMAPHORE waits are elevated (Section 6).
-----------------------------------------------------------------------
SELECT TOP 25
    DB_NAME(qt.dbid)                                       AS DatabaseName,
    qs.execution_count,
    CAST(qs.total_grant_kb / 1024.0 AS DECIMAL(18,2))     AS TotalGrantMB,
    CAST(qs.total_grant_kb / 1024.0 / qs.execution_count
         AS DECIMAL(18,2))                                AS AvgGrantMB,
    CAST(qs.max_grant_kb / 1024.0 AS DECIMAL(18,2))       AS MaxGrantMB,
    qs.total_spills,
    SUBSTRING(qt.[text], (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
             WHEN -1 THEN DATALENGTH(qt.[text])
             ELSE qs.statement_end_offset END
          - qs.statement_start_offset) / 2) + 1)           AS QueryText
FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qs.total_grant_kb > 0
ORDER BY qs.total_grant_kb DESC;

-----------------------------------------------------------------------
-- SECTION 4: MEMORY TARGETS & SYSTEM MEMORY
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 MEMORY TARGETS AND CURRENT USAGE
--     Committed vs. target memory — should be close in steady state.
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
-- 4.2 OS MEMORY STATUS
--     Operating system level memory availability.
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
    CAST(total_page_file_kb / 1024.0 - total_physical_memory_kb / 1024.0
         AS DECIMAL(18,2))                        AS PhysicalPageFileSizeMB,
    CAST(system_cache_kb / 1024.0
         AS DECIMAL(18,2))                        AS SystemCacheMB,
    system_memory_state_desc                      AS SystemMemoryState
FROM sys.dm_os_sys_memory;

-----------------------------------------------------------------------
-- 4.3 PROCESS MEMORY (SQL Server process-level view)
--     Shows whether locked pages is enabled, among other things.
-----------------------------------------------------------------------
SELECT
    CAST(physical_memory_in_use_kb / 1024.0
         AS DECIMAL(18,2))                        AS PhysicalMemoryInUseMB,
    CAST(locked_page_allocations_kb / 1024.0
         AS DECIMAL(18,2))                        AS LockedPagesMB,
    CAST(large_page_allocations_kb / 1024.0
         AS DECIMAL(18,2))                        AS LargePagesMB,
    CAST(virtual_address_space_committed_kb / 1024.0
         AS DECIMAL(18,2))                        AS VASCommittedMB,
    CAST(virtual_address_space_available_kb / 1024.0
         AS DECIMAL(18,2))                        AS VASAvailableMB,
    CAST(available_commit_limit_kb / 1024.0
         AS DECIMAL(18,2))                        AS AvailableCommitLimitMB,
    page_fault_count,
    memory_utilization_percentage,
    process_physical_memory_low,
    process_virtual_memory_low
FROM sys.dm_os_process_memory;

-----------------------------------------------------------------------
-- 4.4 MAX SERVER MEMORY vs. PHYSICAL MEMORY CHECK
--     Verify adequate memory is left for the operating system.
-----------------------------------------------------------------------
SELECT
    CONVERT(DECIMAL(18,2), sm.total_physical_memory_kb / 1048576.0) AS TotalPhysicalGB,
    CONVERT(DECIMAL(18,2), CONVERT(BIGINT, c.value_in_use) / 1024.0) AS MaxServerMemoryGB,
    CONVERT(DECIMAL(18,0), (sm.total_physical_memory_kb / 1024.0 - CONVERT(BIGINT, c.value_in_use))) AS MemoryLeftForOSMB,
    CASE
        WHEN CONVERT(BIGINT, c.value_in_use) = 2147483647
            THEN '*** UNLIMITED — CONFIGURE NOW ***'
        WHEN (sm.total_physical_memory_kb / 1024.0 - CONVERT(BIGINT, c.value_in_use)) < 2048
            THEN '*** LESS THAN 2 GB LEFT FOR OS ***'
        WHEN (sm.total_physical_memory_kb / 1024.0 - CONVERT(BIGINT, c.value_in_use)) < 4096
            THEN '* Less than 4 GB left for OS *'
        ELSE 'OK'
    END                                                              AS [Status]
FROM sys.dm_os_sys_memory sm
    CROSS JOIN sys.configurations c
WHERE c.[name] = 'max server memory (MB)';

-----------------------------------------------------------------------
-- SECTION 5: PAGE LIFE EXPECTANCY
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 PAGE LIFE EXPECTANCY (PLE)
--     How long a page stays in the buffer pool (seconds).
--     Low PLE = memory pressure. Baseline varies by buffer pool size.
--     Rule of thumb: PLE should be > (buffer pool GB × 300).
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
-- SECTION 6: MEMORY-RELATED WAIT STATISTICS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 RESOURCE_SEMAPHORE / CMEMTHREAD WAITS
--     RESOURCE_SEMAPHORE = queries queued waiting for a memory grant
--     (a major red flag for memory pressure).
--     CMEMTHREAD = contention for thread-safe memory objects, often
--     caused by a high rate of ad hoc (non-parameterized) queries.
-----------------------------------------------------------------------
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    CAST(wait_time_ms / 1000.0 AS DECIMAL(18,2))          AS WaitTimeSec,
    CASE
        WHEN waiting_tasks_count > 0
        THEN CAST(wait_time_ms * 1.0 / waiting_tasks_count AS DECIMAL(18,2))
        ELSE 0
    END                                                    AS AvgWaitMs
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    'RESOURCE_SEMAPHORE',
    'RESOURCE_SEMAPHORE_QUERY_COMPILE',
    'CMEMTHREAD'
)
ORDER BY wait_time_ms DESC;

-----------------------------------------------------------------------
-- SECTION 7: RING BUFFER MEMORY MONITOR
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 RING BUFFER MEMORY-RELATED USAGE
--     Historical view of memory resource monitor notifications.
-----------------------------------------------------------------------
SELECT
    EventTime,
    record.value('(/Record/ResourceMonitor/Notification)[1]', 'varchar(max)') AS [Type],
    record.value('(/Record/ResourceMonitor/IndicatorsProcess)[1]', 'int')     AS [IndicatorsProcess],
    record.value('(/Record/ResourceMonitor/IndicatorsSystem)[1]', 'int')      AS [IndicatorsSystem],
    record.value('(/Record/MemoryRecord/AvailablePhysicalMemory)[1]', 'bigint') AS [AvailPhysMemKb],
    record.value('(/Record/MemoryRecord/AvailableVirtualAddressSpace)[1]', 'bigint') AS [AvailVASKb]
FROM (
    SELECT
        DATEADD(ss, (-1 * ((cpu_ticks / CONVERT(float, (cpu_ticks / ms_ticks))) - [timestamp]) / 1000), GETDATE()) AS EventTime,
        CONVERT(xml, record) AS record
    FROM sys.dm_os_ring_buffers
        CROSS JOIN sys.dm_os_sys_info
    WHERE ring_buffer_type = 'RING_BUFFER_RESOURCE_MONITOR'
) AS tab
ORDER BY EventTime DESC;

-----------------------------------------------------------------------
-- SECTION 8: COMPREHENSIVE DIAGNOSTICS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 8.1 DBCC MEMORYSTATUS
--     Comprehensive memory diagnostic information — consolidated
--     snapshot of all memory nodes, clerks, and cache states. Useful
--     for identifying specific out-of-memory errors.
--     Reference: http://support.microsoft.com/kb/907877/en-us
-----------------------------------------------------------------------
-- DBCC MEMORYSTATUS;


-----------------------------------------------------------------------
-- SECTION 9: MEMORY DUMP INFORMATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 9.1 MEMORY DUMP FILES — LOCATION, TIME, AND SIZE
--     Get information on location, time and size of any memory dumps 
--     from SQL Server. Memory dumps may indicate crashes or severe errors.
-----------------------------------------------------------------------
SELECT 
    [filename], 
    creation_time, 
    size_in_bytes/1048576.0 AS [Size (MB)]
FROM sys.dm_server_memory_dumps WITH (NOLOCK) 
ORDER BY creation_time DESC OPTION (RECOMPILE);
GO


-----------------------------------------------------------------------
-- SECTION 10: ERROR LOG CHECKS FOR MEMORY PRESSURE
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 10.1 LONG DURATION BUFFER POOL SCANS FROM ERROR LOG
--     Finds buffer pool scans that took more than 10 seconds in the 
--     current SQL Server Error log.
--     This should happen much less often in SQL Server 2022.
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'Buffer pool scan took';
GO

-----------------------------------------------------------------------
-- 10.2 ERROR 17890 CHECK — "PROCESS MEMORY HAS BEEN PAGED OUT"
--     Confirms severe external memory pressure (the OS trimmed SQL
--     Server's working set). Searches the current error log.
-----------------------------------------------------------------------
EXEC sys.xp_readerrorlog 0, 1, N'paged out';
GO

