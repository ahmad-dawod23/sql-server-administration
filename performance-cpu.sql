-----------------------------------------------------------------------
-- CPU PERFORMANCE ANALYSIS
-- Purpose: Diagnose CPU pressure end to end - identify top CPU-consuming
--          queries (active and cached), compilation overhead, scheduler
--          pressure, kernel vs user CPU time, and the parallelism/ad hoc
--          workload settings most commonly responsible for high CPU.
-- Safety: All queries are read-only except the commented-out example in
--         Section 8.2, which is disabled by default.
-- Applies to: On-prem and Azure SQL MI. Sections carry their own note
--             where platform support differs; anything not tagged runs
--             on both. Requires VIEW SERVER STATE.
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

-----------------------------------------------------------------------
-- OVERVIEW: CPU PRESSURE CONCEPTS & DIAGNOSTIC METHODOLOGY
-----------------------------------------------------------------------
-- SQL Server hitting sustained high CPU is usually an imbalance between
-- workload demand and available processing power. A high value is only
-- a "problem" when it persists long enough to affect query response times.
--
-- Common causes of high CPU consumption:
--   * Non-optimized queries - scans instead of seeks (missing indexes,
--     stale statistics) force the CPU to process far more data than needed.
--   * Excessive compilations/recompilations - ad hoc, non-parameterized
--     queries flood the plan cache with single-use plans; every unique
--     query must be compiled at least once, which is CPU-intensive.
--     Recompiles are also triggered by frequent schema/statistics changes.
--   * Parallelism bottlenecks - a Cost Threshold for Parallelism that is
--     too low (default 5) lets small queries go parallel unnecessarily,
--     adding thread-coordination overhead and CXPACKET waits.
--   * Inefficient T-SQL - cursors (row-by-row), scalar UDFs, and complex
--     JSON/XML parsing burn CPU cycles because the engine interprets
--     code instead of using set-based logic.
--   * Resource contention - "death by a thousand cuts": a very high volume
--     of small, individually-cheap requests cumulatively exhausts the CPU.
--   * External factors - other processes on the host (AV, IIS), or in
--     virtualized environments a "noisy neighbor" VM / host overcommitment.
--
-- Diagnostic approach (see the numbered sections below for the queries):
--   1. Confirm the basics - Section 3.3 (are all cores actually online?)
--   2. Wait stats        - Section 6 (signal vs resource waits, CPU waits)
--   3. Perf counters     - Section 3.2 (compiles/recompiles), Section 4
--   4. Expensive queries - Section 1 (real-time), Section 2 (historical)
--   5. CPU history       - Section 4.1 (ring buffer)
--   6. Scheduler pressure - Section 3.1 (runnable/pending task counts)
--   7. Thread-level      - Section 7 (when no query looks expensive)
--   8. Config/mitigation - Section 8 (parallelism & ad hoc settings)
--
-- Rule-of-thumb thresholds:
--   * Processor: % Processor Time sustained > 80-90% = bottleneck.
--   * Processor Queue Length sustained > 2 per core = CPU can't keep up.
--   * SQL Compilations/sec > 100/sec (relative to batch requests/sec)
--     suggests an ad hoc workload problem.
--   * Signal wait time > 15-25% of total wait time = CPU pressure.
--   * Processor: % Privileged (kernel) Time consistently > 30% suggests
--     memory pressure, driver issues, or an I/O subsystem problem rather
--     than the SQL Server workload itself (see Section 4.2).
--
-- Mitigation strategies (cheapest/highest-impact first):
--   * Query & index tuning - turn scans into seeks; this is the most
--     cost-effective fix and should be tried before anything else.
--   * Tune parallelism - raise Cost Threshold for Parallelism (e.g. 50)
--     and set MAXDOP appropriately (Section 8).
--   * Enable "optimize for ad hoc workloads" to avoid caching full plans
--     for single-use ad hoc statements (Section 8).
--   * Parameterize queries / use stored procs to encourage plan reuse.
--   * Resource Governor (Enterprise) to cap CPU bandwidth per workload.
--   * Scale up (faster cores, more cache) or add RAM to raise the buffer
--     cache hit ratio, which indirectly reduces CPU spent on physical I/O.
--   * Host optimization - Windows power plan = High Performance; use CPU
--     reservations in virtualized environments to avoid noisy neighbors.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: REAL-TIME ACTIVE CPU QUERIES
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 TOP 10 ACTIVE CPU QUERIES BY SESSION
--     Shows currently executing queries ordered by CPU time.
-----------------------------------------------------------------------
SELECT TOP 10
    req.session_id, 
    req.start_time, 
    req.cpu_time AS cpu_time_ms, 
    OBJECT_NAME(st.objectid, st.dbid) AS ObjectName,  
    SUBSTRING(
        REPLACE(REPLACE(
            SUBSTRING(st.text, (req.statement_start_offset/2) + 1,   
                ((CASE statement_end_offset
                    WHEN -1 THEN DATALENGTH(st.text)   
                    ELSE req.statement_end_offset 
                END - req.statement_start_offset)/2) + 1), 
            CHAR(10), ' '), 
        CHAR(13), ' '), 
    1, 512) AS statement_text   
