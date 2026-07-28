/*===========================================================================
    EXTENDED EVENTS - ADMINISTRATION AND TROUBLESHOOTING TEMPLATES

    Purpose: Reusable, independently executable Extended Events templates.

    Safety:
      * This file contains server-level DDL. Run only the required batch.
      * No session in this file is ever started. Every session is created with
        STARTUP_STATE = OFF and no ALTER ... STATE = START is issued anywhere.
        Start a session explicitly using the helpers in Section 1.2.
      * Change file paths, predicates, retention, and startup state first.
      * CREATE EVENT SESSION fails with error 25631 if the name already exists.
        Each template is preceded by a commented drop guard. Uncomment it only
        when you are certain the existing session is yours to replace.
      * The SQL Server service account must be able to write to each path.
      * The target directory must already exist. Extended Events does not
        create it, and the session fails to start if the folder is missing.
      * Verify object availability using Section 1.1 before deployment.

    Azure SQL Managed Instance:
      * Local file paths are not supported. event_file targets must use a Blob
        URL, and master must hold a database scoped credential named exactly
        after the container:
            CREATE DATABASE SCOPED CREDENTIAL
                [https://<account>.blob.core.windows.net/<container>]
                WITH IDENTITY = N'SHARED ACCESS SIGNATURE',
                     SECRET   = N'<sas-token-without-the-leading-question-mark>';
      * The SAS token needs Read, Write, List, and Create on the container.
      * package0.ring_buffer needs no storage setup and is the quickest option
        on Managed Instance. Read it with Section 9.7.
      * sp_configure options in Section 5.2 are supported on Managed Instance.

    Time and units:
      * XE event timestamps are UTC.
      * duration and cpu_time predicates use microseconds.
      * event_file max_file_size is in MB.
      * Session MAX_MEMORY is the dispatch buffer size, not the target size.
        The ring_buffer target has its own max_memory and max_events_limit.

    Contents:
      1. Deployment and discovery helpers
      2. Security and connectivity
      3. Query performance
      4. Execution plan capture
      5. Blocking and deadlocks
      6. Errors and connectivity failures
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
-- 1.2 LIFECYCLE AND RE-DEPLOYMENT HELPERS
--     Execute only after substituting the real session name.
-----------------------------------------------------------------------
-- ALTER EVENT SESSION [SessionName] ON SERVER STATE = START;
-- ALTER EVENT SESSION [SessionName] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [SessionName] ON SERVER;
--
-- Idempotent drop guard. A commented copy of this pattern precedes every
-- CREATE EVENT SESSION in this file so the templates can be re-run.
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'SessionName')
--     DROP EVENT SESSION [SessionName] ON SERVER;
-- GO
-----------------------------------------------------------------------


/*===========================================================================
    SECTION 2: SECURITY AND CONNECTIVITY
===========================================================================*/

-----------------------------------------------------------------------
-- 2.1 LOGIN, LOGOUT, CONNECTIVITY, AND AUTHENTICATION FAILURES
--     Ring-buffer data is volatile and is lost when the session stops or
--     the instance restarts. Use event_file for durable auditing.
--     Read this session with Section 9.7.
--     server_principal_name is the login. Use sqlserver.username instead if
--     you need the database user in the session's database context.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'LoginIssues')
--     DROP EVENT SESSION [LoginIssues] ON SERVER;
-- GO

CREATE EVENT SESSION [LoginIssues] ON SERVER
ADD EVENT sqlserver.connectivity_ring_buffer_recorded
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.client_pid,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.session_nt_username
    )
),
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE ([error_number] = (18456))
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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.session_nt_username
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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.session_nt_username
    )
),
ADD EVENT sqlserver.security_error_ring_buffer_recorded
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
)
ADD TARGET package0.ring_buffer
(
    -- Target retention. Independent of the session MAX_MEMORY below.
    SET max_memory = (4096),        -- KB retained by the target
        max_events_limit = (1000)   -- 0 = unlimited, bounded by max_memory
)
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
--
--     WARNING: predicating on the sql_text action forces SQL Server to
--     materialise the full statement text and run a string comparison for
--     every batch and RPC on the instance, including those that will be
--     discarded. Treat this as a short-lived, targeted hunt, not a session
--     you leave running. Where possible narrow it first with a cheap
--     predicate such as sqlserver.database_id or sqlserver.client_app_name
--     so the expensive comparison is evaluated far less often.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'CaptureQuery')
--     DROP EVENT SESSION [CaptureQuery] ON SERVER;
-- GO

