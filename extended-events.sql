/*===========================================================================
    EXTENDED EVENTS — SESSION TEMPLATES
    Purpose: Reusable XE session definitions organized by functionality
    Safety: *** THIS SCRIPT CONTAINS DDL — REVIEW BEFORE EXECUTING ***
            CREATE EVENT SESSION commands create server-level objects.
            Review each session before running. Use ALTER EVENT SESSION
            to start/stop sessions as needed.
    Applies to: On-prem / Azure SQL MI / Both
===========================================================================

TABLE OF CONTENTS:
    1. SECURITY & LOGIN MONITORING
    2. QUERY MONITORING & PERFORMANCE
    3. EXECUTION PLAN CAPTURE
    4. BLOCKING & DEADLOCK MONITORING
    5. ERROR MONITORING
    6. BACKUP & RESTORE MONITORING
    7. HIGH AVAILABILITY MONITORING
    8. QUERYING & ANALYZING EXTENDED EVENTS

===========================================================================*/


/*===========================================================================
    SECTION 1: SECURITY & LOGIN MONITORING
===========================================================================*/

-----------------------------------------------------------------------
-- 1.1 MONITOR FAILED LOGINS & SECURITY EVENTS
-----------------------------------------------------------------------
CREATE EVENT SESSION [LoginIssues] ON SERVER
ADD EVENT sqlserver.connectivity_ring_buffer_recorded(
    ACTION(
        sqlos.task_time, sqlserver.client_app_name, sqlserver.client_hostname,
        sqlserver.client_pid, sqlserver.database_id, sqlserver.database_name,
        sqlserver.is_system, sqlserver.nt_username, sqlserver.session_id,
        sqlserver.session_nt_username, sqlserver.sql_text, sqlserver.username
    )
),
ADD EVENT sqlserver.login(SET collect_options_text = (1)
    ACTION(
        sqlos.task_time, sqlserver.client_app_name, sqlserver.client_hostname,
        sqlserver.client_pid, sqlserver.database_id, sqlserver.database_name,
        sqlserver.is_system, sqlserver.nt_username, sqlserver.session_id,
        sqlserver.session_nt_username, sqlserver.sql_text, sqlserver.username
    )
),
ADD EVENT sqlserver.logout(
    ACTION(
        sqlos.task_time, sqlserver.client_app_name, sqlserver.client_hostname,
        sqlserver.client_pid, sqlserver.database_id, sqlserver.database_name,
        sqlserver.is_system, sqlserver.nt_username, sqlserver.session_id,
        sqlserver.session_nt_username, sqlserver.sql_text, sqlserver.username
    )
),
ADD EVENT sqlserver.security_error_ring_buffer_recorded(
    ACTION(
        sqlos.task_time, sqlserver.client_app_name, sqlserver.client_hostname,
        sqlserver.client_pid, sqlserver.database_id, sqlserver.database_name,
        sqlserver.is_system, sqlserver.nt_username, sqlserver.session_id,
        sqlserver.session_nt_username, sqlserver.sql_text, sqlserver.username
    )
)
ADD TARGET package0.ring_buffer
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO

-- Start session: ALTER EVENT SESSION [LoginIssues] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [LoginIssues] ON SERVER STATE = STOP;


/*===========================================================================
    SECTION 2: QUERY MONITORING & PERFORMANCE
===========================================================================*/

-----------------------------------------------------------------------
-- 2.1 CAPTURE SPECIFIC SQL QUERIES
--     Example: Capture certificate-related operations
--     Customize the WHERE clause to match desired queries
-----------------------------------------------------------------------
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
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO

-- Start session: ALTER EVENT SESSION [CaptureQuery] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [CaptureQuery] ON SERVER STATE = STOP;

-----------------------------------------------------------------------
-- 2.2 COMPREHENSIVE PERFORMANCE MONITORING
--     Captures: Long-running queries, missing indexes, hash/sort warnings,
--     implicit conversions, deadlocks, and critical errors
-----------------------------------------------------------------------


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


