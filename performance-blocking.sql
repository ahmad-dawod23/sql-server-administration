-----------------------------------------------------------------------
-- BLOCKING & LOCK CONTENTION ANALYSIS
-- Purpose : Identify head blockers, blocking chains, lock waits,
--           and open transactions causing contention.
-- Safety  : All queries are read-only (except Section 7).
-- Applies to : On-prem / Azure SQL MI (Both)
--              Azure SQL DB: queries are scoped to the current database
--              only and cross-database columns will be limited.
-- Layout  : 1. Head blocker detection
--           2. Blocking chain analysis
--           3. Lock contention analysis
--           4. Open transactions / idle blockers
--           5. Session details for the head blocker
--           6. System-wide contributing factors
--           7. Troubleshooting actions (state changing)
-- Notes   : READ UNCOMMITTED is set once below, so individual queries do
--           not repeat WITH (NOLOCK) hints.
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
        -- '1' = session is blocking at least one other session and is not
        --       itself blocked. This covers both an active blocking request
        --       and an idle session sitting on an open transaction.
        CASE
            WHEN blk.blocked_count > 0 AND ISNULL(r.blocking_session_id, 0) = 0 THEN '1'
            ELSE ''
        END,
    [SessionID] = s.session_id,
    [Login] = s.login_name,
    [Database] = DB_NAME(COALESCE(r.database_id, s.database_id)),
    [BlockedBy] = ISNULL(r.blocking_session_id, 0),
    [BlockedSessionCount] = blk.blocked_count,
    -- dm_exec_requests is NULL for idle sessions, so fall back to the session
    [OpenTransactions] = COALESCE(r.open_transaction_count, s.open_transaction_count),
    [Status] = s.status,
    [WaitType] = w.wait_type,
    [WaitTime_ms] = w.wait_duration_ms,
    [WaitResource] = r.wait_resource,
    [WaitResourceDesc] = w.resource_description,
    [Command] = r.command,
    [Application] = s.program_name,
    [TotalCPU_ms] = s.cpu_time,
    -- reads/writes are I/O operation counts, not pages - do not convert to MB
    [TotalPhysicalIOs] = s.reads + s.writes,
    [MemoryUse_KB] = s.memory_usage * 8,
    [LoginTime] = s.login_time,
    [LastRequestStartTime] = s.last_request_start_time,
    [HostName] = s.host_name,
    [QueryHash] = r.query_hash,
    [BlockerQuery_or_MostRecentQuery] = txt.text
FROM sys.dm_exec_sessions AS s
    LEFT OUTER JOIN sys.dm_exec_requests AS r
        ON s.session_id = r.session_id
    -- TOP (1) guards against MARS sessions having multiple connections
    OUTER APPLY (
        SELECT TOP (1) conn_inner.most_recent_sql_handle
        FROM sys.dm_exec_connections AS conn_inner
        WHERE conn_inner.session_id = s.session_id
        ORDER BY conn_inner.connect_time DESC
    ) AS c
    -- TOP (1) collapses the many waiting tasks of a parallel request to one row
    OUTER APPLY (
        SELECT TOP (1) wt.wait_type, wt.wait_duration_ms, wt.resource_description
        FROM sys.dm_os_waiting_tasks AS wt
        WHERE wt.session_id = s.session_id
        ORDER BY wt.wait_duration_ms DESC
    ) AS w
    -- Counted rather than joined, so one blocker blocking N sessions stays one row
    CROSS APPLY (
        SELECT COUNT(*) AS blocked_count
        FROM sys.dm_exec_requests AS r2
        WHERE r2.blocking_session_id = s.session_id
    ) AS blk
    OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.[sql_handle], c.most_recent_sql_handle)) AS txt
WHERE s.is_user_process = 1
    AND (blk.blocked_count > 0 OR ISNULL(r.blocking_session_id, 0) > 0)
