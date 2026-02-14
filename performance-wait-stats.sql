-----------------------------------------------------------------------
-- WAIT STATISTICS ANALYSIS
-- Purpose : Identify top waits on the instance to determine the
--           primary bottleneck (CPU, I/O, memory, locking, network).
--           Wait stats are the #1 starting point for performance triage.
-- Safety  : All queries are read-only. The DBCC SQLPERF command to
--           clear waits is commented out — use only when intentional.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

-----------------------------------------------------------------------
-- 1. TOP WAITS — FILTERED (exclude benign/idle waits)
--    This is the most important query for performance triage.
--    Shows the top waits by cumulative time, excluding waits that
--    are typically harmless (idle, internal, background).
--
--    What to look for:
--      CXPACKET/CXCONSUMER    → Parallelism; check MAXDOP & CTFP
--      PAGEIOLATCH_*          → Storage I/O bottleneck
--      LCK_M_*               → Blocking / locking contention
--      WRITELOG               → Transaction log write latency
--      SOS_SCHEDULER_YIELD    → CPU pressure
--      RESOURCE_SEMAPHORE     → Memory grants exhausted
--      PAGELATCH_*            → In-memory contention (often tempdb)
--      ASYNC_NETWORK_IO       → Client not consuming results fast enough
--      THREADPOOL             → Worker thread exhaustion (critical!)
-----------------------------------------------------------------------

WITH WaitStats AS (
    SELECT
        wait_type,
        wait_time_ms                                        AS TotalWaitMs,
        wait_time_ms - signal_wait_time_ms                  AS ResourceWaitMs,
        signal_wait_time_ms                                 AS SignalWaitMs,
        waiting_tasks_count                                 AS WaitCount,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER()    AS WaitPct,
        ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC)      AS RowNum
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Filter out benign/idle waits
        N'BROKER_EVENTHANDLER',        N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP',           N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER',         N'CHECKPOINT_QUEUE',
        N'CHKPT',                      N'CLR_AUTO_EVENT',
        N'CLR_MANUAL_EVENT',           N'CLR_SEMAPHORE',
        N'DBMIRROR_DBM_EVENT',         N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE',      N'DBMIRRORING_CMD',
        N'DIRTY_PAGE_POLL',            N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC',                   N'FSAGENT',
        N'FT_IFTS_SCHEDULER_IDLE_WAIT',N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL',          N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT',       N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK',            N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP',            N'LAZYWRITER_SLEEP',
        N'LOGMGR_QUEUE',              N'MEMORY_ALLOCATION_EXT',
        N'ONDEMAND_TASK_QUEUE',        N'PARALLEL_REDO_DRAIN_WORKER',
        N'PARALLEL_REDO_LOG_CACHE',    N'PARALLEL_REDO_TRAN_LIST',
        N'PARALLEL_REDO_WORKER_SYNC',  N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS',
        N'PREEMPTIVE_XE_GETTARGETSTATE',
        N'PVS_PREALLOCATE',           N'PWAIT_ALL_COMPONENTS_INITIALIZED',
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',
        N'REDO_THREAD_PENDING_WORK',   N'REQUEST_FOR_DEADLOCK_SEARCH',
        N'RESOURCE_QUEUE',             N'SERVER_IDLE_CHECK',
        N'SLEEP_BPOOL_FLUSH',          N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP',          N'SLEEP_MASTERDBREADY',
        N'SLEEP_MASTERMDREADY',        N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP',          N'SLEEP_SYSTEMTASK',
        N'SLEEP_TASK',                 N'SLEEP_TEMPDBSTARTUP',
        N'SNI_HTTP_ACCEPT',            N'SOS_WORK_DISPATCHER',
        N'SP_SERVER_DIAGNOSTICS_SLEEP',N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        N'SQLTRACE_WAIT_ENTRIES',      N'VDI_CLIENT_OTHER',
        N'WAIT_FOR_RESULTS',           N'WAITFOR',
        N'WAITFOR_TASKSHUTDOWN',       N'WAIT_XTP_CKPT_CLOSE',
        N'WAIT_XTP_HOST_WAIT',         N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        N'WAIT_XTP_RECOVERY',          N'XE_BUFFERMGR_ALLPROCESSED_EVENT',
        N'XE_DISPATCHER_JOIN',         N'XE_DISPATCHER_WAIT',
        N'XE_LIVE_TARGET_TVF',         N'XE_TIMER_EVENT'
    )
    AND waiting_tasks_count > 0
)
SELECT
    MAX(W1.wait_type)                                       AS WaitType,
    CAST(MAX(W1.TotalWaitMs) / 1000.0 AS DECIMAL(16,2))    AS TotalWaitSec,
    CAST(MAX(W1.ResourceWaitMs) / 1000.0 AS DECIMAL(16,2)) AS ResourceWaitSec,
    CAST(MAX(W1.SignalWaitMs) / 1000.0 AS DECIMAL(16,2))   AS SignalWaitSec,
    MAX(W1.WaitCount)                                       AS WaitCount,
    CAST(MAX(W1.WaitPct) AS DECIMAL(5,2))                   AS WaitPct,
    CAST(SUM(W2.WaitPct) AS DECIMAL(5,2))                   AS RunningPct,
    -- Guidance: what does this wait type usually indicate?
    CASE MAX(W1.wait_type)
        WHEN N'CXPACKET'             THEN 'Parallelism — review MAXDOP and Cost Threshold for Parallelism'
        WHEN N'CXCONSUMER'           THEN 'Parallelism consumer — often paired with CXPACKET'
        WHEN N'PAGEIOLATCH_SH'       THEN 'Data page read I/O — check storage latency and buffer pool pressure'
        WHEN N'PAGEIOLATCH_EX'       THEN 'Data page write I/O — check storage latency'
        WHEN N'WRITELOG'             THEN 'Transaction log write latency — check log disk performance'
        WHEN N'IO_COMPLETION'        THEN 'Non-data-page I/O — check storage subsystem'
        WHEN N'SOS_SCHEDULER_YIELD'  THEN 'CPU pressure — queries consuming CPU without yielding'
        WHEN N'RESOURCE_SEMAPHORE'   THEN 'Memory grant waits — queries waiting for memory to execute'
        WHEN N'LCK_M_S'             THEN 'Shared lock wait — blocking on reads'
        WHEN N'LCK_M_X'             THEN 'Exclusive lock wait — blocking on writes'
        WHEN N'LCK_M_IX'            THEN 'Intent exclusive lock wait — blocking contention'
        WHEN N'LCK_M_U'             THEN 'Update lock wait — blocking contention'
        WHEN N'LCK_M_SCH_M'         THEN 'Schema modification lock — DDL blocking'
        WHEN N'LCK_M_SCH_S'         THEN 'Schema stability lock — DDL blocking reads'
        WHEN N'PAGELATCH_EX'         THEN 'In-memory page contention — often tempdb allocation pages'
        WHEN N'PAGELATCH_SH'         THEN 'In-memory page contention — check tempdb config'
        WHEN N'PAGELATCH_UP'         THEN 'In-memory page contention — check tempdb config'
        WHEN N'ASYNC_NETWORK_IO'     THEN 'Client not consuming results fast enough — check app/network'
        WHEN N'THREADPOOL'           THEN '*** CRITICAL: Worker thread exhaustion — increase max worker threads or reduce load ***'
        WHEN N'LATCH_EX'             THEN 'Non-page latch contention — investigate latch class'
        WHEN N'LATCH_SH'             THEN 'Non-page latch contention — investigate latch class'
        WHEN N'OLEDB'                THEN 'OLE DB call — linked servers, DBCC, or DMVs'
        WHEN N'CMEMTHREAD'           THEN 'Memory object contention — may need trace flag 8048'
        WHEN N'TRACEWRITE'           THEN 'Trace/XE write bottleneck'
        WHEN N'PREEMPTIVE_OS_PIPEOPS' THEN 'Named pipe operations — check connectivity'
        ELSE N''
    END                                                      AS Recommendation