-- Start session: ALTER EVENT SESSION [PerformanceMonitoring] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [PerformanceMonitoring] ON SERVER STATE = STOP;

-- Query the .xel file to analyze captured data:
    
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

-- Customization: Adjust duration/cpu_time thresholds, add rpc_completed event, filter by database_id
-- Detects: Long queries (duration/cpu_time), missing indexes, inefficient plans, deadlocks

-----------------------------------------------------------------------
-- 2.3 LONG-RUNNING QUERIES (> 3 seconds)
--     Captures batch and RPC completions exceeding 3 seconds
--     Excludes system databases
-----------------------------------------------------------------------
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

-- Start session: ALTER EVENT SESSION [EE_DBA_LONGRUNNING_3SEC] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [EE_DBA_LONGRUNNING_3SEC] ON SERVER STATE = STOP;
-- Note: Schedule SQL Agent job to analyze data every 30 minutes


/*===========================================================================
    SECTION 3: EXECUTION PLAN CAPTURE
===========================================================================*/

-----------------------------------------------------------------------
-- 3.1 CAPTURE ACTUAL EXECUTION PLANS (WITH FILTERS)
--     Captures actual execution plans with query and plan hashes
--     CRITICAL: Add WHERE filters to reduce overhead
-----------------------------------------------------------------------
-- Drop existing session if it exists:
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'CaptureActualPlans')
BEGIN
    DROP EVENT SESSION CaptureActualPlans ON SERVER;
    PRINT 'Dropped existing event session [CaptureActualPlans].';
END
GO

-- Create session to capture actual execution plans:
CREATE EVENT SESSION CaptureActualPlans ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan (
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
        sqlserver.attach_activity_id
    )
    -- CRITICAL: Add filters to reduce overhead:
    WHERE (
        sqlserver.database_name = N'YourDatabaseName'
        AND sqlserver.session_id <> @@SPID
        AND [duration] > 1000000 -- >1 sec (microseconds)
        -- Optional filters: cpu_time, client_app_name, query_hash, logical_reads
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XE_Traces\CaptureActualPlans.xel', -- Change path (SQL MI: use blob storage)
    max_file_size = (100),
    max_rollover_files = (5)
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

PRINT 'Created event session [CaptureActualPlans].';
GO

-- Start session: ALTER EVENT SESSION [CaptureActualPlans] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [CaptureActualPlans] ON SERVER STATE = STOP;

-----------------------------------------------------------------------
-- 3.2 CAPTURE ACTUAL PLANS BY QUERY HASH
--     Targets a specific query using its query_hash
--     Useful for isolating problematic query patterns
-----------------------------------------------------------------------

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
        sqlserver.query_hash = 0x1234567890ABCDEF -- Replace with target query_hash
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

-- Start session:
ALTER EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER STATE = START;
GO

-- Stop session:
-- ALTER EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER STATE = STOP;

-- Extract XML execution plan from ring buffer:
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

-- View results (save as .sqlplan file if needed):
SELECT * FROM #PlanXmlTemp;
GO


/*===========================================================================
    SECTION 4: BLOCKING & DEADLOCK MONITORING
===========================================================================*/

-----------------------------------------------------------------------
-- 4.1 DEADLOCK INFORMATION CAPTURE
--     Captures XML deadlock reports with full context
--     Note: SQL MI has a default system_health session for deadlocks
-----------------------------------------------------------------------
CREATE EVENT SESSION [Deadlock_Info] ON SERVER 
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlos.task_time,sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_id,sqlserver.database_name,sqlserver.nt_username,sqlserver.num_response_rows,sqlserver.plan_handle,sqlserver.session_id,sqlserver.session_nt_username,sqlserver.sql_text,sqlserver.transaction_id,sqlserver.username))
ADD TARGET package0.event_file(SET filename=N'Deadlock_Info',max_file_size=(100),max_rollover_files=(3))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

