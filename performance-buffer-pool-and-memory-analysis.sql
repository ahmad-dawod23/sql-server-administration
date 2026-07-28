-----------------------------------------------------------------------
-- BUFFER POOL & MEMORY ANALYSIS
-- Purpose : Understand how SQL Server uses memory — per-database
--           buffer pool breakdown, object-level memory usage,
--           memory clerks, and memory grants.
-- Safety  : All queries are read-only. Some may be CPU-intensive
--           on instances with very large buffer pools (see Section 1).
-- Platform: Written for SQL Server (on-prem / IaaS). On Azure SQL
--           Managed Instance and Azure SQL Database, the host-level
--           and error-log queries are unavailable or restricted —
--           notably 1.5, 4.2, 4.3, 4.4, Section 7, 8.1, 9.1 and
--           Section 10. Resource Governor (2.6) is managed by the
--           service on PaaS and is not user-configurable.
--           See sqlmi-specific-queries.sql for PaaS equivalents.
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
--   * Page Life Expectancy (PLE)                   -> Section 5
--   * Buffer Cache Hit Ratio (weak signal, see 1.4) -> 1.4
--   * Target vs. Total Server Memory               -> 4.1
--   * OS memory state / Available Physical Memory  -> 4.2
--   * RESOURCE_SEMAPHORE / CMEMTHREAD waits        -> Section 6
--   * Resource semaphore grant queues              -> 6.2
--   * Error 17890 "paged out" in the error log     -> 10.2
--
-- Memory that is NOT the buffer pool — easy to overlook:
--   * Plan cache / cachestore detail               -> 2.2 - 2.4
--   * In-Memory OLTP (XTP)                         -> 2.5
--   * Resource Governor pool caps                  -> 2.6
--   * Buffer Pool Extension (SSD tier)             -> 1.5
--
-- Suggested triage order:
--   1. Rule out OS-level pressure (4.2) — low available memory means
--      another process may be starving SQL Server of RAM.
--   2. Check RESOURCE_SEMAPHORE waits (6.1) and the semaphore queues
--      (6.2); if elevated, find the expensive queries driving memory
--      grants (3.4). If only ONE Resource Governor pool is starved,
--      the cause is the pool cap (2.6), not the instance.
--   3. Check plan cache bloat via CACHESTORE_SQLCP (2.1/2.3) — ad hoc,
--      non-parameterized workloads can consume large amounts of memory.
--      Confirm which cachestore with 2.4.
--   4. Look for poorly indexed queries causing large scans that flush
--      the buffer pool and drive down PLE — missing indexes often
--      "fix" a perceived memory problem more than adding RAM does.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: BUFFER POOL USAGE
--
-- NOTE: 1.1 - 1.3 each scan sys.dm_os_buffer_descriptors, which holds
-- one row per 8 KB page in cache. On an instance with a large buffer
-- pool (say 256 GB = ~33 million rows) each of these can take tens of
-- seconds and burn CPU. Run them one at a time, off-peak where
-- possible, and avoid running them in a tight monitoring loop.
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
--
--     IMPORTANT: 'Buffer cache hit ratio' is a PERF_LARGE_RAW_FRACTION
--     counter. Its raw cntr_value is NOT a percentage — it must be
--     divided by its matching 'Buffer cache hit ratio base' counter.
--
--     Treat this metric with suspicion. Read-ahead means pages are
--     often already in cache by the time they are "requested", so this
--     ratio sits at 99%+ even on servers with severe memory pressure.
--     PLE (Section 5) and RESOURCE_SEMAPHORE waits (Section 6) are far
--     more reliable indicators. A ratio that is genuinely low is a
--     strong signal; a high one proves nothing.
-----------------------------------------------------------------------
SELECT
    r.[object_name],
    CAST(100.0 * r.cntr_value / NULLIF(b.cntr_value, 0)
         AS DECIMAL(5,2))                         AS BufferCacheHitRatioPct,
    r.cntr_value                                  AS RawValue,
    b.cntr_value                                  AS RawBase
FROM sys.dm_os_performance_counters AS r
    JOIN sys.dm_os_performance_counters AS b
        ON  r.[object_name]  = b.[object_name]
        AND r.instance_name  = b.instance_name
        AND b.counter_name   = 'Buffer cache hit ratio base'
WHERE r.counter_name = 'Buffer cache hit ratio'
  AND r.[object_name] NOT LIKE '%Partition%'
  AND r.[object_name] NOT LIKE '%Node%';

