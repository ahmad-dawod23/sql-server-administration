-- Validate link status:
declare @dagName nvarchar(max)= 'SanjaM_DAG'
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
WHERE ag.is_distributed = 1 and ag.name = @dagName
GO




-- Retrieve the database status
declare @dagName nvarchar(max)= 'SanjaM_AG'
select 
	d.name, hdrs.*
from 
	sys.dm_hadr_database_replica_states hdrs 
	join sys.databases d 
	on hdrs.database_id = d.database_id 
	join sys.availability_groups ag
	on ag.group_id = hdrs.group_id
where
ag.name = @dagName




--- check seeding status

declare @agName nvarchar(max)= 'SanjaM_AG'
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
WHERE groups.name = @agName


---- check availabilty group node status (run on each node):


select r.replica_server_name, r.endpoint_url,
       rs.connected_state_desc, rs.last_connect_error_description, 
       rs.last_connect_error_number, rs.last_connect_error_timestamp 
 from sys.dm_hadr_availability_replica_states rs 
  join sys.availability_replicas r
   on rs.replica_id=r.replica_id
 where rs.is_local=1

--- check availabilty group resource type from powershell

Get-ClusterResourceType | where name -like "SQL Server Availability Group"





--- This Transact-SQL query shows replication lags and last replication time of secondary databases.
 --Column "replication_lag_sec" indicates time difference in seconds between the last_replication value and the timestamp of that transaction's commit on the primary based on the primary database clock. This value is available on the primary database only. 
 
SELECT   
     link_guid  
   , partner_server  
   , last_replication  
   , replication_lag_sec   
FROM sys.dm_geo_replication_link_status;

 sys.dm_geo_replication_link_status, sys.dm_continuous_copy_status
 
 
 
 ---The seeding process and its speed can be monitored via DMV
 
 
 SELECT 
	role_desc,
	transfer_rate_bytes_per_second,
	transferred_size_bytes,
	database_size_bytes,
	start_time_utc,
	estimate_time_complete_utc,
	end_time_utc,
	local_physical_seeding_id
FROM
	sys.dm_hadr_physical_seeding_stats;
	
	
	
	
	
-------find failover event from always on extend event


WITH FailoverEvents AS (
    SELECT 
        object_name,
        CONVERT(XML, event_data) AS event_data
    FROM 
        sys.fn_xe_file_target_read_file('AlwaysOn_health*.xel', NULL, NULL, NULL)
    WHERE 
      object_name = 'availability_replica_state_change'
)
SELECT 
    event_data.value('(/event/@timestamp)[1]', 'datetime') AS FailoverTime,
    event_data.value('(/event/data[@name="previous_state"]/text)[1]', 'nvarchar(50)') AS PreviousState,
    event_data.value('(/event/data[@name="current_state"]/text)[1]', 'nvarchar(50)') AS CurrentState,
    event_data.value('(/event/data[@name="availability_group_name"]/value)[1]', 'sysname') AS AvailabilityGroupName,
    event_data.value('(/event/data[@name="availability_replica_name"]/value)[1]', 'sysname') AS NewPrimaryReplica
FROM 
    FailoverEvents
WHERE 
  event_data.value('(/event/data[@name="current_state"]/value)[1]', 'int') = 1
ORDER BY 
    FailoverTime DESC;