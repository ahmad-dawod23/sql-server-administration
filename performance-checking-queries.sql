-----------------------------------------------------------------------
-- SQL SERVER PERFORMANCE CHECKING QUERIES
-- Purpose : Comprehensive performance analysis including deadlocks,
--           query performance, blocking, wait stats, and stored procedures
-- Safety  : All queries are read-only except DBCC TRACEON (commented)
-- Applies to : On-prem / Azure SQL MI / Both
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

/*******************************************************************************
 SECTION 1: DEADLOCK ANALYSIS
 Purpose: Identify and analyze deadlocks using trace flags and Extended Events
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 TRACE FLAGS FOR DEADLOCK LOGGING (On-Prem)
--     Enables detailed deadlock information in SQL Server error log
--     1204 = deadlock info by node
--     1222 = deadlock info by process and resource (recommended)
--     *** UNCOMMENT TO ENABLE — persists until service restart ***
-----------------------------------------------------------------------
-- Show currently active trace flags
DBCC TRACESTATUS;

-- Enable deadlock trace flags (uncomment to run):
-- DBCC TRACEON (1204, 1222, -1);  -- -1 makes it global
GO

-----------------------------------------------------------------------
-- 1.2 DEADLOCK ANALYSIS — AZURE SQL MANAGED INSTANCE
--     Reads deadlock events from the MI telemetry XE target
--     On-prem: Use the system_health XE session instead (see section 1.3)
-----------------------------------------------------------------------
WITH CTE AS (
    SELECT CAST(event_data AS XML) AS [target_data_XML]
    FROM sys.fn_xe_telemetry_blob_target_read_file('dl', NULL, NULL, NULL)
)
SELECT
    target_data_XML.value('(/event/@timestamp)[1]', 'DateTime2') AS Timestamp,
    target_data_XML.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_xml,
    target_data_XML.query('/event/data[@name=''database_name'']/value')
        .value('(/value)[1]', 'nvarchar(100)') AS db_name
FROM CTE
ORDER BY Timestamp DESC;
GO

-----------------------------------------------------------------------
-- 1.3 DEADLOCK ANALYSIS — ON-PREM (system_health XE session)
--     Extracts deadlock graphs from the default system_health session
--     Works on SQL Server 2012+ without any additional configuration
-----------------------------------------------------------------------

-- This script queries the ring buffer of the system_health Extended Events session for deadlocks
WITH DeadlockEvents AS (
    SELECT
        xdr.value('@timestamp', 'datetime2') AS DeadlockTime,
        xdr.query('.') AS DeadlockGraph
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
GO

-- This script queries the default system_health Extended Events session for deadlocks, returning the output in XML.
-- To view the deadlock graph in a graphical format, click on the DeadlockGraph XML, then save as a file with a .xdl extension, then open the file in SSMS.

SELECT CONVERT(XML, event_data).value('(event[@name="xml_deadlock_report"]/@timestamp)[1]', 'datetime') AS DeadlockDateTime,
       CONVERT(XML, event_data).query('/event/data/value/child::*') AS DeadlockGraph
FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
WHERE object_name LIKE 'xml_deadlock_report';


/*******************************************************************************
 SECTION 2: QUERY PERFORMANCE ANALYSIS (DMV-based)
 Purpose: Identify poorly performing queries using DMVs
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 TOP QUERIES BY TOTAL LOGICAL READS (Instance-Wide)
--     Identifies queries that read lots of pages from buffer pool
--     High logical reads indicate heavy data scanning
-----------------------------------------------------------------------
SELECT TOP(50)
    DB_NAME(t.[dbid]) AS [Database Name],
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
    --,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment if not copying to Excel
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
ORDER BY qs.total_logical_reads DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 2.2 TOP QUERIES BY AVERAGE ELAPSED TIME (Instance-Wide)
--     Identifies queries with the longest average duration
-----------------------------------------------------------------------
SELECT TOP(50)
    DB_NAME(t.[dbid]) AS [Database Name], 
    REPLACE(REPLACE(LEFT(t.[text], 255), CHAR(10),''), CHAR(13),'') AS [Short Query Text],  
    qs.total_elapsed_time/qs.execution_count AS [Avg Elapsed Time],
    qs.min_elapsed_time,
    qs.max_elapsed_time,
    qs.last_elapsed_time,
    qs.execution_count AS [Execution Count],  
    qs.total_logical_reads/qs.execution_count AS [Avg Logical Reads], 
    qs.total_physical_reads/qs.execution_count AS [Avg Physical Reads], 
    qs.total_worker_time/qs.execution_count AS [Avg Worker Time],
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2
        LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index],
    qs.creation_time AS [Creation Time]
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_elapsed_time/qs.execution_count DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 2.3 MOST FREQUENTLY EXECUTED QUERIES (Current Database)
--     Identifies which cached queries are called the most often
--     Helps characterize workload and find caching opportunities
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
    CASE WHEN CONVERT(nvarchar(max), qp.query_plan) COLLATE Latin1_General_BIN2
        LIKE N'%<MissingIndexes>%' THEN 1 ELSE 0 END AS [Has Missing Index], 
    qs.last_execution_time AS [Last Execution Time], 
    qs.creation_time AS [Creation Time]
    --,t.[text] AS [Complete Query Text], qp.query_plan AS [Query Plan] -- uncomment if not copying to Excel
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t 
CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
WHERE t.dbid = DB_ID()
    AND DATEDIFF(Minute, qs.creation_time, GETDATE()) > 0
ORDER BY qs.execution_count DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 2.4 TOP QUERIES BY AVERAGE I/O (Current Database)
--     Lists top statements by average input/output usage
-----------------------------------------------------------------------
SELECT TOP(50)
    OBJECT_NAME(qt.objectid, dbid) AS [Object Name],
    (qs.total_logical_reads + qs.total_logical_writes) /qs.execution_count AS [Avg IO], 
    qs.execution_count AS [Execution Count],
    SUBSTRING(qt.[text], qs.statement_start_offset/2, 
        (CASE 
            WHEN qs.statement_end_offset = -1 
            THEN LEN(CONVERT(nvarchar(max), qt.[text])) * 2 
            ELSE qs.statement_end_offset 
        END - qs.statement_start_offset)/2) AS [Query Text]    
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
WHERE qt.[dbid] = DB_ID()
ORDER BY [Avg IO] DESC OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 2.5 TOP QUERIES BY AVERAGE READS
--     Identifies queries with highest average read operations
-----------------------------------------------------------------------
SELECT TOP(10)
    total_logical_reads/execution_count AS AvgReads,
    SUBSTRING(st.text, (qs.statement_start_offset/2) + 1,
        ((CASE statement_end_offset 
          WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END 
         - qs.statement_start_offset)/2) + 1) as StatementText
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER BY total_logical_reads/execution_count DESC;
GO

-----------------------------------------------------------------------
-- 2.6 TOP 10 WORST PERFORMING QUERIES
--     Identifies queries with highest CPU and elapsed time
-----------------------------------------------------------------------
SELECT TOP 10 
    execution_count AS [Number of Executions],
    total_worker_time/execution_count AS [Average CPU Time],
    Total_Elapsed_Time/execution_count AS [Average Elapsed Time],
    (
        SELECT 
            SUBSTRING(text, statement_start_offset/2,
                (CASE WHEN statement_end_offset = -1
                THEN LEN(CONVERT(nvarchar(max), [text])) * 2
                ELSE statement_end_offset 
                END - statement_start_offset) /2)
        FROM sys.dm_exec_sql_text(sql_handle)
    ) AS query_text
FROM sys.dm_exec_query_stats
ORDER BY [Average CPU Time] DESC;
GO


/*******************************************************************************
 SECTION 3: SESSION AND CONNECTION MONITORING
 Purpose: Monitor active sessions, connections, and blocking
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 CURRENTLY EXECUTING REQUESTS (Basic)
--     Shows all currently executing user requests with basic info
-----------------------------------------------------------------------
SELECT
    s.original_login_name,
    s.program_name,
    r.command, 
    r.wait_type,
    r.wait_time,
    r.blocking_session_id,
    r.sql_handle
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s ON r.session_id = s.session_id		
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.2 CURRENTLY EXECUTING REQUESTS WITH SQL TEXT
--     Includes the complete SQL batch being executed
-----------------------------------------------------------------------
SELECT
    s.original_login_name,
    s.program_name,
    r.command,
    t.text,
    r.wait_type,
    r.wait_time,
    r.blocking_session_id
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s ON r.session_id = s.session_id		
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.3 CURRENTLY EXECUTING REQUESTS WITH SPECIFIC STATEMENT
--     Shows the exact statement being executed rather than the batch
-----------------------------------------------------------------------
SELECT
    s.original_login_name,
    s.program_name,
    r.command, 
    (SELECT TOP (1) SUBSTRING(t.text, r.statement_start_offset / 2 + 1, 
        ((CASE WHEN r.statement_end_offset = -1 
        THEN (LEN(CONVERT(nvarchar(max), t.text)) * 2) 
        ELSE r.statement_end_offset 
        END) - r.statement_start_offset) / 2 + 1)) AS SqlStatement,
    r.wait_type,
    r.wait_time,
    r.blocking_session_id
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text (r.sql_handle) AS t		
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.4 ALL CURRENT EXECUTING REQUESTS (Detailed Analysis)
--     Comprehensive view of all executing requests
-----------------------------------------------------------------------
SELECT
    r.command,
    r.plan_handle,
    r.wait_type,
    r.wait_resource,
    r.wait_time,
    r.session_id,
    r.blocking_session_id
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.5 CONNECTIONS WITH TIMING DETAILS
--     Shows when users connected and last finished a request
-----------------------------------------------------------------------
SELECT
    s.session_id,
    s.login_name,
    c.connect_time,
    s.last_request_end_time 
FROM sys.dm_exec_sessions AS s
INNER JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id 
INNER JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id 
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.6 SESSIONS WITH SQL BATCHES
--     Shows the SQL batches being executed by each session
-----------------------------------------------------------------------
SELECT
    s.session_id,
    s.login_name,
    st.text  
FROM sys.dm_exec_sessions AS s
INNER JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id 
INNER JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id 
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.7 SESSIONS WITH SQL BATCHES AND EXECUTION PLANS
--     Includes both SQL text and query plans for active sessions
-----------------------------------------------------------------------
SELECT
    s.session_id,
    s.login_name,
    st.text,
    qp.query_plan 
FROM sys.dm_exec_sessions AS s
INNER JOIN sys.dm_exec_requests AS r ON s.session_id = r.session_id 
INNER JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id 
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE s.is_user_process = 1;
GO

-----------------------------------------------------------------------
-- 3.8 USER SESSIONS WITH WRITE OPERATIONS
--     Shows only user connections that have performed write operations
-----------------------------------------------------------------------
SELECT * 
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
    AND writes > 0;
GO


/*******************************************************************************
 SECTION 4: TRANSACTION AND ISOLATION MONITORING
 Purpose: Monitor transactions and isolation levels
*******************************************************************************/