-- Start session: ALTER EVENT SESSION [Deadlock_Info] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [Deadlock_Info] ON SERVER STATE = STOP;

-----------------------------------------------------------------------
-- 4.2 DEADLOCKS ONLY (MINIMAL CAPTURE)
--     Lightweight deadlock capture with essential context
-----------------------------------------------------------------------
CREATE EVENT SESSION [Deadlocks_only] ON SERVER 
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.username))
ADD TARGET package0.event_file(SET filename=N'Deadlocks_only',max_file_size=(100),max_rollover_files=(3))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=ON)
GO

-- Start session: ALTER EVENT SESSION [Deadlocks_only] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [Deadlocks_only] ON SERVER STATE = STOP;

-----------------------------------------------------------------------
-- 4.3 BLOCKED PROCESSES (> 10 seconds)
--     Captures processes blocked for more than 10 seconds
--     Requires: blocked process threshold configuration (see below)
-----------------------------------------------------------------------
CREATE EVENT SESSION [DBA_BlockedProcesses] ON SERVER 
ADD EVENT sqlserver.blocked_process_report(
    WHERE ([duration]>=(10000000)))
ADD TARGET package0.event_file(SET filename=N'DBA_BlockedProcesses')
WITH (MAX_MEMORY=8192 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

-- Start session: ALTER EVENT SESSION [DBA_BlockedProcesses] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [DBA_BlockedProcesses] ON SERVER STATE = STOP;

-----------------------------------------------------------------------
-- 4.4 COMBINED BLOCKED PROCESS & DEADLOCK MONITORING
--     Comprehensive blocking and deadlock capture with execution plans
--     Requires: File system path or blob storage (SQL MI)
-----------------------------------------------------------------------
-- Ensure target directory exists before starting
CREATE EVENT SESSION [blocked_process] ON SERVER 
ADD EVENT sqlserver.blocked_process_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.execution_plan_guid,sqlserver.query_hash,sqlserver.query_plan_hash,sqlserver.session_id,sqlserver.sql_text,sqlserver.username)),
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name))
ADD TARGET package0.event_file(SET filename=N'c:\temp\XEventSessions\blocked_process.xel',max_file_size=(65536),max_rollover_files=(5),metadatafile=N'c:\temp\XEventSessions\blocked_process.xem')
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=5 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=OFF,STARTUP_STATE=OFF)
GO

-- Configure blocked process threshold (5 seconds):
EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
EXEC sp_configure 'blocked process threshold', '5';
RECONFIGURE;
GO

-- Start session:
ALTER EVENT SESSION [blocked_process] ON SERVER STATE = START;
GO

-- Stop session:
-- ALTER EVENT SESSION [blocked_process] ON SERVER STATE = STOP;


/*===========================================================================
    SECTION 5: ERROR MONITORING
===========================================================================*/

-----------------------------------------------------------------------
-- 5.1 CAPTURE SQL ERRORS (Severity >= 14)
--     Excludes logon errors (use LoginIssues session instead)
-----------------------------------------------------------------------

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

-- Start session: ALTER EVENT SESSION [Capture_SQL_Errors] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [Capture_SQL_Errors] ON SERVER STATE = STOP;


/*===========================================================================
    SECTION 6: BACKUP & RESTORE MONITORING
===========================================================================*/

-----------------------------------------------------------------------
-- 6.1 MONITOR RESTORE OPERATIONS
--     Tracks restore progress for all databases
-----------------------------------------------------------------------
CREATE EVENT SESSION [restores] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace
    (WHERE [operation_type] = 1) -- Filter for restore operation
ADD TARGET package0.ring_buffer
WITH (STARTUP_STATE = OFF);
GO

-- Start session: ALTER EVENT SESSION [restores] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [restores] ON SERVER STATE = STOP;


