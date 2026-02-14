-----------------------------------------------------------------------
-- BLOCKING & LOCK CONTENTION ANALYSIS
-- Purpose : Identify head blockers, blocking chains, lock waits,
--           and open transactions causing contention.
-- Safety  : All queries are read-only.
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. HEAD BLOCKER FINDER (comprehensive)
--    Identifies the root session causing a blocking chain.
-----------------------------------------------------------------------
-- query 1
SELECT
   [HeadBlocker] = 
        CASE 
            -- session has an active request, is blocked, but is blocking others
            -- or session is idle but has an open transaction and is blocking others 
            WHEN r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL) THEN '1' 
            -- session is either not blocking someone, or is blocking someone but is blocked by another party 
            ELSE '' 
        END, 
   [SessionID] = s.session_id, 
   [Login] = s.login_name,   
   [Database] = db_name(p.dbid), 
   [BlockedBy] = w.blocking_session_id, 
   [OpenTransactions] = r.open_transaction_count, 
   [Status] = s.status, 
   [WaitType] = w.wait_type, 
   [WaitTime_ms] = w.wait_duration_ms, 
   [WaitResource] = r.wait_resource, 
   [WaitResourceDesc] = w.resource_description, 
   [Command] = r.command, 
   [Application] = s.program_name, 
   [TotalCPU_ms] = s.cpu_time, 
   [TotalPhysicalIO_MB] = (s.reads + s.writes) * 8 / 1024, 
   [MemoryUse_KB] = s.memory_usage * 8192 / 1024, 
   [LoginTime] = s.login_time, 
   [LastRequestStartTime] = s.last_request_start_time, 
   [HostName] = s.host_name,
   [QueryHash] = r.query_hash, 
   [BlockerQuery_or_MostRecentQuery] = txt.text
FROM sys.dm_exec_sessions s 
LEFT OUTER JOIN sys.dm_exec_connections c ON (s.session_id = c.session_id) 
LEFT OUTER JOIN sys.dm_exec_requests r ON (s.session_id = r.session_id) 
LEFT OUTER JOIN sys.dm_os_tasks t ON (r.session_id = t.session_id AND r.request_id = t.request_id) 
LEFT OUTER JOIN 
( 
    SELECT *, ROW_NUMBER() OVER (PARTITION BY waiting_task_address ORDER BY wait_duration_ms DESC) AS row_num 
    FROM sys.dm_os_waiting_tasks 
) w ON (t.task_address = w.waiting_task_address) AND w.row_num = 1 
LEFT OUTER JOIN sys.dm_exec_requests r2 ON (s.session_id = r2.blocking_session_id) 
LEFT OUTER JOIN sys.sysprocesses p ON (s.session_id = p.spid) 
OUTER APPLY sys.dm_exec_sql_text (ISNULL(r.[sql_handle], c.most_recent_sql_handle)) AS txt
WHERE s.is_user_process = 1 
AND (r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL)) 
OR blocked > 0 
ORDER BY [HeadBlocker] desc, s.session_id; 


-- query 2
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
t2.blocking_session_id AS [blocker sid],										-- spid of blocker
(SELECT [text] FROM sys.sysprocesses AS p										-- get sql for blocker
CROSS APPLY sys.dm_exec_sql_text(p.[sql_handle]) 
WHERE p.spid = t2.blocking_session_id) AS [blocker_batch]
FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
INNER JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
ON t1.lock_owner_address = t2.resource_address OPTION (RECOMPILE);


-- query 3