FROM WaitStats AS W1
INNER JOIN WaitStats AS W2
    ON W2.RowNum <= W1.RowNum
GROUP BY W1.RowNum
HAVING SUM(W2.WaitPct) - MAX(W1.WaitPct) < 95  -- Show waits up to 95% cumulative
ORDER BY W1.RowNum
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 2. SIGNAL WAIT RATIO
--    Signal wait = time spent waiting for CPU after resource was
--    available. High signal waits (>15-20%) indicate CPU pressure.
--
--    What to look for:
--      Signal % > 20%  → CPU pressure; investigate top CPU queries
--      Signal % < 10%  → CPU is not the bottleneck
-----------------------------------------------------------------------
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0)
         AS DECIMAL(5,2))  AS SignalWaitPct,
    CAST(100.0 * (SUM(wait_time_ms) - SUM(signal_wait_time_ms)) / NULLIF(SUM(wait_time_ms), 0)
         AS DECIMAL(5,2))  AS ResourceWaitPct,
    CASE
        WHEN 100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) > 20
        THEN '*** CPU PRESSURE DETECTED — investigate top CPU queries ***'
        WHEN 100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) > 10
        THEN '* Moderate signal waits — monitor CPU utilization *'
        ELSE 'OK — CPU is not the primary bottleneck'
    END AS Assessment
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    N'SLEEP_TASK', N'WAITFOR', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT',
    N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
    N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
    N'CHKPT', N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT',
    N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
    N'ONDEMAND_TASK_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH',
    N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_SYSTEMTASK',
    N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    N'WAITFOR_TASKSHUTDOWN', N'XE_DISPATCHER_JOIN', N'XE_DISPATCHER_WAIT',
    N'XE_TIMER_EVENT', N'SP_SERVER_DIAGNOSTICS_SLEEP',
    N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'DIRTY_PAGE_POLL',
    N'HADR_WORK_QUEUE', N'HADR_TIMER_TASK', N'HADR_LOGCAPTURE_WAIT',
    N'HADR_NOTIFICATION_DEQUEUE', N'HADR_CLUSAPI_CALL',
    N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE',
    N'PARALLEL_REDO_TRAN_LIST', N'PARALLEL_REDO_WORKER_SYNC',
    N'PARALLEL_REDO_WORKER_WAIT_WORK'
)
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 3. CURRENTLY WAITING TASKS (live snapshot)
--    Shows what sessions are waiting right now and what they're
--    waiting for. Useful during active performance incidents.
-----------------------------------------------------------------------
SELECT
    owt.session_id,
    owt.exec_context_id,
    owt.wait_type,
    owt.wait_duration_ms,
    owt.blocking_session_id,
    owt.resource_description,
    es.login_name,
    es.host_name,
    es.program_name,
    er.command,
    er.status                                     AS RequestStatus,
    DB_NAME(er.database_id)                       AS DatabaseName,
    SUBSTRING(st.[text],
        (er.statement_start_offset / 2) + 1,
        (CASE er.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.[text])
            ELSE er.statement_end_offset
        END - er.statement_start_offset) / 2 + 1) AS CurrentStatement