FROM sys.dm_exec_requests AS req   
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st 
WHERE req.session_id <> @@SPID
ORDER BY cpu_time DESC;
GO 

-----------------------------------------------------------------------
-- 1.2 TOP 10 ACTIVE CPU QUERIES AGGREGATED BY QUERY HASH
--     Aggregates CPU consumption for identical queries.
-----------------------------------------------------------------------
SELECT TOP 10 
    GETDATE() AS runtime,  
    query_stats.query_hash,    
    SUM(query_stats.cpu_time) AS Total_Request_Cpu_Time_Ms, 
    SUM(logical_reads) AS Total_Request_Logical_Reads, 
    MIN(start_time) AS Earliest_Request_start_Time, 
    COUNT(*) AS Number_Of_Requests, 
    SUBSTRING(
        REPLACE(REPLACE(MIN(query_stats.statement_text), CHAR(10), ' '), CHAR(13), ' '), 
    1, 256) AS Statement_Text   
FROM (
    SELECT 
        req.*,  
        SUBSTRING(st.text, (req.statement_start_offset/2) + 1, 
            ((CASE statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)   
                ELSE req.statement_end_offset 
            END - req.statement_start_offset)/2) + 1) AS statement_text   
    FROM sys.dm_exec_requests AS req   
        CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
) AS query_stats   
GROUP BY query_hash
ORDER BY Total_Request_Cpu_Time_Ms DESC;
GO 

-----------------------------------------------------------------------
-- 1.3 DETAILED CPU QUERY ANALYSIS WITH EXECUTION PLANS
--     Includes session details and actual/estimated execution plans.
-----------------------------------------------------------------------
SELECT 
    req.session_id, 
    req.status, 
    req.start_time, 
    req.cpu_time AS cpu_time_ms, 
    req.query_hash,
    req.logical_reads,
    req.dop,
    s.login_name,
    s.host_name,
    s.program_name,
    OBJECT_NAME(st.objectid, st.dbid) AS object_name,
    REPLACE(REPLACE(
        SUBSTRING(st.text, (req.statement_start_offset/2) + 1, 
            ((CASE req.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text) 
                ELSE req.statement_end_offset 
            END - req.statement_start_offset)/2) + 1), 
        CHAR(10), ' '), 
    CHAR(13), ' ') AS statement_text,
    qp.query_plan,
    qsx.query_plan AS query_plan_with_in_flight_statistics
FROM sys.dm_exec_requests AS req
    INNER JOIN sys.dm_exec_sessions AS s 
        ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
    OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) AS qp
    OUTER APPLY sys.dm_exec_query_statistics_xml(req.session_id) AS qsx
WHERE req.session_id <> @@SPID
ORDER BY req.cpu_time DESC;
GO

