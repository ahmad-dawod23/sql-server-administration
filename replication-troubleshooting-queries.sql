/*******************************************************************************
 * REPLICATION TROUBLESHOOTING QUERIES
 * 
 * Purpose: Diagnose replication agent failures, measure latency with tracer 
 *          tokens, and check undistributed commands.
 * 
 * Safety:  All queries are read-only unless noted (run against distribution DB)
 * 
 * Applies to: On-prem SQL Server with transactional replication
 *
 * Table of Contents:
 *   1. Agent Configuration and Status
 *   2. Agent History
 *   3. Error Diagnosis
 *   4. Publication and Subscription Information
 *   5. Tracer Token Management
 *   6. Latency Monitoring
 *   7. Transaction Analysis
 *   8. Troubleshooting Specific Issues
 *   9. Performance Analysis - Agent Waits
 *  10. Maintenance and Cleanup
 ******************************************************************************/

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

/*******************************************************************************
 * SECTION 1: AGENT CONFIGURATION AND STATUS
 ******************************************************************************/

-- 1.1 Identify Replication Agent Jobs
-- Find job IDs for Distribution, LogReader, and Snapshot agents
SELECT
    sjv.job_id, 
    sjv.name AS job_name, 
    sjv.enabled, 
    sjv.category_id, 
    sjv.originating_server,
    sjs.subsystem, 
    sjs.step_id, 
    sjs.step_name, 
    sjs.server, 
    sjs.database_name, 
    sjs.retry_attempts, 
    sjs.output_file_name, 
    sjs.command, 
    sjs.additional_parameters
FROM msdb.dbo.sysjobsteps sjs 
    INNER JOIN msdb.dbo.sysjobs_view sjv 
        ON sjv.job_id = sjs.job_id  
WHERE subsystem IN ('Distribution', 'LogReader', 'Snapshot');
GO

-- 1.2 Get Agent Job History
-- Replace job_id with actual value from query 1.1
EXEC msdb.dbo.sp_help_jobhistory 
    @job_id = 'D55F576C-91B7-48D4-9F77-0C4F11105AD6', 
    @mode = 'FULL';
GO

-- 1.3 Check Configured LogReader Agents
SELECT * 
FROM MSlogreader_agents;
GO

-- 1.4 Check Configured Snapshot Agents
SELECT * 
FROM MSsnapshot_agents;
GO

-- 1.5 Check Configured Distribution Agents
SELECT * 
FROM MSdistribution_agents;
GO

/*******************************************************************************
 * SECTION 2: AGENT HISTORY
 ******************************************************************************/

-- 2.1 LogReader Agent History (by Start Time)
SELECT TOP 1000 * 
FROM MSlogreader_history 
ORDER BY start_time DESC, time DESC;
GO

-- 2.2 Snapshot Agent History (by Start Time)
SELECT TOP 1000 * 
FROM MSsnapshot_history 
ORDER BY start_time DESC, time DESC;
GO

-- 2.3 Distribution Agent History (by Start Time)
SELECT TOP 1000 * 
FROM MSdistribution_history 
ORDER BY start_time DESC, time DESC;
GO

-- 2.4 LogReader Agent History (by Event Time)
SELECT TOP 1000 * 
FROM MSlogreader_history 
ORDER BY time DESC;
GO

-- 2.5 Snapshot Agent History (by Event Time)
SELECT TOP 1000 * 
FROM MSsnapshot_history 
ORDER BY time DESC;
GO

-- 2.6 Distribution Agent History (by Event Time)
SELECT TOP 1000 * 
FROM MSdistribution_history 
ORDER BY time DESC;
GO

-- 2.7 LogReader Agent History (Filtered by Agent ID)
-- Agent ID available from job name or from MSxxxx_agents table
SELECT * 
FROM Distribution..MSlogreader_history 
WHERE agent_id = 1  -- Replace with actual agent_id
ORDER BY start_time DESC, time DESC;
GO

-- 2.8 Snapshot Agent History (Filtered by Agent ID)
SELECT * 
FROM Distribution..MSsnapshot_history 
WHERE agent_id = 1  -- Replace with actual agent_id
ORDER BY start_time DESC, time DESC;
GO

-- 2.9 Distribution Agent History (Filtered by Agent ID)
SELECT * 
FROM Distribution..MSdistribution_history 
WHERE agent_id = 3  -- Replace with actual agent_id
ORDER BY start_time DESC, time DESC;
GO