/*===========================================================================
    SECTION 7: HIGH AVAILABILITY MONITORING
===========================================================================*/

-----------------------------------------------------------------------
-- 7.1 ALWAYSON HEALTH MONITORING
--     Comprehensive AG monitoring with state changes and errors
--     Note: Similar session exists by default in SQL Server
-----------------------------------------------------------------------

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

-- Start session: ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;
-- Stop session:  ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = STOP;


/*===========================================================================
    SECTION 8: QUERYING & ANALYZING EXTENDED EVENTS
    Purpose: Reusable queries to analyze captured Extended Event data
===========================================================================*/

-----------------------------------------------------------------------
-- 8.1 QUERY BLOCKED PROCESS EVENTS
--     Analyzes blocked process reports from the [blocked_process] session
-----------------------------------------------------------------------

WITH events_cte AS (
  SELECT
    xevents.event_data,
    DATEADD(mi,
    DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP),
    xevents.event_data.value(
      '(event/@timestamp)[1]', 'datetime2')) AS [event time] ,
    xevents.event_data.value(
      '(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(128)')
      AS [client app name],
    xevents.event_data.value(
      '(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(max)')
      AS [client host name],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="database_name"]/value)[1]', 'nvarchar(max)')
      AS [database name],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="database_id"]/value)[1]', 'int')
      AS [database_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="object_id"]/value)[1]', 'int')
      AS [object_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="index_id"]/value)[1]', 'int')
      AS [index_id],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="duration"]/value)[1]', 'bigint') / 1000
      AS [duration (ms)],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="lock_mode"]/text)[1]', 'varchar')
      AS [lock_mode],
    xevents.event_data.value(
      '(event[@name="blocked_process_report"]/data[@name="login_sid"]/value)[1]', 'int')
      AS [login_sid],
    xevents.event_data.query(
      '(event[@name="blocked_process_report"]/data[@name="blocked_process"]/value/blocked-process-report)[1]')
      AS blocked_process_report,
    xevents.event_data.query(
      '(event/data[@name="xml_report"]/value/deadlock)[1]')
      AS deadlock_graph
  FROM    sys.fn_xe_file_target_read_file
    ('C:\temp\XEventSessions\blocked_process*.xel',
     'C:\temp\XEventSessions\blocked_process*.xem',
     null, null)
    CROSS APPLY (SELECT CAST(event_data AS XML) AS event_data) as xevents
)
SELECT
  CASE WHEN blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NULL
       THEN 'Deadlock'
       ELSE 'Blocked Process'
       END AS ReportType,
  [event time],
  CASE [client app name] WHEN '' THEN ' -- N/A -- '
                         ELSE [client app name]
                         END AS [client app _name],
  CASE [client host name] WHEN '' THEN ' -- N/A -- '
                          ELSE [client host name]
                          END AS [client host name],
  [database name],
  COALESCE(OBJECT_SCHEMA_NAME(object_id, database_id), ' -- N/A -- ') AS [schema],
  COALESCE(OBJECT_NAME(object_id, database_id), ' -- N/A -- ') AS [table],
  index_id,
  [duration (ms)],
  lock_mode,
  COALESCE(SUSER_NAME(login_sid), ' -- N/A -- ') AS username,
  CASE WHEN blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NULL
       THEN deadlock_graph
       ELSE blocked_process_report
       END AS Report
FROM events_cte
ORDER BY [event time] DESC;
GO

-----------------------------------------------------------------------
-- 8.2 INSERT BLOCKED PROCESS EVENTS INTO TABLE FOR ANALYSIS
--     Stores blocked process reports for historical analysis
-----------------------------------------------------------------------

CREATE TABLE bpr (
    EndTime DATETIME,
    TextData XML,
    EventClass INT DEFAULT(137)
);
GO

