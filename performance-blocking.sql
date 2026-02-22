-----------------------------------------------------------------------
-- BLOCKING & LOCK CONTENTION ANALYSIS
-- Purpose : Identify head blockers, blocking chains, lock waits,
--           and open transactions causing contention.
-- Safety  : All queries are read-only (except Section 6).
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

-----------------------------------------------------------------------
-- SECTION 1: HEAD BLOCKER DETECTION
-- Purpose: Identify the root session(s) causing blocking chains
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 HEAD BLOCKER FINDER (Comprehensive)
--     Identifies the root session causing a blocking chain.
--     Shows detailed information about blockers and blocked sessions.
--     Use this for complete analysis with all relevant metrics.
-----------------------------------------------------------------------
SELECT
    [HeadBlocker] = 
        CASE 
            -- Session has an active request, is blocked, but is blocking others
            -- or session is idle but has an open transaction and is blocking others 
            WHEN r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL) THEN '1' 
            -- Session is either not blocking someone, or is blocking someone but is blocked by another party 
            ELSE '' 
        END, 
    [SessionID] = s.session_id, 
    [Login] = s.login_name,   
    [Database] = DB_NAME(p.dbid), 
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
    LEFT OUTER JOIN sys.dm_exec_connections c 
        ON s.session_id = c.session_id
    LEFT OUTER JOIN sys.dm_exec_requests r 
        ON s.session_id = r.session_id
    LEFT OUTER JOIN sys.dm_os_tasks t 
        ON r.session_id = t.session_id AND r.request_id = t.request_id
    LEFT OUTER JOIN ( 
        SELECT *, 
               ROW_NUMBER() OVER (PARTITION BY waiting_task_address ORDER BY wait_duration_ms DESC) AS row_num 
        FROM sys.dm_os_waiting_tasks 
    ) w 
        ON t.task_address = w.waiting_task_address AND w.row_num = 1
    LEFT OUTER JOIN sys.dm_exec_requests r2 
        ON s.session_id = r2.blocking_session_id
    LEFT OUTER JOIN sys.sysprocesses p 
        ON s.session_id = p.spid
    OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.[sql_handle], c.most_recent_sql_handle)) AS txt
WHERE s.is_user_process = 1 
    AND ((r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL)) OR p.blocked > 0)
ORDER BY [HeadBlocker] DESC, s.session_id;
GO

-----------------------------------------------------------------------
-- 1.2 HEAD BLOCKER FINDER (Simple - Session ID Only)
--     Find session IDs that are blocking others but not blocked themselves.
--     Fastest method - returns only the head blocker session ID(s).
--     Use this for quick identification of the root blocker.
-----------------------------------------------------------------------
SELECT DISTINCT 
    blocking_session_id
FROM sys.dm_exec_requests AS r
WHERE NOT EXISTS (
        SELECT 1 
        FROM sys.dm_exec_requests r2
        WHERE r.blocking_session_id = r2.session_id
            AND r2.blocking_session_id > 0
    )
    AND r.blocking_session_id > 0;
GO

-----------------------------------------------------------------------
-- 1.3 HEAD BLOCKER FINDER (With Query Details)
--     Find sessions that are blocking others but not blocked themselves.
--     Includes detailed session and query information.
--     Use this for moderate detail without the full comprehensive view.
-----------------------------------------------------------------------
SELECT
    r.session_id,
    r.plan_handle,
    r.sql_handle,
    r.request_id,
    r.start_time, 
    r.status,
    r.command, 
    r.database_id,
    r.user_id, 
    r.wait_type,
    r.wait_time,
    r.last_wait_type,
    r.wait_resource, 
    r.total_elapsed_time,
    r.cpu_time, 
    r.transaction_isolation_level,
    r.row_count,
    st.text 
FROM sys.dm_exec_requests r 
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS st  
WHERE r.blocking_session_id = 0 
    AND r.session_id IN (
        SELECT DISTINCT blocking_session_id 
        FROM sys.dm_exec_requests
    ) 
GROUP BY 
    r.session_id, r.plan_handle, r.sql_handle, r.request_id, r.start_time, r.status,
    r.command, r.database_id, r.user_id, r.wait_type, r.wait_time, r.last_wait_type,
    r.wait_resource, r.total_elapsed_time, r.cpu_time, r.transaction_isolation_level,
    r.row_count, st.text  
ORDER BY r.total_elapsed_time DESC;
GO