ORDER BY [HeadBlocker] DESC, s.session_id
OPTION (RECOMPILE);
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
    DB_NAME(r.database_id) AS database_name,
    r.user_id, 
    r.wait_type,
    r.wait_time,
    r.last_wait_type,
    r.wait_resource, 
    r.total_elapsed_time,
    r.cpu_time, 
    r.open_transaction_count,
    r.transaction_isolation_level,
    r.row_count,
    st.text 
FROM sys.dm_exec_requests r 
    -- OUTER APPLY: CROSS APPLY silently drops requests with a NULL sql_handle
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st  
WHERE r.blocking_session_id = 0 
    AND r.session_id IN (
        SELECT blocking_session_id 
        FROM sys.dm_exec_requests
        WHERE blocking_session_id > 0
    ) 
ORDER BY r.total_elapsed_time DESC
OPTION (RECOMPILE);
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
    blocked_session.blocking_session_id AS blocking_session_id,
    blocked_session.session_id AS blocked_session_id,
    blocking_sql.text AS blocking_sql_text,
    blocked_sql.text AS blocked_sql_text,
    wait_info.wait_type,
    wait_info.wait_duration_ms,
    wait_info.resource_description
FROM sys.dm_exec_requests AS blocked_session
    OUTER APPLY sys.dm_exec_sql_text(blocked_session.[sql_handle]) AS blocked_sql
    -- TOP (1): a parallel request has one waiting task per worker, which would
    -- otherwise multiply the result set
    OUTER APPLY (
        SELECT TOP (1) wt.wait_type, wt.wait_duration_ms, wt.resource_description
        FROM sys.dm_os_waiting_tasks AS wt
        WHERE wt.session_id = blocked_session.session_id
        ORDER BY wt.wait_duration_ms DESC
    ) AS wait_info
    -- The blocker may be idle, so resolve it from sessions and fall back to
    -- its most recent batch when there is no active request
    OUTER APPLY (
        SELECT TOP (1) c.most_recent_sql_handle
        FROM sys.dm_exec_connections AS c
        WHERE c.session_id = blocked_session.blocking_session_id
        ORDER BY c.connect_time DESC
    ) AS blocking_connection
    OUTER APPLY (
        SELECT TOP (1) br.[sql_handle]
        FROM sys.dm_exec_requests AS br
        WHERE br.session_id = blocked_session.blocking_session_id
    ) AS blocking_request
    OUTER APPLY sys.dm_exec_sql_text(
        COALESCE(blocking_request.[sql_handle], blocking_connection.most_recent_sql_handle)) AS blocking_sql
WHERE blocked_session.blocking_session_id <> 0
OPTION (RECOMPILE);
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
        -- TOP (1): joining dm_exec_connections directly duplicates rows for MARS
        -- sessions, which then inflates the recursive hierarchy below
        OUTER APPLY (
            SELECT TOP (1) conn_inner.most_recent_sql_handle
            FROM sys.dm_exec_connections AS conn_inner
            WHERE conn_inner.session_id = sess.session_id
            ORDER BY conn_inner.connect_time DESC
        ) AS conn
    WHERE sess.is_user_process = 1
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
    r.open_transaction_count,
    DB_NAME(r.database_id) AS database_name,
    t.text
FROM sys.dm_exec_requests AS r
    -- OUTER APPLY: CROSS APPLY silently drops requests with a NULL sql_handle
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t 
WHERE r.blocking_session_id > 0
OPTION (RECOMPILE);
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
    waiter.batch_text AS [waiter_batch],
    waiter.statement_text AS [waiter_statement],
    t2.blocking_session_id AS [blocker_session_id],
    blocker.batch_text AS [blocker_batch]
