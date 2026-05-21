/*******************************************************************************
 * REPLICATION TROUBLESHOOTING QUERIES
 *
 * Purpose: Diagnose replication agent failures, measure latency with tracer
 *          tokens, inspect undistributed commands, and analyze agent waits.
 *
 * Safety:  All queries are read-only unless explicitly noted.
 *          Most queries run against the [distribution] database on the
 *          Distributor; publisher-side queries run against the publisher DB.
 *
 * Applies to: SQL Server transactional replication (on-prem and IaaS).
 *             Some perfmon / DMV queries also work for merge replication.
 *             Not intended for SQL Managed Instance (use built-in monitoring).
 *
 * Conventions:
 *   - Replace anything labelled "<replace ...>" or shown as a sample value.
 *   - Every section that touches MSrepl_* / MS*_history / MS*_agents tables
 *     starts with USE [distribution] so the script is safe to run piecemeal.
 *
 * Table of Contents:
 *   1. Agent Configuration and Status
 *   2. Agent History
 *   3. Error Diagnosis
 *   4. Publication and Subscription Information
 *   5. Tracer Token Management
 *   6. Latency Monitoring
 *   7. Transaction Analysis
 *   8. Undistributed Commands and Backlog
 *   9. Publisher-Side Checks (Log Reader Backlog, Open Transactions)
 *  10. Snapshot / Reinitialization Status
 *  11. Distribution Database Health
 *  12. Troubleshooting Specific Issues
 *  13. Performance Analysis - Agent Waits
 *  14. Maintenance and Cleanup
 ******************************************************************************/

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
GO

/*******************************************************************************
 * SECTION 1: AGENT CONFIGURATION AND STATUS
 ******************************************************************************/

USE [msdb];
GO

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
    @job_id = 'D55F576C-91B7-48D4-9F77-0C4F11105AD6',  -- <replace job_id>
    @mode   = 'FULL';
GO

USE [distribution];
GO

-- 1.3 Check Configured LogReader Agents
SELECT id, name, publisher_id, publisher_db, publisher_security_mode,
       job_id, job_step_uid, profile_id, debug_flags
FROM dbo.MSlogreader_agents;
GO

-- 1.4 Check Configured Snapshot Agents
SELECT id, name, publisher_id, publisher_db, publication, publisher_security_mode,
       job_id, job_step_uid, profile_id
FROM dbo.MSsnapshot_agents;
GO

-- 1.5 Check Configured Distribution Agents
SELECT id, name, publisher_id, publisher_db, publication,
       subscriber_id, subscriber_db, subscription_type,
       job_id, job_step_uid, profile_id
FROM dbo.MSdistribution_agents;
GO

-- 1.6 Currently Running Replication Agent Sessions on This Server
-- Quick "is anything actually connected?" check
SELECT
    s.session_id,
    s.login_time,
    s.host_name,
    s.program_name,
    s.login_name,
    s.status,
    s.reads,
    s.writes,
    s.logical_reads,
    DB_NAME(s.database_id) AS database_name
FROM sys.dm_exec_sessions s
WHERE s.program_name LIKE 'Replication%'
   OR s.program_name LIKE 'repl-%';
GO

/*******************************************************************************
 * SECTION 2: AGENT HISTORY
 ******************************************************************************/

USE [distribution];
GO

-- 2.1 LogReader Agent History (recent, projected columns)
SELECT TOP (1000)
    agent_id, runstatus, start_time, time, duration,
    delivery_time, delivery_rate, delivery_latency,
    delivered_transactions, delivered_commands, average_commands,
    error_id, comments, xact_seqno
FROM dbo.MSlogreader_history
WHERE time > DATEADD(HOUR, -24, GETDATE())
ORDER BY start_time DESC, time DESC;
GO

-- 2.2 Snapshot Agent History (recent)
SELECT TOP (1000)
    agent_id, runstatus, start_time, time, duration,
    delivered_transactions, delivered_commands, delivery_rate,
    error_id, comments
FROM dbo.MSsnapshot_history
WHERE time > DATEADD(HOUR, -24, GETDATE())
ORDER BY start_time DESC, time DESC;
GO