CREATE EVENT SESSION [CaptureQuery] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE
    (
        -- Cheap predicates first: XE evaluates left to right and short circuits.
        [sqlserver].[database_id] > (4)
        AND [sqlserver].[like_i_sql_unicode_string]
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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE
    (
        [sqlserver].[database_id] > (4)
        AND [sqlserver].[like_i_sql_unicode_string]
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
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'PerformanceMonitoring')
--     DROP EVENT SESSION [PerformanceMonitoring] ON SERVER;
-- GO

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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
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
--     database_id > 4 excludes master, tempdb, model, and msdb only. It does
--     NOT exclude distribution, SSISDB, ReportServer, or any other database
--     you may consider infrastructure. List them explicitly if that matters.
--     is_system = 0 excludes internal system sessions, which is a different
--     filter from the database predicate and complements it.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'EE_DBA_LONGRUNNING_3SEC')
--     DROP EVENT SESSION [EE_DBA_LONGRUNNING_3SEC] ON SERVER;
-- GO

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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE
    (
        [duration] > 3000000
        AND [sqlserver].[database_id] > (4)
        AND [sqlserver].[is_system] = (0)
    )
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
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE
    (
        [duration] > 3000000
        AND [sqlserver].[database_id] > (4)
        AND [sqlserver].[is_system] = (0)
    )
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

    WARNING: query_post_execution_showplan enables standard (per-operator)
    execution statistics profiling for every query on the instance, before
    any predicate is evaluated. Overhead of 20-90% CPU has been observed.
    Use a restrictive predicate, run briefly, and prefer Query Store first.

    Lower-overhead alternatives, in order of preference:
      * Query Store, for plan regression and plan history.
      * sqlserver.query_post_execution_plan_profile (SQL Server 2019+, and
        2016 SP2 CU3 / 2017 CU11 with trace flag 7412). Uses the lightweight
        profiling infrastructure, typically around 2% overhead, and returns
        the same plan XML with runtime statistics.
      * sqlserver.query_post_compilation_showplan for the estimated plan only,
        which fires on compilation and not on every execution.

    Note on causality: TRACK_CAUSALITY = ON already attaches the activity ID
    to every event. Do not also add sqlserver.attach_activity_id as an ACTION.
===========================================================================*/

-----------------------------------------------------------------------
-- 4.1 ACTUAL PLANS FOR SLOW QUERIES IN USER DATABASES
--     Tighten the duration and database_id predicates before use.
--     Substitute query_post_execution_plan_profile where it is available.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'CaptureActualPlans')
--     DROP EVENT SESSION [CaptureActualPlans] ON SERVER;
-- GO

CREATE EVENT SESSION [CaptureActualPlans] ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text,
        sqlserver.tsql_stack
    )
    WHERE
    (
        [duration] > 1000000
        AND [sqlserver].[database_id] > (4)
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
--
--     IMPORTANT: the XE predicate source sqlserver.query_hash is a 64-bit
--     unsigned integer, NOT binary. A hexadecimal literal such as
--     0x1234567890ABCDEF will not match. sys.dm_exec_query_stats.query_hash
--     is binary(8), so it must be converted first.
--
--     Get the decimal value to paste into the predicate below:
--
--       SELECT DISTINCT
--           query_stats.query_hash                    AS query_hash_binary,
--           CONVERT(bigint, query_stats.query_hash)   AS query_hash_decimal
--       FROM sys.dm_exec_query_stats AS query_stats
--       CROSS APPLY sys.dm_exec_sql_text(query_stats.sql_handle) AS sql_text
--       WHERE sql_text.text LIKE N'%<fragment of the query>%';
--
--     If CONVERT returns a negative number, the hash has the high bit set.
--     XE accepts the unsigned form, so add 18446744073709551616 to it, or
--     use the two-part predicate shown in the commented alternative.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'Capture_Actual_Plans_By_Hash')
--     DROP EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER;
-- GO