-----------------------------------------------------------------------
-- SECTION 2: HISTORICAL CPU QUERIES (QUERY STORE)
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 TOP 15 CPU CONSUMING QUERIES FROM QUERY STORE (RECENT)
--     Top 15 CPU consuming queries by query hash from last 2 hours.
--     Note: A query hash can have many query IDs if not parameterized properly.
--     Query Store views are DATABASE-scoped - switch to the target database
--     (USE [YourDb]) before running, and ensure Query Store is enabled.
-----------------------------------------------------------------------
WITH AggregatedCPU AS (
    SELECT 
        q.query_hash, 
        SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, 
        SUM(count_executions * avg_cpu_time / 1000.0) /SUM(count_executions) AS avg_cpu_millisec, 
        MAX(rs.max_cpu_time/1000.00) AS max_cpu_millisec, 
        MAX(max_logical_io_reads) AS max_logical_reads, 
        COUNT(DISTINCT p.plan_id) AS number_of_distinct_plans, 
        COUNT(DISTINCT p.query_id) AS number_of_distinct_query_ids, 
        SUM(CASE WHEN rs.execution_type_desc='Aborted' THEN count_executions ELSE 0 END) AS Aborted_Execution_Count, 
        SUM(CASE WHEN rs.execution_type_desc='Regular' THEN count_executions ELSE 0 END) AS Regular_Execution_Count, 
        SUM(CASE WHEN rs.execution_type_desc='Exception' THEN count_executions ELSE 0 END) AS Exception_Execution_Count, 
        SUM(count_executions) AS total_executions, 
        MIN(qt.query_sql_text) AS sampled_query_text 
    FROM sys.query_store_query_text AS qt 
        JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id 
        JOIN sys.query_store_plan AS p ON q.query_id = p.query_id 
        JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id 
        JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id 
    WHERE   
        rs.execution_type_desc IN ('Regular', 'Aborted', 'Exception') AND   
        rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())  
    GROUP BY q.query_hash 
), 
OrderedCPU AS ( 
    SELECT 
        query_hash, 
        total_cpu_millisec, 
        avg_cpu_millisec,
        max_cpu_millisec,  
        max_logical_reads, 
        number_of_distinct_plans, 
        number_of_distinct_query_ids,  
        total_executions, 
        Aborted_Execution_Count,
        Regular_Execution_Count, 
        Exception_Execution_Count, 
        sampled_query_text, 
        ROW_NUMBER() OVER (ORDER BY total_cpu_millisec DESC, query_hash ASC) AS RN 
    FROM AggregatedCPU 
) 
SELECT * 
FROM OrderedCPU OD  
WHERE OD.RN <= 15 
ORDER BY total_cpu_millisec DESC;
GO

-----------------------------------------------------------------------
-- 2.2 TOP 15 CPU CONSUMING CACHED PLANS (CLASSIC DMV, NO QUERY STORE)
--     Uses sys.dm_exec_query_stats so it works even when Query Store
--     is not enabled. Plans age out of cache, so this only reflects
--     activity since the last plan eviction/restart.
--     The last_execution_time filter restricts this to plans still active
--     recently (pairing with 2.1) - widen or comment it out for an
--     all-time view. Note the totals themselves remain cumulative for the
--     life of the plan, not just the filtered window.
-----------------------------------------------------------------------
SELECT TOP 15
    qs.query_hash,
    DB_NAME(t.dbid) AS database_name,
    qs.execution_count,
    qs.total_worker_time AS total_cpu_time_microsec,
    qs.total_worker_time / qs.execution_count AS avg_cpu_time_microsec,
    qs.total_elapsed_time / qs.execution_count AS avg_elapsed_time_microsec,
    qs.total_logical_reads,
    qs.last_execution_time,
    SUBSTRING(
        REPLACE(REPLACE(
            SUBSTRING(t.text, (qs.statement_start_offset/2) + 1,
                ((CASE qs.statement_end_offset
                    WHEN -1 THEN DATALENGTH(t.text)
                    ELSE qs.statement_end_offset
                END - qs.statement_start_offset)/2) + 1),
            CHAR(10), ' '),
        CHAR(13), ' '),
    1, 256) AS statement_text
FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.last_execution_time >= DATEADD(HOUR, -2, GETDATE())
ORDER BY qs.total_worker_time DESC;
GO

-----------------------------------------------------------------------
-- SECTION 3: CPU SCHEDULER & TASK ANALYSIS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 GET AVERAGE TASK COUNTS (Run Multiple Times)
--     Shows scheduler pressure and CPU workload distribution.
--     Run multiple times to identify trends and spikes.
-----------------------------------------------------------------------
SELECT 
    AVG(current_tasks_count) AS [Avg_Task_Count], 
    AVG(work_queue_count) AS [Avg_Work_Queue_Count],
    AVG(runnable_tasks_count) AS [Avg_Runnable_Task_Count],
    AVG(pending_disk_io_count) AS [Avg_Pending_DiskIO_Count],
    GETDATE() AS [System_Time]
