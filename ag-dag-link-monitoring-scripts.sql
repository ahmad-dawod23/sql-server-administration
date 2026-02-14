-----------------------------------------------------------------------
-- AG / DAG / LINK MONITORING SCRIPTS
-- Purpose : Monitor Availability Group, Distributed AG, and Managed
--           Instance Link health — replica status, seeding progress,
--           failover events, and geo-replication lag.
-- Safety  : All queries are read-only.
-- Applies to : On-prem (AG/DAG) / Azure SQL MI (Link feature)
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