CREATE EVENT SESSION [Capture_Actual_Plans_By_Hash] ON SERVER
ADD EVENT sqlserver.query_post_execution_showplan
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.database_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    -- Replace the placeholder with the decimal value obtained above.
    WHERE ([sqlserver].[query_hash] = (1234567890123456789))
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
--     Set it with Section 5.2 or nothing will ever be captured.
--
--     No ACTIONs are collected here, deliberately. Both events are raised by
--     background monitor tasks (the blocked process monitor and the lock
--     monitor), not by the sessions involved in the blocking or deadlock.
--     Session-scoped actions such as sql_text, session_id, client_app_name,
--     database_name, and query_hash would therefore describe the monitor
--     task and be NULL or actively misleading. Every useful detail already
--     lives inside the report XML, which Section 9.2 shreds.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'blocked_process')
--     DROP EVENT SESSION [blocked_process] ON SERVER;
-- GO

CREATE EVENT SESSION [blocked_process] ON SERVER
ADD EVENT sqlserver.blocked_process_report,
ADD EVENT sqlserver.xml_deadlock_report
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
    SECTION 6: ERRORS AND CONNECTIVITY FAILURES
===========================================================================*/

-----------------------------------------------------------------------
-- 6.1 USER AND ENGINE ERRORS (SEVERITY >= 14)
--     Login failure 18456 is excluded here because 2.1 and 6.2 capture it.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'Capture_SQL_Errors')
--     DROP EVENT SESSION [Capture_SQL_Errors] ON SERVER;
-- GO

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
        sqlserver.sql_text
    )
    WHERE ([severity] >= (14) AND [error_number] <> (18456))
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

-----------------------------------------------------------------------
-- 6.2 CONNECTIVITY, TDS, AND TLS HANDSHAKE FAILURES
--     Complements 2.1 by adding protocol-level failures that never reach a
--     successful login. Pair it with the ring buffer session in 2.1 when
--     diagnosing intermittent client disconnects.
--
--     Azure SQL Managed Instance: replace the filename with the Blob URL
--     form and create the matching database scoped credential first. See
--     the file header. Local paths are rejected on Managed Instance.
--         SET filename = N'https://<account>.blob.core.windows.net/<container>/ConnFailures_TDS_TLS.xel'
--     max_file_size and max_rollover_files are not used with Blob targets.
-----------------------------------------------------------------------
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'ConnFailures_TDS_TLS')
--     DROP EVENT SESSION [ConnFailures_TDS_TLS] ON SERVER;
-- GO