-----------------------------------------------------------------------
-- 4.1 SNAPSHOT ISOLATION — ACTIVE TRANSACTIONS
--     Shows sessions using snapshot isolation and version chain traversal
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
    END AS transaction_isolation_level
FROM sys.dm_tran_active_snapshot_database_transactions t
    JOIN sys.dm_exec_sessions s ON t.session_id = s.session_id
ORDER BY elapsed_time_seconds DESC;
GO

-----------------------------------------------------------------------
-- 4.2 ACTIVE OPEN TRANSACTIONS
--     Finds sessions with uncommitted transactions (potential blocking)
-----------------------------------------------------------------------
SELECT
    SP.SPID,
    SP.open_tran AS OpenTransactions,
    SP.status,
    SP.cmd,
    SP.waittype,
    SP.waittime,
    SP.blocked,
    DEST.[text] AS SQLCode
FROM sys.sysprocesses SP
    CROSS APPLY sys.dm_exec_sql_text(SP.[SQL_HANDLE]) AS DEST
WHERE SP.open_tran >= 1
ORDER BY SP.open_tran DESC, SP.waittime DESC;
GO


-- Find Active Transactions and Execution Plans
SELECT	s_tst.[session_id],
		s_es.[login_name] AS [Login Name],
		S_tdt.[database_transaction_begin_time] AS [Begin Time],
		s_tdt.[database_transaction_log_record_count] AS [Log Records],
		s_tdt.[database_transaction_log_bytes_used] AS [Log Bytes],
		s_tdt.[database_transaction_log_bytes_reserved] AS [Log Reserved],
		s_est.[text] AS [Last T-SQL Text],
		s_eqp.[query_plan] AS [Last Query Plan]
