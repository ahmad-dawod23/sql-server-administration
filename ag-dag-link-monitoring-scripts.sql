-----------------------------------------------------------------------
-- AG / DAG / LINK MONITORING SCRIPTS
-- Purpose : Monitor Availability Group, Distributed AG, and Managed
--           Instance Link health — replica status, seeding progress,
--           failover events, and geo-replication lag.
-- Safety  : All queries are read-only.
-- Applies to : On-prem (AG/DAG) / Azure SQL MI (Link feature)
-----------------------------------------------------------------------
-- TROUBLESHOOTING METHODOLOGY: AG SYNCHRONIZATION ISSUES
-- Troubleshooting Always On Availability Group (AOAG) synchronization
-- issues requires a systematic analysis of synchronization states, log
-- queues, wait statistics, and underlying infrastructure performance.
--
-- 1) Identify the Synchronization State (see queries #2 and #9 below):
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
-- 2) Investigate Log Send Queue latency (see query #10 below):
--    - Network throughput: check for latency/dropped packets in
--      multi-site or cross-region groups; ensure "TCP Congestion
--      Windows Restart" is set to False on Windows servers.
--    - I/O stalls on secondary: high write latency on the secondary's
--      transaction log delays acknowledgments back to primary (see
--      query #11, sys.dm_io_virtual_file_stats).
--    - Primary CPU load: log capture/compression is CPU-intensive; an
--      overloaded primary can cause send queue growth.
--    - Wait type: monitor HADR_SYNC_COMMIT on the primary. High wait
--      times mean the primary is waiting too long for the secondary
--      to harden log records (see query #10).
--
-- 3) Investigate Recovery (Redo) Queue (see query #12 below):
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
--      started and not in conflict; test with Test-NetConnection.
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
--
-- Recommended diagnostic tools:
--    - AlwaysOn_health XEvent session: tracks state changes, lease
--      expirations, and high-severity errors (see query #7 and #16).
--    - sys.dm_hadr_database_replica_states: primary DMV for LSNs,
--      queue sizes, and rates (see query #2 and #9).
--    - Windows Cluster Log: for issues between the SQL Server resource
--      DLL and the WSFC. Generate with PowerShell: Get-ClusterLog.
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
--      issues caused the cluster to lose sight of the node.
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. VALIDATE DAG/LINK STATUS
--    Change @dagName to your Distributed AG name.
-----------------------------------------------------------------------
DECLARE @dagName NVARCHAR(MAX) = N'<YourDAGNameHere>'
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
-- 2. RETRIEVE DATABASE REPLICA STATUS
--    Change @agName to your AG name.
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
-- 2.1 VIEW DATABASE MIRRORING ENDPOINTS
-----------------------------------------------------------------------
SELECT * 
FROM sys.database_mirroring_endpoints 
WHERE type_desc = 'DATABASE_MIRRORING';
GO

-----------------------------------------------------------------------
-- 3. CHECK SEEDING STATUS
--    Change @seedAgName to your AG name.
-----------------------------------------------------------------------
DECLARE @seedAgName NVARCHAR(MAX) = N'<YourAGNameHere>'
SELECT
	ag.local_database_name AS 'Local database name',
	ar.current_state AS 'Current state',
	ar.is_source AS 'Is source', --bit
	ag.internal_state_desc AS 'Internal state desc',
	-- ag.local_physical_seeding_id, 
	-- ag.remote_physical_seeding_id, 
	ag.database_size_bytes / 1024 / 1024 AS 'Database size MB', 
	ag.transferred_size_bytes / 1024 / 1024 AS 'Transferred MB',
	ag.transfer_rate_bytes_per_second / 1024 / 1024 AS 'Transfer rate MB/s', 
	ag.total_disk_io_wait_time_ms / 1000 AS 'Total Disk IO wait (sec)',
	ag.total_network_wait_time_ms / 1000 AS 'Total Network wait (sec)',
	ag.is_compression_enabled AS 'Compression',
	ag.start_time_utc AS 'Start time UTC', 
	ag.estimate_time_complete_utc as 'Estimated time complete UTC',
	ar.completion_time AS 'Completion time', --datetime
	ar.number_of_attempts AS 'Attempt No' --int
FROM sys.dm_hadr_physical_seeding_stats AS ag
	INNER JOIN sys.dm_hadr_automatic_seeding AS ar
	ON local_physical_seeding_id = operation_id
	INNER JOIN sys.availability_groups groups
	ON groups.group_id = ar.ag_id
WHERE groups.name = @seedAgName;
GO

-----------------------------------------------------------------------
-- 4. CHECK AVAILABILITY GROUP NODE STATUS
--    Run this query on each node.
-----------------------------------------------------------------------
SELECT 
    r.replica_server_name, 
    r.endpoint_url,
    rs.connected_state_desc, 
    rs.last_connect_error_description, 
    rs.last_connect_error_number, 
    rs.last_connect_error_timestamp 
FROM sys.dm_hadr_availability_replica_states rs 
    JOIN sys.availability_replicas r
        ON rs.replica_id = r.replica_id
WHERE rs.is_local = 1;
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
-- 6. MONITOR SEEDING PROCESS AND SPEED
--    The seeding process and its speed can be monitored via this DMV.
-----------------------------------------------------------------------
SELECT 
    role_desc,
    transfer_rate_bytes_per_second,
    transferred_size_bytes,
    database_size_bytes,
    start_time_utc,
    estimate_time_complete_utc,
    end_time_utc,
    local_physical_seeding_id
FROM sys.dm_hadr_physical_seeding_stats;
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
    event_data.value('(/event/data[@name="availability_replica_name"]/value)[1]', 'sysname') AS NewPrimaryReplica
FROM FailoverEvents
WHERE event_data.value('(/event/data[@name="current_state"]/value)[1]', 'int') = 1
ORDER BY FailoverTime DESC;
GO
-----------------------------------------------------------------------
-- 8. AG CLUSTER INFORMATION
--    Get information about any AlwaysOn AG cluster this instance is 
--    a part of.
-----------------------------------------------------------------------
SELECT 
    cluster_name, 
    quorum_type_desc, 
    quorum_state_desc
FROM sys.dm_hadr_cluster WITH (NOLOCK) 
OPTION (RECOMPILE);
GO

-- Shows cluster nodes if SQL Server is in a failover cluster
SELECT 
    NodeName, 
    status_description, 
    is_current_owner
FROM sys.dm_os_cluster_nodes WITH (NOLOCK) 
OPTION (RECOMPILE);


-----------------------------------------------------------------------
-- 9. AG HEALTH AND STATUS OVERVIEW
--    Comprehensive overview of AG health and status.
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
FROM sys.dm_hadr_database_replica_states AS drs WITH (NOLOCK)
    INNER JOIN sys.availability_databases_cluster AS adc WITH (NOLOCK)
        ON drs.group_id = adc.group_id 
        AND drs.group_database_id = adc.group_database_id
    INNER JOIN sys.availability_groups AS ag WITH (NOLOCK)
        ON ag.group_id = drs.group_id
    INNER JOIN sys.availability_replicas AS ar WITH (NOLOCK)
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
    CASE WHEN vfs.num_of_writes = 0 THEN 0 
         ELSE vfs.io_stall_write_ms / vfs.num_of_writes END AS avg_write_latency_ms,
    vfs.num_of_reads,
    vfs.io_stall_read_ms,
    CASE WHEN vfs.num_of_reads = 0 THEN 0 
         ELSE vfs.io_stall_read_ms / vfs.num_of_reads END AS avg_read_latency_ms
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
-- 13a. Endpoint state and last connection error per replica
SELECT 
    ar.replica_server_name,
    ar.endpoint_url,
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
    ON ls.instance_name = d.name AND ls.counter_name = 'Log File(s) Size (KB)'
INNER JOIN sys.dm_os_performance_counters AS lu
    ON lu.instance_name = d.name AND lu.counter_name = 'Log File(s) Used Size (KB)'
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
CREATE TABLE #ErrorLogEntries (LogDate DATETIME, ProcessInfo NVARCHAR(50), [Text] NVARCHAR(MAX));

WHILE @i <= @logsToSearch
BEGIN
    INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'Stack Dump';
    INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'Non-yielding';
    INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'lease';
    INSERT INTO #ErrorLogEntries EXEC sys.xp_readerrorlog @i, 1, N'19407';
    SET @i += 1;
END;

SELECT * FROM #ErrorLogEntries ORDER BY LogDate DESC;
DROP TABLE #ErrorLogEntries;
GO

-----------------------------------------------------------------------
-- 17. GENERATE WINDOWS CLUSTER LOG (REFERENCE — RUN IN POWERSHELL)
--     Not executable T-SQL. Use the Windows Cluster Log to diagnose
--     issues between the SQL Server resource DLL and the WSFC, and to
--     confirm IsAlive/lease timeout failures (search for
--     "[hadrag] Resource Alive result 0" or "Lease timeout detected").
--
--     Get-ClusterLog -Destination C:\Temp -UseLocalTime
-----------------------------------------------------------------------