WITH cteHead ( session_id,request_id,wait_type,wait_resource,last_wait_type,is_user_process,request_cpu_time
,request_logical_reads,request_reads,request_writes,wait_time,blocking_session_id,memory_usage
,session_cpu_time,session_reads,session_writes,session_logical_reads
,percent_complete,est_completion_time,request_start_time,request_status,command
,plan_handle,sql_handle,statement_start_offset,statement_end_offset,most_recent_sql_handle
,session_status,group_id,query_hash,query_plan_hash) 
AS ( SELECT sess.session_id, req.request_id, LEFT (ISNULL (req.wait_type, ''), 50) AS 'wait_type'
    , LEFT (ISNULL (req.wait_resource, ''), 40) AS 'wait_resource', LEFT (req.last_wait_type, 50) AS 'last_wait_type'
    , sess.is_user_process, req.cpu_time AS 'request_cpu_time', req.logical_reads AS 'request_logical_reads'
    , req.reads AS 'request_reads', req.writes AS 'request_writes', req.wait_time, req.blocking_session_id,sess.memory_usage
    , sess.cpu_time AS 'session_cpu_time', sess.reads AS 'session_reads', sess.writes AS 'session_writes', sess.logical_reads AS 'session_logical_reads'
    , CONVERT (decimal(5,2), req.percent_complete) AS 'percent_complete', req.estimated_completion_time AS 'est_completion_time'
    , req.start_time AS 'request_start_time', LEFT (req.status, 15) AS 'request_status', req.command
    , req.plan_handle, req.[sql_handle], req.statement_start_offset, req.statement_end_offset, conn.most_recent_sql_handle
    , LEFT (sess.status, 15) AS 'session_status', sess.group_id, req.query_hash, req.query_plan_hash
    FROM sys.dm_exec_sessions AS sess
    LEFT OUTER JOIN sys.dm_exec_requests AS req ON sess.session_id = req.session_id
    LEFT OUTER JOIN sys.dm_exec_connections AS conn on conn.session_id = sess.session_id 
    )
, cteBlockingHierarchy (head_blocker_session_id, session_id, blocking_session_id, wait_type, wait_duration_ms,
wait_resource, statement_start_offset, statement_end_offset, plan_handle, sql_handle, most_recent_sql_handle, [Level])
AS ( SELECT head.session_id AS head_blocker_session_id, head.session_id AS session_id, head.blocking_session_id
    , head.wait_type, head.wait_time, head.wait_resource, head.statement_start_offset, head.statement_end_offset
    , head.plan_handle, head.sql_handle, head.most_recent_sql_handle, 0 AS [Level]
    FROM cteHead AS head
    WHERE (head.blocking_session_id IS NULL OR head.blocking_session_id = 0)
    AND head.session_id IN (SELECT DISTINCT blocking_session_id FROM cteHead WHERE blocking_session_id != 0)
    UNION ALL
    SELECT h.head_blocker_session_id, blocked.session_id, blocked.blocking_session_id, blocked.wait_type,
    blocked.wait_time, blocked.wait_resource, h.statement_start_offset, h.statement_end_offset,
    h.plan_handle, h.sql_handle, h.most_recent_sql_handle, [Level] + 1
    FROM cteHead AS blocked
    INNER JOIN cteBlockingHierarchy AS h ON h.session_id = blocked.blocking_session_id and h.session_id!=blocked.session_id --avoid infinite recursion for latch type of blocking
    WHERE h.wait_type COLLATE Latin1_General_BIN NOT IN ('EXCHANGE', 'CXPACKET') or h.wait_type is null
    )
SELECT bh.*, txt.text AS blocker_query_or_most_recent_query 
FROM cteBlockingHierarchy AS bh 
OUTER APPLY sys.dm_exec_sql_text (ISNULL ([sql_handle], most_recent_sql_handle)) AS txt;


--- query 4

SELECT
	r.session_id,r.plan_handle,r.sql_handle,r.request_id,r.start_time, r.status,r.command, r.database_id,r.user_id, r.wait_type
	,r.wait_time,r.last_wait_type,r.wait_resource, r.total_elapsed_time,r.cpu_time, r.transaction_isolation_level,r.row_count,st.text 
