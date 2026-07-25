/*===========================================================================
    EXTENDED EVENTS - ADMINISTRATION AND TROUBLESHOOTING TEMPLATES

    Purpose: Reusable, independently executable Extended Events templates.

    Safety:
      * This file contains server-level DDL. Run only the required batch.
      * Session creation does not start a session unless explicitly stated.
      * Change file paths, predicates, retention, and startup state first.
      * The SQL Server service account must be able to write to each path.
      * Azure SQL Managed Instance event_file targets require a Blob URL.
      * Verify object availability using Section 1 before deployment.

    Time and units:
      * XE event timestamps are UTC.
      * duration and cpu_time predicates use microseconds.
      * event_file max_file_size is in MB.

    Contents:
      1. Deployment and discovery helpers
      2. Security and connectivity
      3. Query performance
      4. Execution plan capture
      5. Blocking and deadlocks
      6. Errors
      7. Backup and restore
      8. Availability Groups
      9. Reading and administering XE data
===========================================================================*/


/*===========================================================================
    SECTION 1: DEPLOYMENT AND DISCOVERY HELPERS
===========================================================================*/

-----------------------------------------------------------------------
-- 1.1 CHECK WHETHER EVENTS, ACTIONS, AND TARGETS ARE AVAILABLE
--     Add names used by a proposed session before deploying it.
-----------------------------------------------------------------------
DECLARE @RequestedObjects table
(
    object_type nvarchar(60) NOT NULL,
    object_name sysname NOT NULL
);

INSERT @RequestedObjects (object_type, object_name)
VALUES
    (N'event',  N'query_post_execution_showplan'),
    (N'event',  N'blocked_process_report'),
    (N'event',  N'backup_restore_progress_trace'),
    (N'action', N'query_hash'),
    (N'target', N'event_file');

SELECT
    requested.object_type,
    requested.object_name,
    CASE WHEN available.name IS NULL THEN N'Not available' ELSE N'Available' END AS availability,
    available.package_name,
    available.description
FROM @RequestedObjects AS requested
OUTER APPLY
(
    SELECT TOP (1)
        xe_object.name,
        package.name AS package_name,
        xe_object.description
    FROM sys.dm_xe_objects AS xe_object
    INNER JOIN sys.dm_xe_packages AS package
        ON package.guid = xe_object.package_guid
    WHERE xe_object.object_type = requested.object_type
      AND xe_object.name = requested.object_name
) AS available
ORDER BY requested.object_type, requested.object_name;
GO

-----------------------------------------------------------------------
-- Lifecycle examples (execute only after changing the session name):
-- ALTER EVENT SESSION [SessionName] ON SERVER STATE = START;
-- ALTER EVENT SESSION [SessionName] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [SessionName] ON SERVER;
-----------------------------------------------------------------------


/*===========================================================================
    SECTION 2: SECURITY AND CONNECTIVITY
===========================================================================*/

-----------------------------------------------------------------------
-- 2.1 LOGIN, LOGOUT, CONNECTIVITY, AND AUTHENTICATION FAILURES
--     Ring-buffer data is volatile. Use event_file for durable auditing.
-----------------------------------------------------------------------
CREATE EVENT SESSION [LoginIssues] ON SERVER
ADD EVENT sqlserver.connectivity_ring_buffer_recorded
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.client_pid,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.session_nt_username,
        sqlserver.username
    )
),
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([error_number] = 18456)
),
ADD EVENT sqlserver.login
(
    SET collect_options_text = (1)
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.client_pid,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.session_nt_username,
        sqlserver.username
    )
),
ADD EVENT sqlserver.logout
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.client_pid,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.session_nt_username,
        sqlserver.username
    )
),
ADD EVENT sqlserver.security_error_ring_buffer_recorded
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.username
    )
)
ADD TARGET package0.ring_buffer
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 3: QUERY PERFORMANCE
===========================================================================*/