-----------------------------------------------------------------------
-- SECTION 2: BLOCKING CHAIN ANALYSIS
-- Purpose: Understand the complete blocking hierarchy from head to victims
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 BLOCKING CHAIN WITH SQL TEXT
--     Shows blocker and blocked sessions with their SQL statements.
--     Includes wait type and wait duration for each blocked session.
--     Use this for quick view of blocker-blocked pairs with query text.
-----------------------------------------------------------------------
SELECT
    blocking_session.session_id AS blocking_session_id,
    blocked_session.session_id AS blocked_session_id,
    blocking_sql.text AS blocking_sql_text,
    blocked_sql.text AS blocked_sql_text,
    wait_info.wait_type,
    wait_info.wait_duration_ms
FROM sys.dm_exec_requests AS blocked_session
INNER JOIN sys.dm_exec_connections AS blocked_connection
    ON blocked_session.session_id = blocked_connection.session_id
CROSS APPLY sys.dm_exec_sql_text(blocked_connection.most_recent_sql_handle) AS blocked_sql
INNER JOIN sys.dm_exec_requests AS blocking_session
    ON blocked_session.blocking_session_id = blocking_session.session_id
INNER JOIN sys.dm_exec_connections AS blocking_connection
    ON blocking_session.session_id = blocking_connection.session_id
CROSS APPLY sys.dm_exec_sql_text(blocking_connection.most_recent_sql_handle) AS blocking_sql
INNER JOIN sys.dm_os_waiting_tasks AS wait_info
    ON blocked_session.session_id = wait_info.session_id
WHERE blocked_session.blocking_session_id <> 0;
GO

-----------------------------------------------------------------------
-- 2.2 BLOCKING HIERARCHY WITH CTE (Complete Chain)
--     Shows complete blocking chain from head blocker to all victims.
--     Recursively identifies all levels of blocking.
--     Use this for complex multi-level blocking scenarios.
-----------------------------------------------------------------------
WITH cteHead (session_id, request_id, wait_type, wait_resource, last_wait_type, 
    is_user_process, request_cpu_time, request_logical_reads, request_reads, 
    request_writes, wait_time, blocking_session_id, memory_usage, session_cpu_time, 
    session_reads, session_writes, session_logical_reads, percent_complete, 
    est_completion_time, request_start_time, request_status, command, plan_handle, 
    sql_handle, statement_start_offset, statement_end_offset, most_recent_sql_handle, 
    session_status, group_id, query_hash, query_plan_hash) 
AS (
    SELECT 
        sess.session_id, 
        req.request_id, 
        LEFT(ISNULL(req.wait_type, ''), 50) AS wait_type,
        LEFT(ISNULL(req.wait_resource, ''), 40) AS wait_resource, 
        LEFT(req.last_wait_type, 50) AS last_wait_type,
        sess.is_user_process, 
        req.cpu_time AS request_cpu_time, 
        req.logical_reads AS request_logical_reads,
        req.reads AS request_reads, 
        req.writes AS request_writes, 
        req.wait_time, 
        req.blocking_session_id,
        sess.memory_usage,
        sess.cpu_time AS session_cpu_time, 
        sess.reads AS session_reads, 
        sess.writes AS session_writes, 
        sess.logical_reads AS session_logical_reads,
        CONVERT(DECIMAL(5,2), req.percent_complete) AS percent_complete, 
        req.estimated_completion_time AS est_completion_time,
        req.start_time AS request_start_time, 
        LEFT(req.status, 15) AS request_status, 
        req.command,
        req.plan_handle, 
        req.[sql_handle], 
        req.statement_start_offset, 
        req.statement_end_offset, 
        conn.most_recent_sql_handle,
        LEFT(sess.status, 15) AS session_status, 
        sess.group_id, 
        req.query_hash, 
        req.query_plan_hash
    FROM sys.dm_exec_sessions AS sess
        LEFT OUTER JOIN sys.dm_exec_requests AS req 
            ON sess.session_id = req.session_id
        LEFT OUTER JOIN sys.dm_exec_connections AS conn 
            ON conn.session_id = sess.session_id 
),
cteBlockingHierarchy (head_blocker_session_id, session_id, blocking_session_id, 
    wait_type, wait_duration_ms, wait_resource, statement_start_offset, 
    statement_end_offset, plan_handle, sql_handle, most_recent_sql_handle, [Level])
