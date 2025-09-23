--Extended events In Prod SQL Servers

--Extended Events is a powerful event-handling framework that was introduced in SQL Server 2008 to provide a more scalable and flexible alternative to SQL Server Profiler. It allows you to capture a wide --range of events that occur within the SQL Server database engine. Extended Events can be used for performance monitoring, troubleshooting, and auditing purposes. Here's a brief overview of how to work --with Extended Events in SQL Server:



---- check restores state:


CREATE EVENT SESSION [restores] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace
   (WHERE [operation_type] = 1 )   -- Filter for restore operation
ADD TARGET package0.ring_buffer
WITH (STARTUP_STATE=OFF)
GO





--- extended event to monitor failed logins:

CREATE EVENT SESSION [LoginIssues] ON SERVER

ADD EVENT sqlserver.connectivity_ring_buffer_recorded(

    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.is_system,sqlserver.nt_username,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.username)),

ADD EVENT sqlserver.login(SET collect_options_text=(1)
 
    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.is_system,sqlserver.nt_username,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.username)),

ADD EVENT sqlserver.logout(

    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.is_system,sqlserver.nt_username,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.username)),

ADD EVENT sqlserver.security_error_ring_buffer_recorded(

    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.is_system,sqlserver.nt_username,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.username))

ADD TARGET package0.ring_buffer

WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)

GO




--=== extended event to capture specific sql queries like the below edge case where a customer might need to capture certifcate creations, god knows why???

CREATE EVENT SESSION [CaptureQuery] ON SERVER
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.sql_text -- Action needed to capture the statement text for filtering
    )
    WHERE (
        -- Use LIKE for flexibility, adjust as needed
        sqlserver.sql_text LIKE N'%BACKUP CERTIFICATE%'
        AND sqlserver.session_id <> @@SPID -- Avoid capturing this DDL
    )
)
-- Optional: Add rpc_completed if needed for specific client connection methods
-- ADD EVENT sqlserver.rpc_completed(
--     ACTION(sqlserver.client_hostname,sqlserver.database_name,sqlserver.username,sqlserver.sql_text)
--     WHERE (sqlserver.sql_text LIKE N'%BACKUP CERTIFICATE%')
-- )

ADD TARGET package0.ring_buffer
--ADD TARGET package0.event_file(SET filename=N'CaptureCertificateBackups.xel')
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF);


GO

-- Start the session
-- ALTER EVENT SESSION [CaptureCertificateBackups] ON SERVER STATE = START;
-- Stop the session
-- ALTER EVENT SESSION [CaptureCertificateBackups] ON SERVER STATE = STOP;



-------------------------------------------------


--Here's a comprehensive SQL Server Extended Events (XEvents) session to monitor performance issues like long-running queries, missing indexes, and inefficient operations:


CREATE EVENT SESSION [PerformanceMonitoring] ON SERVER 
(
    -- Events to capture
    ADD EVENT sqlserver.sql_statement_completed (
        ACTION (sqlserver.sql_text, sqlserver.execution_plan, sqlserver.session_id, sqlserver.database_id, sqlserver.client_app_name, sqlserver.username)
        WHERE duration > 5000000 -- Filter for queries > 5 seconds
           OR logical_reads > 10000 -- High read operations
           OR cpu_time > 1000000 -- CPU > 1 second
    ),
    ADD EVENT sqlserver.sp_statement_completed (
        ACTION (sqlserver.sql_text, sqlserver.execution_plan, sqlserver.session_id, sqlserver.database_id, sqlserver.client_app_name, sqlserver.username)
    ),
    ADD EVENT sqlserver.missing_index_found (
        ACTION (sqlserver.database_id, sqlserver.session_id, sqlserver.username)
    ),
    ADD EVENT sqlserver.hash_warning (
        ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.username)
    ),
    ADD EVENT sqlserver.sort_warning (
        ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.username)
    ),
    ADD EVENT sqlserver.plan_affecting_convert (
        ACTION (sqlserver.sql_text, sqlserver.execution_plan, sqlserver.session_id)
    ),
    ADD EVENT sqlserver.lock_deadlock (
        ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.username)
    ),
    ADD EVENT sqlserver.error_reported (
        ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.username)
        WHERE severity >= 16 -- Focus on critical errors
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XEvents\PerformanceMonitoring.xel',
    max_file_size = 100, -- MB
    max_rollover_files = 5
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = ON
);