FROM sys.dm_os_schedulers
WHERE scheduler_id < 255  -- Exclude hidden schedulers
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 3.2 COMPILATION / RECOMPILATION PRESSURE
--     High SQL Compilations/sec or Re-Compilations/sec relative to Batch
--     Requests/sec points to an ad hoc, non-parameterized workload flooding
--     the plan cache (see Section 8 for the 'optimize for ad hoc workloads'
--     mitigation). Values are cumulative since the last service restart -
--     run twice a few seconds apart and diff them to get a rate.
-----------------------------------------------------------------------
SELECT 
    object_name,
    counter_name,
    cntr_value,
    GETDATE() AS sample_time
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
    'SQL Compilations/sec',
    'SQL Re-Compilations/sec',
    'Batch Requests/sec'
)
ORDER BY counter_name;
GO

-----------------------------------------------------------------------
-- 3.3 CPU / SCHEDULER CONFIGURATION SANITY CHECK
--     Run this FIRST when investigating high CPU. Confirms SQL Server is
--     actually scheduling on every core the OS reports. Schedulers stuck
--     in VISIBLE OFFLINE mean cores are being ignored - usually an edition
--     core limit (Standard caps at the lesser of 4 sockets / 24 cores), an
--     ALTER SERVER CONFIGURATION SET PROCESS AFFINITY setting, or a
--     licensing mismatch. Tuning queries is pointless if the instance is
--     only using half the box.
--     Note: softnuma_configuration_desc requires SQL Server 2016+.
-----------------------------------------------------------------------
SELECT
    cpu_count AS logical_cpu_count,
    scheduler_count,
    hyperthread_ratio AS logical_cores_per_socket,
    cpu_count / NULLIF(hyperthread_ratio, 0) AS physical_socket_count,
    max_workers_count,
    affinity_type_desc,
    softnuma_configuration_desc,
    virtual_machine_type_desc,
    sqlserver_start_time
FROM sys.dm_os_sys_info;
GO

-- Scheduler states: any VISIBLE OFFLINE rows mean cores are not being used.
SELECT
    [status],
    COUNT(*) AS scheduler_count,
    SUM(current_tasks_count) AS current_tasks,
    SUM(runnable_tasks_count) AS runnable_tasks
FROM sys.dm_os_schedulers
GROUP BY [status]
ORDER BY [status];
GO

-----------------------------------------------------------------------
-- SECTION 4: SQL SERVER INSTANCE CPU UTILIZATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 SQL SERVER INSTANCE CPU UTILIZATION HISTORY
--     Shows SQL Server vs Other process CPU utilization over time.
--     Adjust @lastNmin to change time window.
--     Applies to: On-prem and Azure SQL MI (sys.dm_os_ring_buffers is not
--     available in Azure SQL Database). The ring buffer holds roughly the
--     last 256 one-minute samples, so it cannot look back further.
-----------------------------------------------------------------------
DECLARE @ts BIGINT;
DECLARE @lastNmin TINYINT;
SET @lastNmin = 100;

SELECT @ts = (SELECT cpu_ticks / (cpu_ticks / ms_ticks) FROM sys.dm_os_sys_info); 

SELECT TOP(@lastNmin)
    SQLProcessUtilization AS [SQLServer_CPU_Utilization], 
    SystemIdle AS [System_Idle_Process], 
    100 - SystemIdle - SQLProcessUtilization AS [Other_Process_CPU_Utilization], 
    DATEADD(ms, -1 * (@ts - [timestamp]), GETDATE()) AS [Event_Time] 
FROM (
    SELECT 
        record.value('(./Record/@id)[1]', 'int') AS record_id, 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS [SystemIdle], 
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS [SQLProcessUtilization], 
        [timestamp]      
    FROM (
        SELECT [timestamp], CONVERT(XML, record) AS [record]             
        FROM sys.dm_os_ring_buffers             
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' 
            AND record LIKE '%<SystemHealth>%'
    ) AS x 
) AS y 
ORDER BY record_id DESC;
GO