/*******************************************************************************
 * SECTION 3: ERROR DIAGNOSIS
 ******************************************************************************/

-- 3.1 Recent Replication Errors
SELECT TOP 1000 * 
FROM MSrepl_errors 
ORDER BY time DESC;
GO

-- 3.2 Investigate Specific Transaction Error
-- Use transaction sequence number from error message
SELECT * 
FROM dbo.MSrepl_transactions
WHERE xact_seqno = 0x00CB2EBA000031B4001300000000;  -- Replace with actual seqno
GO

SELECT * 
FROM dbo.MSrepl_commands
WHERE xact_seqno = 0x00CB2EBA000031B4001300000000;  -- Replace with actual seqno
GO

-- 3.3 Browse Replication Commands for Error
-- Use values from error message
EXEC sp_browsereplcmds  
    @xact_seqno_start = '0x00CB2EBA000031B4001300000000',
    @xact_seqno_end = '0x00CB2EBA000031B4001300000000',
    @command_id = 16, 
    @publisher_database_id = 2;
GO

/*******************************************************************************
 * SECTION 4: PUBLICATION AND SUBSCRIPTION INFORMATION
 ******************************************************************************/

-- 4.1 Find Publications with Subscription Details
USE [distribution];
GO

SELECT DISTINCT 
    pb.publisher_db, 
    da.subscriber_db, 
    pb.publication, 
    pd.id AS pub_db_id, 
    da.id AS agent_id,
    CASE ps.status
        WHEN 0 THEN 'Inactive'
        WHEN 1 THEN 'Subscribed'
        WHEN 2 THEN 'Active'
    END AS subscription_status,
    pb.description
FROM dbo.MSpublications pb
    LEFT JOIN dbo.MSdistribution_agents da 
        ON da.publication = pb.publication
        AND da.subscriber_db <> 'virtual'
    LEFT JOIN dbo.MSsubscriptions ps 
        ON ps.publisher_db = pb.publisher_db 
        AND ps.subscriber_db = da.subscriber_db
    JOIN dbo.MSpublisher_databases pd 
        ON pb.publisher_db = pd.publisher_db;
GO

-- 4.2 Get Publisher Database IDs
SELECT * 
FROM distribution.dbo.MSpublisher_databases;
GO

-- 4.3 Get Distribution Agent IDs by Publisher Database
SELECT * 
FROM distribution.dbo.MSdistribution_agents 
WHERE publisher_database_id = 1;  -- Replace with actual publisher_database_id
GO

/*******************************************************************************
 * SECTION 5: TRACER TOKEN MANAGEMENT
 ******************************************************************************/

-- 5.1 Post Tracer Token
EXEC sp_posttracertoken @publication = 'publication_name';  -- Replace with actual publication name
GO

-- 5.2 View Tracer Token History
EXEC sp_helptracertokens 
    @publisher = 'instance\name',           -- Replace with actual publisher
    @publication = 'publication_TABLES',     -- Replace with actual publication
    @publisher_db = 'publisher_database';    -- Replace with actual database
GO

-- 5.3 View Specific Tracer Token Details
EXEC sp_helptracertokenhistory 
    @publisher = 'instance\name',           -- Replace with actual publisher
    @publication = 'publication_TABLES',     -- Replace with actual publication
    @publisher_db = 'publisher_database',    -- Replace with actual database
    @tracer_id = -2147483634;                -- Replace with actual tracer_id
GO

-- 5.4 Delete Faulty Tracer Token
-- Use this to remove tracer tokens that show NULL subscriber latency
EXEC sp_deletetracertokenhistory 
    @publisher = 'instance\name',           -- Replace with actual publisher
    @publication = 'publication_TABLES',     -- Replace with actual publication
    @publisher_db = 'publisher_database',    -- Replace with actual database
    @tracer_id = -2147483634;                -- Replace with actual tracer_id
GO

/*******************************************************************************
 * SECTION 6: LATENCY MONITORING
 ******************************************************************************/

-- 6.1 Comprehensive Replication Lag with Tracer Tokens
SELECT
    ps.name AS [publisher],
    p.publisher_db,
    p.publication,
    ss.name AS [subscriber],
    da.subscriber_db,
    t.publisher_commit,
    t.distributor_commit,
    h.subscriber_commit,
    DATEDIFF(SECOND, t.publisher_commit, t.distributor_commit) AS [pub_to_dist_sec],
    DATEDIFF(SECOND, t.distributor_commit, h.subscriber_commit) AS [dist_to_sub_sec],
    DATEDIFF(SECOND, t.publisher_commit, h.subscriber_commit) AS [total_latency_sec]