FROM sys.dm_tran_locks AS t1
    INNER JOIN sys.dm_os_waiting_tasks AS t2
        ON t1.lock_owner_address = t2.resource_address 
    -- TOP (1): a session can expose more than one request under MARS, which
    -- would make a scalar subquery fail with "returned more than 1 value"
    OUTER APPLY (
        SELECT TOP (1)
            qt.[text] AS batch_text,
            -- Offsets are byte based, hence /2, and are zero based, hence +1
            SUBSTRING(
                qt.[text],
                (r.statement_start_offset / 2) + 1,
                ((CASE r.statement_end_offset
                      WHEN -1 THEN DATALENGTH(qt.[text])
                      ELSE r.statement_end_offset
                  END - r.statement_start_offset) / 2) + 1) AS statement_text
        FROM sys.dm_exec_requests AS r
            OUTER APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS qt
        WHERE r.session_id = t1.request_session_id
    ) AS waiter
    OUTER APPLY (
        -- The blocker is often idle, so read its most recent batch from the
        -- connection rather than from dm_exec_requests
        SELECT TOP (1) qt.[text] AS batch_text
        FROM sys.dm_exec_connections AS c
            OUTER APPLY sys.dm_exec_sql_text(
                COALESCE(
                    (SELECT TOP (1) br.[sql_handle]
                     FROM sys.dm_exec_requests AS br
                     WHERE br.session_id = c.session_id),
                    c.most_recent_sql_handle)) AS qt
        WHERE c.session_id = t2.blocking_session_id
        ORDER BY c.connect_time DESC
    ) AS blocker
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 4: OPEN TRANSACTIONS AND IDLE BLOCKERS
-- Purpose: Find transactions left open by an application, which is the
--          most common cause of sustained blocking. These sessions are
--          idle ("sleeping" / "AWAITING COMMAND") so they do NOT appear
--          in the active-request queries in Section 6.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 IDLE SESSIONS WITH AN OPEN TRANSACTION
--     Sessions that have no active request but still hold a transaction.
--     Sort by idle time: the longest idle sessions are the usual culprits.
-----------------------------------------------------------------------
SELECT
    [SessionID] = s.session_id,
    [Login] = s.login_name,
    [HostName] = s.host_name,
    [Application] = s.program_name,
    [Status] = s.status,
    [OpenTransactions] = s.open_transaction_count,
    [SecondsIdle] = DATEDIFF(SECOND, s.last_request_end_time, SYSDATETIME()),
    [LastRequestStartTime] = s.last_request_start_time,
    [LastRequestEndTime] = s.last_request_end_time,
    [BlockedSessionCount] = blk.blocked_count,
    [Database] = DB_NAME(s.database_id),
    [LastQuery] = txt.text
FROM sys.dm_exec_sessions AS s
    OUTER APPLY (
        SELECT TOP (1) conn_inner.most_recent_sql_handle
        FROM sys.dm_exec_connections AS conn_inner
        WHERE conn_inner.session_id = s.session_id
        ORDER BY conn_inner.connect_time DESC
    ) AS c
    CROSS APPLY (
        SELECT COUNT(*) AS blocked_count
        FROM sys.dm_exec_requests AS r2
        WHERE r2.blocking_session_id = s.session_id
    ) AS blk
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS txt
WHERE s.is_user_process = 1
    AND s.open_transaction_count > 0
    AND NOT EXISTS (
        SELECT 1
        FROM sys.dm_exec_requests AS r
        WHERE r.session_id = s.session_id
    )