-----------------------------------------------------------------------
-- 4.2 KERNEL (PRIVILEGED) TIME VS USER TIME ACROSS SQL SERVER THREADS
--     Kernel time = CPU spent servicing OS/kernel work (I/O requests,
--     interrupts, paging); User time = CPU spent running SQL Server
--     itself. If Percent_Kernel_Time is consistently > 30%, suspect
--     memory pressure (heavy paging), a slow/overloaded I/O subsystem,
--     or outdated device drivers rather than the SQL workload itself.
--     Note: this covers SQL Server's own threads only (not the whole host),
--     and the totals are cumulative since each thread started. The raw
--     kernel/usermode columns are counter units - only the percentages
--     below are meaningful, since the units cancel out.
--     Applies to: On-prem primarily; sys.dm_os_threads may be restricted
--     on Azure SQL MI depending on permissions.
-----------------------------------------------------------------------
SELECT 
    SUM(kernel_time) AS total_kernel_time_raw,
    SUM(usermode_time) AS total_usermode_time_raw,
    CAST(100.0 * SUM(kernel_time) / NULLIF(SUM(kernel_time) + SUM(usermode_time), 0) AS DECIMAL(5,2)) AS percent_kernel_time,
    CAST(100.0 * SUM(usermode_time) / NULLIF(SUM(kernel_time) + SUM(usermode_time), 0) AS DECIMAL(5,2)) AS percent_usermode_time
FROM sys.dm_os_threads;
GO

-----------------------------------------------------------------------
-- SECTION 5: DATABASE-LEVEL CPU ANALYSIS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 DATABASE CPU CONSUMPTION SNAPSHOT AND DELTA
--     Shows CPU consumption by database with delta analysis.
--     Takes two snapshots 10 seconds apart to show CPU rate.
--     Caveats: attribution is per cached plan, so ad hoc/dynamic SQL may be
--     credited to the connection's database rather than the object's, and
--     plans evicted between the two snapshots can skew (even negate) deltas.
-----------------------------------------------------------------------
-- First snapshot
IF OBJECT_ID('tempdb.dbo.#tbl', 'U') IS NOT NULL
    DROP TABLE #tbl;

WITH DB_CPU AS (
    SELECT 
        DatabaseID, 
        DB_Name(DatabaseID) AS [DatabaseName], 
        SUM(total_worker_time) AS [CPU_Time_Microsec] 
    FROM sys.dm_exec_query_stats AS qs 
        CROSS APPLY (
            SELECT CONVERT(INT, value) AS [DatabaseID]  
            FROM sys.dm_exec_plan_attributes(qs.plan_handle)  
            WHERE attribute = N'dbid'
        ) AS epa 
    GROUP BY DatabaseID
) 
SELECT 
    GETDATE() AS reportedtime,
    ROW_NUMBER() OVER(ORDER BY [CPU_Time_Microsec] DESC) AS [SNO], 
    DatabaseName AS [DBName], 
    [CPU_Time_Microsec], 
    CAST([CPU_Time_Microsec] * 1.0 / SUM([CPU_Time_Microsec]) OVER() * 100.0 AS DECIMAL(5, 2)) AS [CPUPercent] 
INTO #tbl
FROM DB_CPU 
WHERE DatabaseID > 4  -- Exclude system databases 
    AND DatabaseID <> 32767  -- Exclude ResourceDB 
ORDER BY SNO 
OPTION(RECOMPILE); 

-- Wait 10 seconds
WAITFOR DELAY '00:00:10';

-- Second snapshot with delta calculation
WITH DB_CPU AS (
    SELECT 
        DatabaseID, 
        DB_Name(DatabaseID) AS [DatabaseName], 
        SUM(total_worker_time) AS [CPU_Time_Microsec] 
    FROM sys.dm_exec_query_stats AS qs 
        CROSS APPLY (
            SELECT CONVERT(INT, value) AS [DatabaseID]  
            FROM sys.dm_exec_plan_attributes(qs.plan_handle)  
            WHERE attribute = N'dbid'
        ) AS epa 
    GROUP BY DatabaseID
) 
SELECT 
    a.DatabaseName AS [DBName], 
    a.[CPU_Time_Microsec] - b.[CPU_Time_Microsec] AS [CPU_Time_Delta_Microsec],
    CAST((a.[CPU_Time_Microsec] - b.[CPU_Time_Microsec]) * 1.0 / NULLIF(SUM((a.[CPU_Time_Microsec] - b.[CPU_Time_Microsec])) OVER(), 0) * 100.0 AS DECIMAL(5, 2)) AS [CPUPercent_Last10Sec] 
FROM DB_CPU a 
    INNER JOIN #tbl b ON a.[DatabaseName] = b.[DBName]