---

-- Key Features
--| Component       | Purpose                                                                 |
--|-----------------|-------------------------------------------------------------------------|
--| Events Captured | Monitors long-running queries, missing indexes, memory warnings, deadlocks, and critical errors. 
--| Actions         | Captures SQL text, execution plans, session details, and client context. 
--| Filters         | Focuses on resource-intensive queries (duration, reads, CPU). 
--| Targets         | Stores data in a file for later analysis. 

---

-- How to Use
--1. Deploy: Run the script in SSMS (adjust file path and filters as needed).
--2. Start Session:

   ALTER EVENT SESSION PerformanceMonitoring ON SERVER STATE = START;
 
--3. Stop Session:
 
   ALTER EVENT SESSION PerformanceMonitoring ON SERVER STATE = STOP;
   
--4. Analyze Data:
--   - In SSMS: Right-click the `.xel` file > View Event Files.
--   - Query directly:
    
     SELECT 
         event_data.value('(@name)[1]', 'varchar(50)') AS event_name,
         event_data.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration,
         event_data.value('(data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
         event_data.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
         event_data.query('.') AS raw_data
     FROM 
         sys.fn_xe_file_target_read_file('C:\XEvents\PerformanceMonitoring.xel', NULL, NULL, NULL)
     CROSS APPLY 
         eventdata.nodes('//event') AS ed(event_data);
     

---

-- Customization Tips
-- Adjust Thresholds: Modify `duration`, `logical_reads`, or `cpu_time` values to suit your workload.
-- Add/Remove Events: Include `rpc_completed` for remote calls or exclude events you don’t need.
-- Focus on Specific DBs: Add `AND sqlserver.database_id = DB_ID('YourDBName')` to event predicates.
-- Minimize Overhead: Avoid capturing execution plans (`query_plan`) in production unless troubleshooting specific issues.

---

--Common Issues Detected
-- Long Inserts/Queries: Identified by high `duration` or `cpu_time`.
-- Bad Indexes: Highlighted by `missing_index_found` events.
-- Inefficient Plans: Revealed via `plan_affecting_convert` or `hash_warning`.
-- Deadlocks: Tracked via `lock_deadlock` events.

--This template provides a balanced approach for proactive performance monitoring. Adjust filters and events based on your environment’s needs!





-- ====================================================================================
-- Segment 1: Create or Recreate the Extended Event Session
-- ====================================================================================
-- Drop the session if it already exists
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'CaptureActualPlans')
BEGIN
    DROP EVENT SESSION CaptureActualPlans ON SERVER;
    PRINT 'Dropped existing event session [CaptureActualPlans].';
END
GO