-----------------------------------------------------------------------
-- 1.5 BUFFER POOL EXTENSION (BPE) STATUS
--     BPE spills clean pages to an SSD file to act as a second-tier
--     cache. Enterprise/Standard, SQL Server 2014+.
--     Only useful when the server is RAM-constrained AND the extension
--     file sits on genuinely fast local storage. It caches CLEAN pages
--     only, so it helps read-heavy OLTP and does nothing for writes.
--     Microsoft guidance: size it no more than 4x (Standard) or 32x
--     (Enterprise) max server memory; 4x-8x is the practical sweet spot.
--     Returns no rows when BPE is disabled, which is the norm on
--     modern servers where RAM is cheaper than the complexity.
-----------------------------------------------------------------------
SELECT
    [path]                                        AS ExtensionFilePath,
    [state_description]                           AS [State],
    CAST(current_size_in_kb / 1048576.0
         AS DECIMAL(18,2))                        AS CurrentSizeGB
FROM sys.dm_os_buffer_pool_extension_configuration;

-- Pages currently held in the extension file vs. in RAM.
-- Warning: scans sys.dm_os_buffer_descriptors (see Section 1 note).
SELECT
    CASE WHEN is_in_bpool_extension = 1 THEN 'Extension (SSD)'
         ELSE 'RAM' END                           AS Location,
    COUNT(*)                                      AS PagesInMemory,
    CAST(COUNT(*) * 8.0 / 1024 AS DECIMAL(18,2))  AS SizeMB,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()
         AS DECIMAL(5,2))                         AS PctOfTotal
FROM sys.dm_os_buffer_descriptors
GROUP BY is_in_bpool_extension;