AS (
    SELECT 
        head.session_id AS head_blocker_session_id, 
        head.session_id AS session_id, 
        head.blocking_session_id,
        head.wait_type, 
        head.wait_time, 
        head.wait_resource, 
        head.statement_start_offset, 
        head.statement_end_offset,
        head.plan_handle, 
        head.sql_handle, 
        head.most_recent_sql_handle, 
        0 AS [Level]
    FROM cteHead AS head
    WHERE (head.blocking_session_id IS NULL OR head.blocking_session_id = 0)
        AND head.session_id IN (
            SELECT DISTINCT blocking_session_id 
            FROM cteHead 
            WHERE blocking_session_id != 0
        )
    UNION ALL
    SELECT 
        h.head_blocker_session_id, 
        blocked.session_id, 
        blocked.blocking_session_id, 
        blocked.wait_type,
        blocked.wait_time, 
        blocked.wait_resource, 
        h.statement_start_offset, 
        h.statement_end_offset,
        h.plan_handle, 
        h.sql_handle, 
        h.most_recent_sql_handle, 
        [Level] + 1
    FROM cteHead AS blocked
        INNER JOIN cteBlockingHierarchy AS h 
            ON h.session_id = blocked.blocking_session_id 
            AND h.session_id != blocked.session_id -- Avoid infinite recursion for latch type of blocking
    WHERE h.wait_type COLLATE Latin1_General_BIN NOT IN ('EXCHANGE', 'CXPACKET') 
        OR h.wait_type IS NULL
)
SELECT 
    bh.*, 
    txt.text AS blocker_query_or_most_recent_query 
FROM cteBlockingHierarchy AS bh 
    OUTER APPLY sys.dm_exec_sql_text(ISNULL([sql_handle], most_recent_sql_handle)) AS txt;
GO

-----------------------------------------------------------------------
-- 2.3 VIEW BLOCKED PROCESSES (Summary)
--     Shows all blocked sessions with their status and wait information.
--     Simpler alternative to queries 2.1 and 2.2 for quick overview.
-----------------------------------------------------------------------
SELECT 
    r.session_id, 
    r.status, 
    r.blocking_session_id,
    r.command, 
    r.wait_type, 
    r.wait_time,
    t.text
FROM sys.dm_exec_requests AS r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t 
WHERE r.blocking_session_id > 0;
GO

-----------------------------------------------------------------------
-- SECTION 3: LOCK CONTENTION ANALYSIS
-- Purpose: Analyze lock resources and contention details
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 LOCK CONTENTION BY RESOURCE
--     Shows lock resource types and blocking relationships.
--     Identifies what resources are being locked and who is waiting.
-----------------------------------------------------------------------
SELECT 
    t1.resource_type,
    t1.resource_database_id,
    DB_NAME(t1.resource_database_id) AS database_name,
    t1.resource_associated_entity_id,
    t1.request_mode,
    t1.request_session_id,
    t2.blocking_session_id
FROM sys.dm_tran_locks AS t1
    INNER JOIN sys.dm_os_waiting_tasks AS t2
        ON t1.lock_owner_address = t2.resource_address;
GO

-----------------------------------------------------------------------
-- 3.2 LOCK CONTENTION DETAILS (With Query Text)
--     Shows lock details, wait time, blocker and waiter information.
--     Includes full query text for both waiting and blocking sessions.
--     Run multiple times to catch transient blocking.
-----------------------------------------------------------------------
SELECT 
    t1.resource_type AS [lock_type], 
    DB_NAME(t1.resource_database_id) AS [database],
    t1.resource_associated_entity_id AS [blocked_object],
    t1.request_mode AS [lock_requested], 
    t1.request_session_id AS [waiter_session_id], 
    t2.wait_duration_ms AS [wait_time_ms],
    (SELECT [text] 
     FROM sys.dm_exec_requests AS r WITH (NOLOCK)
         CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) 
     WHERE r.session_id = t1.request_session_id) AS [waiter_batch],
    (SELECT SUBSTRING(qt.[text], r.statement_start_offset/2, 
        (CASE WHEN r.statement_end_offset = -1 
         THEN LEN(CONVERT(NVARCHAR(MAX), qt.[text])) * 2 
         ELSE r.statement_end_offset END - r.statement_start_offset)/2) 
     FROM sys.dm_exec_requests AS r WITH (NOLOCK)
         CROSS APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
     WHERE r.session_id = t1.request_session_id) AS [waiter_statement],
    t2.blocking_session_id AS [blocker_session_id],
    (SELECT [text] 
     FROM sys.sysprocesses AS p
         CROSS APPLY sys.dm_exec_sql_text(p.[sql_handle]) 
     WHERE p.spid = t2.blocking_session_id) AS [blocker_batch]