ORDER BY [SecondsIdle] DESC
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 4.2 OLDEST ACTIVE TRANSACTIONS (With Log Usage)
--     Shows every active transaction, its age, state and how much log it
--     has generated. Long-running write transactions both block others
--     and prevent log truncation.
--     Note: a transaction spanning several databases returns one row per
--     database.
-----------------------------------------------------------------------
SELECT
    [SessionID] = st.session_id,
    [TransactionID] = at.transaction_id,
    [TransactionName] = at.[name],
    [BeganAt] = at.transaction_begin_time,
    [DurationSeconds] = DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()),
    [TransactionType] =
        CASE at.transaction_type
            WHEN 1 THEN 'Read/write'
            WHEN 2 THEN 'Read-only'
            WHEN 3 THEN 'System'
            WHEN 4 THEN 'Distributed'
            ELSE 'Unknown'
        END,
    [TransactionState] =
        CASE at.transaction_state
            WHEN 0 THEN 'Not fully initialized'
            WHEN 1 THEN 'Initialized, not started'
            WHEN 2 THEN 'Active'
            WHEN 3 THEN 'Ended (read-only)'
            WHEN 4 THEN 'Commit initiated (distributed)'
            WHEN 5 THEN 'Prepared, awaiting resolution'
            WHEN 6 THEN 'Committed'
            WHEN 7 THEN 'Rolling back'
            WHEN 8 THEN 'Rolled back'
            ELSE 'Unknown'
        END,
    [Database] = DB_NAME(dt.database_id),
    [LogRecords] = dt.database_transaction_log_record_count,
    [LogBytesUsed_KB] = dt.database_transaction_log_bytes_used / 1024,
    [IsUserTransaction] = st.is_user_transaction,
    [Login] = s.login_name,
    [HostName] = s.host_name,
    [Application] = s.program_name,
    [SessionStatus] = s.[status],
    [CurrentOrLastQuery] = txt.text
FROM sys.dm_tran_active_transactions AS at
    INNER JOIN sys.dm_tran_session_transactions AS st
        ON at.transaction_id = st.transaction_id
    LEFT OUTER JOIN sys.dm_tran_database_transactions AS dt
        ON at.transaction_id = dt.transaction_id
    LEFT OUTER JOIN sys.dm_exec_sessions AS s
        ON st.session_id = s.session_id
    OUTER APPLY (
        SELECT TOP (1) conn_inner.most_recent_sql_handle
        FROM sys.dm_exec_connections AS conn_inner
        WHERE conn_inner.session_id = st.session_id
        ORDER BY conn_inner.connect_time DESC
    ) AS c
    OUTER APPLY (
        SELECT TOP (1) r.[sql_handle]
        FROM sys.dm_exec_requests AS r
        WHERE r.session_id = st.session_id
    ) AS req
    OUTER APPLY sys.dm_exec_sql_text(
        COALESCE(req.[sql_handle], c.most_recent_sql_handle)) AS txt
ORDER BY at.transaction_begin_time
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- SECTION 5: SESSION DETAILS FOR HEAD BLOCKER
-- Purpose: Detailed analysis of head blocker session
-- Note: Use queries from Section 1 to identify the head blocker session ID first
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 HEAD BLOCKER SESSION DETAILS
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
    open_transaction_count,
    last_request_start_time,
    last_request_end_time
FROM sys.dm_exec_sessions
WHERE session_id = @SessionID;
GO

-----------------------------------------------------------------------
-- 5.2 HEAD BLOCKER CONNECTION DETAILS
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
-- 5.3 HEAD BLOCKER QUERY TEXT
--     Get the SQL text being executed by head blocker.
--     Uses sys.dm_exec_input_buffer, the modern and joinable replacement
--     for DBCC INPUTBUFFER, alongside the most recent batch text.
--     Replace @SessionID with actual session ID from Section 1 queries.
-----------------------------------------------------------------------
DECLARE @SessionID INT = NULL; -- Replace NULL with actual session_id from Section 1

SELECT 
    c.session_id,
    t.text AS [most_recent_batch],
    ib.event_info AS [input_buffer]
FROM sys.dm_exec_connections AS c
    -- OUTER APPLY: CROSS APPLY silently drops rows with a NULL handle
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t 
    OUTER APPLY sys.dm_exec_input_buffer(c.session_id, NULL) AS ib
WHERE c.session_id = @SessionID;
GO

-----------------------------------------------------------------------
-- SECTION 6: SYSTEM-WIDE PERFORMANCE ANALYSIS
-- Purpose: Identify system-wide issues that may contribute to blocking
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 LONG RUNNING REQUESTS
--     Identify long-running active requests that may be causing issues.
--     Requests running for a long time may hold locks for extended periods.
--     Note: idle sessions holding a transaction are NOT active requests -
--     use Section 4 for those.
-----------------------------------------------------------------------
DECLARE @MinElapsedMs INT = 5000; -- Only show requests running longer than this