-- Create the Extended Event session
CREATE EVENT SESSION CaptureActualPlans ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan (
    -- Collect additional useful actions (columns)
    ACTION (
        sqlserver.sql_text,         -- The text of the SQL batch
        sqlserver.tsql_stack,       -- T-SQL call stack (if in a proc/func)
        sqlserver.database_id,
        sqlserver.database_name,
        sqlserver.client_hostname,
        sqlserver.client_app_name,
        sqlserver.session_id,
        sqlserver.username,
        sqlserver.query_hash,       -- Hash of the query text (normalized)
        sqlserver.query_plan_hash,  -- Hash of the execution plan
        sqlserver.context_info,     -- Context info set by SET CONTEXT_INFO
        sqlserver.attach_activity_id -- For correlating with other events
    )
    -- ====================================================================================
    -- !!! CRITICAL: ADD FILTERS TO REDUCE OVERHEAD AND CAPTURE ONLY WHAT YOU NEED !!!
    -- ====================================================================================
    WHERE (
        -- Example: Filter by database name (adjust as needed)
        sqlserver.database_name = N'YourDatabaseName' -- Or use database_id if preferred
        -- Example: Filter out your own session
        AND sqlserver.session_id <> @@SPID
        -- Example: Filter by duration (e.g., only queries running longer than 1 second = 1,000,000 microseconds)
        AND [duration] > 1000000 -- Duration is in microseconds
		and sqlserver.
        -- Example: Filter by CPU time (e.g., only queries consuming more than 500ms CPU = 500,000 microseconds)
        -- AND [cpu_time] > 500000
        -- Example: Filter by a specific application name
        -- AND sqlserver.client_app_name = N'YourApplicationName'
        -- Example: Filter by a specific query hash (if you know it from Query Store or other DMVs)
        -- AND sqlserver.query_hash = 0xYOUR_QUERY_HASH
        -- Example: Only capture plans if there's a certain number of reads
        -- AND [logical_reads] > 1000
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XE_Traces\CaptureActualPlans.xel', -- !!! CHANGE THIS PATH !!! For SQL MI, use blob storage URI
    max_file_size = (100),      -- MB
    max_rollover_files = (5)    -- Number of rollover files
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = ON,       -- Useful for correlating events
    STARTUP_STATE = OFF         -- Do not start automatically on server restart
);
GO

PRINT 'Created event session [CaptureActualPlans].';
GO





---=======================================================================================================

--- actual query plan finder

CREATE EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER 
ADD EVENT sqlserver.query_post_execution_showplan(
    ACTION(
        sqlserver.database_id,
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.session_id
    )
    WHERE (
        sqlserver.query_hash = 0x1234567890ABCDEF -- Replace with your actual query_hash
    )
)
ADD TARGET package0.ring_buffer
WITH (
    MAX_MEMORY = 50MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-- Start the session
ALTER EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER STATE = START;






-- Pull XML actual execution plan from ring buffer and format for saving
SELECT 
    event_data.value('(event/data[@name="query_plan"]/value)[1]', 'nvarchar(max)') AS [ActualExecutionPlanXml]
INTO #PlanXmlTemp
FROM (
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_sessions AS s
    JOIN sys.dm_xe_session_targets AS t
        ON s.address = t.event_session_address
    WHERE s.name = 'Capture_Actual_Plans_By_Hash'
      AND t.target_name = 'ring_buffer'
) AS Data
CROSS APPLY TargetData.nodes('RingBufferTarget/event') AS XEvent(event_data);

-- View or copy/paste the result into a .sqlplan file
SELECT * FROM #PlanXmlTemp;


---========================================================================================================
















--To capture the errors in the server

CREATE EVENT SESSION [Capture_SQL_Errors] ON SERVER 
ADD EVENT sqlserver.error_reported(
    ACTION(package0.last_error,sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.is_system,sqlserver.plan_handle,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.server_principal_name,sqlserver.session_id,sqlserver.sql_text,sqlserver.username)

WHERE ([package0].[greater_than_equal_int64]([severity],(14)) AND [package0].[not_equal_uint64]([category],'LOGON'))),
ADD EVENT sqlserver.errorlog_written(
    ACTION(package0.last_error,sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.is_system,sqlserver.plan_handle,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.server_principal_name,sqlserver.session_id,sqlserver.sql_text,sqlserver.username)
WHERE ([package0].[not_equal_int64]([error_id],(18456)) AND [package0].[not_equal_int64]([error_id],(18265))))
ADD TARGET package0.event_file(SET filename=N'Capture_SQL_Errors.xel',max_file_size=(100),max_rollover_files=(3))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_MULTIPLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

--To capture DeadLocks information in the server (not needed for sql mi, there is one already deployed for each sql mi server)

CREATE EVENT SESSION [Deadlock_Info] ON SERVER 
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.nt_username,sqlserver.num_response_rows,sqlserver.plan_handle,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.transaction_id,sqlserver.username))
ADD TARGET package0.event_file(SET filename=N'Deadlock_Info',max_file_size=(100),max_rollover_files=(3))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

--To capture DeadLocks only in the server

CREATE EVENT SESSION [Deadlocks_only] ON SERVER 
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.username))
ADD TARGET package0.event_file(SET filename=N'Deadlocks_only',max_file_size=(100),max_rollover_files=(3))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

--For email notification, create a sql agent job using below 

CREATE TABLE errorlog (
            LogDate DATETIME 
            , ProcessInfo VARCHAR(100)
            , [Text] VARCHAR(MAX)
            );