-----------------------------------------------------------------------
-- SECTION 2: MEMORY CLERKS & ALLOCATIONS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 MEMORY CLERKS — top consumers
--     Shows where SQL Server allocates memory beyond the buffer pool
--     (plan cache, lock manager, columnstore, etc.).
--
--     Aggregated by clerk type — sys.dm_os_memory_clerks returns one
--     row per clerk instance per memory node, so an un-grouped TOP N
--     can hide the real biggest consumer behind many small rows.
--
--     What to look for:
--       MEMORYCLERK_SQLBUFFERPOOL — data page cache (normally #1)
--       CACHESTORE_SQLCP          — ad hoc / prepared plans; if large,
--                                   see 2.3
--       CACHESTORE_OBJCP          — stored procedure plans
--       MEMORYCLERK_XTP           — In-Memory OLTP
--       MEMORYCLERK_SQLCLR        — CLR; a common surprise consumer
--       OBJECTSTORE_LOCK_MANAGER  — lock memory; large = escalation or
--                                   long-running transactions
-----------------------------------------------------------------------
SELECT TOP 20
    [type]                                        AS ClerkType,
    COUNT(*)                                      AS ClerkCount,
    CAST(SUM(pages_kb) / 1024.0 AS DECIMAL(18,2)) AS AllocatedMB,
    CAST(100.0 * SUM(pages_kb) / NULLIF(SUM(SUM(pages_kb)) OVER (), 0)
         AS DECIMAL(5,2))                         AS PctOfAllocated,
    CAST(SUM(virtual_memory_reserved_kb) / 1024.0
         AS DECIMAL(18,2))                        AS VirtualReservedMB,
    CAST(SUM(virtual_memory_committed_kb) / 1024.0
         AS DECIMAL(18,2))                        AS VirtualCommittedMB
FROM sys.dm_os_memory_clerks
GROUP BY [type]
ORDER BY AllocatedMB DESC;

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
-- 2.4 CACHE STORE DETAIL
--     Breaks the CACHESTORE_* clerks from 2.1 down into individual
--     caches with entry counts and hit ratios — the level of detail
--     dm_os_memory_clerks cannot give you.
--
--     Common entries:
--       Object Plans / SQL Plans / Bound Trees — the plan cache
--       TokenAndPermUserStore — security token cache. Sustained
--         growth here (multi-GB, millions of entries) is a known
--         issue on servers with heavy cross-database or dynamic SQL
--         under many logins, and shows up as CMEMTHREAD waits.
--       Temporary Tables & Table Variables — large values suggest
--         heavy tempdb object churn.
--
--     A cache with millions of entries and a poor hit ratio is memory
--     being wasted on things nobody reuses.
-----------------------------------------------------------------------
SELECT
    cc.[name]                                     AS CacheName,
    cc.[type]                                     AS CacheType,
    cc.entries_count                              AS Entries,
    cc.entries_in_use_count                       AS EntriesInUse,
    CAST(cc.pages_kb / 1024.0 AS DECIMAL(18,2))   AS AllocatedMB,
    cc.pages_in_use_kb / 1024                     AS InUseMB
FROM sys.dm_os_memory_cache_counters AS cc
WHERE cc.pages_kb > 0
ORDER BY cc.pages_kb DESC;

-- Cache pressure: the clock hands. SQL Server sweeps caches with two
-- "clock hands" to evict entries. Movement of the EXTERNAL hand means
-- eviction driven by overall memory pressure; the INTERNAL hand means
-- that individual cache hit its own size cap. Steadily climbing
-- rounds_count on a cache you care about (e.g. Object Plans) means
-- plans are being thrown away and recompiled.
SELECT
    ch.[name]                                     AS CacheName,
    ch.[type]                                     AS CacheType,
    ch.clock_hand,
    ch.clock_status,
    ch.rounds_count,
    ch.removed_all_rounds_count,
    ch.removed_last_round_count
FROM sys.dm_os_memory_cache_clock_hands AS ch
WHERE ch.rounds_count > 0
ORDER BY ch.removed_all_rounds_count DESC;

-----------------------------------------------------------------------
-- 2.5 IN-MEMORY OLTP (XTP) — MEMORY USAGE
--     Memory-optimized tables live entirely in memory and their data
--     is NOT part of the buffer pool — it is stolen from it. A large
--     MEMORYCLERK_XTP figure in 2.1 is explained here.
--
--     Critical: if an In-Memory OLTP database runs out of memory,
--     INSERTs and UPDATEs FAIL with error 41805 rather than merely
--     slowing down. Always bind memory-optimized databases to a
--     Resource Governor pool (see 2.6) so they cannot starve the rest
--     of the instance, and vice versa.
--     Requires SQL Server 2014+. Returns no rows if XTP is unused.
-----------------------------------------------------------------------
-- Instance-wide XTP allocation. The clerk 'name' identifies the
-- owning database (e.g. 'DB_ID: 7') or an internal XTP structure.
SELECT
    [name]                                        AS ClerkName,
    memory_node_id,
    CAST(pages_kb / 1024.0 AS DECIMAL(18,2))      AS AllocatedMB,
    CAST(virtual_memory_committed_kb / 1024.0
         AS DECIMAL(18,2))                        AS VirtualCommittedMB
FROM sys.dm_os_memory_clerks
WHERE [type] = 'MEMORYCLERK_XTP'
  AND pages_kb > 0
ORDER BY pages_kb DESC;

-- Per-object detail for the CURRENT database.
-- sys.dm_db_xtp_table_memory_stats is database-scoped, so switch
-- context to each memory-optimized database in turn.
SELECT
    SCHEMA_NAME(o.[schema_id])                    AS [Schema],
    OBJECT_NAME(ms.[object_id])                   AS ObjectName,
    CAST(ms.memory_allocated_for_table_kb / 1024.0
         AS DECIMAL(18,2))                        AS TableAllocatedMB,
    CAST(ms.memory_used_by_table_kb / 1024.0
         AS DECIMAL(18,2))                        AS TableUsedMB,
    CAST(ms.memory_allocated_for_indexes_kb / 1024.0
         AS DECIMAL(18,2))                        AS IndexAllocatedMB,
    CAST(ms.memory_used_by_indexes_kb / 1024.0
         AS DECIMAL(18,2))                        AS IndexUsedMB
FROM sys.dm_db_xtp_table_memory_stats AS ms
    JOIN sys.objects AS o ON ms.[object_id] = o.[object_id]
WHERE ms.[object_id] > 0
ORDER BY ms.memory_allocated_for_table_kb DESC;

-----------------------------------------------------------------------
-- 2.6 RESOURCE GOVERNOR POOL MEMORY
--     Resource Governor caps memory per pool. If a pool is capped,
--     queries in it can hit RESOURCE_SEMAPHORE waits (Section 6) while
--     the instance overall looks like it has plenty of free memory —
--     a classic false negative when triaging.
--     'internal' and 'default' pools always exist; extra rows mean
--     someone has configured governance (or bound an In-Memory OLTP
--     database, see 2.5).
-----------------------------------------------------------------------
SELECT
    rp.pool_id,
    rp.[name]                                     AS PoolName,
    rp.min_memory_percent,
    rp.max_memory_percent,
    CAST(rp.max_memory_kb / 1024.0 AS DECIMAL(18,2))        AS MaxMemoryMB,
    CAST(rp.used_memory_kb / 1024.0 AS DECIMAL(18,2))       AS UsedMemoryMB,
    CAST(rp.target_memory_kb / 1024.0 AS DECIMAL(18,2))     AS TargetMemoryMB,
    rp.out_of_memory_count,
    rp.total_memgrant_count,
    rp.total_memgrant_timeout_count
FROM sys.dm_resource_governor_resource_pools AS rp
ORDER BY rp.pool_id;

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
--     Shows waiting and granted memory with query details.
--     grant_time IS NULL = the query is queued waiting for its grant
--     (this is what RESOURCE_SEMAPHORE waits look like in real time).
--     Run repeatedly to identify patterns.
-----------------------------------------------------------------------
SELECT
    mg.session_id,
    DB_NAME(s.database_id)   AS DatabaseName,
    CASE WHEN mg.grant_time IS NULL THEN 'WAITING' ELSE 'GRANTED' END AS GrantState,
    DATEDIFF(SECOND, mg.request_time, COALESCE(mg.grant_time, SYSDATETIME())) AS SecondsToGrant,
    mg.requested_memory_kb,
    mg.granted_memory_kb,
    mg.ideal_memory_kb,
    mg.request_time,
    mg.grant_time,
    mg.query_cost,
    mg.dop,
    mg.wait_order,
    mg.is_next_candidate,
    st.[text]                AS QueryText
FROM sys.dm_exec_query_memory_grants AS mg
    LEFT JOIN sys.dm_exec_sessions AS s
        ON mg.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS st
ORDER BY
    CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END,
    mg.requested_memory_kb DESC;

-----------------------------------------------------------------------
-- 3.4 TOP QUERIES BY MEMORY GRANT (historical, from plan cache)
--     Identifies cached queries with the largest memory grants —
--     useful when RESOURCE_SEMAPHORE waits are elevated (Section 6).
--     A large gap between MaxGrantMB and MaxUsedGrantMB means the
--     optimizer is over-estimating and reserving memory the query
--     never needs — usually stale statistics or bad cardinality
--     estimates. Spills mean the opposite (under-estimation).
--     Requires SQL Server 2016 SP1+ (total_spills: 2016 SP2 / 2017+).
--     NOTE: plan cache only — evicted plans are invisible here. Query
--     Store gives a more complete history where it is enabled.
-----------------------------------------------------------------------
SELECT TOP 25
    DB_NAME(qt.dbid)                                       AS DatabaseName,
    qs.execution_count,
    CAST(qs.total_grant_kb / 1024.0 AS DECIMAL(18,2))      AS TotalGrantMB,
    CAST(qs.total_grant_kb / 1024.0 / qs.execution_count
         AS DECIMAL(18,2))                                 AS AvgGrantMB,
    CAST(qs.max_grant_kb / 1024.0 AS DECIMAL(18,2))        AS MaxGrantMB,
    CAST(qs.max_used_grant_kb / 1024.0 AS DECIMAL(18,2))   AS MaxUsedGrantMB,
    CAST(100.0 * qs.max_used_grant_kb / NULLIF(qs.max_grant_kb, 0)
         AS DECIMAL(5,2))                                  AS GrantUsedPct,
    qs.total_spills,
    qs.last_execution_time,
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
--     Total < Target for a sustained period after warm-up means SQL
--     Server cannot get the memory it wants (external pressure), or
--     the workload simply has not needed it yet.
--     Stolen Server Memory is everything NOT used for data pages
--     (plan cache, memory grants, locks, CLR). Persistently high
--     stolen memory starves the buffer pool and drives PLE down.
-----------------------------------------------------------------------
SELECT
    RTRIM(counter_name)                           AS CounterName,
    CAST(cntr_value / 1024.0 AS DECIMAL(18,2))    AS ValueMB
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
--     Low PLE = memory pressure. The old "300 seconds" rule dates from
--     4 GB servers and is meaningless today, so the threshold below is
--     scaled to the actual buffer pool size:
--         target PLE = (buffer pool GB / 4) * 300
--     Judge PLE by its trend against your own baseline, not by a
--     single reading. A sharp cliff matters more than the absolute
--     number — it usually means one query scanned something large.
--
--     NUMA: this returns the instance-wide 'Buffer Manager' counter.
--     On a NUMA system also check the per-node 'Buffer Node' counters
--     (5.2) — one starved node can be masked by a healthy average.
-----------------------------------------------------------------------
WITH ple AS (
    SELECT cntr_value
    FROM sys.dm_os_performance_counters
    WHERE [object_name] LIKE '%Buffer Manager%'
      AND counter_name = 'Page life expectancy'
),
bp AS (
    SELECT CAST(cntr_value / 1048576.0 AS DECIMAL(18,2)) AS BufferPoolGB
    FROM sys.dm_os_performance_counters
    WHERE [object_name] LIKE '%Memory Manager%'
      AND counter_name = 'Database Cache Memory (KB)'
)
SELECT
    ple.cntr_value                                AS PLE_Seconds,
    CAST(ple.cntr_value / 60.0 AS DECIMAL(10,1))  AS PLE_Minutes,
    bp.BufferPoolGB,
    CAST(300.0 * bp.BufferPoolGB / 4 AS INT)      AS TargetPLE_Seconds,
    CASE
        WHEN ple.cntr_value < (300.0 * bp.BufferPoolGB / 4) / 2 THEN '*** CRITICAL ***'
        WHEN ple.cntr_value <  300.0 * bp.BufferPoolGB / 4      THEN '* Warning *'
        ELSE 'OK'
    END                                           AS [Status]
FROM ple
    CROSS JOIN bp;

-----------------------------------------------------------------------
-- 5.2 PAGE LIFE EXPECTANCY PER NUMA NODE
--     Only meaningful on multi-node NUMA systems. If one node's PLE is
--     far below the others, look at affinity, MAXDOP, and whether a
--     single large query is repeatedly hammering one node.
-----------------------------------------------------------------------
SELECT
    [object_name],
    instance_name                                 AS NumaNode,
    cntr_value                                    AS PLE_Seconds
FROM sys.dm_os_performance_counters
WHERE [object_name] LIKE '%Buffer Node%'
  AND counter_name = 'Page life expectancy'
ORDER BY instance_name;

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
-- 6.2 QUERY RESOURCE SEMAPHORES
--     The other half of the RESOURCE_SEMAPHORE story. Shows the actual
--     memory grant pools and their queues.
--       waiter_count > 0            = queries are queued right now
--       grantee_count near max      = the pool is saturated
--       target_memory < max_target  = SQL has shrunk the grant pool,
--                                     usually due to memory pressure
--     resource_semaphore_id 0 = regular queries, 1 = small queries
--     (< 5 MB grants, which get their own reserved pool).
--     Values are per Resource Governor pool.
-----------------------------------------------------------------------
SELECT
    pool_id,
    resource_semaphore_id,
    CAST(target_memory_kb / 1024.0 AS DECIMAL(18,2))    AS TargetMemoryMB,
    CAST(max_target_memory_kb / 1024.0 AS DECIMAL(18,2)) AS MaxTargetMemoryMB,
    CAST(total_memory_kb / 1024.0 AS DECIMAL(18,2))     AS TotalMemoryMB,
    CAST(available_memory_kb / 1024.0 AS DECIMAL(18,2)) AS AvailableMemoryMB,
    CAST(granted_memory_kb / 1024.0 AS DECIMAL(18,2))   AS GrantedMemoryMB,
    CAST(used_memory_kb / 1024.0 AS DECIMAL(18,2))      AS UsedMemoryMB,
    grantee_count,
    waiter_count,
    timeout_error_count,
    forced_grant_count
FROM sys.dm_exec_query_resource_semaphores
ORDER BY pool_id, resource_semaphore_id;

-----------------------------------------------------------------------
-- SECTION 7: RING BUFFER MEMORY MONITOR
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 RING BUFFER MEMORY-RELATED USAGE
--     Historical view of memory resource monitor notifications.
--     RESOURCE_MEMPHYSICAL_LOW / RESOURCE_MEMVIRTUAL_LOW entries are
--     the smoking gun for external memory pressure — they record the
--     moment the OS told SQL Server to give memory back.
--     Buffer holds ~1024 records and is cleared on restart.
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
        DATEADD(ms, -1 * (si.ms_ticks - rb.[timestamp]), GETDATE()) AS EventTime,
        CONVERT(xml, rb.record) AS record
    FROM sys.dm_os_ring_buffers AS rb
        CROSS JOIN sys.dm_os_sys_info AS si
    WHERE rb.ring_buffer_type = 'RING_BUFFER_RESOURCE_MONITOR'
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
    CAST(size_in_bytes / 1048576.0 AS DECIMAL(18,2)) AS [Size (MB)]
FROM sys.dm_server_memory_dumps
ORDER BY creation_time DESC;
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