SELECT
    [SessionID] = r.session_id,
    [ElapsedSeconds] = r.total_elapsed_time / 1000,
    [Status] = r.[status],
    [Command] = r.command,
    [BlockedBy] = r.blocking_session_id,
    [OpenTransactions] = r.open_transaction_count,
    [WaitType] = r.wait_type,
    [WaitTime_ms] = r.wait_time,
    [LastWaitType] = r.last_wait_type,
    [CPU_ms] = r.cpu_time,
    [LogicalReads] = r.logical_reads,
    [PercentComplete] = CONVERT(DECIMAL(5, 2), r.percent_complete),
    [Database] = DB_NAME(r.database_id),
    [Login] = s.login_name,
    [HostName] = s.host_name,
    [Application] = s.program_name,
    [Query] = txt.text
FROM sys.dm_exec_requests AS r
    INNER JOIN sys.dm_exec_sessions AS s
        ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.[sql_handle]) AS txt
WHERE s.is_user_process = 1
    AND r.session_id <> @@SPID
    AND r.total_elapsed_time > @MinElapsedMs
ORDER BY r.total_elapsed_time DESC
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 6.2 THREADPOOL WAITS
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
-- SECTION 7: TROUBLESHOOTING ACTIONS
-- Purpose: Manual intervention commands for resolving blocking
-- WARNING: These commands modify system state - use with caution
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 MANUAL BLOCKING ANALYSIS AND SESSION KILLING
--     Step-by-step process to identify and kill a blocking session.
--     CAUTION: KILL rolls back the session's entire open transaction.
--     Rollback is single-threaded and can take AS LONG AS, or longer
--     than, the work already done. Killing a large writer can therefore
--     extend the outage rather than end it, and the locks are held for
--     the whole rollback.
-----------------------------------------------------------------------
/*
-- Step 1: Find the head blocker (see Section 1 for richer versions)
SELECT DISTINCT r.blocking_session_id
FROM sys.dm_exec_requests AS r
WHERE r.blocking_session_id > 0
    AND NOT EXISTS (
        SELECT 1
        FROM sys.dm_exec_requests AS r2
        WHERE r2.session_id = r.blocking_session_id
            AND r2.blocking_session_id > 0
    );

-- Step 2: Inspect what the blocker last submitted
--         sys.dm_exec_input_buffer is the modern replacement for
--         DBCC INPUTBUFFER(<spid>) and can be joined to other DMVs.
SELECT * FROM sys.dm_exec_input_buffer(<replace_with_blocker_spid>, NULL);

-- Step 3: Assess the cost of killing it BEFORE killing it.
--         Do NOT judge safety by the statement currently visible: a session
--         showing a SELECT may already have performed large modifications
--         earlier in the same transaction. What matters is the transaction.
SELECT
    st.session_id,
    at.transaction_begin_time,
    DATEDIFF(SECOND, at.transaction_begin_time, SYSDATETIME()) AS duration_seconds,
    dt.database_transaction_log_record_count AS log_records,
    dt.database_transaction_log_bytes_used / 1024 AS log_bytes_used_kb
FROM sys.dm_tran_session_transactions AS st
    INNER JOIN sys.dm_tran_active_transactions AS at
        ON st.transaction_id = at.transaction_id
    LEFT OUTER JOIN sys.dm_tran_database_transactions AS dt
        ON at.transaction_id = dt.transaction_id
WHERE st.session_id = <replace_with_blocker_spid>;

--         A high log_record count means an expensive rollback. Prefer having
--         the application commit or roll back cleanly where that is possible.

-- Step 4: Kill only after the above has been reviewed.
KILL <replace_with_blocker_spid>;

-- Step 5: Monitor the rollback. If it is slow, DO NOT restart the instance:
--         recovery would simply continue the same rollback at startup.
KILL <replace_with_blocker_spid> WITH STATUSONLY;
*/