CREATE EVENT SESSION [ConnFailures_TDS_TLS] ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.session_nt_username
    )
    WHERE
    (
        [error_number] = (17832)    -- TDS or login packet structurally invalid
        OR [error_number] = (17835) -- encryption required, client did not agree
        OR [error_number] = (17836) -- length in network packet header invalid
        OR [error_number] = (18456) -- login failed
    )
),
ADD EVENT sqlserver.connectivity_ring_buffer_recorded
(
    ACTION
    (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.session_id
    )
)
ADD TARGET package0.event_file
(
    SET filename = N'C:\XEvents\ConnFailures_TDS_TLS.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH
(
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 15 SECONDS,
    TRACK_CAUSALITY = OFF,
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
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'BackupRestoreProgress')
--     DROP EVENT SESSION [BackupRestoreProgress] ON SERVER;
-- GO

CREATE EVENT SESSION [BackupRestoreProgress] ON SERVER
ADD EVENT sqlserver.backup_restore_progress_trace
(
    ACTION
    (
        sqlserver.database_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    -- Optional filter. The operation_type map is version specific, so confirm
    -- the keys on this build before enabling the predicate:
    --   SELECT map_key, map_value
    --   FROM sys.dm_xe_map_values
    --   WHERE name = N'backup_restore_operation_type';
    -- WHERE ([operation_type] = (1))
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
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'BackupRestoreDiagnostics')
--     DROP EVENT SESSION [BackupRestoreDiagnostics] ON SERVER;
-- GO

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
-- IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'DBA_AlwaysOn_health')
--     DROP EVENT SESSION [DBA_AlwaysOn_health] ON SERVER;
-- GO

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
--     The wildcard reads every rollover file, so this scans the whole set.
--     Pass a specific .xel name, or use the third and fourth parameters
--     (initial_file_name, initial_offset) to resume, on large collections.
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
--     Session 5.1 collects no ACTIONs because both events fire on a
--     background monitor task. All session context is therefore read out of
--     the report XML itself, which is what the process attributes below do.
--     OBJECT_NAME and OBJECT_SCHEMA_NAME only resolve when this is run on
--     the same instance that produced the file and the object still exists.
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
        event_xml.value(N'(/event/data[@name="database_id"]/value)[1]', N'int') AS database_id,
        event_xml.value(N'(/event/data[@name="object_id"]/value)[1]', N'int') AS object_id,
        event_xml.value(N'(/event/data[@name="index_id"]/value)[1]', N'int') AS index_id,
        event_xml.value(N'(/event/data[@name="duration"]/value)[1]', N'bigint') / 1000 AS duration_ms,
        event_xml.value(N'(/event/data[@name="lock_mode"]/text)[1]', N'nvarchar(60)') AS lock_mode,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@spid)[1]', N'int') AS blocked_spid,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@loginname)[1]', N'nvarchar(128)') AS blocked_login,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@clientapp)[1]', N'nvarchar(128)') AS blocked_client_app,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@hostname)[1]', N'nvarchar(128)') AS blocked_hostname,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/@waittime)[1]', N'bigint') AS blocked_wait_time_ms,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocked-process/process/inputbuf)[1]', N'nvarchar(4000)') AS blocked_input_buffer,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@spid)[1]', N'int') AS blocking_spid,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@loginname)[1]', N'nvarchar(128)') AS blocking_login,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@clientapp)[1]', N'nvarchar(128)') AS blocking_client_app,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/@hostname)[1]', N'nvarchar(128)') AS blocking_hostname,
        event_xml.value(N'(/event/data[@name="blocked_process"]/value/blocked-process-report/blocking-process/process/inputbuf)[1]', N'nvarchar(4000)') AS blocking_input_buffer,
        event_xml.query(N'(/event/data[@name="blocked_process"]/value/blocked-process-report)[1]') AS blocked_process_report,
        event_xml.query(N'(/event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
    FROM EventFileData
    WHERE event_xml IS NOT NULL
)
SELECT
    CASE event_name WHEN N'xml_deadlock_report' THEN N'Deadlock' ELSE N'Blocked Process' END AS report_type,
    event_time_utc,
    DB_NAME(database_id) AS database_name,
    OBJECT_SCHEMA_NAME(NULLIF(object_id, 0), database_id) AS schema_name,
    OBJECT_NAME(NULLIF(object_id, 0), database_id) AS object_name,
    index_id,
    duration_ms,
    lock_mode,
    blocked_spid,
    blocked_login,
    NULLIF(blocked_client_app, N'') AS blocked_client_app,
    NULLIF(blocked_hostname, N'') AS blocked_hostname,
    blocked_wait_time_ms,
    blocked_input_buffer,
    blocking_spid,
    blocking_login,
    NULLIF(blocking_client_app, N'') AS blocking_client_app,
    NULLIF(blocking_hostname, N'') AS blocking_hostname,
    blocking_input_buffer,
    CASE event_name WHEN N'xml_deadlock_report' THEN deadlock_graph ELSE blocked_process_report END AS report_xml