-- 2.3 Distribution Agent History (recent)
SELECT TOP (1000)
    agent_id, runstatus, start_time, time, duration,
    delivery_time, delivery_rate, delivery_latency,
    delivered_transactions, delivered_commands, average_commands,
    current_delivery_rate, current_delivery_latency,
    error_id, comments, xact_seqno
FROM dbo.MSdistribution_history
WHERE time > DATEADD(HOUR, -24, GETDATE())
ORDER BY start_time DESC, time DESC;
GO

-- 2.4 LogReader Agent History (filtered by Agent ID)
SELECT TOP (500)
    runstatus, start_time, time, duration, delivery_latency,
    delivered_transactions, delivered_commands, error_id, comments, xact_seqno
FROM dbo.MSlogreader_history
WHERE agent_id = 1                                    -- <replace agent_id from 1.3>
ORDER BY start_time DESC, time DESC;
GO

-- 2.5 Snapshot Agent History (filtered by Agent ID)
SELECT TOP (500)
    runstatus, start_time, time, duration,
    delivered_transactions, delivered_commands, error_id, comments
FROM dbo.MSsnapshot_history
WHERE agent_id = 1                                    -- <replace agent_id from 1.4>
ORDER BY start_time DESC, time DESC;
GO

-- 2.6 Distribution Agent History (filtered by Agent ID)
SELECT TOP (500)
    runstatus, start_time, time, duration, delivery_latency,
    delivered_transactions, delivered_commands,
    current_delivery_rate, current_delivery_latency,
    error_id, comments, xact_seqno
FROM dbo.MSdistribution_history
WHERE agent_id = 3                                    -- <replace agent_id from 1.5>
ORDER BY start_time DESC, time DESC;
GO

-- 2.7 runstatus reference:
--   1 = Start, 2 = Succeed, 3 = In Progress, 4 = Idle,
--   5 = Retry, 6 = Fail
GO

/*******************************************************************************
 * SECTION 3: ERROR DIAGNOSIS
 ******************************************************************************/

USE [distribution];
GO

-- 3.1 Recent Replication Errors
SELECT TOP (1000)
    id, time, error_type_id, source_type_id, source_name,
    error_code, error_text
FROM dbo.MSrepl_errors
WHERE time > DATEADD(DAY, -7, GETDATE())
ORDER BY time DESC;
GO

-- 3.2 Investigate Specific Transaction Error
-- Use the transaction sequence number from the error message
DECLARE @xact_seqno VARBINARY(16) = 0x00CB2EBA000031B4001300000000;  -- <replace>

SELECT *
FROM dbo.MSrepl_transactions
WHERE xact_seqno = @xact_seqno;

SELECT *
FROM dbo.MSrepl_commands
WHERE xact_seqno = @xact_seqno;
GO

-- 3.3 Browse Replication Commands for Error
-- Use values from error message
EXEC sp_browsereplcmds
    @xact_seqno_start      = '0x00CB2EBA000031B4001300000000',  -- <replace>
    @xact_seqno_end        = '0x00CB2EBA000031B4001300000000',  -- <replace>
    @command_id            = 16,                                -- <replace>
    @publisher_database_id = 2;                                 -- <replace>
GO

/*******************************************************************************
 * SECTION 4: PUBLICATION AND SUBSCRIPTION INFORMATION
 ******************************************************************************/

USE [distribution];
GO

-- 4.1 Find Publications with Subscription Details
SELECT DISTINCT
    pb.publisher_db,
    da.subscriber_db,
    pb.publication,
    pd.id  AS pub_db_id,
    da.id  AS agent_id,
    CASE ps.status
        WHEN 0 THEN 'Inactive'
        WHEN 1 THEN 'Subscribed'
        WHEN 2 THEN 'Active'
    END    AS subscription_status,
    pb.description
FROM dbo.MSpublications pb
    LEFT JOIN dbo.MSdistribution_agents da
        ON da.publication = pb.publication
       AND da.subscriber_db <> 'virtual'
    LEFT JOIN dbo.MSsubscriptions ps
        ON ps.publisher_db  = pb.publisher_db
       AND ps.subscriber_db = da.subscriber_db
    JOIN dbo.MSpublisher_databases pd
        ON pb.publisher_db = pd.publisher_db;