WHERE DatabaseID > 4  -- Exclude system databases 
    AND DatabaseID <> 32767  -- Exclude ResourceDB 
ORDER BY a.[CPU_Time_Microsec] - b.[CPU_Time_Microsec] DESC 
OPTION(RECOMPILE);

-- Cleanup
DROP TABLE IF EXISTS #tbl;
GO

-----------------------------------------------------------------------
-- SECTION 6: CPU PRESSURE INDICATORS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 CPU PRESSURE ANALYSIS VIA WAIT STATISTICS
--     Shows signal waits vs resource waits ratio.
--     High signal waits (>25%) indicate CPU pressure.
--     Note: values are cumulative since the last service restart (or since
--     wait stats were last cleared), so they describe the whole uptime
--     window, not "right now".
-----------------------------------------------------------------------
-- OPTIONAL/DESTRUCTIVE: resets all wait stats instance-wide so the next
-- sample reflects only recent activity. Leave commented out unless you are
-- sure nothing else depends on the existing baseline.
-- DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
-- GO

-- Analyze signal vs resource waits
-- Benign/idle wait types are excluded so background threads parked on
-- SLEEP_*/BROKER_*/XE_* waits do not deflate the signal wait percentage.
SELECT 
    CAST(100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS NUMERIC(20,2)) AS [Percent_Signal_CPU_Waits],
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS NUMERIC(20,2)) AS [Percent_Resource_Waits]
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
    N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
    N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
    N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
    N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
    N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
    N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE',
    N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE', N'KSOURCE_WAKEUP',
    N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', N'MEMORY_ALLOCATION_EXT',
    N'ONDEMAND_TASK_QUEUE', N'PARALLEL_REDO_DRAIN_WORKER',
    N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',
    N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
    N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', N'PREEMPTIVE_XE_GETTARGETSTATE',
    N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
    N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
    N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE',
    N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH',
    N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH',
    N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY',
    N'SLEEP_MASTERMDREADY', N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP',
    N'SLEEP_SYSTEMTASK', N'SLEEP_TASK', N'SLEEP_TEMPDBSTARTUP',
    N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER', N'SP_SERVER_DIAGNOSTICS_SLEEP',
    N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    N'SQLTRACE_WAIT_ENTRIES', N'STARTUP_DEPENDENCY_MANAGER',
    N'WAIT_FOR_RESULTS', N'WAIT_XTP_RECOVERY', N'WAIT_XTP_HOST_WAIT',
    N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE',
    N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'XE_DISPATCHER_JOIN',
    N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT'
);
GO

-----------------------------------------------------------------------
-- 6.2 TOP CPU-RELATED WAIT TYPES
--     SOS_SCHEDULER_YIELD: workers voluntarily yielding the CPU but
--       taking a long time to return from the runnable queue - classic
--       CPU pressure signal.
--     CXPACKET/CXCONSUMER: parallelism coordination overhead - review
--       Cost Threshold for Parallelism / MAXDOP (Section 8) if excessive.
--     THREADPOOL: worker thread exhaustion.
--     RESOURCE_SEMAPHORE_QUERY_COMPILE: compilation throttling under
--       memory/CPU pressure from too many concurrent compiles.
-----------------------------------------------------------------------
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS DECIMAL(5,2)) AS percent_signal_wait
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    'SOS_SCHEDULER_YIELD', 'CXPACKET', 'CXCONSUMER',
    'THREADPOOL', 'RESOURCE_SEMAPHORE_QUERY_COMPILE'
)
ORDER BY wait_time_ms DESC;
GO

-----------------------------------------------------------------------
-- SECTION 7: PERFMON/THREAD-LEVEL TROUBLESHOOTING
-- Applies to: On-prem (Windows). Perfmon steps do not apply to Azure SQL MI;
--             query 7.2 works anywhere sys.dm_os_threads is exposed.
-----------------------------------------------------------------------