FROM ParsedEvents
ORDER BY event_time_utc DESC;
GO

-----------------------------------------------------------------------
-- 9.3 PERSIST BLOCKED PROCESS REPORTS FOR HISTORICAL ANALYSIS
--
--     The table is created in whatever database is current. Add a USE
--     statement, or fully qualify the name, so this does not land in master.
--
--     The unique hash key makes repeated imports of overlapping .xel files
--     idempotent. Note the trade-off: two genuinely distinct incidents that
--     produce byte-identical report XML are treated as one. That is rare,
--     because the report embeds spid, wait time, and transaction id, but if
--     you need every occurrence, include event_time_utc in the hash input
--     and drop the unique constraint.
-----------------------------------------------------------------------
-- USE [DBA_Admin];
-- GO

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
    sessions.name AS session_name,
    events.package AS event_package,
    events.name AS event_name,
    events.predicate,
    actions.package AS action_package,
    actions.name AS action_name
FROM sys.server_event_sessions AS sessions
INNER JOIN sys.server_event_session_events AS events
    ON events.event_session_id = sessions.event_session_id
LEFT JOIN sys.server_event_session_actions AS actions
    ON actions.event_session_id = events.event_session_id
   AND actions.event_id = events.event_id
ORDER BY sessions.name, events.name, actions.name;
GO

-----------------------------------------------------------------------
-- 9.7 READ A RING BUFFER TARGET
--     Required for Section 2.1 (LoginIssues), which has no file target.
--     Ring buffer contents are volatile: they are discarded when the
--     session stops and when the instance restarts.
--     target_data is truncated at roughly 4 MB by the DMV, so lower
--     max_events_limit on the target if events appear to be missing.
-----------------------------------------------------------------------
DECLARE @SessionName sysname = N'LoginIssues';

WITH TargetData AS
(
    SELECT TRY_CAST(session_target.target_data AS xml) AS target_xml
    FROM sys.dm_xe_sessions AS running_session
    INNER JOIN sys.dm_xe_session_targets AS session_target
        ON session_target.event_session_address = running_session.address
    WHERE running_session.name = @SessionName
      AND session_target.target_name = N'ring_buffer'
)
SELECT
    event_node.value(N'@name', N'sysname') AS event_name,
    event_node.value(N'@timestamp', N'datetime2(7)') AS event_time_utc,
    event_node.value(N'(action[@name="session_id"]/value)[1]', N'int') AS session_id,
    event_node.value(N'(action[@name="server_principal_name"]/value)[1]', N'nvarchar(128)') AS server_principal_name,
    event_node.value(N'(action[@name="session_nt_username"]/value)[1]', N'nvarchar(128)') AS session_nt_username,
    NULLIF(event_node.value(N'(action[@name="client_app_name"]/value)[1]', N'nvarchar(128)'), N'') AS client_app_name,
    NULLIF(event_node.value(N'(action[@name="client_hostname"]/value)[1]', N'nvarchar(128)'), N'') AS client_hostname,
    event_node.value(N'(action[@name="client_pid"]/value)[1]', N'int') AS client_pid,
    event_node.value(N'(action[@name="database_name"]/value)[1]', N'sysname') AS database_name,
    event_node.value(N'(data[@name="error_number"]/value)[1]', N'int') AS error_number,
    event_node.value(N'(data[@name="severity"]/value)[1]', N'int') AS severity,
    event_node.value(N'(data[@name="state"]/value)[1]', N'int') AS error_state,
    event_node.value(N'(data[@name="message"]/value)[1]', N'nvarchar(4000)') AS message,
    event_node.value(N'(data[@name="record"]/value)[1]', N'nvarchar(max)') AS ring_buffer_record,
    event_node.query(N'.') AS raw_event
FROM TargetData
CROSS APPLY target_xml.nodes(N'/RingBufferTarget/event') AS ring_buffer_event(event_node)
ORDER BY event_time_utc DESC;
GO

/*===========================================================================
    END OF FILE
===========================================================================*/