FROM sys.dm_os_waiting_tasks AS owt
LEFT JOIN sys.dm_exec_sessions AS es
    ON owt.session_id = es.session_id
LEFT JOIN sys.dm_exec_requests AS er
    ON owt.session_id = er.session_id
OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) AS st
WHERE owt.session_id > 50  -- Exclude system sessions
ORDER BY owt.wait_duration_ms DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 4. WAIT STATS SNAPSHOT — DELTA MEASUREMENT
--    Captures two snapshots separated by a delay to measure
--    waits occurring during that specific interval.
--    Adjust the WAITFOR DELAY as needed (default: 30 seconds).
--
--    Use this when cumulative waits are stale or you need to
--    measure the current workload specifically.
-----------------------------------------------------------------------

/*
-- Uncomment this block to run the delta measurement

-- Snapshot 1
IF OBJECT_ID('tempdb..#WaitStats1') IS NOT NULL DROP TABLE #WaitStats1;
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
INTO #WaitStats1
FROM sys.dm_os_wait_stats;

-- Wait interval
WAITFOR DELAY '00:00:30';

-- Snapshot 2 with delta calculation
IF OBJECT_ID('tempdb..#WaitStats2') IS NOT NULL DROP TABLE #WaitStats2;
SELECT
    ws2.wait_type,
    ws2.waiting_tasks_count - ISNULL(ws1.waiting_tasks_count, 0)   AS WaitCount,
    ws2.wait_time_ms - ISNULL(ws1.wait_time_ms, 0)                AS WaitTimeMs,
    ws2.signal_wait_time_ms - ISNULL(ws1.signal_wait_time_ms, 0)   AS SignalWaitMs,
    (ws2.wait_time_ms - ISNULL(ws1.wait_time_ms, 0))
        - (ws2.signal_wait_time_ms - ISNULL(ws1.signal_wait_time_ms, 0)) AS ResourceWaitMs
INTO #WaitStats2
FROM sys.dm_os_wait_stats AS ws2
LEFT JOIN #WaitStats1 AS ws1
    ON ws2.wait_type = ws1.wait_type
WHERE (ws2.wait_time_ms - ISNULL(ws1.wait_time_ms, 0)) > 0;

SELECT TOP 20
    wait_type                                         AS WaitType,
    WaitCount,
    CAST(WaitTimeMs / 1000.0 AS DECIMAL(16,2))        AS WaitTimeSec,
    CAST(ResourceWaitMs / 1000.0 AS DECIMAL(16,2))    AS ResourceWaitSec,
    CAST(SignalWaitMs / 1000.0 AS DECIMAL(16,2))       AS SignalWaitSec,
    CASE
        WHEN WaitCount > 0
        THEN CAST(WaitTimeMs * 1.0 / WaitCount AS DECIMAL(16,2))
        ELSE 0
    END                                                AS AvgWaitMs
FROM #WaitStats2
ORDER BY WaitTimeMs DESC;

-- Cleanup
DROP TABLE #WaitStats1;
DROP TABLE #WaitStats2;
*/