-----------------------------------------------------------------------
-- 3.1 CAPTURE STATEMENTS CONTAINING SPECIFIC TEXT
--     Change the case-insensitive LIKE predicate before creation.
-----------------------------------------------------------------------
CREATE EVENT SESSION [CaptureQuery] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE
    (
        [sqlserver].[like_i_sql_unicode_string]
            ([sqlserver].[sql_text], N'%BACKUP CERTIFICATE%')
    )
),
ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE
    (
        [sqlserver].[like_i_sql_unicode_string]
            ([sqlserver].[sql_text], N'%BACKUP CERTIFICATE%')
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\CaptureQuery.xel',
        max_file_size = (50),
        max_rollover_files = (4)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 15 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-----------------------------------------------------------------------
-- 3.2 FILTERED PERFORMANCE DIAGNOSTICS
--     duration > 5 sec, CPU > 1 sec, or logical reads > 10,000.
-----------------------------------------------------------------------
CREATE EVENT SESSION [PerformanceMonitoring] ON SERVER
ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([duration] > 5000000 OR [cpu_time] > 1000000 OR [logical_reads] > 10000)
),
ADD EVENT sqlserver.sql_batch_completed
(
    SET collect_batch_text = (1)
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([duration] > 5000000 OR [cpu_time] > 1000000 OR [logical_reads] > 10000)
),
ADD EVENT sqlserver.hash_warning
(
    ACTION (sqlserver.database_name, sqlserver.session_id, sqlserver.sql_text)
),
ADD EVENT sqlserver.plan_affecting_convert
(
    ACTION
    (
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.session_id,
        sqlserver.sql_text
    )
),
ADD EVENT sqlserver.sort_warning
(
    ACTION (sqlserver.database_name, sqlserver.session_id, sqlserver.sql_text)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\PerformanceMonitoring.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-----------------------------------------------------------------------
-- 3.3 LONG-RUNNING BATCHES AND RPC CALLS (> 3 SECONDS)
--     The database_id predicate excludes system databases.
-----------------------------------------------------------------------
CREATE EVENT SESSION [EE_DBA_LONGRUNNING_3SEC] ON SERVER
ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([duration] > 3000000 AND [sqlserver].[database_id] > 4)
),
ADD EVENT sqlserver.sql_batch_completed
(
    SET collect_batch_text = (1)
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([duration] > 3000000 AND [sqlserver].[database_id] > 4)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\EE_DBA_LONGRUNNING_3SEC.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 4: EXECUTION PLAN CAPTURE

    WARNING: query_post_execution_showplan can add material overhead. Use a
    restrictive predicate, run briefly, and prefer Query Store when possible.
===========================================================================*/

-----------------------------------------------------------------------
-- 4.1 ACTUAL PLANS FOR SLOW QUERIES IN USER DATABASES
--     Tighten the duration and database_id predicates before use.
-----------------------------------------------------------------------
CREATE EVENT SESSION [CaptureActualPlans] ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan
(
    ACTION
    (
        sqlserver.attach_activity_id,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.tsql_stack,
        sqlserver.username
    )
    WHERE
    (
        [duration] > 1000000
        AND [sqlserver].[database_id] > 4
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\CaptureActualPlans.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 15 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-----------------------------------------------------------------------
-- 4.2 ACTUAL PLANS FOR ONE QUERY HASH
--     Replace 0x1234567890ABCDEF before creating the session.
-----------------------------------------------------------------------
CREATE EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([sqlserver].[query_hash] = 0x1234567890ABCDEF)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\CaptureActualPlansByHash.xel',
        max_file_size = (50),
        max_rollover_files = (3)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 5: BLOCKING AND DEADLOCKS
===========================================================================*/

-----------------------------------------------------------------------
-- 5.1 BLOCKED PROCESS REPORTS AND DEADLOCK GRAPHS
--     blocked_process_report requires a nonzero blocked process threshold.
-----------------------------------------------------------------------
CREATE EVENT SESSION [blocked_process] ON SERVER
ADD EVENT sqlserver.blocked_process_report
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
),
ADD EVENT sqlserver.xml_deadlock_report
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.session_id
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\blocked_process.xel',
        max_file_size = (100),
        max_rollover_files = (10)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO

-----------------------------------------------------------------------
-- 5.2 ENABLE BLOCKED PROCESS REPORTING AT A 5-SECOND THRESHOLD
--     Instance-level change. Run this batch separately if required.
-----------------------------------------------------------------------
EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure N'blocked process threshold (s)', 5;
RECONFIGURE;
GO


/*===========================================================================
    SECTION 6: ERRORS
===========================================================================*/

-----------------------------------------------------------------------
-- 6.1 USER AND ENGINE ERRORS (SEVERITY >= 14)
--     Login failure 18456 is excluded because LoginIssues captures it.
-----------------------------------------------------------------------
CREATE EVENT SESSION [Capture_SQL_Errors] ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.is_system,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.username
    )
    WHERE ([severity] >= 14 AND [error_number] <> 18456)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\Capture_SQL_Errors.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 7: BACKUP AND RESTORE
===========================================================================*/

-----------------------------------------------------------------------
-- 7.1 DURABLE BACKUP AND RESTORE PROGRESS TRACE
--     Confirm operation_type values before adding a version-specific filter.
-----------------------------------------------------------------------
CREATE EVENT SESSION [BackupRestoreProgress] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace
(
    ACTION
    (
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
     --WHERE (operation_type = 1)

)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\BackupRestoreProgress.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO

-----------------------------------------------------------------------
-- 7.2 TARGETED BACKUP/RESTORE WAIT DIAGNOSTICS
--     Replace session_id 55. Keep this high-volume session short-lived.
--     This replaces the prior global trace-flag diagnostics.
-----------------------------------------------------------------------
CREATE EVENT SESSION [BackupRestoreDiagnostics] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace
(
    ACTION (sqlserver.database_name, sqlserver.session_id, sqlserver.sql_text)
    WHERE ([sqlserver].[session_id] = 55)
),
ADD EVENT sqlserver.databases_backup_restore_throughput
(
    ACTION (sqlserver.database_name, sqlserver.session_id)
    WHERE ([sqlserver].[session_id] = 55)
),
ADD EVENT sqlos.wait_info
(
    ACTION (sqlserver.database_name, sqlserver.session_id, sqlserver.sql_text)
    WHERE ([sqlserver].[session_id] = 55 AND [duration] > 0)
),
ADD EVENT sqlos.wait_info_external
(
    ACTION (sqlserver.database_name, sqlserver.session_id, sqlserver.sql_text)
    WHERE ([sqlserver].[session_id] = 55 AND [duration] > 0)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\BackupRestoreDiagnostics.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 8: AVAILABILITY GROUPS
===========================================================================*/

-----------------------------------------------------------------------
-- 8.1 CUSTOM AVAILABILITY GROUP HEALTH SESSION
--     SQL Server normally creates AlwaysOn_health; do not overwrite it.
-----------------------------------------------------------------------
CREATE EVENT SESSION [DBA_AlwaysOn_health] ON SERVER
ADD EVENT sqlserver.alwayson_ddl_executed,
ADD EVENT sqlserver.availability_group_lease_expired,
ADD EVENT sqlserver.availability_replica_automatic_failover_validation,
ADD EVENT sqlserver.availability_replica_manager_state_change,
ADD EVENT sqlserver.availability_replica_state_change,
ADD EVENT sqlserver.error_reported
(
    WHERE
    (
        [error_number] = 1480
        OR [error_number] = 823
        OR [error_number] = 824
        OR [error_number] = 829
        OR [error_number] = 9642
        OR [error_number] = 9691
        OR [error_number] = 9692
        OR [error_number] = 9693
        OR [error_number] = 26022
        OR [error_number] = 26023
        OR [error_number] = 26024
        OR [error_number] = 26069
        OR [error_number] = 26070
        OR [error_number] = 28034
        OR [error_number] = 28036
        OR [error_number] = 28047
        OR [error_number] = 28048
        OR [error_number] = 28080
        OR [error_number] = 28091
        OR [error_number] = 35201
        OR [error_number] = 35202
        OR [error_number] = 35204
        OR [error_number] = 35206
        OR [error_number] = 35207
        OR [error_number] = 35217
        OR [error_number] = 35264
        OR [error_number] = 35265
        OR [error_number] = 41142
        OR [error_number] = 41144
        OR [error_number] = 41188
        OR [error_number] = 41189
        OR ([error_number] > 41047 AND [error_number] < 41056)
    )
),
ADD EVENT sqlserver.hadr_db_partner_set_sync_state,
ADD EVENT sqlserver.lock_redo_blocked,
ADD EVENT sqlserver.sp_server_diagnostics_component_result
(
    SET collect_data = (1)
    WHERE ([state] = 3)
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\DBA_AlwaysOn_health.xel',
        max_file_size = (100),
        max_rollover_files = (10)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
GO


/*===========================================================================
    SECTION 9: READING AND ADMINISTERING XE DATA
===========================================================================*/

-----------------------------------------------------------------------
-- 9.1 READ EVENT FILES - GENERIC SHREDDED OUTPUT
-----------------------------------------------------------------------
WITH EventFileData AS
(
    SELECT TRY_CAST(event_data AS xml) AS event_xml
    FROM sys.fn_xe_file_target_read_file
    (
        N'C:\XEvents\PerformanceMonitoring*.xel', NULL, NULL, NULL
    )
)
SELECT
    event_xml.value(N'(/event/@name)[1]', N'sysname') AS event_name,
    event_xml.value(N'(/event/@timestamp)[1]', N'datetime2(7)') AS event_time_utc,
    event_xml.value(N'(/event/data[@name="duration"]/value)[1]', N'bigint') AS duration_us,
    event_xml.value(N'(/event/data[@name="cpu_time"]/value)[1]', N'bigint') AS cpu_time_us,
    event_xml.value(N'(/event/data[@name="logical_reads"]/value)[1]', N'bigint') AS logical_reads,
    event_xml.value(N'(/event/action[@name="database_name"]/value)[1]', N'sysname') AS database_name,
    event_xml.value(N'(/event/action[@name="session_id"]/value)[1]', N'int') AS session_id,
    event_xml.value(N'(/event/action[@name="sql_text"]/value)[1]', N'nvarchar(4000)') AS sql_text,
    event_xml AS raw_event
FROM EventFileData
WHERE event_xml IS NOT NULL
ORDER BY event_time_utc DESC;
GO

-----------------------------------------------------------------------
-- 9.2 READ BLOCKED PROCESS REPORTS AND DEADLOCK GRAPHS
-----------------------------------------------------------------------
WITH EventFileData AS
(
    SELECT TRY_CAST(event_data AS xml) AS event_xml
    FROM sys.fn_xe_file_target_read_file
    (
        N'C:\XEvents\blocked_process*.xel', NULL, NULL, NULL
    )
),
ParsedEvents AS
(
    SELECT
        event_xml.value(N'(/event/@name)[1]', N'sysname') AS event_name,
        event_xml.value(N'(/event/@timestamp)[1]', N'datetime2(7)') AS event_time_utc,
        event_xml.value(N'(/event/action[@name="client_app_name"]/value)[1]', N'nvarchar(128)') AS client_app_name,
        event_xml.value(N'(/event/action[@name="client_hostname"]/value)[1]', N'nvarchar(128)') AS client_hostname,
        event_xml.value(N'(/event/action[@name="database_name"]/value)[1]', N'sysname') AS database_name,
        event_xml.value(N'(/event/data[@name="database_id"]/value)[1]', N'int') AS database_id,
        event_xml.value(N'(/event/data[@name="object_id"]/value)[1]', N'int') AS object_id,
        event_xml.value(N'(/event/data[@name="index_id"]/value)[1]', N'int') AS index_id,
        event_xml.value(N'(/event/data[@name="duration"]/value)[1]', N'bigint') / 1000 AS duration_ms,
        event_xml.value(N'(/event/data[@name="lock_mode"]/text)[1]', N'nvarchar(60)') AS lock_mode,
        event_xml.query(N'(/event/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS blocked_process_report,
        event_xml.query(N'(/event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
    FROM EventFileData
    WHERE event_xml IS NOT NULL
)
SELECT
    CASE event_name WHEN N'xml_deadlock_report' THEN N'Deadlock' ELSE N'Blocked Process' END AS report_type,
    event_time_utc,
    NULLIF(client_app_name, N'') AS client_app_name,
    NULLIF(client_hostname, N'') AS client_hostname,
    database_name,
    OBJECT_SCHEMA_NAME(object_id, database_id) AS schema_name,
    OBJECT_NAME(object_id, database_id) AS object_name,
    index_id,
    duration_ms,
    lock_mode,
    CASE event_name WHEN N'xml_deadlock_report' THEN deadlock_graph ELSE blocked_process_report END AS report_xml
FROM ParsedEvents
ORDER BY event_time_utc DESC;
GO

-----------------------------------------------------------------------
-- 9.3 PERSIST BLOCKED PROCESS REPORTS FOR HISTORICAL ANALYSIS
--     The unique key makes repeated imports idempotent.
-----------------------------------------------------------------------
IF OBJECT_ID(N'dbo.XE_BlockedProcessReports', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.XE_BlockedProcessReports
    (
        blocked_process_report_id bigint IDENTITY(1, 1) NOT NULL,
        event_time_utc datetime2(7) NOT NULL,
        event_xml xml NOT NULL,
        event_hash varbinary(32) NOT NULL,
        CONSTRAINT PK_XE_BlockedProcessReports
            PRIMARY KEY CLUSTERED (blocked_process_report_id),
        CONSTRAINT UQ_XE_BlockedProcessReports_EventHash
            UNIQUE NONCLUSTERED (event_hash)
    );
END;
GO

WITH EventFileData AS
(
    SELECT TRY_CAST(event_data AS xml) AS event_xml
    FROM sys.fn_xe_file_target_read_file
    (
        N'C:\XEvents\blocked_process*.xel', NULL, NULL, NULL
    )
),
BlockedProcessEvents AS
(
    SELECT
        event_xml.value(N'(/event/@timestamp)[1]', N'datetime2(7)') AS event_time_utc,
        event_xml.query(N'(/event/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS report_xml,
        HASHBYTES
        (
            N'SHA2_256',
            CONVERT
            (
                nvarchar(max),
                event_xml.query(N'(/event/data[@name="blocked_process"]/value/blocked-process-report)[1]')
            )
        ) AS event_hash
    FROM EventFileData
    WHERE event_xml.value(N'(/event/@name)[1]', N'sysname') = N'blocked_process_report'
),
DeduplicatedEvents AS
(
    SELECT
        event_time_utc,
        report_xml,
        event_hash,
        ROW_NUMBER() OVER (PARTITION BY event_hash ORDER BY event_time_utc) AS duplicate_number
    FROM BlockedProcessEvents
    WHERE report_xml.exist(N'/blocked-process-report') = 1
)
INSERT dbo.XE_BlockedProcessReports (event_time_utc, event_xml, event_hash)
SELECT source.event_time_utc, source.report_xml, source.event_hash
FROM DeduplicatedEvents AS source
WHERE source.duplicate_number = 1
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.XE_BlockedProcessReports AS target
      WHERE target.event_hash = source.event_hash
  );
GO

-----------------------------------------------------------------------
-- 9.4 READ ACTUAL EXECUTION PLANS FROM EVENT FILES
-----------------------------------------------------------------------
WITH EventFileData AS
(
    SELECT TRY_CAST(event_data AS xml) AS event_xml
    FROM sys.fn_xe_file_target_read_file
    (
        N'C:\XEvents\CaptureActualPlans*.xel', NULL, NULL, NULL
    )
)
SELECT
    event_xml.value(N'(/event/@timestamp)[1]', N'datetime2(7)') AS event_time_utc,
    event_xml.value(N'(/event/action[@name="database_name"]/value)[1]', N'sysname') AS database_name,
    event_xml.value(N'(/event/action[@name="query_hash"]/value)[1]', N'varchar(34)') AS query_hash,
    event_xml.value(N'(/event/action[@name="query_plan_hash"]/value)[1]', N'varchar(34)') AS query_plan_hash,
    event_xml.value(N'(/event/action[@name="sql_text"]/value)[1]', N'nvarchar(4000)') AS sql_text,
    event_xml.query(N'(/event/data[@name="showplan_xml"]/value/*)[1]') AS actual_plan_xml
FROM EventFileData
WHERE event_xml IS NOT NULL
ORDER BY event_time_utc DESC;
GO

-----------------------------------------------------------------------
-- 9.5 LIST CONFIGURED SESSIONS, STATE, AND TARGETS
-----------------------------------------------------------------------
SELECT
    configured.name AS session_name,
    CASE WHEN running.address IS NULL THEN N'Stopped' ELSE N'Running' END AS session_state,
    configured.event_retention_mode_desc,
    configured.max_memory,
    configured.max_dispatch_latency,
    configured.startup_state,
    configured_target.name AS configured_target,
    CASE WHEN running_target.target_name IS NULL THEN N'Not initialized' ELSE N'Initialized' END AS target_state
FROM sys.server_event_sessions AS configured
LEFT JOIN sys.dm_xe_sessions AS running
    ON running.name = configured.name
LEFT JOIN sys.server_event_session_targets AS configured_target
    ON configured_target.event_session_id = configured.event_session_id
LEFT JOIN sys.dm_xe_session_targets AS running_target
    ON running_target.event_session_address = running.address
   AND running_target.target_name = configured_target.name
ORDER BY configured.name, configured_target.name;
GO

-----------------------------------------------------------------------
-- 9.6 VIEW SESSION EVENTS, ACTIONS, AND PREDICATES
-----------------------------------------------------------------------
SELECT
    session.name AS session_name,
    event.package AS event_package,
    event.name AS event_name,
    event.predicate,
    action.package AS action_package,
    action.name AS action_name
FROM sys.server_event_sessions AS session
INNER JOIN sys.server_event_session_events AS event
    ON event.event_session_id = session.event_session_id
LEFT JOIN sys.server_event_session_actions AS action
    ON action.event_session_id = event.event_session_id
   AND action.event_id = event.event_id
ORDER BY session.name, event.name, action.name;
GO

/*===========================================================================
    END OF FILE
===========================================================================*/