FROM dbo.MStracer_tokens t
    INNER JOIN dbo.MStracer_history h 
        ON h.parent_tracer_id = t.tracer_id
    INNER JOIN dbo.MSpublications p 
        ON p.publication_id = t.publication_id
    INNER JOIN dbo.MSdistribution_agents da 
        ON da.id = h.agent_id
    INNER JOIN sys.servers ps 
        ON ps.server_id = p.publisher_id
    INNER JOIN sys.servers ss 
        ON ss.server_id = da.subscriber_id
WHERE 1=1
    -- Uncomment and modify filters as needed:
    -- AND p.publisher_db = 'YourPublisherDB'
    -- AND DATEDIFF(SECOND, t.publisher_commit, h.subscriber_commit) > 60
    -- AND t.publisher_commit > '2025-01-01 00:00:00'
    -- AND ss.name = 'YourSubscriber'
    -- AND p.publication IN ('publication1', 'publication2')
    -- AND h.subscriber_commit IS NOT NULL
ORDER BY
    ps.name,
    p.publisher_db,
    p.publication,
    ss.name,
    da.subscriber_db,
    t.publisher_commit DESC;
GO

-- 6.2 System Performance Counters for Latency
SELECT 
    instance_name,
    counter_name,
    cntr_value,
    ROUND(cntr_value / 1000.0, 0) AS latency_sec  
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
    'Logreader:Delivery Latency',  -- Publisher to Distributor
    'Dist:Delivery Latency'         -- Distributor to Subscriber
)
ORDER BY instance_name;
GO

-- 6.3 Advanced Latency Analysis with Weighted Calculations
;WITH Replication_Tracers AS
(
    SELECT
        ps.name AS [publisher],
        p.publisher_db,
        p.publication,
        ss.name AS [subscriber],
        da.subscriber_db,
        t.publisher_commit,
        t.distributor_commit,
        h.subscriber_commit,
        DATEDIFF(SECOND, t.publisher_commit, t.distributor_commit) AS [pub_to_dist_sec],
        DATEDIFF(SECOND, t.distributor_commit, h.subscriber_commit) AS [dist_to_sub_sec],
        DATEDIFF(SECOND, t.publisher_commit, h.subscriber_commit) AS [total_latency_sec]
    FROM [distribution].[dbo].[MStracer_tokens] t
        INNER JOIN [distribution].[dbo].[MStracer_history] h 
            ON h.parent_tracer_id = t.tracer_id
        INNER JOIN [distribution].[dbo].[MSpublications] p 
            ON p.publication_id = t.publication_id
        INNER JOIN [distribution].[dbo].[MSdistribution_agents] da 
            ON da.id = h.agent_id
        INNER JOIN sys.servers ps 
            ON ps.server_id = p.publisher_id
        INNER JOIN sys.servers ss 
            ON ss.server_id = da.subscriber_id
),
Replication_Latency AS
(
    -- Recent tokens with actual latency
    SELECT
        publisher,
        publisher_db,
        publication,
        subscriber,
        subscriber_db,
        publisher_commit,
        [total_latency_sec]
    FROM Replication_Tracers
    WHERE publisher_commit > DATEADD(HOUR, -1, GETDATE())
        AND [total_latency_sec] IS NOT NULL
    
    UNION
    
    -- Oldest pending token per subscription (NULL latency)
    SELECT
        publisher,
        publisher_db,
        publication,
        subscriber,
        subscriber_db,
        publisher_commit,
        [total_latency_sec]
    FROM (
        SELECT
            publisher,
            publisher_db,
            publication,
            subscriber,
            subscriber_db,
            publisher_commit,
            [total_latency_sec],
            RANK() OVER (
                PARTITION BY publisher, publisher_db, publication, subscriber, subscriber_db 
                ORDER BY publisher_commit ASC
            ) AS rn
        FROM Replication_Tracers
        WHERE [total_latency_sec] IS NULL
    ) tmp
    WHERE tmp.rn = 1
)
SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    publisher_commit,
    ISNULL([total_latency_sec], DATEDIFF(SECOND, publisher_commit, GETDATE())) AS lag_sec,
    RANK() OVER (
        PARTITION BY publisher, publisher_db, publication, subscriber, subscriber_db 
        ORDER BY publisher_commit DESC
    ) AS rank_order
