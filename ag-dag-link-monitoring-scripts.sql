-----------------------------------------------------------------------
-- AG / DAG / LINK MONITORING SCRIPTS
-- Purpose : Monitor Availability Group, Distributed AG, and Managed
--           Instance Link health — replica status, seeding progress,
--           failover events, and geo-replication lag.
-- Safety  : All queries are read-only against user data. Query #16
--           creates/drops a #temp table and needs securityadmin (or
--           sysadmin) to run xp_readerrorlog.
-- Applies to : On-prem (AG/DAG) / Azure SQL MI (Link feature).
--           MI-only    : #5 (sys.dm_geo_replication_link_status).
--           On-prem only: #4b/#8 (cluster DMVs), #16 (xp_readerrorlog),
--                         #18 (listener), #19 (Get-ClusterLog).
-----------------------------------------------------------------------
-- TROUBLESHOOTING METHODOLOGY: AG SYNCHRONIZATION ISSUES
-- Troubleshooting Always On Availability Group (AOAG) synchronization
-- issues requires a systematic analysis of synchronization states, log
-- queues, wait statistics, and underlying infrastructure performance.
--
-- 1) Identify the Synchronization State (see queries #2a, #4a and #9
--    below):
--    - SYNCHRONIZED     : Synchronous-commit mode; secondary is caught
--                         up and primary waits for acknowledgment
--                         before committing transactions.
--    - SYNCHRONIZING    : Normal healthy state for async-commit
--                         replicas. For sync replicas, it means the
--                         secondary is currently catching up.
--    - NOT SYNCHRONIZING: Replica is disconnected or data movement has
--                         been suspended.
--    - REVERTING        : Secondary must undo changes (e.g. after a
--                         failover interrupted a large transaction) to
--                         go back in sync. Inherently slow.
--
-- 2) Investigate Log Send Queue latency (see queries #6 and #10 below):
--    - Network throughput: check for latency/dropped packets in
--      multi-site or cross-region groups; on Windows, disable TCP
--      Congestion Window Restart:
--      Set-NetTCPSetting -SettingName <profile> -CwndRestart False
--    - I/O stalls on secondary: high write latency on the secondary's
--      transaction log delays acknowledgments back to primary (see
--      query #11, sys.dm_io_virtual_file_stats).
--    - Primary CPU load: log capture/compression is CPU-intensive; an
--      overloaded primary can cause send queue growth.
--    - Wait type: monitor HADR_SYNC_COMMIT on the primary. High wait
--      times mean the primary is waiting too long for the secondary
--      to harden log records (see query #10).
--
-- 3) Investigate Recovery (Redo) Queue (see queries #6 and #12 below):
--    - Redo thread blockage: read-only workloads on the secondary
--      acquire Schema Stability (Sch-S) locks, which can block redo
--      threads attempting Schema Modification (Sch-M) operations
--      (e.g. ALTER TABLE).
--    - Parallel redo issues: watch for DIRTY_PAGE_TABLE_LOCK or
--      PARALLEL_REDO_FLOW_CONTROL waits. If redo is frequently
--      blocked, consider temporarily disabling readable secondaries.
--    - Resource contention: ensure the secondary has enough CPU and
--      I/O bandwidth to keep up with the redo rate.
--
-- 4) Resolve Disconnections and Timeouts (see query #13 below):
--    - Intermittent disconnects often result from SESSION_TIMEOUT
--      being exceeded (default 10 seconds).
--    - High CPU (100%) or non-yielding schedulers can prevent SQL
--      Server from responding to pings within the timeout.
--    - Verify database mirroring endpoints (default port 5022) are
--      started and not in conflict; test with Test-NetConnection
--      (see query #2b). If clients cannot connect but replicas are
--      healthy, check the listener and routing config (query #18).
--    - Ensure encryption algorithms and authentication types match on
--      both replicas.
--
-- 5) Handle Critical Error Scenarios (see queries #14/#15 below):
--    - Transaction Log Full (Error 9002): if the primary log cannot
--      truncate due to AVAILABILITY_REPLICA, log records haven't been
--      hardened on all secondaries. Add log space or, as a last
--      resort, remove a problematic secondary to allow truncation.
--    - Automatic seeding failures: ensure the secondary has CREATE ANY
--      DATABASE permission; check the error log for path access
--      issues or mismatched FILESTREAM settings.
--    - Suspect/Recovery Pending databases on primary: failover will
--      NOT automatically occur. Remove the replica from the group,
--      fix the underlying issue (e.g. I/O failure), and rejoin it.
--      Check sys.dm_hadr_auto_page_repair (query #17) for evidence of
--      underlying storage corruption.
--
-- Recommended diagnostic tools:
--    - AlwaysOn_health XEvent session: tracks state changes, lease
--      expirations, and high-severity errors (see query #7 and #16).
--    - sys.dm_hadr_database_replica_states: primary DMV for LSNs,
--      queue sizes, and rates (see queries #2a, #6 and #9).
--    - Windows Cluster Log: for issues between the SQL Server resource
--      DLL and the WSFC. Generate with PowerShell: Get-ClusterLog
--      (see query #19).
--
-- IsAlive / LEASE TIMEOUT FAILURES
-- An IsAlive check failure means the Windows Cluster service (the SQL
-- Server Resource DLL) contacted the instance via shared memory and
-- got no response within the timeout (default 5 sec, tied to a
-- 20-second lease). The cluster then assumes the instance is dead/hung
-- and restarts it or fails it over. Common root causes:
--   1. SQL Server "frozen" by memory dump generation: a critical error
--      (scheduler deadlock, access violation, assertion failure)
--      triggers SQLDumper, which suspends the whole process, including
--      the thread that answers the cluster heartbeat. Evidence: "Stack
--      Dump being sent to..." in the error log just before failure.
--   2. Severe resource exhaustion: CPU pinned near 100% starves the
--      lease-response thread ("thread starvation"); or memory pressure
--      forces aggressive working-set trimming/paging, and slow disk
--      I/O to page memory back in exceeds the timeout.
--   3. Virtualization issues: VM snapshots or vMotion can "stun" the
--      guest OS for several seconds; if this exceeds the lease
--      timeout, the cluster detects a time jump/timeout and fails the
--      resource. Memory ballooning on an overcommitted host can cause
--      similar unresponsiveness.
--   4. Communication/Lease failure: the AG lease mechanism (used to
--      prevent split-brain) exchanges heartbeats between the SQL
--      Server resource DLL and the instance. On failure, SQL Server
--      proactively restarts. Error log shows: "Error: 19407, The lease
--      between availability group '...' and the Windows Server
--      Failover Cluster has expired."
--
-- Troubleshooting steps for IsAlive/lease failures — examine, for the
-- time of failure:
--   1. SQL Server Error Log: look for "Stack Dump", "Non-yielding
--      scheduler", or "Lease expired" messages just before the restart
--      (see query #16).
--   2. Windows Cluster Log: generate via PowerShell (Get-ClusterLog).
--      Search for "[hadrag] Resource Alive result 0" or "Lease timeout
--      detected"; often includes CPU/memory stats at failure time.
--   3. Windows System Event Log: look for Event IDs 1135 (cluster node
--      removed) or 1177 (quorum lost) to see if network connectivity
--      issues caused the cluster to lose sight of the node. Cross-check
--      quorum votes with query #4b.
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
-- Session-level READ UNCOMMITTED persists across the GO batches below,
-- so no per-table NOLOCK hints are needed.

-----------------------------------------------------------------------
-- 1. VALIDATE DAG/LINK STATUS
--    Change @dagName to your Distributed AG name.
-----------------------------------------------------------------------
DECLARE @dagName NVARCHAR(MAX) = N'<YourDAGNameHere>';
SELECT 
   ag.[name] AS [DAG Name], 
   ag.is_distributed, 
   ar.replica_server_name AS [Underlying AG],
   ars.role_desc AS [Role], 
   ars.connected_state_desc AS [Connected Status],
   ars.synchronization_health_desc AS [Sync Status],
   ar.endpoint_url as [Endpoint URL],
   ar.availability_mode_desc AS [Sync mode],
   ar.failover_mode_desc AS [Failover mode],
   ar.seeding_mode_desc AS [Seeding mode],
   ar.primary_role_allow_connections_desc AS [Primary allow connections],
   ar.secondary_role_allow_connections_desc AS [Secondary allow connections]
FROM  sys.availability_groups AS ag
INNER JOIN sys.availability_replicas AS ar 
   ON  ag.group_id = ar.group_id        
INNER JOIN sys.dm_hadr_availability_replica_states AS ars       
   ON  ar.replica_id = ars.replica_id
WHERE ag.is_distributed = 1 AND ag.name = @dagName;
GO

-----------------------------------------------------------------------
-- 2a. RETRIEVE DATABASE REPLICA STATUS
--     Change @agName to your AG name.
-----------------------------------------------------------------------
DECLARE @agName NVARCHAR(MAX) = N'<YourAGNameHere>';
SELECT 
    d.name, 
    hdrs.*
FROM sys.dm_hadr_database_replica_states hdrs 
    JOIN sys.databases d 
        ON hdrs.database_id = d.database_id 
    JOIN sys.availability_groups ag
        ON ag.group_id = hdrs.group_id
WHERE ag.name = @agName;
GO

-----------------------------------------------------------------------
-- 2b. VIEW DATABASE MIRRORING ENDPOINTS
--     The AG data-movement endpoint (default port 5022). state_desc
--     must be 'STARTED' on every replica.
-----------------------------------------------------------------------
SELECT 
    name,
    state_desc,
    role_desc,
    is_encryption_enabled,
    encryption_algorithm_desc,
    connection_auth_desc
FROM sys.database_mirroring_endpoints 
WHERE type_desc = 'DATABASE_MIRRORING';
GO

-----------------------------------------------------------------------
-- 3. CHECK SEEDING STATUS AND SPEED
--    Change @seedAgName to your AG name. Drop the availability_groups
--    join and the WHERE clause to see every seeding operation running
--    on this instance regardless of AG.
-----------------------------------------------------------------------
DECLARE @seedAgName NVARCHAR(MAX) = N'<YourAGNameHere>';
SELECT
	pss.local_database_name AS [Local database name],
	auto.current_state AS [Current state],
	auto.is_source AS [Is source], --bit
	pss.internal_state_desc AS [Internal state desc],
	-- pss.local_physical_seeding_id, 
	-- pss.remote_physical_seeding_id, 
	CAST(pss.database_size_bytes / 1048576.0 AS DECIMAL(19, 2)) AS [Database size MB], 
	CAST(pss.transferred_size_bytes / 1048576.0 AS DECIMAL(19, 2)) AS [Transferred MB],
	CAST(pss.transfer_rate_bytes_per_second / 1048576.0 AS DECIMAL(19, 2)) AS [Transfer rate MB/s], 
	CAST(pss.total_disk_io_wait_time_ms / 1000.0 AS DECIMAL(19, 1)) AS [Total Disk IO wait (sec)],
	CAST(pss.total_network_wait_time_ms / 1000.0 AS DECIMAL(19, 1)) AS [Total Network wait (sec)],
	pss.is_compression_enabled AS [Compression],
	pss.start_time_utc AS [Start time UTC], 
	pss.estimate_time_complete_utc AS [Estimated time complete UTC],
	pss.end_time_utc AS [End time UTC],
	auto.completion_time AS [Completion time], --datetime
	auto.number_of_attempts AS [Attempt No] --int
FROM sys.dm_hadr_physical_seeding_stats AS pss
	INNER JOIN sys.dm_hadr_automatic_seeding AS auto
		ON pss.local_physical_seeding_id = auto.operation_id
	INNER JOIN sys.availability_groups AS groups
		ON groups.group_id = auto.ag_id
WHERE groups.name = @seedAgName;
GO

-----------------------------------------------------------------------
-- 4a. AVAILABILITY GROUP-LEVEL HEALTH
--     Fastest "is this AG healthy?" check. Run on any replica.
--     Per-replica connection state and last connect error is in #13a.
-----------------------------------------------------------------------
SELECT 
    ag.name AS [AG Name],
    ags.primary_replica,
    ags.primary_recovery_health_desc,
    ags.secondary_recovery_health_desc,
    ags.synchronization_health_desc,
    ag.failure_condition_level,
    ag.health_check_timeout,
    ag.automated_backup_preference_desc,
    ag.is_distributed
FROM sys.availability_groups AS ag
INNER JOIN sys.dm_hadr_availability_group_states AS ags
    ON ag.group_id = ags.group_id
ORDER BY ag.name;
GO

-----------------------------------------------------------------------
-- 4b. WSFC QUORUM VOTES PER MEMBER
--     A member with number_of_quorum_votes = 0 cannot help form
--     quorum. Enough members going OFFLINE causes quorum loss —
--     correlate with System Event Log IDs 1135 / 1177.
-----------------------------------------------------------------------
SELECT 
    member_name,
    member_type_desc,
    member_state_desc,
    number_of_quorum_votes
FROM sys.dm_hadr_cluster_members
ORDER BY member_name;
GO

-----------------------------------------------------------------------
-- 5. GEO-REPLICATION LINK STATUS (Azure SQL MI)
--    Shows replication lags and last replication time of secondary databases.
--    Column "replication_lag_sec" indicates time difference in seconds 
--    between the last_replication value and the timestamp of that 
--    transaction's commit on the primary based on the primary database clock.
--    This value is available on the primary database only.
-----------------------------------------------------------------------
SELECT   
    link_guid, 
    partner_server, 
    last_replication, 
    replication_lag_sec   
FROM sys.dm_geo_replication_link_status;
GO
 
 
 
-----------------------------------------------------------------------
-- 6. ESTIMATED DATA LOSS (RPO) AND CATCH-UP TIME (RTO)
--    Run on the PRIMARY — queue sizes and rates are only meaningful
--    there. Uses the raw columns exposed in query #9:
--      Est RPO sec = log_send_queue_size / log_send_rate
--                    (committed data not yet hardened on the secondary)
--      Est RTO sec = redo_queue_size / redo_rate
--                    (time the secondary needs to catch up post-failover)
--    Rates are point-in-time averages, so treat these as indicative.
--    A large queue with a NULL/0 rate means movement is stalled, not fast.
-----------------------------------------------------------------------
SELECT 
    ag.name AS [AG Name],
    ar.replica_server_name,
    adc.[database_name],
    ar.availability_mode_desc,
    drs.synchronization_state_desc,
    drs.log_send_queue_size AS [Log Send Queue KB],
    drs.log_send_rate AS [Log Send Rate KB/s],
    CAST(drs.log_send_queue_size / NULLIF(drs.log_send_rate, 0) * 1.0 AS DECIMAL(19, 1)) AS [Est RPO sec],
    drs.redo_queue_size AS [Redo Queue KB],
    drs.redo_rate AS [Redo Rate KB/s],
    CAST(drs.redo_queue_size / NULLIF(drs.redo_rate, 0) * 1.0 AS DECIMAL(19, 1)) AS [Est RTO sec],
    drs.last_commit_time,
    DATEDIFF(SECOND, drs.last_commit_time, SYSDATETIME()) AS [Secs Since Last Commit]
FROM sys.dm_hadr_database_replica_states AS drs
INNER JOIN sys.availability_replicas AS ar
    ON drs.replica_id = ar.replica_id
INNER JOIN sys.availability_groups AS ag
    ON ag.group_id = drs.group_id
INNER JOIN sys.availability_databases_cluster AS adc
    ON drs.group_id = adc.group_id 
    AND drs.group_database_id = adc.group_database_id
WHERE drs.is_primary_replica = 0
ORDER BY [Est RPO sec] DESC;
GO
	
-----------------------------------------------------------------------
-- 7. FIND FAILOVER EVENTS FROM ALWAYS ON EXTENDED EVENT
--    Queries the AlwaysOn_health extended event session.
-----------------------------------------------------------------------
WITH FailoverEvents AS (
    SELECT 
        object_name,
        CONVERT(XML, event_data) AS event_data
    FROM sys.fn_xe_file_target_read_file('AlwaysOn_health*.xel', NULL, NULL, NULL)
    WHERE object_name = 'availability_replica_state_change'
)
SELECT 
    event_data.value('(/event/@timestamp)[1]', 'datetime') AS FailoverTime,
    event_data.value('(/event/data[@name="previous_state"]/text)[1]', 'nvarchar(50)') AS PreviousState,
    event_data.value('(/event/data[@name="current_state"]/text)[1]', 'nvarchar(50)') AS CurrentState,
    event_data.value('(/event/data[@name="availability_group_name"]/value)[1]', 'sysname') AS AvailabilityGroupName,
    event_data.value('(/event/data[@name="availability_replica_name"]/value)[1]', 'sysname') AS ReplicaName
FROM FailoverEvents
-- Filter on the state text rather than the numeric map value (the int
-- mapping is version-specific). Remove the WHERE clause to see every
-- replica state transition, not just promotions to primary.
WHERE event_data.value('(/event/data[@name="current_state"]/text)[1]', 'nvarchar(50)') LIKE N'PRIMARY%'
ORDER BY FailoverTime DESC;
GO
-----------------------------------------------------------------------
-- 8. AG CLUSTER INFORMATION
--    Get information about any AlwaysOn AG cluster this instance is 
--    a part of. Per-member quorum votes are in #4b.
-----------------------------------------------------------------------
SELECT 
    cluster_name, 
    quorum_type_desc, 
    quorum_state_desc
FROM sys.dm_hadr_cluster 
OPTION (RECOMPILE);
GO

-- Shows cluster nodes if SQL Server is in a failover cluster
SELECT 
    NodeName, 
    status_description, 
    is_current_owner
FROM sys.dm_os_cluster_nodes 
OPTION (RECOMPILE);
GO


-----------------------------------------------------------------------
-- 9. AG HEALTH AND STATUS OVERVIEW
--    Comprehensive per-database, per-replica detail (LSNs, queues,
--    rates). For the derived RPO/RTO seconds, see #6.
-----------------------------------------------------------------------
SELECT 
    ag.name AS [AG Name], 
    ar.replica_server_name, 
    ar.availability_mode_desc, 
    adc.[database_name], 
    drs.is_local, 
    drs.is_primary_replica, 
    drs.synchronization_state_desc, 
    drs.is_commit_participant, 
    drs.synchronization_health_desc, 
    drs.recovery_lsn, 
    drs.truncation_lsn, 
    drs.last_sent_lsn, 
    drs.last_sent_time, 
    drs.last_received_lsn, 
    drs.last_received_time, 
    drs.last_hardened_lsn, 
    drs.last_hardened_time, 
    drs.last_redone_lsn, 
    drs.last_redone_time, 
    drs.log_send_queue_size, 
    drs.log_send_rate, 
    drs.redo_queue_size, 
    drs.redo_rate, 
    drs.filestream_send_rate, 
    drs.end_of_log_lsn, 
    drs.last_commit_lsn, 
    drs.last_commit_time, 
    drs.database_state_desc 
FROM sys.dm_hadr_database_replica_states AS drs
    INNER JOIN sys.availability_databases_cluster AS adc
        ON drs.group_id = adc.group_id 
        AND drs.group_database_id = adc.group_database_id
    INNER JOIN sys.availability_groups AS ag
        ON ag.group_id = drs.group_id
    INNER JOIN sys.availability_replicas AS ar
        ON drs.group_id = ar.group_id 
        AND drs.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name, adc.[database_name] 
OPTION (RECOMPILE);
GO

-----------------------------------------------------------------------
-- 10. LOG SEND QUEUE / HADR_SYNC_COMMIT WAIT ANALYSIS
--     High HADR_SYNC_COMMIT waits on the primary indicate it is
--     waiting too long for a synchronous secondary to harden log
--     records. Also review HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING
--     and HADR% waits below for broader AG-related bottlenecks.
-----------------------------------------------------------------------
SELECT 
    wait_type, 
    waiting_tasks_count, 
    wait_time_ms, 
    max_wait_time_ms, 
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE 'HADR%'
    OR wait_type IN ('DIRTY_PAGE_TABLE_LOCK', 'PARALLEL_REDO_FLOW_CONTROL', 'REDO_THREAD_PENDING_WORK')
ORDER BY wait_time_ms DESC;
GO

-----------------------------------------------------------------------
-- 11. SECONDARY LOG WRITE I/O LATENCY (LOG SEND QUEUE ROOT CAUSE)
--     Run on the secondary replica. High avg_write_latency_ms on the
--     transaction log file delays acknowledgments to the primary and
--     grows log_send_queue_size.
-----------------------------------------------------------------------
SELECT 
    DB_NAME(vfs.database_id) AS [Database],
    mf.physical_name,
    mf.type_desc,
    vfs.num_of_writes,
    vfs.io_stall_write_ms,
    CAST(vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) * 1.0 AS DECIMAL(19, 2)) AS avg_write_latency_ms,
    vfs.num_of_reads,
    vfs.io_stall_read_ms,
    CAST(vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads, 0) * 1.0 AS DECIMAL(19, 2)) AS avg_read_latency_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id 
    AND vfs.file_id = mf.file_id
WHERE mf.type_desc = 'LOG'
ORDER BY avg_write_latency_ms DESC;
GO

-----------------------------------------------------------------------
-- 12. REDO BLOCKING ANALYSIS (RECOVERY QUEUE ROOT CAUSE)
--     Run on the secondary replica. Schema Stability (Sch-S) locks
--     held by read-only queries can block the redo thread's Schema
--     Modification (Sch-M) requests, stalling redo_queue_size.
-----------------------------------------------------------------------
SELECT 
    wt.session_id,
    wt.wait_type,
    wt.wait_duration_ms,
    wt.blocking_session_id,
    r.status,
    r.command,
    r.wait_resource,
    t.text AS blocking_sql_text
FROM sys.dm_os_waiting_tasks AS wt
LEFT JOIN sys.dm_exec_requests AS r
    ON wt.blocking_session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE wt.wait_type LIKE 'LCK_M_SCH%'
    OR wt.wait_type IN ('DIRTY_PAGE_TABLE_LOCK', 'PARALLEL_REDO_FLOW_CONTROL', 'REDO_THREAD_PENDING_WORK')
ORDER BY wt.wait_duration_ms DESC;
GO

-----------------------------------------------------------------------
-- 13. CONNECTION HEALTH / SESSION_TIMEOUT DIAGNOSTICS
--     Correlate replica connection state with resource pressure that
--     can cause missed pings (SESSION_TIMEOUT, default 10 sec) or
--     non-yielding schedulers.
-----------------------------------------------------------------------
-- 13a. Endpoint state and last connection error per replica.
--      Add "AND ars.is_local = 1" to see only this node's view.
SELECT 
    ar.replica_server_name,
    ar.endpoint_url,
    ars.is_local,
    ars.role_desc,
    ars.connected_state_desc,
    ars.last_connect_error_number,
    ars.last_connect_error_description,
    ars.last_connect_error_timestamp
FROM sys.dm_hadr_availability_replica_states AS ars
INNER JOIN sys.availability_replicas AS ar
    ON ars.replica_id = ar.replica_id
ORDER BY ars.last_connect_error_timestamp DESC;
GO

-- 13b. Scheduler health — non-yielding schedulers / CPU starvation
SELECT 
    scheduler_id, 
    cpu_id, 
    status, 
    is_online, 
    runnable_tasks_count, 
    current_tasks_count, 
    work_queue_count, 
    pending_disk_io_count
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE'
ORDER BY runnable_tasks_count DESC;
GO

-----------------------------------------------------------------------
-- 14. SUSPECT / RECOVERY PENDING DATABASES
--     If an AG database enters SUSPECT or RECOVERY_PENDING on the
--     primary, automatic failover will NOT occur. Investigate and
--     remediate (fix underlying I/O issue, then remove/rejoin replica).
-----------------------------------------------------------------------
SELECT 
    name AS [database_name], 
    state_desc, 
    is_in_standby, 
    is_read_only
FROM sys.databases
WHERE state_desc IN ('SUSPECT', 'RECOVERY_PENDING', 'RESTORING', 'EMERGENCY');
GO

-----------------------------------------------------------------------
-- 15. TRANSACTION LOG GROWTH DUE TO AVAILABILITY_REPLICA (ERROR 9002)
--     If log_reuse_wait_desc = 'AVAILABILITY_REPLICA', the primary's
--     log cannot truncate because log records haven't been hardened
--     on all secondaries. Compare against log_send_queue_size in
--     query #9 to identify the lagging replica.
-----------------------------------------------------------------------
SELECT 
    d.name AS [database_name],
    d.log_reuse_wait_desc,
    ls.cntr_value * 8 / 1024.0 AS log_size_mb,
    lu.cntr_value * 8 / 1024.0 AS log_used_mb,
    CAST(lu.cntr_value AS FLOAT) / NULLIF(ls.cntr_value, 0) * 100 AS log_used_pct
FROM sys.databases AS d
INNER JOIN sys.dm_os_performance_counters AS ls
    ON ls.instance_name = d.name 
    AND ls.counter_name = 'Log File(s) Size (KB)'
    AND ls.object_name LIKE '%:Databases%'
INNER JOIN sys.dm_os_performance_counters AS lu
    ON lu.instance_name = d.name 
    AND lu.counter_name = 'Log File(s) Used Size (KB)'
    AND lu.object_name LIKE '%:Databases%'
WHERE d.log_reuse_wait_desc = 'AVAILABILITY_REPLICA'
ORDER BY log_used_pct DESC;
GO

-----------------------------------------------------------------------
-- 16. SEARCH ERROR LOG FOR CRITICAL AG / CLUSTER EVENTS
--     Looks for stack dumps, non-yielding schedulers, and lease
--     expiration messages that precede IsAlive failures or
--     unexpected restarts. Adjust @logsToSearch to cover the
--     time window of interest.
-----------------------------------------------------------------------
DECLARE @logsToSearch INT = 3; -- number of archived error logs to scan (0 = current)
DECLARE @i INT = 0;
IF OBJECT_ID('tempdb..#ErrorLogEntries') IS NOT NULL 
    DROP TABLE #ErrorLogEntries;
CREATE TABLE #ErrorLogEntries (LogDate DATETIME, ProcessInfo NVARCHAR(50), [Text] NVARCHAR(MAX));

WHILE @i <= @logsToSearch
BEGIN
    -- A freshly cycled instance may not have @i archives yet; skip those.
    BEGIN TRY
        INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'Stack Dump';
        INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'Non-yielding';
        INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'lease';
        INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'19407';
    END TRY
    BEGIN CATCH
        PRINT CONCAT('Skipped error log archive ', @i, ': ', ERROR_MESSAGE());
    END CATCH;
    SET @i += 1;
END;

SELECT * FROM #ErrorLogEntries ORDER BY LogDate DESC;
DROP TABLE #ErrorLogEntries;
GO

-----------------------------------------------------------------------
-- 17. AUTOMATIC PAGE REPAIR
--     AGs automatically repair certain corrupt pages by fetching a
--     clean copy from a partner replica. Rows here mean you HAVE had
--     page corruption — treat as an I/O subsystem red flag and follow
--     up with DBCC CHECKDB and the storage team.
--       error_type: -1 = 823 hardware error, 1 = 824 (other),
--                    2 = bad checksum, 3 = torn page
--     Run on both primary and secondary; results are per-replica.
-----------------------------------------------------------------------
SELECT 
    DB_NAME(database_id) AS [database_name],
    file_id,
    page_id,
    error_type,
    page_status_desc,
    modification_time
FROM sys.dm_hadr_auto_page_repair
ORDER BY modification_time DESC;
GO

-----------------------------------------------------------------------
-- 18. LISTENER AND READ-ONLY ROUTING CONFIGURATION
--     Connectivity problems that look like AG failures are often just
--     listener or routing misconfiguration.
-----------------------------------------------------------------------
-- 18a. Listener definition per AG. is_conformant = 0 means the WSFC
--      resource was changed outside SQL Server and may not behave.
SELECT 
    ag.name AS [AG Name],
    agl.dns_name,
    agl.port,
    agl.ip_configuration_string_from_cluster,
    agl.is_conformant
FROM sys.availability_group_listeners AS agl
INNER JOIN sys.availability_groups AS ag
    ON ag.group_id = agl.group_id
ORDER BY ag.name;
GO

-- 18b. Is the listener actually online and listening on this node?
SELECT 
    ip_address,
    is_ipv4,
    port,
    type_desc,
    state_desc,
    start_time
FROM sys.dm_tcp_listener_states
WHERE type_desc = 'TSQL'
ORDER BY port;
GO

-- 18c. Read-only routing list. A missing read_only_routing_url, or a
--      secondary set to NO for secondary_role_allow_connections, is
--      why ApplicationIntent=ReadOnly connections land on the primary.
SELECT 
    ag.name AS [AG Name],
    src.replica_server_name AS [When primary is],
    rl.routing_priority,
    tgt.replica_server_name AS [Route read-only to],
    tgt.read_only_routing_url,
    tgt.secondary_role_allow_connections_desc
FROM sys.availability_read_only_routing_lists AS rl
INNER JOIN sys.availability_replicas AS src
    ON rl.replica_id = src.replica_id
INNER JOIN sys.availability_replicas AS tgt
    ON rl.read_only_replica_id = tgt.replica_id
INNER JOIN sys.availability_groups AS ag
    ON ag.group_id = src.group_id
ORDER BY ag.name, src.replica_server_name, rl.routing_priority;
GO

-----------------------------------------------------------------------
-- 19. GENERATE WINDOWS CLUSTER LOG (REFERENCE — RUN IN POWERSHELL)
--     Not executable T-SQL. Use the Windows Cluster Log to diagnose
--     issues between the SQL Server resource DLL and the WSFC, and to
--     confirm IsAlive/lease timeout failures (search for
--     "[hadrag] Resource Alive result 0" or "Lease timeout detected").
--
--     Get-ClusterLog -Destination C:\Temp -UseLocalTime
-----------------------------------------------------------------------