GO

-- 4.2 Get Publisher Database IDs
SELECT id, publisher_id, publisher_db, publication_type
FROM dbo.MSpublisher_databases;
GO

-- 4.3 Get Distribution Agent IDs by Publisher Database
SELECT id, name, publisher_db, publication, subscriber_db, subscription_type
FROM dbo.MSdistribution_agents
WHERE publisher_database_id = 1;                       -- <replace>
GO

/*******************************************************************************
 * SECTION 5: TRACER TOKEN MANAGEMENT
 ******************************************************************************/

-- 5.1 Post Tracer Token (run on the PUBLISHER, against the published database)
-- USE [<publisher_database>];
EXEC sys.sp_posttracertoken
    @publication = 'publication_name';                 -- <replace>
GO

-- 5.2 View Tracer Token History (run on the DISTRIBUTOR)
USE [distribution];
GO
EXEC sys.sp_helptracertokens
    @publisher    = 'instance\name',                   -- <replace>
    @publication  = 'publication_TABLES',              -- <replace>
    @publisher_db = 'publisher_database';              -- <replace>
GO

-- 5.3 View Specific Tracer Token Details
EXEC sys.sp_helptracertokenhistory
    @publisher    = 'instance\name',                   -- <replace>
    @publication  = 'publication_TABLES',              -- <replace>
    @publisher_db = 'publisher_database',              -- <replace>
    @tracer_id    = -2147483634;                       -- <replace>
GO

-- 5.4 Delete Faulty Tracer Token
-- Use this to remove tracer tokens that show NULL subscriber latency
EXEC sys.sp_deletetracertokenhistory
    @publisher    = 'instance\name',                   -- <replace>
    @publication  = 'publication_TABLES',              -- <replace>
    @publisher_db = 'publisher_database',              -- <replace>
    @tracer_id    = -2147483634;                       -- <replace>
GO

/*******************************************************************************
 * SECTION 6: LATENCY MONITORING
 ******************************************************************************/

USE [distribution];
GO

-- 6.1 Comprehensive Replication Lag with Tracer Tokens
SELECT
    ps.name             AS publisher,
    p.publisher_db,
    p.publication,
    ss.name             AS subscriber,
    da.subscriber_db,
    t.publisher_commit,
    t.distributor_commit,
    h.subscriber_commit,
    DATEDIFF(SECOND, t.publisher_commit,   t.distributor_commit) AS pub_to_dist_sec,
    DATEDIFF(SECOND, t.distributor_commit, h.subscriber_commit)  AS dist_to_sub_sec,
    DATEDIFF(SECOND, t.publisher_commit,   h.subscriber_commit)  AS total_latency_sec
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
WHERE 1 = 1
    -- Uncomment / modify filters as needed:
    -- AND p.publisher_db = 'YourPublisherDB'
    -- AND DATEDIFF(SECOND, t.publisher_commit, h.subscriber_commit) > 60
    -- AND t.publisher_commit > DATEADD(DAY, -1, GETDATE())
    -- AND ss.name = 'YourSubscriber'
    -- AND p.publication IN ('publication1', 'publication2')
    -- AND h.subscriber_commit IS NOT NULL
ORDER BY
    ps.name, p.publisher_db, p.publication, ss.name, da.subscriber_db,
    t.publisher_commit DESC;
GO

-- 6.2 System Performance Counters for Latency
-- Notes:
--   * Both counters report the latency of the LAST delivered batch in
--     MILLISECONDS - they are point-in-time, not cumulative.
--   * Logreader:Delivery Latency = time from a transaction's commit at the
--     publisher to its arrival in the distribution database.
--   * Dist:Delivery Latency     = time from a command being read out of
--     the distribution database to its commit at the subscriber.
--   * instance_name identifies the publisher_db / subscription.
SELECT
    object_name,
    instance_name,
    counter_name,
    cntr_value                                  AS latency_ms,
    CAST(cntr_value / 1000.0 AS DECIMAL(10, 3)) AS latency_sec
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
        'Logreader:Delivery Latency',
        'Dist:Delivery Latency'
      )
ORDER BY object_name, instance_name;
GO