FROM Replication_Latency
ORDER BY lag_sec DESC;
GO

-- 6.4 Simple Lag Check - Last Replicated Transaction
-- Step 1: Find the last replicated transaction
SELECT MAX(xact_seqno) AS last_xact_seqno
FROM MSsubscriptions s
    INNER JOIN MSpublications p 
        ON p.publication_id = s.publication_id
    INNER JOIN MSdistribution_history h 
        ON h.agent_id = s.agent_id
WHERE subscriber_db = 'my_database_name';  -- Replace with actual subscriber database
GO

-- Step 2: Find when that transaction was sent
SELECT entry_time 
FROM dbo.MSrepl_transactions
WHERE xact_seqno = 0x0005D665000015750080000000000000;  -- Replace with xact_seqno from Step 1
GO

-- Step 3: Count pending transactions and commands
SELECT 
    xact_seqno, 
    COUNT(*) AS command_count
FROM dbo.MSrepl_commands
WHERE xact_seqno IN (
    SELECT xact_seqno 
    FROM dbo.MSrepl_transactions
    WHERE entry_time > '2025-01-01 00:00:00'  -- Replace with entry_time from Step 2
        AND publisher_database_id = 3          -- Replace with actual publisher_database_id
)
GROUP BY xact_seqno
HAVING COUNT(1) > 15
ORDER BY COUNT(*) DESC;
GO

/*******************************************************************************
 * SECTION 7: TRANSACTION ANALYSIS
 ******************************************************************************/

-- 7.1 Identify Large Transactions
-- Standard: up to 5 commands for OLTP, 400-500 commands for batches
-- Large transactions can cause replication delays
SELECT 
    rt.entry_time, 
    rt.xact_seqno, 
    COUNT(*) AS command_count
FROM distribution.dbo.MSrepl_commands rc
    JOIN distribution.dbo.MSrepl_transactions rt 
        ON rc.xact_seqno = rt.xact_seqno
    JOIN distribution.dbo.MSpublisher_databases pd 
        ON pd.id = rc.publisher_database_id
WHERE rt.entry_time >= CAST(GETDATE() AS DATE)  -- Today's transactions
    AND pd.publisher_db = 'YourPublisherDB'     -- Replace with actual publisher database
GROUP BY rt.entry_time, rt.xact_seqno
HAVING COUNT(1) > 1000
ORDER BY COUNT(*) DESC;
GO

-- 7.2 Analyze Distribution Agent Progress
-- Find current transaction being replicated
;WITH CTE1 AS (
    SELECT TOP 10
        ROW_NUMBER() OVER (ORDER BY dh.xact_seqno DESC, dh.time DESC) AS rownum,
        CONVERT(XML, dh.comments).value('(/stats/@cmds)[1]', 'int') AS stats_cmds,
        CONVERT(XML, dh.comments).value('(/stats/@state)[1]', 'int') AS stats_state,
        CONVERT(XML, dh.comments).value('(/stats/@work)[1]', 'int') AS stats_work,
        CONVERT(XML, dh.comments).value('(/stats/@idle)[1]', 'int') AS stats_idle,
        dh.*
    FROM distribution.dbo.MSdistribution_history dh (NOLOCK)
    WHERE dh.agent_id = 24  -- Replace with actual distribution agent ID
    ORDER BY dh.xact_seqno DESC, dh.time DESC
)
SELECT 
    c1.stats_cmds - c2.stats_cmds AS cmd_diff, 
    DATEDIFF(MINUTE, c2.time, c1.time) AS mins,
    c1.*
FROM CTE1 c1
    LEFT JOIN CTE1 c2 ON c1.rownum = c2.rownum - 1
ORDER BY c1.rownum;
GO

-- 7.3 Find Next Transaction to be Replicated
SELECT TOP 1 *
FROM distribution.dbo.MSrepl_transactions (NOLOCK)
WHERE publisher_database_id = 1                       -- Replace with actual publisher_database_id
    AND xact_seqno > 0x0005D665000015750080000000000000  -- Replace with last replicated xact_seqno
ORDER BY xact_seqno ASC;
GO

-- 7.4 Count Commands in Current Transaction
SELECT COUNT(*) AS command_count
FROM distribution.dbo.MSrepl_commands
WHERE xact_seqno = 0x0005D665000015750080000000000000  -- Replace with xact_seqno being replicated
    AND publisher_database_id = 1;                     -- Replace with actual publisher_database_id