FROM sys.dm_exec_requests r 
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) as st  
WHERE r.blocking_session_id = 0 and r.session_id in (SELECT distinct(blocking_session_id) FROM sys.dm_exec_requests) 
GROUP BY 
	r.session_id, r.plan_handle,r.sql_handle, r.request_id,r.start_time, r.status,r.command, r.database_id,r.user_id, r.wait_type
	,r.wait_time,r.last_wait_type,r.wait_resource, r.total_elapsed_time,r.cpu_time, r.transaction_isolation_level,r.row_count,st.text  
ORDER BY r.total_elapsed_time desc


-----------------------------------------------------------------------
-- 4. SNAPSHOT ISOLATION LEVEL ā ACTIVE TRANSACTIONS
--    Shows which sessions are using snapshot isolation and their
--    version chain traversal.
-----------------------------------------------------------------------
SELECT
    transaction_sequence_num,
    commit_sequence_num,
    is_snapshot,
    t.session_id,
    first_snapshot_sequence_num,
    max_version_chain_traversed,
    elapsed_time_seconds,
    host_name,
    login_name,
    CASE transaction_isolation_level
        WHEN '0' THEN 'Unspecified'
        WHEN '1' THEN 'ReadUncommitted'
        WHEN '2' THEN 'ReadCommitted'
        WHEN '3' THEN 'Repeatable'
        WHEN '4' THEN 'Serializable'
        WHEN '5' THEN 'Snapshot'
    END                          AS transaction_isolation_level
FROM sys.dm_tran_active_snapshot_database_transactions t
    JOIN sys.dm_exec_sessions s
        ON t.session_id = s.session_id
ORDER BY elapsed_time_seconds DESC;

-----------------------------------------------------------------------
-- 5. ACTIVE OPEN TRANSACTIONS
--    Find sessions with uncommitted transactions (potential blocking).
-----------------------------------------------------------------------
SELECT
    SP.SPID,
    SP.open_tran                 AS OpenTransactions,
    SP.status,
    SP.cmd,
    SP.waittype,
    SP.waittime,
    SP.blocked,
    DEST.[text]                  AS SQLCode
FROM sys.sysprocesses SP
    CROSS APPLY sys.dm_exec_sql_text(SP.[SQL_HANDLE]) AS DEST
WHERE SP.open_tran >= 1
ORDER BY SP.open_tran DESC, SP.waittime DESC;
-- Isolate top waits for server instance since last restart or wait statistics clear  (Query 42) (Top Waits)

WITH [Waits] 