FROM sys.dm_tran_database_transactions s_tdt
   JOIN sys.dm_tran_session_transactions s_tst
      ON s_tst.[transaction_id] = s_tdt.[transaction_id]
   JOIN sys.[dm_exec_sessions] s_es
      ON s_es.[session_id] = s_tst.[session_id]
   JOIN sys.dm_exec_connections s_ec
      ON s_ec.[session_id] = s_tst.[session_id]
   LEFT OUTER JOIN sys.dm_exec_requests s_er
      ON s_er.[session_id] = s_tst.[session_id]
   CROSS APPLY sys.dm_exec_sql_text (s_ec.[most_recent_sql_handle]) AS s_est
   OUTER APPLY sys.dm_exec_query_plan (s_er.[plan_handle]) AS s_eqp
ORDER BY [Begin Time] ASC;
GO 




-----------------------------------------------------------------------
-- 8.1 ALL SERVER CONNECTIONS
--     Returns details of every connection to the server
-----------------------------------------------------------------------
SELECT * FROM sys.dm_exec_connections;
GO

-----------------------------------------------------------------------
-- 8.2 ALL SERVER SESSIONS
--     Returns details of every session on the server
-----------------------------------------------------------------------
SELECT * FROM sys.dm_exec_sessions;
GO

-----------------------------------------------------------------------
-- 8.3 ALL CURRENT REQUESTS
--     Returns details of current requests that are executing
-----------------------------------------------------------------------
SELECT * FROM sys.dm_exec_requests;
GO