FROM sys.dm_tran_locks AS t1 WITH (NOLOCK)
    INNER JOIN sys.dm_os_waiting_tasks AS t2 WITH (NOLOCK)
        ON t1.lock_owner_address = t2.resource_address 
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 4: SESSION DETAILS FOR HEAD BLOCKER
-- Purpose: Detailed analysis of head blocker session
-- Note: Use queries from Section 1 to identify the head blocker session ID first
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 HEAD BLOCKER SESSION DETAILS
--     Analyze session information for head blocker.
--     Replace @SessionID with actual session ID from Section 1 queries.
-----------------------------------------------------------------------
DECLARE @SessionID INT = NULL; -- Replace NULL with actual session_id from Section 1

SELECT
    session_id,
    login_time,
    [host_name],
    [program_name],
    login_name,
    [status],
    last_request_start_time,
    last_request_end_time
FROM sys.dm_exec_sessions
WHERE session_id = @SessionID;
GO

-----------------------------------------------------------------------
-- 4.2 HEAD BLOCKER CONNECTION DETAILS
--     Analyze connection information for head blocker.
--     Replace @SessionID with actual session ID from Section 1 queries.
-----------------------------------------------------------------------
DECLARE @SessionID INT = NULL; -- Replace NULL with actual session_id from Section 1

SELECT 
    session_id,
    connect_time,
    client_net_address,
    client_tcp_port,
    most_recent_sql_handle
FROM sys.dm_exec_connections
WHERE session_id = @SessionID;
GO

-----------------------------------------------------------------------
-- 4.3 HEAD BLOCKER QUERY TEXT
--     Get the SQL text being executed by head blocker.
--     Replace @SessionID with actual session ID from Section 1 queries.
-----------------------------------------------------------------------
DECLARE @SessionID INT = NULL; -- Replace NULL with actual session_id from Section 1

SELECT 
    c.session_id,
    t.text AS [query_text]
FROM sys.dm_exec_connections AS c
    CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t 
WHERE c.session_id = @SessionID;
GO

-----------------------------------------------------------------------
-- SECTION 5: SYSTEM-WIDE PERFORMANCE ANALYSIS
-- Purpose: Identify system-wide issues that may contribute to blocking
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 LONG RUNNING PROCESSES
--     Identify long-running active sessions that may be causing issues.
--     Sessions with long batch duration may hold locks for extended periods.
-----------------------------------------------------------------------
SELECT
    p.spid,
    RIGHT(CONVERT(VARCHAR, 
        DATEADD(ms, DATEDIFF(ms, p.last_batch, GETDATE()), '1900-01-01'), 
        121), 12) AS batch_duration,
    p.program_name,
    p.hostname,
    p.loginame,
    p.status,
    p.cmd,
    p.blocked,
    p.open_tran
FROM master.dbo.sysprocesses p
WHERE p.spid > 50
    AND p.status NOT IN ('background', 'sleeping')
    AND p.cmd NOT IN (
        'AWAITING COMMAND',
        'MIRROR HANDLER',
        'LAZY WRITER',
        'CHECKPOINT SLEEP',
        'RA MANAGER'
    )
ORDER BY batch_duration DESC;
GO

-----------------------------------------------------------------------
-- 5.2 THREADPOOL WAITS
--     Analyze all requests currently waiting for a free worker thread.
--     High numbers indicate thread starvation which can cause blocking.
-----------------------------------------------------------------------
SELECT 
    session_id,
    wait_duration_ms,
    wait_type,
    blocking_session_id,
    resource_description
FROM sys.dm_os_waiting_tasks
WHERE wait_type = 'THREADPOOL'
ORDER BY wait_duration_ms DESC;
GO

-----------------------------------------------------------------------
-- SECTION 6: TROUBLESHOOTING ACTIONS
-- Purpose: Manual intervention commands for resolving blocking
-- WARNING: These commands modify system state - use with caution
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 MANUAL BLOCKING ANALYSIS AND SESSION KILLING
--     Step-by-step process to identify and kill blocking sessions.
--     CAUTION: Killing sessions will roll back their transactions.
--     Only kill sessions after verifying they are safe to terminate.
-----------------------------------------------------------------------
/*
-- Step 1: Check for blocking
USE master;
SELECT DISTINCT blocked 
FROM sysprocesses 
WHERE blocked <> 0;

-- Step 2: Check if the blocker is also blocked (find the head blocker)
SELECT blocked 
FROM sysprocesses 
WHERE spid = <replace_with_blocker_spid>;

-- Step 3: Check the command being executed by the blocker
DBCC INPUTBUFFER(<replace_with_blocker_spid>);

-- Step 4: If the blocker is executing a SELECT statement (read-only),
--         the session can typically be safely killed
-- CAUTION: This will roll back any open transaction
KILL <replace_with_blocker_spid>;
*/