/*
-----------------------------------------------------------------------
-- 7.1 PERFMON APPROACH FOR THREAD-LEVEL ANALYSIS
--     Manual steps to identify the OS thread burning CPU. Use this when
--     CPU is high but Sections 1-2 show no obviously expensive query -
--     it can expose background/system threads (log writer, ghost cleanup,
--     lazy writer, external CLR) rather than user workload.
-----------------------------------------------------------------------

STEP 1: Launch Perfmon
    - Type 'perfmon' in Windows CMD or launch from Control Panel
    - Click "Add counters" and select "Thread" object
    - Select these counters simultaneously:
        * % Processor Time
        * ID Thread
        * Thread State
        * Thread Wait Reason
    - Select all instances beginning with "sqlservr"

STEP 2: Change to Report View
    - Press Ctrl+R or click "View Report" tab

STEP 3: Identify Problem Thread
    - Note the "ID Thread" and "% Processor Time" values
    - Find the thread with highest CPU usage

STEP 4: Feed that "ID Thread" value into query 7.2 below, which maps the
        OS thread all the way through to the session and query text.
*/

-----------------------------------------------------------------------
-- 7.2 MAP OS THREADS TO WORKERS, SESSIONS AND QUERY TEXT
--     Modern replacement for the deprecated sys.sysprocesses spid/kpid
--     correlation. os_thread_id is the same value Perfmon reports as
--     "ID Thread" (step 3 above).
--     Note: kernel_time/usermode_time are cumulative since the thread
--     started, so they identify a persistently hot thread rather than
--     instantaneous CPU. A thread with no session attached is a
--     background/system task.
--     To target one specific thread, uncomment the WHERE clause.
-----------------------------------------------------------------------
SELECT TOP 20
    t.os_thread_id,
    t.kernel_time,
    t.usermode_time,
    t.kernel_time + t.usermode_time AS total_thread_time,
    w.[state] AS worker_state,
    tk.task_state,
    tk.session_id,
    r.status AS request_status,
    r.command,
    r.cpu_time AS request_cpu_time_ms,
    r.wait_type,
    r.open_transaction_count,
    DB_NAME(r.database_id) AS database_name,
    s.login_name,
    s.host_name,
    s.program_name,
    SUBSTRING(
        REPLACE(REPLACE(st.text, CHAR(10), ' '), CHAR(13), ' '),
    1, 256) AS batch_text
FROM sys.dm_os_threads AS t
    LEFT JOIN sys.dm_os_workers AS w
        ON t.worker_address = w.worker_address
    LEFT JOIN sys.dm_os_tasks AS tk
        ON w.task_address = tk.task_address
    LEFT JOIN sys.dm_exec_requests AS r
        ON tk.session_id = r.session_id
    LEFT JOIN sys.dm_exec_sessions AS s
        ON tk.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
-- WHERE t.os_thread_id = {ID_Thread_From_Perfmon}
ORDER BY t.kernel_time + t.usermode_time DESC
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 8: PARALLELISM & AD HOC WORKLOAD CONFIGURATION CHECKS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 8.1 CURRENT PARALLELISM / AD HOC PLAN CACHE SETTINGS
--     Review before changing them:
--       * cost threshold for parallelism - raise from the default of 5
--         (e.g. to 50) so small/cheap queries stay single-threaded.
--       * max degree of parallelism - cap per-query worker threads so
--         one query can't consume all schedulers.
--       * optimize for ad hoc workloads - when enabled, only a small
--         plan stub is cached on first execution of an ad hoc batch,
--         reducing plan cache bloat and recompilation overhead.
-----------------------------------------------------------------------
SELECT 
    name,
    value,
    value_in_use,
    description
FROM sys.configurations
WHERE name IN (
    'cost threshold for parallelism',
    'max degree of parallelism',
    'optimize for ad hoc workloads'
)
ORDER BY name;
GO

-----------------------------------------------------------------------
-- 8.2 EXAMPLE: APPLY RECOMMENDED PARALLELISM / AD HOC SETTINGS
--     Uncomment and adjust values for your workload before running.
--     Requires sysadmin and RECONFIGURE to take effect.
--     Change one setting at a time and measure - these are instance-wide.
--     MAXDOP can also be set per database (ALTER DATABASE SCOPED
--     CONFIGURATION SET MAXDOP) or per query (OPTION (MAXDOP n)).
-----------------------------------------------------------------------
/*
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sp_configure 'cost threshold for parallelism', 50;  -- default is 5
EXEC sp_configure 'max degree of parallelism', 8;         -- tune to workload/NUMA
EXEC sp_configure 'optimize for ad hoc workloads', 1;     -- 0 = off, 1 = on
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- END OF CPU PERFORMANCE ANALYSIS
-----------------------------------------------------------------------