AS (SELECT wait_type, wait_time_ms/ 1000.0 AS [WaitS],

          (wait_time_ms - signal_wait_time_ms) / 1000.0 AS [ResourceS],

           signal_wait_time_ms / 1000.0 AS [SignalS],

           waiting_tasks_count AS [WaitCount],

           100.0 *  wait_time_ms / SUM (wait_time_ms) OVER() AS [Percentage],

           ROW_NUMBER() OVER(ORDER BY wait_time_ms DESC) AS [RowNum]

    FROM sys.dm_os_wait_stats WITH (NOLOCK)

    WHERE [wait_type] NOT IN (

	    N'AZURE_IMDS_VERSIONS',

        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',

		N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',

        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',

        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',

		N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',

        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',

        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT', 

		N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',

        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', 

		N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',

		N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',

		N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',

		N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',

		N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',

		N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',

		N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',

		N'PREEMPTIVE_OS_DELETESECURITYCONTEXT', N'PREEMPTIVE_OS_REPORTEVENT',

		N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',

		N'PREEMPTIVE_OS_WRITEFILE', N'PREEMPTIVE_OS_WRITEFILEGATHER',

		N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',

		N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',

		N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',

		N'POPULATE_LOCK_ORDINALS',

        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',

		N'PWAIT_EXTENSIBILITY_CLEANUP_TASK',

		N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',

        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH',

		N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',

		N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',

        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',

        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',

		N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SOS_WORKER_MIGRATION', N'VDI_CLIENT_OTHER',



-- Isolate top waits for server instance since last restart or wait statistics clear  (Query 42) (Top Waits)

WITH [Waits] 

AS (SELECT wait_type, wait_time_ms/ 1000.0 AS [WaitS],

          (wait_time_ms - signal_wait_time_ms) / 1000.0 AS [ResourceS],

           signal_wait_time_ms / 1000.0 AS [SignalS],

           waiting_tasks_count AS [WaitCount],

           100.0 *  wait_time_ms / SUM (wait_time_ms) OVER() AS [Percentage],

           ROW_NUMBER() OVER(ORDER BY wait_time_ms DESC) AS [RowNum]

    FROM sys.dm_os_wait_stats WITH (NOLOCK)

    WHERE [wait_type] NOT IN (

	    N'AZURE_IMDS_VERSIONS',

        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',

		N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',

        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',

        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',

		N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',

        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',

        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT', 

		N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',

        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', 

		N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',

		N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',

		N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',

		N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',

		N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',

		N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',

		N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',

		N'PREEMPTIVE_OS_DELETESECURITYCONTEXT', N'PREEMPTIVE_OS_REPORTEVENT',

		N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',

		N'PREEMPTIVE_OS_WRITEFILE', N'PREEMPTIVE_OS_WRITEFILEGATHER',

		N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',

		N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',

		N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',

		N'POPULATE_LOCK_ORDINALS',

        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',

		N'PWAIT_EXTENSIBILITY_CLEANUP_TASK',

		N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',

        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH',

		N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',

		N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',

        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',

        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',

		N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SOS_WORKER_MIGRATION', N'VDI_CLIENT_OTHER',

		N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',

		N'STARTUP_DEPENDENCY_MANAGER',

		N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',

		N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY',

		N'XE_BUFFERMGR_ALLPROCESSED_EVENT', N'XE_DISPATCHER_JOIN',

        N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT')

    AND waiting_tasks_count > 0)

SELECT

    MAX (W1.wait_type) AS [WaitType],

	CAST (MAX (W1.Percentage) AS DECIMAL (5,2)) AS [Wait Percentage],

	CAST ((MAX (W1.WaitS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgWait_Sec],

    CAST ((MAX (W1.ResourceS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgRes_Sec],

    CAST ((MAX (W1.SignalS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgSig_Sec], 

    CAST (MAX (W1.WaitS) AS DECIMAL (16,2)) AS [Wait_Sec],

    CAST (MAX (W1.ResourceS) AS DECIMAL (16,2)) AS [Resource_Sec],

    CAST (MAX (W1.SignalS) AS DECIMAL (16,2)) AS [Signal_Sec],

    MAX (W1.WaitCount) AS [Wait Count],

	CAST (N'https://www.sqlskills.com/help/waits/' + W1.wait_type AS XML) AS [Help/Info URL]

FROM Waits AS W1

INNER JOIN Waits AS W2

ON W2.RowNum <= W1.RowNum

GROUP BY W1.RowNum, W1.wait_type

HAVING SUM (W2.Percentage) - MAX (W1.Percentage) < 99 -- percentage threshold

OPTION (RECOMPILE);

------





-- Gives you an idea of table sizes, and possible data compression opportunities













-- Get some key table properties (Query 76) (Table Properties)

SELECT OBJECT_NAME(t.[object_id]) AS [ObjectName], p.[rows] AS [Table Rows], p.index_id, 

       p.data_compression_desc AS [Index Data Compression],

       t.create_date, t.lock_on_bulk_load, t.is_replicated, t.has_replication_filter, 

       t.is_tracked_by_cdc, t.lock_escalation_desc, t.is_filetable, 

	   t.is_memory_optimized, t.durability_desc, 

	   t.temporal_type_desc, t.is_remote_data_archive_enabled, t.is_external -- new for SQL Server 2016

FROM sys.tables AS t WITH (NOLOCK)

INNER JOIN sys.partitions AS p WITH (NOLOCK)

ON t.[object_id] = p.[object_id]

WHERE OBJECT_NAME(t.[object_id]) NOT LIKE N'sys%'