/*******************************************************************************
 SECTION 11: QUERY STORE ANALYSIS
 Purpose: Investigate query performance using Query Store
*******************************************************************************/

-----------------------------------------------------------------------
-- 11.1 QUERY STORE — INVESTIGATE BY QUERY HASH
--     Find all plans and execution stats for a specific query hash
--     Update the query_hash value in the WHERE clause
--
--     What to look for:
--       • Multiple plan_hashes for same query_hash = plan regression
--       • High avg_cpu_time with low count = occasional expensive plan
--       • Compare avg_physical_io_reads across plans for sniffing
-----------------------------------------------------------------------
WITH query_ids AS (
    SELECT
        q.query_hash,
        q.query_id,
        p.query_plan_hash,
        SUM(qrs.count_executions) * AVG(qrs.avg_cpu_time) / 1000. AS total_cpu_time_ms,
        SUM(qrs.count_executions) AS sum_executions,
        AVG(qrs.avg_cpu_time) / 1000. AS avg_cpu_time_ms,
        AVG(qrs.avg_logical_io_reads) / 1000. AS avg_logical_io_reads_ms,
        AVG(qrs.avg_physical_io_reads) / 1000. AS avg_physical_io_reads_ms
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
    TRY_CAST(p.query_plan AS XML) AS query_plan
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
-- 11.2 QUERY STORE — SEARCH BY SQL TEXT OR QUERY HASH
--     Find a specific query by text pattern or hash
--     Update the WHERE clause with your search criteria
-----------------------------------------------------------------------
-- USE [YourDatabaseName];  -- switch to the target database first
-- GO
SELECT
    qt.query_sql_text,
    CAST(p.query_plan AS XML) AS ExecutionPlan,
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
GO

-----------------------------------------------------------------------
-- 11.3 QUERY STORE — TOP RESOURCE-CONSUMING QUERIES (Last 24 Hours)
--     Quick overview of the most expensive queries in the recent window
-----------------------------------------------------------------------
SELECT TOP 25
    q.query_id,
    qt.query_sql_text,
    SUM(rs.count_executions) AS TotalExecutions,
    SUM(rs.count_executions * rs.avg_cpu_time) / 1000. AS TotalCpuMs,
    AVG(rs.avg_cpu_time) / 1000. AS AvgCpuMs,
    AVG(rs.avg_logical_io_reads) AS AvgLogicalReads,
    AVG(rs.avg_physical_io_reads) AS AvgPhysicalReads,
    AVG(rs.avg_duration) / 1000. AS AvgDurationMs,
    COUNT(DISTINCT p.plan_id) AS PlanCount,
    -- If PlanCount > 1, this query may have plan instability
    CASE
        WHEN COUNT(DISTINCT p.plan_id) > 1
        THEN '* Multiple plans — possible parameter sniffing *'
        ELSE ''
    END AS PlanStabilityNote
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -24, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY TotalCpuMs DESC;
GO




/*******************************************************************************
 SECTION 12: PERFORMANCE COUNTERS
 Purpose: Monitor key SQL Server performance counters
*******************************************************************************/

-----------------------------------------------------------------------
-- 12 KEY PERFORMANCE COUNTERS

SELECT
	[counter_name] = RTRIM([counter_name]),
	[cntr_value],
	[instance_name],
	[description] = CASE [counter_name] 
	WHEN 'Batch Requests/sec'  ------------------------------------------------------------------------------------------------
		THEN 'Number of batches SQL Server is receiving per second. 
			  This counter is a good indicator of how much activity is being processed by your SQL Server box. 
			  The higher the number, the more queries are being executed on your box.'			 
	WHEN 'Buffer cache hit ratio' ---------------------------------------------------------------------------------------------
		THEN 'How often SQL Server is able to find data pages in its buffer cache when a query needs a data page. 
			  The higher this number the better, because it means SQL Server was able to get data for 
			  queries out of memory instead of reading from disk. 
			  You want this number to be as close to 100 as possible. 
			  Having this counter at 100 means that 100% of the time SQL Server has found the needed data pages in memory. 
			  A low buffer cache hit ratio could indicate a memory problem.'
	WHEN 'Buffer cache hit ratio base' ----------------------------------------------------------------------------------------
		THEN 'Base value - divisor to calculate the hit ratio percentage'
	WHEN 'Checkpoint pages/sec' -----------------------------------------------------------------------------------------------
		THEN 'Number of pages written to disk by a checkpoint operation. 
		      You should watch this counter over time to establish a baseline for your systems. 
		      Once a baseline value has been established you can watch this value to see if it is climbing. 
		      If this counter is climbing, it might mean you are running into memory pressures that are causing 
		      dirty pages to be flushed to disk more frequently than normal.'	
	WHEN 'Dist:Delivery Latency' ----------------------------------------------------------------------------------------------
		THEN 'Latency (ms) from Distributor to Subscriber'
	WHEN 'Free pages' ---------------------------------------------------------------------------------------------------------
		THEN 'Total number of free pages on all free lists. Minimum values below 640 indicate memory pressure'
	WHEN 'Lock Waits/sec' -----------------------------------------------------------------------------------------------------
		THEN 'Number of times per second that SQL Server is not able to retain a lock right away for a resource. 
		      You want to keep this counter at zero, or close to zero at all times.'
	WHEN 'Logreader:Delivery Latency' -----------------------------------------------------------------------------------------
		THEN 'Latency (ms) from Publisher to Distributor'
	WHEN 'Page life expectancy' -----------------------------------------------------------------------------------------------
		THEN 'How long pages stay in the buffer cache in seconds. 
			  The longer a page stays in memory, the more likely server will not need to read from HDD to resolve a query. 
			  Some say anything below 300 (or 5 minutes) means you might need additional memory.'
	WHEN 'Page Splits/sec' ----------------------------------------------------------------------------------------------------
		THEN 'Number of times SQL Server had to split a page when updating or inserting data per second. 
			  Page splits are expensive, and cause your table to perform more poorly due to fragmentation. 
			  Therefore, the fewer page splits you have the better your system will perform. 
			  Ideally this counter should be less than 20% of the batch requests per second.'
	WHEN 'Processes blocked' --------------------------------------------------------------------------------------------------
		THEN 'Number of blocked processes. 
			  When one process is blocking another process, the blocked process cannot move forward with 
			  its execution plan until the resource that is causing it to wait is freed up. 
			  Ideally you don''t want to see any blocked processes. 
			  When processes are being blocked you should investigate.'
	WHEN 'SQL Compilations/sec' -----------------------------------------------------------------------------------------------
		THEN 'Number of times SQL Server compiles an execution plan per second. 
			  Compiling an execution plan is a resource-intensive operation. 
			  Compilations/Sec should be compared with the number of Batch Requests/Sec to get an indication 
			  of whether or not complications might be hurting your performance. 
			  To do that, divide the number of batch requests by the number of compiles per second 
			  to give you a ratio of the number of batches executed per compile. 
			  Ideally you want to have one compile per every 10 batch requests.'
	WHEN 'SQL Re-Compilations/sec' --------------------------------------------------------------------------------------------
		THEN 'Number of times a re-compile event was triggered per second.
			  When the execution plan is invalidated due to some significant event, SQL Server will re-compile it. 
			  Re-compiles, like compiles, are expensive operations so you want to minimize the number of re-compiles. 
			  Ideally you want to keep this counter less than 10% of the number of Compilations/Sec.'
	WHEN 'User Connections' ---------------------------------------------------------------------------------------------------
		THEN 'Number of different users that are connected to SQL Server at the time the sample was taken. 
			  You need to watch this counter over time to understand your baseline user connection numbers. 
			  Once you have some idea of your high and low water marks during normal usage of your system, 
			  you can then look for times when this counter exceeds the high and low marks. 
			  If the value of this counter goes down and the load on the system is the same, 
			  then you might have a bottleneck that is not allowing your server to handle the normal load.'												
	ELSE ''	
	END
FROM 
	sys.dm_os_performance_counters
WHERE 
	[counter_name]
IN
(
	'Buffer cache hit ratio',
	'Buffer cache hit ratio base',
	'Page life expectancy', 
	'Batch Requests/Sec',
	'SQL Compilations/Sec',
	'SQL Re-Compilations/Sec',
	'User Connections',
	'Page Splits/sec',
	'Processes blocked',
	'Free pages',
	'Checkpoint pages/sec',
	'Logreader:Delivery Latency',
	'Dist:Delivery Latency'
)
AND
	[object_name] NOT LIKE '%Partition%' 
AND
	[object_name] NOT LIKE '%Node%'
OR
(
	[counter_name] = 'Lock Waits/sec'
	AND
	[instance_name] = '_Total'
)
ORDER BY 1;
GO