WITH events_cte AS (
    SELECT
        DATEADD(mi,
        DATEDIFF(mi, GETUTCDATE(), CURRENT_TIMESTAMP),
        xevents.event_data.value('(event/@timestamp)[1]',
           'datetime2')) AS [event_time] ,
        xevents.event_data.query('(event[@name="blocked_process_report"]/data[@name="blocked_process"]/value/blocked-process-report)[1]')
            AS blocked_process_report
    FROM    sys.fn_xe_file_target_read_file
        ('C:\temp\XEventSessions\blocked_process*.xel',
         'C:\temp\XEventSessions\blocked_process*.xem',
         null, null)
        CROSS APPLY (SELECT CAST(event_data AS XML) AS event_data) as xevents
)
INSERT INTO bpr (EndTime, TextData)
SELECT
    [event_time],
    blocked_process_report
FROM events_cte
WHERE blocked_process_report.value('(blocked-process-report[@monitorLoop])[1]', 'nvarchar(max)') IS NOT NULL
ORDER BY [event_time] DESC;
GO

-- View stored blocked process reports:
EXEC sp_blocked_process_report_viewer @Trace='bpr', @Type='TABLE';
GO

-----------------------------------------------------------------------
-- 8.3 QUERY DEADLOCK EVENTS WITH EMAIL NOTIFICATION
--     Retrieves deadlock XML from event files
--     Can be used with SQL Agent for email alerts
-----------------------------------------------------------------------
CREATE TABLE errorlog (
    LogDate DATETIME, 
    ProcessInfo VARCHAR(100),
    [Text] VARCHAR(MAX)
);
GO

DECLARE @tag VARCHAR(MAX), @path VARCHAR(MAX);
INSERT INTO errorlog EXEC sp_readerrorlog;
SELECT @tag = text
FROM errorlog 
WHERE [Text] LIKE 'Logging%MSSQL\Log%';
DROP TABLE errorlog;
SET @path = SUBSTRING(@tag, 38, CHARINDEX('MSSQL\Log', @tag) - 29);

SELECT 
    CONVERT(xml, event_data).query('/event/data/value/child::') AS DeadlockReport,
    CONVERT(xml, event_data).value('(event[@name="xml_deadlock_report"]/@timestamp)[1]', 'datetime') AS Execution_Time
FROM sys.fn_xe_file_target_read_file(@path + '\deadlocks.xel', NULL, NULL, NULL)
WHERE OBJECT_NAME LIKE 'xml_deadlock_report';
GO

-----------------------------------------------------------------------
-- 8.4 LIST ALL ACTIVE EXTENDED EVENT SESSIONS
-----------------------------------------------------------------------
SELECT 
    s.name AS session_name,
    s.event_retention_mode_desc,
    s.max_memory,
    s.max_dispatch_latency,
    CASE WHEN se.session_id IS NULL THEN 'Stopped' ELSE 'Running' END AS session_status,
    t.target_name,
    t.execution_count
FROM sys.server_event_sessions s
LEFT JOIN sys.dm_xe_sessions se ON s.name = se.name
LEFT JOIN sys.server_event_session_targets st ON s.event_session_id = st.event_session_id
LEFT JOIN sys.dm_xe_session_targets t ON se.address = t.event_session_address
ORDER BY s.name;
GO

-----------------------------------------------------------------------
-- 8.5 VIEW EVENT SESSION CONFIGURATION DETAILS
-----------------------------------------------------------------------
SELECT 
    s.name AS session_name,
    e.name AS event_name,
    e.package AS event_package,
    a.name AS action_name,
    a.package AS action_package
FROM sys.server_event_sessions s
JOIN sys.server_event_session_events e ON s.event_session_id = e.event_session_id
LEFT JOIN sys.server_event_session_actions a ON e.event_session_id = a.event_session_id 
    AND e.event_id = a.event_id
ORDER BY s.name, e.name, a.name;
GO

/*===========================================================================
    END OF FILE
===========================================================================*/