-----------------------------------------------------------------------
-- 5. LATCH WAIT STATISTICS
--    Non-page latches — useful when LATCH_EX or LATCH_SH are in
--    the top waits. Shows which latch class is causing contention.
-----------------------------------------------------------------------
SELECT
    latch_class,
    waiting_requests_count                        AS WaitCount,
    wait_time_ms                                  AS WaitTimeMs,
    CAST(wait_time_ms / 1000.0 AS DECIMAL(16,2))  AS WaitTimeSec,
    max_wait_time_ms                              AS MaxWaitMs,
    CASE latch_class
        WHEN 'BUFFER'            THEN 'Buffer pool page — likely tempdb contention if paired with PAGELATCH'
        WHEN 'ACCESS_METHODS_DATASET_PARENT'  THEN 'Parallel scan coordination'
        WHEN 'FGCB_ADD_REMOVE'   THEN 'File group management — check autogrow events'
        WHEN 'LOG_MANAGER'       THEN 'Log manager — transaction log contention'
        WHEN 'DBCC_MULTIOBJECT_SCANNER' THEN 'DBCC operation in progress'
        ELSE ''
    END                                           AS Notes
FROM sys.dm_os_latch_stats
WHERE waiting_requests_count > 0
  AND latch_class <> N'BUFFER'  -- BUFFER is almost always top; filter if noisy
ORDER BY wait_time_ms DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 6. SPINLOCK STATISTICS (SQL Server 2008 R2 SP2+)
--    Spinlocks are lightweight synchronization objects. High spinlock
--    contention usually indicates very high CPU and concurrency.
-----------------------------------------------------------------------
SELECT
    [name]                                        AS SpinlockName,
    collisions,
    spins,
    spins_per_collision,
    sleep_time,
    backoffs
FROM sys.dm_os_spinlock_stats
WHERE collisions > 0
ORDER BY spins DESC
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 7. CLEAR WAIT STATISTICS (use with caution)
--    Resets cumulative wait stats. Useful for before/after testing
--    or when stats are stale after a long uptime.
--    *** UNCOMMENT AND RUN ONLY INTENTIONALLY ***
-----------------------------------------------------------------------
-- DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR);
-- GO
-- PRINT 'Wait statistics have been cleared at ' + CONVERT(VARCHAR(30), GETDATE(), 121);


-----------------------------------------------------------------------
-- WAIT TYPE QUICK REFERENCE
-----------------------------------------------------------------------
/*
    CATEGORY: STORAGE / I/O
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ Wait Type               │ Meaning                                      │
    ├─────────────────────────┼──────────────────────────────────────────────┤
    │ PAGEIOLATCH_SH/EX       │ Reading/writing data pages from/to disk      │
    │ WRITELOG                 │ Flushing transaction log to disk              │
    │ IO_COMPLETION            │ Non-data-page I/O (sorts, worktables)       │
    │ ASYNC_IO_COMPLETION      │ Async I/O (backups, file operations)        │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: CPU
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ SOS_SCHEDULER_YIELD      │ Query yielding CPU — high volume = pressure │
    │ THREADPOOL               │ No free worker threads (CRITICAL)           │
    │ CXPACKET / CXCONSUMER    │ Parallelism coordination waits              │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: MEMORY
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ RESOURCE_SEMAPHORE       │ Waiting for memory grant to execute query   │
    │ CMEMTHREAD               │ Memory object contention                    │
    │ RESOURCE_SEMAPHORE_QUERY_COMPILE │ Waiting for memory to compile plan │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: LOCKING / BLOCKING
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ LCK_M_S                  │ Waiting for shared lock                     │
    │ LCK_M_X                  │ Waiting for exclusive lock                  │
    │ LCK_M_U                  │ Waiting for update lock                     │
    │ LCK_M_IX                 │ Waiting for intent exclusive lock           │
    │ LCK_M_SCH_M              │ Waiting for schema modification lock        │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: TEMPDB / IN-MEMORY CONTENTION
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ PAGELATCH_EX/SH/UP      │ In-memory page latch — often tempdb PFS/GAM │
    │ LATCH_EX/SH             │ Non-buffer latch contention                  │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: NETWORK / CLIENT
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ ASYNC_NETWORK_IO         │ Client not reading results fast enough      │
    │ PREEMPTIVE_OS_PIPEOPS    │ Named pipe communication wait               │
    └─────────────────────────┴──────────────────────────────────────────────┘

    CATEGORY: AVAILABILITY GROUPS
    ┌─────────────────────────┬──────────────────────────────────────────────┐
    │ HADR_SYNC_COMMIT         │ Waiting for synchronous commit ack          │
    │ HADR_TRANSPORT_SESSION   │ AG transport layer communication            │
    └─────────────────────────┴──────────────────────────────────────────────┘
*/