DECLARE @tag VARCHAR (MAX) , @path VARCHAR(MAX);
INSERT INTO errorlog EXEC sp_readerrorlog;
SELECT @tag = text
FROM errorlog 
WHERE [Text] LIKE 'Logging%MSSQL\Log%';
DROP TABLE errorlog;
SET @path = SUBSTRING(@tag, 38, CHARINDEX('MSSQL\Log', @tag) - 29);
select @path
SELECT 
  CONVERT(xml, event_data).query('/event/data/value/child::') AS DeadlockReport,
  CONVERT(xml, event_data).value('(event[@name="xml_deadlock_report"]/@timestamp)[1]', 'datetime') 
  AS Execution_Time
FROM sys.fn_xe_file_target_read_file(@path + '\deadlocks.xel', NULL, NULL, NULL)
WHERE OBJECT_NAME like 'xml_deadlock_report';



 

--Always on health

CREATE EVENT SESSION [AlwaysOn_health] ON SERVER 
ADD EVENT sqlserver.alwayson_ddl_executed,
ADD EVENT sqlserver.availability_group_lease_expired,
ADD EVENT sqlserver.availability_replica_automatic_failover_validation,
ADD EVENT sqlserver.availability_replica_manager_state_change,
ADD EVENT sqlserver.availability_replica_state,
ADD EVENT sqlserver.availability_replica_state_change,
ADD EVENT sqlserver.error_reported(
    WHERE ([error_number]=(9691) OR [error_number]=(35204) OR [error_number]=(9693) OR [error_number]=(26024) OR [error_number]=(28047) OR [error_number]=(26023) OR [error_number]=(9692) OR [error_number]=(28034) OR [error_number]=(28036) OR [error_number]=(28048) OR [error_number]=(28080) OR [error_number]=(28091) OR [error_number]=(26022) OR [error_number]=(9642) OR [error_number]=(35201) OR [error_number]=(35202) OR [error_number]=(35206) OR [error_number]=(35207) OR [error_number]=(26069) OR [error_number]=(26070) OR [error_number]>(41047) AND [error_number]<(41056) OR [error_number]=(41142) OR [error_number]=(41144) OR [error_number]=(1480) OR [error_number]=(823) OR [error_number]=(824) OR [error_number]=(829) OR [error_number]=(35264) OR [error_number]=(35265) OR [error_number]=(41188) OR [error_number]=(41189) OR [error_number]=(35217))),
ADD EVENT sqlserver.hadr_db_partner_set_sync_state,
ADD EVENT sqlserver.hadr_trace_message,
ADD EVENT sqlserver.lock_redo_blocked,
ADD EVENT sqlserver.sp_server_diagnostics_component_result(SET collect_data=(1)
    WHERE ([state]=(3))),
ADD EVENT ucs.ucs_connection_setup
ADD TARGET package0.event_file(SET filename=N'AlwaysOn_health.xel',max_file_size=(100),max_rollover_files=(10))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

--EE_DBA_LONGRUNNING_3SEC

CREATE EVENT SESSION [EE_DBA_LONGRUNNING_3SEC] ON SERVER 
ADD EVENT sqlserver.rpc_completed(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.query_hash,sqlserver.session_id,sqlserver.sql_text,sqlserver.tsql_frame,sqlserver.username)
    WHERE ([package0].[greater_than_uint64]([duration],(3000000)) AND [sqlserver].[database_id]>(4))),
ADD EVENT sqlserver.sql_batch_completed(SET collect_batch_text=(1)
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.session_id,sqlserver.sql_text,sqlserver.tsql_frame,sqlserver.username)
    WHERE ([package0].[greater_than_uint64]([duration],(3000000)) AND [package0].[greater_than_uint64]([sqlserver].[database_id],(4))))
ADD TARGET package0.event_file(SET filename=N'EE_DBA_LONGRUNNING_3SEC',max_file_size=(100),max_rollover_files=(1))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

--Schedule the job every 30 mins

 
--BlockedProcesses

CREATE EVENT SESSION [DBA_BlockedProcesses] ON SERVER 
ADD EVENT sqlserver.blocked_process_report(
    WHERE ([duration]>=(10000000)))
ADD TARGET package0.event_file(SET filename=N'DBA_BlockedProcesses')
WITH (MAX_MEMORY=8192 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO