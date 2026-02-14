/*
00 - Triage.sql
SQL Server / Azure SQL Managed Instance - Incident Triage (read-mostly)

Intent:
- One script you can run first during an incident.
- Read-only queries by default.

Notes:
- Some sections require permissions (VIEW SERVER STATE, msdb access, etc.).
- The optional error log section uses xp_readerrorlog (often sysadmin).
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @Top int = 25;

PRINT '=== 00 - TRIAGE START ===';
PRINT CONCAT('UTC now: ', CONVERT(varchar(19), GETUTCDATE(), 120));
PRINT CONCAT('Local now: ', CONVERT(varchar(19), GETDATE(), 120));

--------------------------------------------------------------------------------
-- 1) Instance info and key configuration
--------------------------------------------------------------------------------
SELECT
    @@SERVERNAME AS server_name,
    CAST(SERVERPROPERTY('ServerName') AS sysname) AS serverproperty_servername,
    CAST(SERVERPROPERTY('MachineName') AS sysname) AS machine_name,
    CAST(SERVERPROPERTY('InstanceName') AS sysname) AS instance_name,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
    CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered;

SELECT
    sqlserver_start_time,
    DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()) AS uptime_hours,
    cpu_count,
    scheduler_count,
    physical_memory_kb / 1024 AS physical_memory_mb,
    committed_kb / 1024 AS os_committed_mb,
    committed_target_kb / 1024 AS os_committed_target_mb
FROM sys.dm_os_sys_info;

SELECT name, value_in_use
FROM sys.configurations
WHERE name IN
(
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads',
    'blocked process threshold (s)'
)
ORDER BY name;

--------------------------------------------------------------------------------
-- 2) Database posture (state, recovery, log reuse wait, checksum)
--------------------------------------------------------------------------------
SELECT
    d.name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc,
    d.log_reuse_wait_desc,
    d.compatibility_level,
    d.page_verify_option_desc,
    d.is_read_only,
    d.is_auto_close_on,
    d.is_auto_shrink_on,
    d.is_auto_create_stats_on,
    d.is_auto_update_stats_on,
    d.is_auto_update_stats_async_on
FROM sys.databases AS d
ORDER BY d.name;

--------------------------------------------------------------------------------
-- 3) Running requests (what is burning time right now?)
--------------------------------------------------------------------------------
SELECT TOP (@Top)
    r.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(r.database_id) AS database_name,
    r.status,
    r.command,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time AS wait_time_ms,
    r.wait_resource,
    r.cpu_time AS cpu_time_ms,
    r.total_elapsed_time AS elapsed_time_ms,
    r.reads,
    r.writes,
    r.logical_reads,
    r.row_count,
    r.percent_complete,
    r.start_time,
    SUBSTRING(txt.text,
              (r.statement_start_offset/2) + 1,
              (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(txt.text) ELSE r.statement_end_offset END - r.statement_start_offset)/2 + 1) AS statement_text,
    txt.text AS batch_text
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s
    ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
WHERE s.is_user_process = 1
ORDER BY r.cpu_time DESC, r.total_elapsed_time DESC;

--------------------------------------------------------------------------------
-- 4) Blocking (quick head blocker view)
--------------------------------------------------------------------------------
;WITH waiting AS
(
    SELECT
        r.session_id,
        r.blocking_session_id
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id <> 0
), head_blockers AS
(
    SELECT DISTINCT w.blocking_session_id AS session_id
    FROM waiting AS w
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM sys.dm_exec_requests AS r2
        WHERE r2.session_id = w.blocking_session_id
          AND r2.blocking_session_id <> 0
    )
)
SELECT
    hb.session_id AS head_blocker_session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status,
    c.net_transport,
    c.client_net_address,
    DB_NAME(r.database_id) AS database_name,
    r.command,
    r.wait_type,
    r.cpu_time AS cpu_time_ms,
    r.total_elapsed_time AS elapsed_time_ms,
    txt.text AS most_recent_batch
FROM head_blockers AS hb
JOIN sys.dm_exec_sessions AS s
    ON s.session_id = hb.session_id
LEFT JOIN sys.dm_exec_connections AS c
    ON c.session_id = hb.session_id
LEFT JOIN sys.dm_exec_requests AS r
    ON r.session_id = hb.session_id
OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) AS txt
ORDER BY r.total_elapsed_time DESC;

--------------------------------------------------------------------------------
-- 5) Wait stats (server-level)
--------------------------------------------------------------------------------
;WITH waits AS
(
    SELECT
        wait_type,
        wait_time_ms,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN
    (
        'SLEEP_TASK','SLEEP_SYSTEMTASK','BROKER_TASK_STOP','BROKER_TO_FLUSH','BROKER_EVENTHANDLER',
        'LAZYWRITER_SLEEP','SQLTRACE_BUFFER_FLUSH','CLR_AUTO_EVENT','CLR_MANUAL_EVENT','REQUEST_FOR_DEADLOCK_SEARCH',
        'XE_TIMER_EVENT','XE_DISPATCHER_JOIN','XE_DISPATCHER_WAIT','LOGMGR_QUEUE','CHECKPOINT_QUEUE',
        'FT_IFTS_SCHEDULER_IDLE_WAIT','ONDEMAND_TASK_QUEUE','DISPATCHER_QUEUE_SEMAPHORE','BROKER_RECEIVE_WAITFOR'
    )
), totals AS
(
    SELECT SUM(wait_time_ms) AS total_wait_time_ms
    FROM waits
)
SELECT TOP (20)
    w.wait_type,
    CAST(w.wait_time_ms / 1000.0 AS decimal(18,2)) AS wait_time_s,
    CAST(w.signal_wait_time_ms / 1000.0 AS decimal(18,2)) AS signal_wait_time_s,
    CAST(100.0 * w.wait_time_ms / NULLIF(t.total_wait_time_ms, 0) AS decimal(6,2)) AS pct_total
FROM waits AS w
CROSS JOIN totals AS t
ORDER BY w.wait_time_ms DESC;

--------------------------------------------------------------------------------
-- 6) Top cached queries (plan cache) by CPU and reads
--------------------------------------------------------------------------------
;WITH top_cpu AS
(
    SELECT TOP (@Top)
        qs.plan_handle,
        qs.sql_handle,
        qs.total_worker_time,
        qs.execution_count,
        qs.total_elapsed_time,
        qs.total_logical_reads,
        qs.total_logical_writes,
        qs.creation_time,
        qs.last_execution_time
    FROM sys.dm_exec_query_stats AS qs
    ORDER BY qs.total_worker_time DESC
)
SELECT
    tc.total_worker_time / 1000.0 AS total_cpu_ms,
    tc.execution_count,
    (tc.total_worker_time / 1000.0) / NULLIF(tc.execution_count, 0) AS avg_cpu_ms,
    tc.total_logical_reads,
    tc.total_logical_writes,
    tc.creation_time,
    tc.last_execution_time,
    DB_NAME(txt.dbid) AS database_name,
    txt.text
FROM top_cpu AS tc
CROSS APPLY sys.dm_exec_sql_text(tc.sql_handle) AS txt
ORDER BY tc.total_worker_time DESC;

;WITH top_reads AS
(
    SELECT TOP (@Top)
        qs.plan_handle,
        qs.sql_handle,
        qs.total_logical_reads,
        qs.execution_count,
        qs.total_worker_time,
        qs.total_elapsed_time,
        qs.creation_time,
        qs.last_execution_time
    FROM sys.dm_exec_query_stats AS qs
    ORDER BY qs.total_logical_reads DESC
)
SELECT
    tr.total_logical_reads,
    tr.execution_count,
    tr.total_logical_reads * 1.0 / NULLIF(tr.execution_count, 0) AS avg_logical_reads,
    tr.total_worker_time / 1000.0 AS total_cpu_ms,
    tr.creation_time,
    tr.last_execution_time,
    DB_NAME(txt.dbid) AS database_name,
    txt.text
FROM top_reads AS tr
CROSS APPLY sys.dm_exec_sql_text(tr.sql_handle) AS txt
ORDER BY tr.total_logical_reads DESC;

--------------------------------------------------------------------------------
-- 7) Memory pressure indicators
--------------------------------------------------------------------------------
SELECT
    total_physical_memory_kb / 1024 AS total_physical_memory_mb,
    available_physical_memory_kb / 1024 AS available_physical_memory_mb,
    system_memory_state_desc
FROM sys.dm_os_sys_memory;

SELECT
    physical_memory_in_use_kb / 1024 AS sql_physical_memory_in_use_mb,
    large_page_allocations_kb / 1024 AS large_page_allocations_mb,
    locked_page_allocations_kb / 1024 AS locked_page_allocations_mb,
    memory_utilization_percentage,
    available_commit_limit_kb / 1024 AS available_commit_limit_mb,
    process_physical_memory_low,
    process_virtual_memory_low
FROM sys.dm_os_process_memory;

SELECT
    counter_name,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Manager%'
  AND counter_name IN ('Page life expectancy','Free list stalls/sec');

SELECT
    counter_name,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Memory Manager%'
  AND counter_name IN ('Memory Grants Pending','Memory Grants Outstanding');

--------------------------------------------------------------------------------
-- 8) tempdb quick view
--------------------------------------------------------------------------------
IF DB_ID('tempdb') IS NOT NULL
BEGIN
    SELECT
        SUM(user_object_reserved_page_count) * 8 AS user_objects_kb,
        SUM(internal_object_reserved_page_count) * 8 AS internal_objects_kb,
        SUM(version_store_reserved_page_count) * 8 AS version_store_kb,
        SUM(unallocated_extent_page_count) * 8 AS free_space_kb,
        SUM(mixed_extent_page_count) * 8 AS mixed_extent_kb
    FROM tempdb.sys.dm_db_file_space_usage;

    SELECT TOP (@Top)
        tsu.session_id,
        s.login_name,
        s.host_name,
        s.program_name,
        (tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) * 8 AS allocated_kb,
        (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count) * 8 AS deallocated_kb,
        ((tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count)
          - (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count)) * 8 AS net_kb
    FROM sys.dm_db_session_space_usage AS tsu
    JOIN sys.dm_exec_sessions AS s
        ON s.session_id = tsu.session_id
    WHERE tsu.session_id > 50
    ORDER BY net_kb DESC;
END;

--------------------------------------------------------------------------------
-- 9) File I/O stalls (per database file)
--------------------------------------------------------------------------------
SELECT TOP (@Top)
    DB_NAME(mf.database_id) AS database_name,
    mf.type_desc,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.num_of_writes,
    vfs.io_stall_read_ms,
    vfs.io_stall_write_ms,
    CAST(vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads, 0) AS decimal(18,2)) AS avg_read_stall_ms,
    CAST(vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS decimal(18,2)) AS avg_write_stall_ms,
    (mf.size * 8) / 1024 AS size_mb,
    mf.growth,
    mf.is_percent_growth
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON mf.database_id = vfs.database_id
   AND mf.file_id = vfs.file_id
ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;

--------------------------------------------------------------------------------
-- 10) Backup posture (msdb) - last full/diff/log and age
--------------------------------------------------------------------------------
BEGIN TRY
    IF DB_ID('msdb') IS NOT NULL
    BEGIN
        ;WITH dbs AS
        (
            SELECT name
            FROM sys.databases
            WHERE name NOT IN ('tempdb')
        ), last_bk AS
        (
            SELECT
                d.name AS database_name,
                MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full,
                MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS last_diff,
                MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log
            FROM dbs AS d
            LEFT JOIN msdb.dbo.backupset AS b
                ON b.database_name = d.name
            GROUP BY d.name
        )
        SELECT
            lb.database_name,
            d.recovery_model_desc,
            lb.last_full,
            DATEDIFF(HOUR, lb.last_full, GETDATE()) AS hours_since_full,
            lb.last_diff,
            DATEDIFF(HOUR, lb.last_diff, GETDATE()) AS hours_since_diff,
            lb.last_log,
            DATEDIFF(HOUR, lb.last_log, GETDATE()) AS hours_since_log
        FROM last_bk AS lb
        JOIN sys.databases AS d
            ON d.name = lb.database_name
        ORDER BY
            CASE WHEN lb.last_full IS NULL THEN 0 ELSE 1 END,
            hours_since_full DESC;

        -- Flag: FULL/BULK_LOGGED DBs with no recent log backup
        SELECT
            d.name AS database_name,
            d.recovery_model_desc,
            lb.last_log,
            DATEDIFF(HOUR, lb.last_log, GETDATE()) AS hours_since_log
        FROM sys.databases AS d
        LEFT JOIN
        (
            SELECT database_name, MAX(backup_finish_date) AS last_log
            FROM msdb.dbo.backupset
            WHERE type = 'L'
            GROUP BY database_name
        ) AS lb
            ON lb.database_name = d.name
        WHERE d.recovery_model_desc IN ('FULL','BULK_LOGGED')
          AND d.name NOT IN ('tempdb')
          AND (lb.last_log IS NULL OR lb.last_log < DATEADD(HOUR, -24, GETDATE()))
        ORDER BY hours_since_log DESC;
    END
END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message;
END CATCH;

--------------------------------------------------------------------------------
-- 11) AG health (if enabled)
--------------------------------------------------------------------------------
IF CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 1
BEGIN
    SELECT
        ag.name AS availability_group,
        ar.replica_server_name,
        ars.role_desc,
        ars.connected_state_desc,
        ars.synchronization_health_desc,
        ar.availability_mode_desc,
        ar.failover_mode_desc
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar
        ON ar.group_id = ag.group_id
    JOIN sys.dm_hadr_availability_replica_states AS ars
        ON ars.replica_id = ar.replica_id;

    SELECT
        ag.name AS availability_group,
        d.name AS database_name,
        drs.synchronization_state_desc,
        drs.synchronization_health_desc,
        drs.log_send_queue_size,
        drs.redo_queue_size,
        drs.redo_rate,
        drs.log_send_rate,
        drs.last_commit_time
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.databases AS d
        ON d.database_id = drs.database_id
    JOIN sys.availability_groups AS ag
        ON ag.group_id = drs.group_id
    ORDER BY drs.log_send_queue_size DESC, drs.redo_queue_size DESC;
END;

--------------------------------------------------------------------------------
-- 12) Agent job failures (msdb) - last 24 hours
--------------------------------------------------------------------------------
BEGIN TRY
    IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
    BEGIN
        ;WITH h AS
        (
            SELECT
                j.name AS job_name,
                msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
                h.step_id,
                h.step_name,
                h.run_status,
                h.message
            FROM msdb.dbo.sysjobhistory AS h
            JOIN msdb.dbo.sysjobs AS j
                ON j.job_id = h.job_id
            WHERE h.run_status IN (0,2,3) -- 0 failed, 2 retry, 3 canceled
        )
        SELECT TOP (@Top)
            job_name,
            run_datetime,
            step_id,
            step_name,
            run_status,
            message
        FROM h
        WHERE run_datetime >= DATEADD(HOUR, -24, GETDATE())
        ORDER BY run_datetime DESC;
    END
END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS error_number,
        ERROR_MESSAGE() AS error_message;
END CATCH;

--------------------------------------------------------------------------------
-- 13) Optional: error log search (uncomment when you need it)
--------------------------------------------------------------------------------
-- EXEC xp_readerrorlog 0, 1, N'Error', NULL, NULL, NULL, N'desc';
-- EXEC xp_readerrorlog 0, 1, N'failed', NULL, NULL, NULL, N'desc';

PRINT '=== 00 - TRIAGE END ===';