-- 6.3 Advanced Latency Analysis with Pending-Token Fallback
;WITH Replication_Tracers AS
(
    SELECT
        ps.name AS publisher,
        p.publisher_db,
        p.publication,
        ss.name AS subscriber,
        da.subscriber_db,
        t.publisher_commit,
        t.distributor_commit,
        h.subscriber_commit,
        DATEDIFF(SECOND, t.publisher_commit,   t.distributor_commit) AS pub_to_dist_sec,
        DATEDIFF(SECOND, t.distributor_commit, h.subscriber_commit)  AS dist_to_sub_sec,
        DATEDIFF(SECOND, t.publisher_commit,   h.subscriber_commit)  AS total_latency_sec
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
),
Replication_Latency AS
(
    -- Recent tokens with actual latency
    SELECT publisher, publisher_db, publication, subscriber, subscriber_db,
           publisher_commit, total_latency_sec
    FROM Replication_Tracers
    WHERE publisher_commit > DATEADD(HOUR, -1, GETDATE())
      AND total_latency_sec IS NOT NULL

    UNION ALL  -- branches are disjoint by total_latency_sec NULL/NOT NULL

    -- Oldest pending token per subscription (NULL latency)
    SELECT publisher, publisher_db, publication, subscriber, subscriber_db,
           publisher_commit, total_latency_sec
    FROM (
        SELECT publisher, publisher_db, publication, subscriber, subscriber_db,
               publisher_commit, total_latency_sec,
               RANK() OVER (
                   PARTITION BY publisher, publisher_db, publication,
                                subscriber, subscriber_db
                   ORDER BY publisher_commit ASC
               ) AS rn
        FROM Replication_Tracers
        WHERE total_latency_sec IS NULL
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
    ISNULL(total_latency_sec, DATEDIFF(SECOND, publisher_commit, GETDATE()))
        AS lag_sec,
    RANK() OVER (
        PARTITION BY publisher, publisher_db, publication,
                     subscriber, subscriber_db
        ORDER BY publisher_commit DESC
    ) AS rank_order
FROM Replication_Latency
ORDER BY lag_sec DESC;
GO

-- 6.4 Simple Lag Check - Last Delivered Transaction per Agent
-- Step 1: Pick the agent (use 1.5 / 4.3 to find the right agent_id).
DECLARE @agent_id INT = 3;                              -- <replace agent_id>

-- Step 2: Find the last seqno actually delivered by that agent.
--   MSdistribution_history.xact_seqno is the high-water mark of the batch
--   that finished in each history row, so MAX() per-agent is accurate.
DECLARE @last_xact_seqno VARBINARY(16) =
(
    SELECT MAX(xact_seqno)
    FROM dbo.MSdistribution_history WITH (NOLOCK)
    WHERE agent_id     = @agent_id
      AND xact_seqno IS NOT NULL
);

SELECT @last_xact_seqno AS last_delivered_seqno;

-- Step 3: When was that transaction queued at the distributor?
SELECT entry_time, publisher_database_id
FROM dbo.MSrepl_transactions WITH (NOLOCK)
WHERE xact_seqno = @last_xact_seqno;
GO

-- 6.5 Pending Commands per Subscription (built-in, no math)
-- Most reliable single number for "how far behind am I".
EXEC sys.sp_replmonitorsubscriptionpendingcmds
    @publisher          = 'instance\name',             -- <replace>
    @publisher_db       = 'publisher_database',        -- <replace>
    @publication        = 'publication_name',          -- <replace>
    @subscriber         = 'subscriber_instance',       -- <replace>
    @subscriber_db      = 'subscriber_database',       -- <replace>
    @subscription_type  = 0;                           -- 0=push, 1=pull
GO

/*******************************************************************************
 * SECTION 7: TRANSACTION ANALYSIS
 ******************************************************************************/

USE [distribution];
GO

-- 7.1 Identify Large Transactions (today)
-- Heuristic: <5 commands typical OLTP, 400-500 batched, >1000 = "fat".
-- Pre-filter MSrepl_commands by publisher_database_id to avoid scanning
-- the full commands table on busy distributors.
DECLARE @publisher_db SYSNAME = 'YourPublisherDB';      -- <replace>

;WITH cmds AS
(
    SELECT rc.xact_seqno, rc.publisher_database_id
    FROM dbo.MSrepl_commands rc
    WHERE rc.publisher_database_id IN
          (SELECT id FROM dbo.MSpublisher_databases WHERE publisher_db = @publisher_db)
)
SELECT
    rt.entry_time,
    rt.xact_seqno,
    COUNT(*) AS command_count
FROM cmds c
    JOIN dbo.MSrepl_transactions rt
        ON rt.xact_seqno             = c.xact_seqno
       AND rt.publisher_database_id  = c.publisher_database_id
WHERE rt.entry_time >= CAST(GETDATE() AS DATE)
GROUP BY rt.entry_time, rt.xact_seqno
HAVING COUNT(*) > 1000
ORDER BY COUNT(*) DESC;
GO

-- 7.2 Analyze Distribution Agent Progress (XML stats from history)
;WITH CTE1 AS
(
    SELECT TOP (10)
        ROW_NUMBER() OVER (ORDER BY dh.xact_seqno DESC, dh.time DESC) AS rownum,
        CONVERT(XML, dh.comments).value('(/stats/@cmds)[1]',  'int') AS stats_cmds,
        CONVERT(XML, dh.comments).value('(/stats/@state)[1]', 'int') AS stats_state,
        CONVERT(XML, dh.comments).value('(/stats/@work)[1]',  'int') AS stats_work,
        CONVERT(XML, dh.comments).value('(/stats/@idle)[1]',  'int') AS stats_idle,
        dh.agent_id, dh.runstatus, dh.start_time, dh.time, dh.duration,
        dh.delivery_rate, dh.delivery_latency,
        dh.delivered_transactions, dh.delivered_commands, dh.xact_seqno
    FROM dbo.MSdistribution_history dh WITH (NOLOCK)
    WHERE dh.agent_id = 24                              -- <replace agent_id>
    ORDER BY dh.xact_seqno DESC, dh.time DESC
)
SELECT
    c1.stats_cmds - c2.stats_cmds      AS cmd_diff,
    DATEDIFF(MINUTE, c2.time, c1.time) AS minutes_between_rows,
    c1.*
FROM CTE1 c1
    LEFT JOIN CTE1 c2 ON c1.rownum = c2.rownum - 1
ORDER BY c1.rownum;
GO

-- 7.3 Find Next Transaction to be Replicated
SELECT TOP (1) *
FROM dbo.MSrepl_transactions WITH (NOLOCK)
WHERE publisher_database_id = 1                         -- <replace>
  AND xact_seqno > 0x0005D665000015750080000000000000   -- <replace last delivered seqno>
ORDER BY xact_seqno ASC;
GO

-- 7.4 Count Commands in a Specific Transaction
SELECT COUNT(*) AS command_count
FROM dbo.MSrepl_commands
WHERE xact_seqno            = 0x0005D665000015750080000000000000  -- <replace>
  AND publisher_database_id = 1;                                  -- <replace>
GO

/*******************************************************************************
 * SECTION 8: UNDISTRIBUTED COMMANDS AND BACKLOG
 ******************************************************************************/

USE [distribution];
GO

-- 8.1 Pending Commands per Publication / Subscription (built-in)
EXEC sys.sp_replmonitorsubscriptionpendingcmds
    @publisher          = 'instance\name',              -- <replace>
    @publisher_db       = 'publisher_database',         -- <replace>
    @publication        = 'publication_name',           -- <replace>
    @subscriber         = 'subscriber_instance',        -- <replace>
    @subscriber_db      = 'subscriber_database',        -- <replace>
    @subscription_type  = 0;
GO

-- 8.2 High-Level Publisher Health (latency, pending cmds, status)
EXEC sys.sp_replmonitorhelppublisher
    @publisher = 'instance\name';                       -- <replace, NULL = all>
GO

-- 8.3 Per-Publication Subscription Status (status / latency / cmds)
EXEC sys.sp_replmonitorhelpsubscription
    @publisher          = 'instance\name',              -- <replace>
    @publisher_db       = 'publisher_database',         -- <replace>
    @publication        = 'publication_name',           -- <replace>
    @publication_type   = 0;                            -- 0=trans, 1=snap, 2=merge
GO

-- 8.4 Manual Backlog Estimate (commands not yet delivered to a subscriber)
-- Counts MSrepl_commands rows newer than the last seqno actually delivered
-- by the distribution agent for each publication / subscription.
;WITH last_delivered AS
(
    SELECT
        da.publisher_database_id,
        da.publication,
        da.subscriber_db,
        MAX(dh.xact_seqno) AS last_xact_seqno
    FROM dbo.MSdistribution_agents da
        LEFT JOIN dbo.MSdistribution_history dh
            ON dh.agent_id = da.id
    WHERE da.subscriber_db <> 'virtual'
    GROUP BY da.publisher_database_id, da.publication, da.subscriber_db
)
SELECT
    pd.publisher_db,
    ld.publication,
    ld.subscriber_db,
    ld.last_xact_seqno,
    COUNT_BIG(*) AS pending_commands
FROM last_delivered ld
    JOIN dbo.MSrepl_commands rc WITH (NOLOCK)
        ON rc.publisher_database_id = ld.publisher_database_id
       AND rc.xact_seqno > ISNULL(ld.last_xact_seqno, 0x0)
    JOIN dbo.MSpublisher_databases pd
        ON pd.id = ld.publisher_database_id
GROUP BY pd.publisher_db, ld.publication, ld.subscriber_db, ld.last_xact_seqno
ORDER BY pending_commands DESC;
GO

/*******************************************************************************
 * SECTION 9: PUBLISHER-SIDE CHECKS (LOG READER BACKLOG, OPEN TRANSACTIONS)
 ******************************************************************************/

-- Run these on the PUBLISHER, against the published database.
-- USE [<published_database>];
-- GO

-- 9.1 Oldest Open / Unreplicated Transaction in the Log
DBCC OPENTRAN WITH TABLERESULTS;
GO

-- 9.2 Log Reader Backlog Snapshot
-- Returns the number of transactions in the publisher log waiting to be
-- read by the Log Reader Agent, plus the time of the oldest one.
EXEC sys.sp_replcounters;
GO

-- 9.3 Pending Transactions Awaiting Log Reader
-- 0 = caught up; >0 = log reader behind / not running
EXEC sys.sp_repltrans;
GO

-- 9.4 Log-Space Used by Replication
-- If log_reuse_wait_desc = 'REPLICATION' on the published DB, the log
-- reader is behind or disabled - investigate before the log fills.
SELECT
    name,
    log_reuse_wait_desc,
    state_desc,
    recovery_model_desc
FROM sys.databases
WHERE database_id = DB_ID();
GO

/*******************************************************************************
 * SECTION 10: SNAPSHOT / REINITIALIZATION STATUS
 ******************************************************************************/

-- 10.1 Subscription Sync Type and Reinit State (run on SUBSCRIBER DB)
-- USE [<subscriber_database>];
SELECT
    publisher,
    publisher_db,
    publication,
    subscription_type,            -- 0=push, 1=pull, 2=anonymous
    sync_type,                    -- 1=automatic, 2=none, etc.
    [status],                     -- 0=inactive,1=subscribed,2=active
    subscription_seqno,
    last_updated
FROM dbo.MSreplication_subscriptions;
GO

-- 10.2 Subscriptions Marked for Reinitialization (on DISTRIBUTOR)
USE [distribution];
GO
SELECT
    da.publisher_db,
    da.publication,
    da.subscriber_db,
    s.[status],
    s.subscription_type,
    s.sync_type,
    s.subscription_seqno
FROM dbo.MSsubscriptions s
    JOIN dbo.MSdistribution_agents da
        ON da.id = s.agent_id
WHERE s.[status] IN (0, 1)            -- 0=Inactive, 1=Subscribed (awaiting init)
ORDER BY da.publisher_db, da.publication, da.subscriber_db;
GO

-- 10.3 Latest Snapshot Generated per Publication
SELECT
    a.publisher_db,
    a.publication,
    MAX(h.start_time)         AS last_snapshot_start,
    MAX(h.delivered_commands) AS last_snapshot_commands
FROM dbo.MSsnapshot_agents a
    LEFT JOIN dbo.MSsnapshot_history h
        ON h.agent_id = a.id
       AND h.runstatus = 2          -- 2 = Succeeded
GROUP BY a.publisher_db, a.publication
ORDER BY a.publisher_db, a.publication;
GO

/*******************************************************************************
 * SECTION 11: DISTRIBUTION DATABASE HEALTH
 ******************************************************************************/

USE [distribution];
GO

-- 11.1 Distribution DB Size and File Usage
SELECT
    f.name           AS logical_name,
    f.type_desc,
    f.physical_name,
    CAST(f.size      * 8.0 / 1024 AS DECIMAL(12, 2)) AS size_mb,
    CAST(FILEPROPERTY(f.name, 'SpaceUsed') * 8.0 / 1024
                                       AS DECIMAL(12, 2)) AS used_mb,
    f.growth, f.is_percent_growth, f.max_size
FROM sys.database_files f;
GO

-- 11.2 Row Counts for the Big Replication Tables
SELECT
    OBJECT_NAME(p.object_id) AS table_name,
    SUM(p.row_count)         AS row_count_estimate,
    SUM(p.reserved_page_count) * 8 / 1024 AS reserved_mb
FROM sys.dm_db_partition_stats p
    JOIN sys.objects o ON o.object_id = p.object_id
WHERE o.is_ms_shipped = 1
  AND p.index_id IN (0, 1)
  AND OBJECT_NAME(p.object_id) IN
      ('MSrepl_commands', 'MSrepl_transactions', 'MSrepl_errors',
       'MSdistribution_history', 'MSlogreader_history', 'MSsnapshot_history',
       'MSrepl_backup_lsns', 'MStracer_tokens', 'MStracer_history')
GROUP BY p.object_id
ORDER BY reserved_mb DESC;
GO

-- 11.3 Distribution Cleanup / Maintenance Job Status
SELECT
    j.name,
    j.enabled,
    h.run_date, h.run_time, h.run_duration,
    CASE h.run_status
        WHEN 0 THEN 'Failed'  WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'   WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
    END AS run_status_desc,
    h.message
FROM msdb.dbo.sysjobs j
    OUTER APPLY (
        SELECT TOP (3) hh.run_date, hh.run_time, hh.run_duration,
                       hh.run_status, hh.message
        FROM msdb.dbo.sysjobhistory hh
        WHERE hh.job_id  = j.job_id
          AND hh.step_id = 0
        ORDER BY hh.run_date DESC, hh.run_time DESC
    ) h
WHERE j.name IN
    ('Distribution clean up: distribution',
     'Agent history clean up: distribution',
     'Expired subscription clean up',
     'Reinitialize subscriptions having data validation failures',
     'Replication agents checkup')
ORDER BY j.name, h.run_date DESC, h.run_time DESC;
GO

/*******************************************************************************
 * SECTION 12: TROUBLESHOOTING SPECIFIC ISSUES
 ******************************************************************************/

-- 12.1 Fix Identity Insert Errors on Subscriber
-- Error: "Cannot insert explicit value for identity column when
--         IDENTITY_INSERT is set to OFF"
-- Sets the replication identity flag for every table that actually has
-- an identity column. sp_msforeachtable is undocumented and skips tables
-- in some edge cases, so we enumerate sys.tables explicitly.
--
-- Run on the SUBSCRIBER database.
SET NOCOUNT ON;

DECLARE @schema   SYSNAME,
        @table    SYSNAME,
        @objid    INT,
        @msg      NVARCHAR(400);

DECLARE id_cursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
    SELECT s.name, t.name, t.object_id
    FROM sys.tables t
        JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE OBJECTPROPERTY(t.object_id, 'TableHasIdentity') = 1
      AND t.is_ms_shipped = 0;

OPEN id_cursor;
FETCH NEXT FROM id_cursor INTO @schema, @table, @objid;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @msg = QUOTENAME(@schema) + N'.' + QUOTENAME(@table)
             + N' (object_id ' + CAST(@objid AS NVARCHAR(20)) + N')';
    PRINT N'Setting identity-for-replication on ' + @msg;

    BEGIN TRY
        EXEC sys.sp_identitycolumnforreplication @objid, 1;
    END TRY
    BEGIN CATCH
        PRINT N'  FAILED: ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM id_cursor INTO @schema, @table, @objid;
END;

CLOSE id_cursor;
DEALLOCATE id_cursor;
GO

/*******************************************************************************
 * SECTION 13: PERFORMANCE ANALYSIS - AGENT WAITS
 ******************************************************************************/

-- 13.1 Find a Replication Agent Session ID
SELECT
    session_id,
    program_name,
    reads,
    writes,
    logical_reads,
    DB_NAME(database_id) AS database_name
FROM sys.dm_exec_sessions
WHERE program_name LIKE 'Replication%'
   OR program_name LIKE 'repl-%';
GO

-- 13.2 Create Extended Event Session to Track Agent Waits
-- EDIT BEFORE RUNNING:
--   * @session_id  - value from 13.1
--   * @xe_path     - writeable folder; default uses the SQL log directory
DECLARE @session_id INT = 61;                          -- <replace>
DECLARE @log_path   NVARCHAR(260)
        = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(260));
DECLARE @xe_path    NVARCHAR(260)
        = LEFT(@log_path, LEN(@log_path) - CHARINDEX('\', REVERSE(@log_path)) + 1)
        + N'ReplAGTStats.xel';

DECLARE @sql NVARCHAR(MAX) = N'
CREATE EVENT SESSION Replication_AGT_Waits ON SERVER
ADD EVENT sqlos.wait_info (
    ACTION (sqlserver.session_id)
    WHERE [package0].[equal_uint64]([sqlserver].[session_id], ('
    + CAST(@session_id AS NVARCHAR(10)) + N'))
)
ADD TARGET package0.asynchronous_file_target (
    SET FILENAME = N''' + @xe_path + N'''
);';

PRINT @sql;
EXEC (@sql);
GO

-- 13.3 Start Extended Event Session
ALTER EVENT SESSION Replication_AGT_Waits ON SERVER STATE = START;
GO

-- Let it run while the issue reproduces, then STOP before reading:
-- ALTER EVENT SESSION Replication_AGT_Waits ON SERVER STATE = STOP;
-- GO

-- 13.4 Cleanup: Drop Extended Event Session
-- DROP EVENT SESSION Replication_AGT_Waits ON SERVER;
-- GO

-- 13.5 Read Extended Event Data - Stage 1
-- Adjust the path to match what 13.2 used.
SELECT CAST(event_data AS XML) AS event_data
INTO #ReplicationAgentWaits_Stage_1
FROM sys.fn_xe_file_target_read_file(
        N'ReplAGTStats*.xel',                          -- <replace path if needed>
        NULL, NULL, NULL);
GO

-- 13.6 Parse Extended Event Data - Stage 2
SELECT
    event_data.value('(/event/action[@name="session_id"]/value)[1]',    'SMALLINT')     AS session_id,
    event_data.value('(/event/data[@name="wait_type"]/text)[1]',        'VARCHAR(100)') AS wait_type,
    event_data.value('(/event/data[@name="duration"]/value)[1]',        'BIGINT')       AS duration,
    event_data.value('(/event/data[@name="signal_duration"]/value)[1]', 'BIGINT')       AS signal_duration,
    event_data.value('(/event/data[@name="completed_count"]/value)[1]', 'BIGINT')       AS completed_count
INTO #ReplicationAgentWaits_Stage_2
FROM #ReplicationAgentWaits_Stage_1;
GO

-- 13.7 Aggregate Wait Statistics
SELECT
    session_id,
    wait_type,
    SUM(duration)        AS total_duration_ms,
    SUM(signal_duration) AS total_signal_duration_ms,
    SUM(completed_count) AS total_wait_count
FROM #ReplicationAgentWaits_Stage_2
GROUP BY session_id, wait_type
ORDER BY session_id, SUM(duration) DESC;
GO

-- 13.8 Cleanup temp tables
DROP TABLE IF EXISTS #ReplicationAgentWaits_Stage_1;
DROP TABLE IF EXISTS #ReplicationAgentWaits_Stage_2;
GO