GO

/*******************************************************************************
 * SECTION 8: TROUBLESHOOTING SPECIFIC ISSUES
 ******************************************************************************/

-- 8.1 Fix Identity Insert Errors
-- Error: "Cannot insert explicit value for identity column when IDENTITY_INSERT is set to OFF"
-- This sets the identity column replication flag for all tables
EXEC sp_msforeachtable 
    @command1 = 'DECLARE @int INT; 
                 SET @int = OBJECT_ID(''?''); 
                 EXEC sys.sp_identitycolumnforreplication @int, 1;';
GO

/*******************************************************************************
 * SECTION 9: PERFORMANCE ANALYSIS - AGENT WAITS
 ******************************************************************************/

-- 9.1 Find Distribution Agent Session ID
SELECT 
    session_id, 
    program_name, 
    reads, 
    writes, 
    logical_reads, 
    DB_NAME(database_id) AS database_name
FROM sys.dm_exec_sessions
WHERE program_name LIKE 'Replication%';
GO

-- 9.2 Create Extended Event Session to Track Agent Waits
CREATE EVENT SESSION Replication_AGT_Waits
ON SERVER
ADD EVENT sqlos.wait_info(
    ACTION (sqlserver.session_id)
    WHERE [package0].[equal_uint64]([sqlserver].[session_id], (61))  -- Replace with session_id from 9.1
)
ADD TARGET package0.asynchronous_file_target(
    SET FILENAME = N'C:\SQLskills\ReplAGTStats.xel',
        METADATAFILE = N'C:\SQLskills\ReplAGTStats.xem'
);
GO

-- 9.3 Start Extended Event Session
ALTER EVENT SESSION Replication_AGT_Waits ON SERVER STATE = START;
GO

-- Let it run for appropriate duration, then stop it:
-- ALTER EVENT SESSION Replication_AGT_Waits ON SERVER STATE = STOP;
-- GO

-- 9.4 Cleanup: Drop Extended Event Session
-- DROP EVENT SESSION Replication_AGT_Waits ON SERVER;
-- GO

-- 9.5 Read Extended Event Data - Stage 1
-- Load raw XML data from extended event files
SELECT CAST(event_data AS XML) AS event_data
INTO #ReplicationAgentWaits_Stage_1
FROM sys.fn_xe_file_target_read_file(
    'C:\SQLskills\ReplAGTStats*.xel',
    'C:\SQLskills\ReplAGTStats*.xem',
    NULL, 
    NULL
);
GO

-- 9.6 Parse Extended Event Data - Stage 2
-- Extract wait information from XML
SELECT
    event_data.value('(/event/action[@name=''session_id'']/value)[1]', 'SMALLINT') AS session_id,
    event_data.value('(/event/data[@name=''wait_type'']/text)[1]', 'VARCHAR(100)') AS wait_type,
    event_data.value('(/event/data[@name=''duration'']/value)[1]', 'BIGINT') AS duration,
    event_data.value('(/event/data[@name=''signal_duration'']/value)[1]', 'BIGINT') AS signal_duration,
    event_data.value('(/event/data[@name=''completed_count'']/value)[1]', 'BIGINT') AS completed_count
INTO #ReplicationAgentWaits_Stage_2
FROM #ReplicationAgentWaits_Stage_1;
GO

-- 9.7 Aggregate Wait Statistics
-- Final result: wait statistics by session and wait type
SELECT 
    session_id,
    wait_type,
    SUM(duration) AS total_duration,
    SUM(signal_duration) AS total_signal_duration,
    SUM(completed_count) AS total_wait_count
FROM #ReplicationAgentWaits_Stage_2
GROUP BY session_id, wait_type
ORDER BY session_id, SUM(duration) DESC;
GO

-- Cleanup temp tables
DROP TABLE IF EXISTS #ReplicationAgentWaits_Stage_1;
DROP TABLE IF EXISTS #ReplicationAgentWaits_Stage_2;
GO

/*******************************************************************************
 * SECTION 10: MAINTENANCE AND CLEANUP
 ******************************************************************************/

-- 10.1 Set Distribution History Retention Period
-- Sets the history retention period to 72 hours
EXEC dbo.sp_MShistory_cleanup @history_retention = 72;
GO

/*******************************************************************************
 * END OF REPLICATION TROUBLESHOOTING QUERIES
 *******************************************************************************/