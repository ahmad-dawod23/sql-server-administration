/********************************************************************************************
 * SQL SERVER PERFORMANCE MONITORING UTILITY
 ********************************************************************************************
 * PURPOSE:
 *   This script creates a comprehensive performance monitoring solution for SQL Server that:
 *   - Automatically captures performance metrics at regular intervals via SQL Agent Job
 *   - Stores historical performance data for trend analysis
 *   - Provides stored procedures to analyze wait statistics, blocking, CPU usage, and queries
 *
 * COMPONENTS:
 *   1. SQL Agent Job: SQLPerfMonitor (scheduled to run every 10 minutes)
 *   2. Database: SQL_PerfMonitor (stores all collected metrics)
 *   3. Tables: Store wait stats, resource stats, blocking info, active queries, CPU metrics
 *   4. Stored Procedures: Data collection and analysis routines
 *   5. Analysis Queries: Sample queries to retrieve and analyze collected data
 *
 * WHAT IT MONITORS:
 *   - Wait Statistics (what SQL Server is waiting on)
 *   - Database Resource Utilization (CPU, IO, Memory, DTU for Azure SQL)
 *   - Blocking Chains (head blockers and victims)
 *   - Active/Resource-Intensive Queries
 *   - CPU Utilization Trends
 *   - Plan Cache Pollution
 *   - Index Quality (duplicates, redundant, disabled, missing on FKs)
 *
 * DEPLOYMENT INSTRUCTIONS:
 *   1. Execute this entire script on your SQL Server instance
 *   2. The SQL Agent Job will be created and scheduled automatically
 *   3. Uncomment and specify @owner_login_name if needed (line 45)
 *   4. Adjust the schedule if needed (currently: every 10 minutes on Saturdays)
 *   5. Data collection starts immediately based on the schedule
 *
 * QUERYING THE DATA:
 *   See the "ANALYSIS QUERIES SECTION" at the bottom of this script for examples
 *
 ********************************************************************************************/

USE [msdb]
GO

/********************************************************************************************
 * SECTION 1: SQL AGENT JOB CREATION
 ********************************************************************************************
 * Creates a SQL Agent Job named "SQLPerfMonitor" that runs on a schedule to collect
 * performance metrics. The job executes sp_Capture_Custom_SqlDiag which is the main
 * data collection orchestrator.
 *
 * SCHEDULE: Currently set to run every 10 minutes on Saturdays
 *   - freq_type=8 (Weekly)
 *   - freq_interval=64 (Saturday)
 *   - freq_subday_interval=10 (Every 10 minutes)
 *
 * TO MODIFY SCHEDULE: Adjust parameters in sp_add_jobschedule below
 ********************************************************************************************/

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

-- Ensure the job category exists
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
	EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
END

-- Create the SQL Agent Job
DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job 
	@job_name=N'SQLPerfMonitor', 
	@enabled=1, 
	@notify_level_eventlog=0, 
	@notify_level_email=0, 
	@notify_level_netsend=0, 
	@notify_level_page=0, 
	@delete_level=0, 
	@description=N'Capture SQL Server performance Statistics on demand or as per job schedule and store them in [SQL_PerfMonitor] database for later analysis.', 
	@category_name=N'[Uncategorized (Local)]', 
	-- @owner_login_name=N'YourLoginName', -- OPTIONAL: Uncomment and specify the job owner login
	@job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Add the job step that executes the main collection procedure
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
	@job_id=@jobId, 
	@step_name=N'CapturePerfStatsData', 
	@step_id=1, 
	@cmdexec_success_code=0, 
	@on_success_action=1,  -- Quit with success
	@on_success_step_id=0, 
	@on_fail_action=2,     -- Quit with failure
	@on_fail_step_id=0, 
	@retry_attempts=0, 
	@retry_interval=0, 
	@os_run_priority=0, 
	@subsystem=N'TSQL', 
	@command=N'exec [sqlmonitor].[sp_Capture_Custom_SqlDiag] @CaptureHeadBlockerSeperately = 1', 
	@database_name=N'SQL_PerfMonitor', 
	@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Set the starting step
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Create the job schedule (runs every 10 minutes on Saturdays)
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule 
	@job_id=@jobId, 
	@name=N'SQL_PerfMonitor_Sch', 
	@enabled=1, 
	@freq_type=8,              -- 8 = Weekly, change to 4 for Daily
	@freq_interval=64,         -- 64 = Saturday (1=Sun, 2=Mon, 4=Tue, 8=Wed, 16=Thu, 32=Fri, 64=Sat)
	@freq_subday_type=2,       -- 2 = Minutes
	@freq_subday_interval=10,  -- Run every 10 minutes
	@freq_relative_interval=0, 
	@freq_recurrence_factor=1, -- Recur every week
	@active_start_date=20250503, 
	@active_end_date=99991231, 
	@active_start_time=0,      -- Midnight
	@active_end_time=235959,   -- 11:59:59 PM
	@schedule_uid=N'ee265e8f-4589-4fec-9b64-6e96b57c5138'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- Associate the job with the local server
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO

/********************************************************************************************
 * SECTION 2: DATABASE AND SCHEMA CREATION
 ********************************************************************************************
 * Creates the SQL_PerfMonitor database if it doesn't exist (drops and recreates if exists)
 * This database stores all performance monitoring data collected by the SQL Agent Job.
 ********************************************************************************************/

USE [master]
GO

-- Drop and recreate the database to ensure a clean slate
IF EXISTS (SELECT name FROM sys.databases WHERE name = 'SQL_PerfMonitor')
BEGIN
    PRINT 'SQL_PerfMonitor already exists. Dropping it to recreate...';
    DROP DATABASE SQL_PerfMonitor
END

GO

CREATE DATABASE [SQL_PerfMonitor]
GO

USE [SQL_PerfMonitor]
GO

-- Create schema to organize all monitoring objects
CREATE SCHEMA [sqlmonitor]
GO

/********************************************************************************************
 * SECTION 3: TABLE DEFINITIONS
 ********************************************************************************************
 * Creates tables to store various performance metrics:
 *   - tbl_DB_WAIT_STATS: Wait statistics (what resources SQL Server is waiting on)
 *   - tbl_db_resource_stats: Resource utilization metrics (CPU, IO, Memory, DTU)
 *   - tbl_HEADBLOCKERSUMMARY: Blocking chain information
 *   - tbl_ResourceIntensiveQuery: Active and resource-intensive queries
 *   - tbl_SPU_HEALTH: CPU utilization over time
 *   - runtimeenv: Runtime environment variables/configuration
 *   - tbl_PERF_STATS_NEW_RUNTIMES: Tracking of data collection runs
 ********************************************************************************************/

/********************************************************************************************
 * TABLE: tbl_DB_WAIT_STATS
 * PURPOSE: Stores wait statistics from sys.dm_db_wait_stats
 * COLUMNS:
 *   - runtime: Timestamp when the data was captured
 *   - wait_type: Type of wait (e.g., LCK_M_X, PAGEIOLATCH_SH, CXPACKET)
 *   - waiting_tasks_count: Number of tasks waiting
 *   - wait_time_ms: Total wait time in milliseconds
 *   - max_wait_time_ms: Maximum wait time for a single wait
 *   - signal_wait_time_ms: Time spent waiting for signal (CPU scheduling)
 *   - wait_category: Computed column that categorizes waits for easier analysis
 *
 * QUERY EXAMPLES:
 *   -- See top wait types over time
 *   SELECT runtime, wait_type, wait_category, wait_time_ms
 *   FROM sqlmonitor.tbl_DB_WAIT_STATS
 *   WHERE runtime > DATEADD(HOUR, -1, GETDATE())
 *   ORDER BY wait_time_ms DESC
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_DB_WAIT_STATS](
	[runtime] [datetime] NULL,
	[wait_type] [varchar](100) NULL,
	[waiting_tasks_count] [bigint] NULL,
	[wait_time_ms] [bigint] NULL,
	[max_wait_time_ms] [bigint] NULL,
	[signal_wait_time_ms] [bigint] NULL,
	-- Computed column: Categorizes wait types into meaningful groups for analysis
	[wait_category]  AS (case when [wait_type] like 'LCK%' then 'Locks' when [wait_type] like 'PAGEIO%' then 'Page I/O Latch' when [wait_type] like 'PAGELATCH%' then 'Page Latch (non-I/O)' when [wait_type] like 'LATCH%' then 'Latch (non-buffer)' when [wait_type] like 'IO_COMPLETION' then 'I/O Completion' when [wait_type] like 'ASYNC_NETWORK_IO' then 'Network I/O (client fetch)' when [wait_type]='CMEMTHREAD' OR [wait_type]='SOS_RESERVEDMEMBLOCKLIST' OR [wait_type]='RESOURCE_SEMAPHORE' then 'Memory' when [wait_type] like 'RESOURCE_SEMAPHORE_%' then 'Compilation' when [wait_type] like 'MSQL_XP' then 'XProc' when [wait_type] like 'WRITELOG' then 'Writelog' when [wait_type]='DISPATCHER_QUEUE_SEMAPHORE' OR [wait_type]='FT_IFTS_SCHEDULER_IDLE_WAIT' OR [wait_type]='WAITFOR' OR [wait_type]='EXECSYNC' OR [wait_type]='SQLTRACE_INCREMENTAL_FLUSH_SLEEP' OR [wait_type]='XE_TIMER_EVENT' OR [wait_type]='XE_DISPATCHER_WAIT' OR [wait_type]='WAITFOR_TASKSHUTDOWN' OR [wait_type]='WAIT_FOR_RESULTS' OR [wait_type]='SQLTRACE_BUFFER_FLUSH' OR [wait_type]='SNI_HTTP_ACCEPT' OR [wait_type]='SLEEP_TEMPDBSTARTUP' OR [wait_type]='SLEEP_TASK' OR [wait_type]='SLEEP_SYSTEMTASK' OR [wait_type]='SLEEP_MSDBSTARTUP' OR [wait_type]='SLEEP_DCOMSTARTUP' OR [wait_type]='SLEEP_DBSTARTUP' OR [wait_type]='SLEEP_BPOOL_FLUSH' OR [wait_type]='SERVER_IDLE_CHECK' OR [wait_type]='RESOURCE_QUEUE' OR [wait_type]='REQUEST_FOR_DEADLOCK_SEARCH' OR [wait_type]='ONDEMAND_TASK_QUEUE' OR [wait_type]='LOGMGR_QUEUE' OR [wait_type]='LAZYWRITER_SLEEP' OR [wait_type]='KSOURCE_WAKEUP' OR [wait_type]='FSAGENT' OR [wait_type]='CLR_MANUAL_EVENT' OR [wait_type]='CLR_AUTO_EVENT' OR [wait_type]='CHKPT' OR [wait_type]='CHECKPOINT_QUEUE' OR [wait_type]='BROKER_TO_FLUSH' OR [wait_type]='BROKER_TASK_STOP' OR [wait_type]='BROKER_TRANSMITTER' OR [wait_type]='BROKER_RECEIVE_WAITFOR' OR [wait_type]='BROKER_EVENTHANDLER' OR [wait_type]='DBMIRROR_EVENTS_QUEUE' OR [wait_type]='DBMIRROR_DBM_EVENT' OR [wait_type]='DBMIRRORING_CMD' OR [wait_type]='DBMIRROR_WORKER_QUEUE' OR [wait_type]='RESOURCE_GOVERNOR_IDLE' OR [wait_type]='PREEMPTIVE_OS_CRYPTOPS' OR [wait_type]='VDI_CLIENT_OTHER' then 'IGNORABLE' else [wait_type] end)
) ON [PRIMARY]
GO
-- Clustered index on tbl_DB_WAIT_STATS for efficient time-series queries
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO

CREATE CLUSTERED INDEX [idx_waitstats] ON [sqlmonitor].[tbl_DB_WAIT_STATS]
(
	[runtime] ASC,
	[wait_category] ASC,
	[wait_type] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/********************************************************************************************
 * VIEW: vw_WAIT_CATEGORY_STATS
 * PURPOSE: Aggregates wait statistics by wait category for easier trend analysis
 * USAGE: Used by WaitStatsTop5Categories stored procedure to identify top wait categories
 *
 * QUERY EXAMPLE:
 *   SELECT * FROM sqlmonitor.vw_WAIT_CATEGORY_STATS
 *   WHERE runtime > DATEADD(HOUR, -1, GETDATE())
 *   ORDER BY wait_time_ms DESC
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE VIEW [sqlmonitor].[vw_WAIT_CATEGORY_STATS] AS 
SELECT 
  runtime,
  wait_category, 
  SUM (ISNULL (waiting_tasks_count, 0)) AS waiting_tasks_count, 
  SUM (ISNULL (wait_time_ms, 0)) AS wait_time_ms, 
  SUM (ISNULL (signal_wait_time_ms, 0)) AS signal_wait_time_ms, 
  MAX (ISNULL (max_wait_time_ms, 0)) AS max_wait_time_ms
FROM [sqlmonitor].[tbl_DB_WAIT_STATS] (NOLOCK) 
WHERE wait_category != 'IGNORABLE'
GROUP BY runtime, wait_category

GO
/********************************************************************************************
 * TABLE: runtimeenv
 * PURPOSE: Stores runtime environment variables and configuration settings
 * USAGE: Tracks last processed ring buffer record IDs to avoid duplicate CPU data collection
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[runtimeenv](
	[codepath] [varchar](100) NULL,    -- Location/context where the variable is used
	[name] [nvarchar](200) NULL,       -- Variable name
	[value] [nvarchar](255) NULL       -- Variable value
) ON [PRIMARY]
GO
/********************************************************************************************
 * TABLE: tbl_db_resource_stats
 * PURPOSE: Stores database resource utilization metrics (primarily for Azure SQL Database)
 * SOURCE: sys.dm_db_resource_stats
 * COLUMNS:
 *   - avg_cpu_percent: Average CPU utilization percentage
 *   - avg_data_io_percent: Average data I/O percentage
 *   - avg_log_write_percent: Average log write I/O percentage
 *   - avg_memory_usage_percent: Average memory usage percentage
 *   - dtu_limit: DTU limit for the database (Azure SQL only)
 *
 * QUERY EXAMPLE:
 *   SELECT end_time, avg_cpu_percent, avg_data_io_percent, avg_log_write_percent
 *   FROM sqlmonitor.tbl_db_resource_stats
 *   WHERE end_time > DATEADD(HOUR, -4, GETDATE())
 *   ORDER BY end_time
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_db_resource_stats](
	[end_time] [datetime] NULL,
	[avg_cpu_percent] [decimal](5, 2) NULL,
	[avg_data_io_percent] [decimal](5, 2) NULL,
	[avg_log_write_percent] [decimal](5, 2) NULL,
	[avg_memory_usage_percent] [decimal](5, 2) NULL,
	[xtp_storage_percent] [decimal](5, 2) NULL,
	[max_worker_percent] [decimal](5, 2) NULL,
	[max_session_percent] [decimal](5, 2) NULL,
	[dtu_limit] [int] NULL,
	[avg_login_rate_percent] [decimal](5, 2) NULL,
	[avg_instance_cpu_percent] [decimal](5, 2) NULL,
	[avg_instance_memory_percent] [decimal](5, 2) NULL,
	[cpu_limit] [decimal](5, 2) NULL,
	[replica_role] [int] NULL
) ON [PRIMARY]
GO
/****** Object:  Index [idx_tbl_db_resource_stats]    Script Date: 03/05/2025 16:00:21 ******/
CREATE CLUSTERED INDEX [idx_tbl_db_resource_stats] ON [sqlmonitor].[tbl_db_resource_stats]
(
	[end_time] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/********************************************************************************************
 * TABLE: tbl_HEADBLOCKERSUMMARY
 * PURPOSE: Stores information about blocking chains and head blockers
 * DESCRIPTION: A "head blocker" is a session that is blocking other sessions but is not
 *              itself blocked by anyone. This table helps identify blocking issues.
 * COLUMNS:
 *   - head_blocker_session_id: The session ID causing the blocking
 *   - blocked_task_count: Number of tasks being blocked by this session
 *   - tot_wait_duration_ms: Total wait time caused by this blocker
 *   - max_blocking_chain_depth: Maximum depth of the blocking chain
 *   - stmt_text: The SQL statement being executed by the head blocker
 *
 * QUERY EXAMPLE:
 *   SELECT runtime, head_blocker_session_id, blocked_task_count, 
 *          tot_wait_duration_ms, stmt_text
 *   FROM sqlmonitor.tbl_HEADBLOCKERSUMMARY
 *   WHERE runtime > DATEADD(HOUR, -1, GETDATE())
 *   ORDER BY tot_wait_duration_ms DESC
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_HEADBLOCKERSUMMARY](
	[rownum] [bigint] IDENTITY(1,1) NOT NULL,
	[runtime] [datetime] NULL,
	[head_blocker_session_id] [int] NULL,
	[blocked_task_count] [int] NULL,
	[tot_wait_duration_ms] [bigint] NULL,
	[blocking_resource_wait_type] [nvarchar](100) NULL,
	[avg_wait_duration_ms] [bigint] NULL,
	[max_wait_duration_ms] [bigint] NULL,
	[max_blocking_chain_depth] [int] NULL,
	[head_blocker_proc_name] [nvarchar](100) NULL,
	[head_blocker_proc_objid] [nvarchar](100) NULL,
	[stmt_text] [nvarchar](max) NULL,
	[head_blocker_plan_handle] [varbinary](150) NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/********************************************************************************************
 * TABLE: tbl_PERF_STATS_NEW_RUNTIMES
 * PURPOSE: Tracks timestamps of data collection runs for blocking detection
 * USAGE: Used to correlate blocking data with specific collection intervals
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_PERF_STATS_NEW_RUNTIMES](
	[runtime] [datetime] NULL
) ON [PRIMARY]
GO
/********************************************************************************************
 * TABLE: tbl_ResourceIntensiveQuery
 * PURPOSE: Captures currently executing queries with detailed execution statistics
 * SOURCE: sys.dm_exec_requests, sys.dm_exec_sessions, and related DMVs
 * DESCRIPTION: Stores top 500 active queries sorted by CPU time at each collection interval
 * KEY COLUMNS:
 *   - cpu_time: CPU time consumed by the query
 *   - duration_ms: Total elapsed time
 *   - logical_reads: Number of logical reads (buffer cache reads)
 *   - physical_reads: Number of physical disk reads
 *   - Granted_query_memory_KB: Memory granted to the query
 *   - blocking_session_id: Session blocking this query (if any)
 *   - wait_type: Current wait type
 *   - sql_text: The actual SQL statement text
 *   - query_plan: XML execution plan
 *
 * QUERY EXAMPLES:
 *   -- Find queries with high logical reads (CPU consumers)
 *   SELECT TOP 20 runtime, session_id, cpu_time, logical_reads, sql_text
 *   FROM sqlmonitor.tbl_ResourceIntensiveQuery
 *   ORDER BY logical_reads DESC
 *
 *   -- Find long-running queries
 *   SELECT TOP 20 runtime, session_id, duration_ms, sql_text
 *   FROM sqlmonitor.tbl_ResourceIntensiveQuery
 *   ORDER BY duration_ms DESC
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_ResourceIntensiveQuery](
	[runtime] [datetime] NULL,
	[session_id] [smallint] NULL,
	[host_name] [sysname] NOT NULL,
	[login_name] [sysname] NOT NULL,
	[DBName] [sysname] NOT NULL,
	[status] [nvarchar](60) NULL,
	[command] [nvarchar](64) NULL,
	[cpu_time] [int] NULL,
	[duration_ms] [int] NULL,
	[reads] [bigint] NULL,
	[logical_reads] [bigint] NULL,
	[writes] [bigint] NULL,
	[Physical_IO_Performed] [int] NULL,
	[Physical_IO_Bytes] [bigint] NULL,
	[rows] [bigint] NULL,
	[Granted_query_memory_KB] [int] NULL,
	[Task_Status] [nvarchar](120) NULL,
	[scheduler_id] [int] NULL,
	[blocking_session_id] [smallint] NULL,
	[wait_type] [nvarchar](120) NULL,
	[wait_time] [int] NULL,
	[wait_resource] [nvarchar](512) NULL,
	[lock_timeout] [int] NULL,
	[open_transaction_count] [int] NULL,
	[Transaction_Name] [nvarchar](32) NULL,
	[Transaction_State] [nvarchar](80) NULL,
	[transaction_isolation_level] [smallint] NULL,
	[executing_managed_code] [bit] NULL,
	[sql_text] [nvarchar](max) NULL,
	[query_plan] [xml] NULL,
	[Cursor_Text] [nvarchar](max) NULL,
	[Cursor_Plan] [xml] NULL,
	[sql_handle] [varbinary](64) NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/********************************************************************************************
 * TABLE: tbl_SPU_HEALTH
 * PURPOSE: Stores CPU utilization metrics over time
 * SOURCE: sys.dm_os_ring_buffers (RING_BUFFER_SCHEDULER_MONITOR)
 * COLUMNS:
 *   - runtime: Data collection timestamp
 *   - EventTime: When the CPU measurement was taken
 *   - system_idle_cpu: Percentage of CPU that was idle
 *   - sql_cpu_utilization: Percentage of CPU used by SQL Server
 *
 * QUERY EXAMPLE:
 *   SELECT EventTime, sql_cpu_utilization, system_idle_cpu,
 *          100 - sql_cpu_utilization - system_idle_cpu AS other_process_cpu
 *   FROM sqlmonitor.tbl_SPU_HEALTH
 *   WHERE EventTime > DATEADD(HOUR, -4, GETDATE())
 *   ORDER BY EventTime
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [sqlmonitor].[tbl_SPU_HEALTH](
	[runtime] [datetime] NULL,
	[record_id] [int] NULL,
	[EventTime] [datetime] NULL,
	[timestamp] [varchar](20) NULL,
	[system_idle_cpu] [int] NULL,
	[sql_cpu_utilization] [int] NULL
) ON [PRIMARY]
GO
/****** Object:  Index [idx_tbl_SPU_HEALTH]    Script Date: 03/05/2025 16:00:22 ******/
CREATE CLUSTERED INDEX [idx_tbl_SPU_HEALTH] ON [sqlmonitor].[tbl_SPU_HEALTH]
(
	[EventTime] ASC,
	[record_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [idx_dbwaitstats]    Script Date: 03/05/2025 16:00:22 ******/
CREATE NONCLUSTERED INDEX [idx_dbwaitstats] ON [sqlmonitor].[tbl_DB_WAIT_STATS]
(
	[wait_category] ASC,
	[runtime] ASC
)
INCLUDE([wait_time_ms]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [idx_tblRSQuery]    Script Date: 03/05/2025 16:00:22 ******/
CREATE NONCLUSTERED INDEX [idx_tblRSQuery] ON [sqlmonitor].[tbl_ResourceIntensiveQuery]
(
	[session_id] ASC,
	[blocking_session_id] ASC,
	[runtime] ASC
)
INCLUDE([Task_Status],[wait_type],[wait_time],[wait_resource],[open_transaction_count],[sql_text],[Cursor_Text]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/********************************************************************************************
 * SECTION 4: STORED PROCEDURES - DATA COLLECTION
 ********************************************************************************************
 * These procedures are called by the SQL Agent Job to collect performance metrics
 * at regular intervals.
 ********************************************************************************************/

/********************************************************************************************
 * PROCEDURE: sp_Capture_Active_Queries
 * PURPOSE: Captures currently executing queries with detailed execution statistics
 * FREQUENCY: Called every time the SQL Agent Job runs
 * WHAT IT CAPTURES:
 *   - Top 500 active queries sorted by CPU time
 *   - Session information (host, login, database)
 *   - Execution statistics (CPU, reads, writes, duration)
 *   - Blocking information
 *   - Transaction details
 *   - Query text and execution plans
 *
 * DATA DESTINATION: sqlmonitor.tbl_ResourceIntensiveQuery
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE procedure [sqlmonitor].[sp_Capture_Active_Queries]
as
Begin
	insert into [sqlmonitor].[tbl_ResourceIntensiveQuery]
		SELECT top 500 getdate(),r.session_id,
			   se.host_name,
			   se.login_name,
			   Db_name(r.database_id) AS dbname,
			   r.status,
			   r.command,
			   r.cpu_time,
			   r.total_elapsed_time as duration_ms,
			   r.reads,
			   r.logical_reads,
			   r.writes,t.pending_io_count as "Physical_IO_Performed",
				 t.pending_io_byte_count as "Physical_IO_Bytes",
				 r.row_count as rows,r.granted_query_memory*8 as Granted_query_memory_KB ,
				 t.task_state as Task_Status,
				 t.scheduler_id,
				 r.blocking_session_id, r.wait_type,r.wait_time,r.wait_resource,r.lock_timeout,r.open_transaction_count,
				 at.name as Transaction_Name, 
				 case at.transaction_state 
						when 0 then 'Initalizing' 
						when 1 then 'Initalized but not Started' 
						when 2 then 'Active' 
						when 3 then 'Transaction Ended (applicable to read-only Transaction)' 
						when 4 then 'Commit process has been initiated on the distributed transaction' 
						when 5 then 'In prepare state' 
						when 6 then 'Committed' 
						when 7 then 'Rolling back' 
						when 8 then 'Rolled Back' 
					end  as Transaction_State,
				 r.transaction_isolation_level,r.executing_managed_code,
			   s.TEXT                 sql_text,
			   p.query_plan           query_plan,
			   sql_CURSORSQL.text as Cursor_Text,
			   SQL_CURSORPLAN.query_plan as Cursor_Plan,
			   r.sql_handle
		FROM   sys.dm_exec_requests r
			   INNER JOIN sys.dm_exec_sessions se ON r.session_id = se.session_id
			   LEFT OUTER JOIN sys.dm_tran_active_transactions at on at.transaction_id = r.transaction_id
					 INNER JOIN sys.dm_os_tasks t on t.request_id=r.request_id and t.session_id=se.session_id and r.scheduler_id=t.scheduler_id
			   OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) s
			   OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) p
			   OUTER APPLY sys.dm_exec_cursors(r.session_id) AS SQL_CURSORS
			   OUTER APPLY sys.dm_exec_sql_text(SQL_CURSORS.sql_handle) AS SQL_CURSORSQL
						   LEFT JOIN sys.dm_exec_query_stats AS SQL_CURSORSTATS
							 ON SQL_CURSORSTATS.sql_handle = SQL_CURSORS.sql_handle
			   OUTER APPLY sys.dm_exec_query_plan(SQL_CURSORSTATS.plan_handle) AS SQL_CURSORPLAN

		WHERE  r.session_id <> @@SPID
			 and   se.is_user_process = 1 
			 and r.database_id <> 1
		order by cpu_time desc
End
GO
/********************************************************************************************
 * PROCEDURE: sp_Capture_Custom_SqlDiag
 * PURPOSE: Main orchestrator procedure that calls all individual data collection procedures
 * CALLED BY: SQL Agent Job "SQLPerfMonitor"
 * PARAMETERS:
 *   @CaptureHeadBlockerSeperately: If 1, captures detailed blocking chain information
 *
 * WHAT IT COLLECTS:
 *   1. Active/Resource-Intensive Queries
 *   2. Wait Statistics
 *   3. Database Resource Stats (for Azure SQL)
 *   4. CPU Utilization Metrics
 *   5. Head Blocker/Blocking Chain Information (if parameter = 1)
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE procedure [sqlmonitor].[sp_Capture_Custom_SqlDiag] (@CaptureHeadBlockerSeperately int)
AS
BEGIN

	-- Capture resource-intensive queries currently executing
	EXEC [sqlmonitor].[sp_Capture_Active_Queries]

	-- Capture wait statistics
	EXEC [sqlmonitor].[sp_Capture_Wait_stats]
	
	-- Capture database resource statistics (primarily for Azure SQL Database)
	Exec [sqlmonitor].[sp_Capture_DB_Resource_Stats]

	-- Capture CPU utilization metrics
	EXEC [sqlmonitor].[sp_Capture_SPU_Health]

	-- Optionally capture detailed blocking information
	if @CaptureHeadBlockerSeperately = 1
	begin
		declare @runtime datetime
		select @runtime = getdate()
		-- Detect and capture blocking chains
		EXEC [sqlmonitor].[sp_perf_stats_new] @RUNTIME=@RUNTIME
		INSERT INTO [sqlmonitor].[tbl_PERF_STATS_NEW_RUNTIMES] VALUES (@RUNTIME)
	end

end
GO
/********************************************************************************************
 * PROCEDURE: sp_Capture_DB_Resource_Stats
 * PURPOSE: Captures database resource utilization (primarily for Azure SQL Database)
 * SOURCE: sys.dm_db_resource_stats DMV
 * DATA DESTINATION: sqlmonitor.tbl_db_resource_stats
 * NOTE: Only captures new records since last collection to avoid duplicates
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
create procedure [sqlmonitor].[sp_Capture_DB_Resource_Stats]
As
begin
   declare @lastrec datetime
   -- Check if we have existing data
   if exists (select top 1 end_time from sqlmonitor.tbl_db_resource_stats)
   begin
			-- Find the last recorded timestamp
			select @lastrec= max(end_time) from tbl_db_resource_stats

			 -- Insert only new records
			 insert into sqlmonitor.tbl_db_resource_stats
			 select end_time,avg_cpu_percent,avg_data_io_percent,avg_log_write_percent,avg_memory_usage_percent,xtp_storage_percent,max_worker_percent,max_session_percent,dtu_limit,avg_login_rate_percent,avg_instance_cpu_percent,avg_instance_memory_percent,cpu_limit,replica_role
			 from sys.dm_db_resource_stats
			 where end_time > @lastrec
	end
	else 
			-- First run: insert all available data
			insert into sqlmonitor.tbl_db_resource_stats
			select end_time,avg_cpu_percent,avg_data_io_percent,avg_log_write_percent,avg_memory_usage_percent,xtp_storage_percent,max_worker_percent,max_session_percent,dtu_limit,avg_login_rate_percent,avg_instance_cpu_percent,avg_instance_memory_percent,cpu_limit,replica_role
			from sys.dm_db_resource_stats
 end
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_Capture_SPU_Health]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


/****** Object:  StoredProcedure [sqlmonitor].[sp_Capture_CPU_Health]    Script Date: 12/08/2021 12:08:18 ******/
CREATE Procedure [sqlmonitor].[sp_Capture_SPU_Health]
as
begin
	SET NUMERIC_ROUNDABORT OFF

	declare @runtime datetime = getdate()
	declare @firstrun int =0
	DECLARE @querystarttime datetime = getdate()
	declare @MaxRingBufferRecordID int

	if not exists (select * from runtimeenv where codepath='PERF_INFREQUENT' and name='LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID')
	begin
		select @MaxRingBufferRecordID =max( cast (record as xml).value('(Record/@id)[1]', 'int')) from sys.dm_os_ring_buffers  where ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'
		insert into runtimeenv (CodePath,Name, Value) values ('PERF_INFREQUENT', 'LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID', @MaxRingBufferRecordID)
	end

	if not exists (select * from runtimeenv where codepath='PERF_INFREQUENT' and name='LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID')
	begin
		select @MaxRingBufferRecordID =max( cast (record as xml).value('(Record/@id)[1]', 'int')) from sys.dm_os_ring_buffers  where ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'
		insert into runtimeenv (CodePath,Name, Value) values ('PERF_INFREQUENT', 'LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID', @MaxRingBufferRecordID)
	end

	declare @LastRingBufferRecordID int
	select @LastRingBufferRecordID = cast (Value as int) from runtimeenv where codepath='PERF_INFREQUENT' and name='LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID'
	set @LastRingBufferRecordID = @LastRingBufferRecordID - 5

	INSERT INTO [sqlmonitor].[tbl_SPU_Health]
	 SELECT 
     CONVERT (varchar(30), @runtime, 126) AS runtime, 
      record.value('(Record/@id)[1]', 'int') AS record_id,
      CONVERT (varchar, DATEADD (ms, -1 * (inf.ms_ticks - [timestamp]), GETDATE()), 126) AS EventTime, [timestamp], 
      record.value('(Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS system_idle_cpu,
      record.value('(Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_cpu_utilization 
    FROM sys.dm_os_sys_info inf CROSS JOIN (
      SELECT timestamp, CONVERT (xml, record) AS record 
      FROM sys.dm_os_ring_buffers 
      WHERE ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'
        AND record LIKE '%<SystemHealth>%'
        and (@firstrun = 1 or cast (record as xml).value('(Record/@id)[1]', 'int') > @LastRingBufferRecordID )
        ) AS t
    ORDER BY record.value('(Record/@id)[1]', 'int') DESC
    
	select @MaxRingBufferRecordID =max( cast (record as xml).value('(Record/@id)[1]', 'int')) from sys.dm_os_ring_buffers  where ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'
	update 	   runtimeenv 
	set Value = @MaxRingBufferRecordID
	where codepath='PERF_INFREQUENT' and name='LAST_RING_BUFFER_SCHEDULER_MONITOR_RECORD_ID'

end
GO
/********************************************************************************************
 * PROCEDURE: sp_Capture_Wait_stats
 * PURPOSE: Captures current wait statistics from sys.dm_db_wait_stats
 * DATA DESTINATION: sqlmonitor.tbl_DB_WAIT_STATS
 * NOTE: Wait stats are cumulative since database restart; deltas are calculated during analysis
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE Procedure [sqlmonitor].[sp_Capture_Wait_stats]
as
begin
	insert into [sqlmonitor].[tbl_DB_WAIT_STATS] (runtime,wait_type,waiting_tasks_count,wait_time_ms,max_wait_time_ms,signal_wait_time_ms)
	select getdate() as runtime, wait_type,waiting_tasks_count,wait_time_ms,max_wait_time_ms,signal_wait_time_ms
	from sys.dm_db_wait_stats
end
GO

/********************************************************************************************
 * SECTION 4: STORED PROCEDURES - ANALYSIS AND REPORTING
 ********************************************************************************************
 * These procedures analyze the collected performance data and generate reports.
 * They are called manually (not by the SQL Agent Job) when you want to analyze performance.
 ********************************************************************************************/

/********************************************************************************************
 * PROCEDURE: sp_Check_DBResourceStats
 * PURPOSE: Analyzes database resource utilization over a time window
 * PARAMETERS:
 *   @StartTime: Start of analysis window (NULL or '19000101' = earliest data)
 *   @EndTime: End of analysis window (NULL or '29990101' = latest data)
 * 
 * RETURNS:
 *   ResultSet 1: Average and maximum resource utilization percentages
 *   ResultSet 2: Detailed time-series data with DTU consumption (for Azure SQL)
 *
 * EXAMPLE USAGE:
 *   -- Analyze last 4 hours
 *   EXEC sp_Check_DBResourceStats @StartTime='2025-05-03 10:00', @EndTime='2025-05-03 14:00'
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE procedure [sqlmonitor].[sp_Check_DBResourceStats] @StartTime datetime='19000101', @EndTime datetime='29990101'
As
Begin
	-- Normalize start time to actual data point
	IF (@StartTime IS NOT NULL AND @StartTime != '19000101') SELECT @StartTime = MAX (end_time) FROM [sqlmonitor].[tbl_db_resource_stats] WHERE end_time <= @StartTime 
	IF (@StartTime IS NULL OR @StartTime = '19000101') SELECT @StartTime = MIN (end_time) FROM [sqlmonitor].[tbl_db_resource_stats]

	-- Normalize end time to actual data point
	IF (@EndTime IS NOT NULL AND @EndTime != '29990101') SELECT @EndTime = MIN (end_time) FROM [sqlmonitor].[tbl_db_resource_stats] WHERE end_time >= @EndTime 
	IF (@EndTime IS NULL OR @EndTime = '29990101') SELECT @EndTime = MAX (end_time) FROM [sqlmonitor].[tbl_db_resource_stats]

	-- Summary statistics
	SELECT 
		AVG(avg_cpu_percent) AS 'Average CPU Utilization In Percent',   
		MAX(avg_cpu_percent) AS 'Maximum CPU Utilization In Percent',   
		AVG(avg_data_io_percent) AS 'Average Data IO In Percent',   
		MAX(avg_data_io_percent) AS 'Maximum Data IO In Percent',   
		AVG(avg_log_write_percent) AS 'Average Log Write I/O Throughput Utilization In Percent',   
		MAX(avg_log_write_percent) AS 'Maximum Log Write I/O Throughput Utilization In Percent',   
		AVG(avg_memory_usage_percent) AS 'Average Memory Usage In Percent',   
		MAX(avg_memory_usage_percent) AS 'Maximum Memory Usage In Percent'   
	FROM sqlmonitor.tbl_db_resource_stats
	WHERE end_time between @StartTime and @EndTime;

	-- Time-series data with DTU calculation (applicable for Azure SQL)
	SELECT 
	 end_time AS [EndTime]
	  , (SELECT Max(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [AvgDTU_Percent]  
	  , ((dtu_limit)*((SELECT Max(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v))/100.00)) AS [AvgDTUsUsed]
	  , dtu_limit AS [DTULimit]
	FROM sqlmonitor.tbl_db_resource_stats
	WHERE end_time between @StartTime and @EndTime;
end
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_check_Outstanding_FileIO_IfAny]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_check_Outstanding_FileIO_IfAny] @dbname sysname
AS
BEGIN
	select vfs.database_id, case df.type when 0 then 'Data' when 1 then 'Log' end as File_Type,
	ior.io_pending,io_stall_write_ms/1000/1000 as io_stall_write_sec 
	from sys.dm_io_pending_io_requests ior
	inner join sys.dm_io_virtual_file_stats (DB_ID(@dbname), NULL) vfs on (vfs.file_handle = ior.io_handle)
	inner join sys.database_files df on (df.file_id = vfs.file_id)
END
GO
/********************************************************************************************
 * PROCEDURE: sp_CheckForPlanCachePollution
 * PURPOSE: Identifies plan cache pollution caused by non-parameterized queries
 * DATA SOURCE: sys.dm_exec_cached_plans
 *
 * WHAT IS PLAN CACHE POLLUTION?
 *   When queries are not parameterized, SQL Server creates a new execution plan for each
 *   literal value variation. For example:
 *     SELECT * FROM Users WHERE UserID = 1
 *     SELECT * FROM Users WHERE UserID = 2
 *   ...create TWO separate plans instead of reusing one parameterized plan.
 *
 * OUTPUT COLUMNS:
 *   - Total Plans: Number of cached plans for this object type
 *   - Total MBs: Memory consumed by all plans
 *   - Total Plans - USE Count 1: Plans used only once (likely won't be reused)
 *   - Total MBs - USE Count 1: Memory wasted on single-use plans
 *   - Percent Wasted: Percentage of plan cache memory wasted
 *
 * INTERPRETATION:
 *   - High "Percent Wasted" (>50%) indicates poor query parameterization
 *   - "Adhoc" object type with many single-use plans is the main culprit
 *   - Consider using sp_executesql or stored procedures
 *   - May also indicate need for OPTIMIZE FOR UNKNOWN or plan guides
 *
 * REMEDIATION:
 *   - Enable "Optimize for ad hoc workloads" server configuration
 *   - Parameterize queries in application code
 *   - Use stored procedures or sp_executesql
 *   - Consider forced parameterization for the database (use cautiously)
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [sqlmonitor].[sp_CheckForPlanCachePollution]
AS 
SELECT [Cache Type] = [cp].[objtype] 
	, [Total Plans] = COUNT_BIG (*) 
	, [Total MBs]
		= SUM (CAST ([cp].[size_in_bytes] 
			AS DECIMAL (18, 2))) / 1024.0 / 1024.0 
	, [Avg Use Count] 
		= AVG ([cp].[usecounts]) 
	, [Total MBs - USE Count 1]
		= SUM (CAST ((CASE WHEN [cp].[usecounts] = 1 
		THEN [cp].[size_in_bytes] ELSE 0 END) 
			AS DECIMAL (18, 2))) / 1024.0 / 1024.0
	, [Total Plans - USE Count 1]
		= SUM (CASE WHEN [cp].[usecounts] = 1 
				THEN 1 ELSE 0 END) 
	, [Percent Wasted]
		= (SUM (CAST ((CASE WHEN [cp].[usecounts] = 1 
			THEN [cp].[size_in_bytes] ELSE 0 END) 
			AS DECIMAL (18, 2))) 
		 / SUM ([cp].[size_in_bytes])) * 100
FROM [sys].[dm_exec_cached_plans] AS [cp]
GROUP BY [cp].[objtype]
ORDER BY [Total MBs - USE Count 1] DESC;
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_perf_stats_new]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/****** Object:  StoredProcedure [sqlmonitor].[sp_perf_stats_new]    Script Date: 12/08/2021 12:08:18 ******/

CREATE PROCEDURE [sqlmonitor].[sp_perf_stats_new] @appname sysname='SQLDIAG', @runtime datetime 
AS
--DECLARE @appname sysname='SQLDIAG', @runtime datetime =GETDATE()

  SET NOCOUNT ON
  DECLARE @msg varchar(100)
  DECLARE @querystarttime datetime
  DECLARE @queryduration int
  DECLARE @qrydurationwarnthreshold int
  DECLARE @servermajorversion int
  DECLARE @cpu_time_start bigint, @elapsed_time_start bigint
  DECLARE @sql nvarchar(max)
  DECLARE @cte nvarchar(max)
  DECLARE @rowcount bigint
 -- DECLARE @runtime datetime

  SELECT @cpu_time_start = cpu_time, @elapsed_time_start = total_elapsed_time FROM sys.dm_exec_requests WHERE session_id = @@SPID

  IF OBJECT_ID ('tempdb.#tmp_requests') IS NOT NULL DROP TABLE #tmp_requests
  IF OBJECT_ID ('tempdb.#tmp_requests2') IS NOT NULL DROP TABLE #tmp_requests2
  
  IF @runtime IS NULL 
  BEGIN 
    SET @runtime = GETDATE()
    --SET @msg = 'Start time: ' + CONVERT (varchar(30), @runtime, 126)
    --RAISERROR (@msg, 0, 1) WITH NOWAIT
  END
  SET @qrydurationwarnthreshold = 500
  
  -- SERVERPROPERTY ('ProductVersion') returns e.g. "9.00.2198.00" --> 9
  SET @servermajorversion = REPLACE (LEFT (CONVERT (varchar, SERVERPROPERTY ('ProductVersion')), 2), '.', '')

  RAISERROR (@msg, 0, 1) WITH NOWAIT
  SET @querystarttime = GETDATE()
  SELECT
    sess.session_id, req.request_id, tasks.exec_context_id AS ecid, tasks.task_address, req.blocking_session_id, LEFT (tasks.task_state, 15) AS task_state, 
    tasks.scheduler_id, LEFT (ISNULL (req.wait_type, ''), 50) AS wait_type, LEFT (ISNULL (req.wait_resource, ''), 40) AS wait_resource, 
    LEFT (req.last_wait_type, 50) AS last_wait_type, 
    /* sysprocesses is the only way to get open_tran count for sessions w/o an active request (SQLBUD #487091) */
    CASE 
      WHEN req.open_transaction_count IS NOT NULL THEN req.open_transaction_count 
      ELSE (SELECT open_tran FROM sys.sysprocesses sysproc WHERE sess.session_id = sysproc.spid) 
    END AS open_trans, 
    LEFT (CASE COALESCE(req.transaction_isolation_level, sess.transaction_isolation_level)
      WHEN 0 THEN '0-Read Committed' 
      WHEN 1 THEN '1-Read Uncommitted (NOLOCK)' 
      WHEN 2 THEN '2-Read Committed' 
      WHEN 3 THEN '3-Repeatable Read' 
      WHEN 4 THEN '4-Serializable' 
      WHEN 5 THEN '5-Snapshot' 
      ELSE CONVERT (varchar(30), req.transaction_isolation_level) + '-UNKNOWN' 
    END, 30) AS transaction_isolation_level, 
    sess.is_user_process, req.cpu_time AS request_cpu_time, 
    /* CASE stmts necessary to workaround SQLBUD #438189 (fixed in SP2) */
    CASE WHEN (@servermajorversion > 9) OR (@servermajorversion = 9 AND SERVERPROPERTY ('ProductLevel') >= 'SP2' COLLATE Latin1_General_BIN) 
      THEN req.logical_reads ELSE req.logical_reads - sess.logical_reads END AS request_logical_reads, 
    CASE WHEN (@servermajorversion > 9) OR (@servermajorversion = 9 AND SERVERPROPERTY ('ProductLevel') >= 'SP2' COLLATE Latin1_General_BIN) 
      THEN req.reads ELSE req.reads - sess.reads END AS request_reads, 
    CASE WHEN (@servermajorversion > 9) OR (@servermajorversion = 9 AND SERVERPROPERTY ('ProductLevel') >= 'SP2' COLLATE Latin1_General_BIN)
      THEN req.writes ELSE req.writes - sess.writes END AS request_writes, 
    sess.memory_usage, sess.cpu_time AS session_cpu_time, sess.reads AS session_reads, sess.writes AS session_writes, sess.logical_reads AS session_logical_reads, 
    sess.total_scheduled_time, sess.total_elapsed_time, sess.last_request_start_time, sess.last_request_end_time, sess.row_count AS session_row_count, 
    sess.prev_error, req.open_resultset_count AS open_resultsets, req.total_elapsed_time AS request_total_elapsed_time, 
    CONVERT (decimal(5,2), req.percent_complete) AS percent_complete, req.estimated_completion_time AS est_completion_time, req.transaction_id, 
    req.start_time AS request_start_time, LEFT (req.status, 15) AS request_status, req.command, req.plan_handle, req.sql_handle, req.statement_start_offset, 
    req.statement_end_offset, req.database_id, req.[user_id], req.executing_managed_code, tasks.pending_io_count, sess.login_time, 
    LEFT (sess.[host_name], 20) AS [host_name], LEFT (ISNULL (sess.program_name, ''), 50) AS program_name, ISNULL (sess.host_process_id, 0) AS host_process_id, 
    ISNULL (sess.client_version, 0) AS client_version, LEFT (ISNULL (sess.client_interface_name, ''), 30) AS client_interface_name, 
    LEFT (ISNULL (sess.login_name, ''), 30) AS login_name, LEFT (ISNULL (sess.nt_domain, ''), 30) AS nt_domain, LEFT (ISNULL (sess.nt_user_name, ''), 20) AS nt_user_name, 
    ISNULL (conn.net_packet_size, 0) AS net_packet_size, LEFT (ISNULL (conn.client_net_address, ''), 20) AS client_net_address, conn.most_recent_sql_handle, 
    LEFT (sess.status, 15) AS session_status,
    /* sys.dm_os_workers and sys.dm_os_threads removed due to perf impact, no predicate pushdown (SQLBU #488971) */
    --  workers.is_preemptive,
    --  workers.is_sick, 
    --  workers.exception_num AS last_worker_exception, 
    --  convert (varchar (20), mastersys.fn_varbintohexstr (workers.exception_address)) AS last_exception_address
    --  threads.os_thread_id 
    sess.group_id
  INTO #tmp_requests
  FROM sys.dm_exec_sessions sess 
  /* Join hints are required here to work around bad QO join order/type decisions (ultimately by-design, caused by the lack of accurate DMV card estimates) */
  LEFT OUTER MERGE JOIN sys.dm_exec_requests req  ON sess.session_id = req.session_id
  LEFT OUTER MERGE JOIN sys.dm_os_tasks tasks ON tasks.session_id = sess.session_id AND tasks.request_id = req.request_id 
  /* The following two DMVs removed due to perf impact, no predicate pushdown (SQLBU #488971) */
  --  LEFT OUTER MERGE JOIN sys.dm_os_workers workers ON tasks.worker_address = workers.worker_address
  --  LEFT OUTER MERGE JOIN sys.dm_os_threads threads ON workers.thread_address = threads.thread_address
  LEFT OUTER MERGE JOIN sys.dm_exec_connections conn on conn.session_id = sess.session_id
  left outer merge join sys.dm_exec_requests req2 on sess.session_id = req2.blocking_session_id 
  WHERE 
    /* Get execution state for all active queries... */
    (req.session_id IS NOT NULL AND (sess.is_user_process = 1 OR req.status COLLATE Latin1_General_BIN NOT IN ('background', 'sleeping')))
    /* ... and also any head blockers, even though they may not be running a query at the moment. */
    --OR (sess.session_id IN (SELECT DISTINCT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id != 0))
      or req2.session_id is not null
  /* redundant due to the use of join hints, but added here to suppress warning message */
  OPTION (FORCE ORDER)  


  SET @rowcount = @@ROWCOUNT
  SET @queryduration = DATEDIFF (ms, @querystarttime, GETDATE())
  --IF @queryduration > @qrydurationwarnthreshold
  --  PRINT 'DebugPrint: perfstats qry1 - ' + CONVERT (varchar, @queryduration) + 'ms, rowcount=' + CONVERT(varchar, @rowcount) + CHAR(13) + CHAR(10)

  ----IF NOT EXISTS (SELECT * FROM #tmp_requests WHERE session_id <> @@SPID AND ISNULL (host_name, '') != @appname) BEGIN
  ----  PRINT 'No active queries'
  --END
  --ELSE BEGIN
    -- There are active queries (other than this one). 
    -- This query could be collapsed into the query above.  It is broken out here to avoid an excessively 
    -- large memory grant due to poor cardinality estimates (see previous bugs -- ultimate cause is the 
    -- lack of od stats for many DMVs). 
    SET @querystarttime = GETDATE()
    SELECT 
      IDENTITY (int,1,1) AS tmprownum, 
      r.session_id, r.request_id, r.ecid, r.blocking_session_id, ISNULL (waits.blocking_exec_context_id, 0) AS blocking_ecid, 
      r.task_state, waits.wait_type, ISNULL (waits.wait_duration_ms, 0) AS wait_duration_ms, r.wait_resource, 
      LEFT (ISNULL (waits.resource_description, ''), 140) AS resource_description, r.last_wait_type, r.open_trans, 
      r.transaction_isolation_level, r.is_user_process, r.request_cpu_time, r.request_logical_reads, r.request_reads, 
      r.request_writes, r.memory_usage, r.session_cpu_time, r.session_reads, r.session_writes, r.session_logical_reads, 
      r.total_scheduled_time, r.total_elapsed_time, r.last_request_start_time, r.last_request_end_time, r.session_row_count, 
      r.prev_error, r.open_resultsets, r.request_total_elapsed_time, r.percent_complete, r.est_completion_time, 
      -- r.tran_name, r.transaction_begin_time, r.tran_type, r.tran_state, 
      LEFT (COALESCE (reqtrans.name, sesstrans.name, ''), 24) AS tran_name, 
      COALESCE (reqtrans.transaction_begin_time, sesstrans.transaction_begin_time) AS transaction_begin_time, 
      LEFT (CASE COALESCE (reqtrans.transaction_type, sesstrans.transaction_type)
        WHEN 1 THEN '1-Read/write'
        WHEN 2 THEN '2-Read only'
        WHEN 3 THEN '3-System'
        WHEN 4 THEN '4-Distributed'
        ELSE CONVERT (varchar(30), COALESCE (reqtrans.transaction_type, sesstrans.transaction_type)) + '-UNKNOWN' 
      END, 15) AS tran_type, 
      LEFT (CASE COALESCE (reqtrans.transaction_state, sesstrans.transaction_state)
        WHEN 0 THEN '0-Initializing'
        WHEN 1 THEN '1-Initialized'
        WHEN 2 THEN '2-Active'
        WHEN 3 THEN '3-Ended'
        WHEN 4 THEN '4-Preparing'
        WHEN 5 THEN '5-Prepared'
        WHEN 6 THEN '6-Committed'
        WHEN 7 THEN '7-Rolling back'
        WHEN 8 THEN '8-Rolled back'
        ELSE CONVERT (varchar(30), COALESCE (reqtrans.transaction_state, sesstrans.transaction_state)) + '-UNKNOWN'
      END, 15) AS tran_state, 
      r.request_start_time, r.request_status, r.command, r.plan_handle, r.sql_handle, r.statement_start_offset, 
      r.statement_end_offset, r.database_id, r.[user_id], r.executing_managed_code, r.pending_io_count, r.login_time, 
      r.[host_name], r.program_name, r.host_process_id, r.client_version, r.client_interface_name, r.login_name, r.nt_domain, 
      r.nt_user_name, r.net_packet_size, r.client_net_address, r.most_recent_sql_handle, r.session_status, r.scheduler_id,
      -- r.is_preemptive, r.is_sick, r.last_worker_exception, r.last_exception_address, 
      -- r.os_thread_id
      r.group_id
    INTO #tmp_requests2
    FROM #tmp_requests r
    /* Join hints are required here to work around bad QO join order/type decisions (ultimately by-design, caused by the lack of accurate DMV card estimates) */
    /* Perf: no predicate pushdown on sys.dm_tran_active_transactions (SQLBU #489000) */
    LEFT OUTER MERGE JOIN sys.dm_tran_active_transactions reqtrans ON r.transaction_id = reqtrans.transaction_id
    /* No predicate pushdown on sys.dm_tran_session_transactions (SQLBU #489000) */
    LEFT OUTER MERGE JOIN sys.dm_tran_session_transactions sessions_transactions on sessions_transactions.session_id = r.session_id
    /* No predicate pushdown on sys.dm_tran_active_transactions (SQLBU #489000) */
    LEFT OUTER MERGE JOIN sys.dm_tran_active_transactions sesstrans ON sesstrans.transaction_id = sessions_transactions.transaction_id
    /* Suboptimal perf: see SQLBUD #449144. But we have to handle this in qry3 instead of here to avoid SQLBUD #489109. */
    LEFT OUTER MERGE JOIN sys.dm_os_waiting_tasks waits ON waits.waiting_task_address = r.task_address 
    ORDER BY r.session_id, blocking_ecid
    /* redundant due to the use of join hints, but added here to suppress warning message */
    OPTION (FORCE ORDER)  
 --   SET @rowcount = @@ROWCOUNT
 
     /* This index typically takes <10ms to create, and drops the head blocker summary query cost from ~250ms CPU down to ~20ms. */
    CREATE NONCLUSTERED INDEX idx2 ON #tmp_requests2 (blocking_session_id, session_id, wait_type, wait_duration_ms)


    SET @querystarttime = GETDATE()
	--insert into tbl_requests
    --EXEC sp_executesql @sql, N'@runtime datetime, @appname sysname', @runtime = @runtime, @appname = @appname
    --SET @rowcount = @@ROWCOUNT

    /* Resultset #2: Head blocker summary */
    /* Intra-query blocking relationships (parallel query waits) aren't "true" blocking problems that we should report on here. */
    IF EXISTS (SELECT * FROM #tmp_requests2 WHERE blocking_session_id != 0 AND wait_type NOT IN ('WAITFOR', 'EXCHANGE', 'CXPACKET') AND wait_duration_ms > 0) 
      
      SET @cte = '
      WITH BlockingHierarchy (head_blocker_session_id, session_id, blocking_session_id, wait_type, wait_duration_ms, 
        wait_resource, statement_start_offset, statement_end_offset, plan_handle, sql_handle, most_recent_sql_handle, [Level]) 
      AS (
        SELECT head.session_id AS head_blocker_session_id, head.session_id AS session_id, head.blocking_session_id, 
          head.wait_type, head.wait_duration_ms, head.wait_resource, head.statement_start_offset, head.statement_end_offset, 
          head.plan_handle, head.sql_handle, head.most_recent_sql_handle, 0 AS [Level]
        FROM #tmp_requests2 head
        WHERE (head.blocking_session_id IS NULL OR head.blocking_session_id = 0) 
          AND head.session_id IN (SELECT DISTINCT blocking_session_id FROM #tmp_requests2 WHERE blocking_session_id != 0) 
        UNION ALL 
        SELECT h.head_blocker_session_id, blocked.session_id, blocked.blocking_session_id, blocked.wait_type, 
          blocked.wait_duration_ms, blocked.wait_resource, h.statement_start_offset, h.statement_end_offset, 
          h.plan_handle, h.sql_handle, h.most_recent_sql_handle, [Level] + 1
        FROM #tmp_requests2 blocked
        INNER JOIN BlockingHierarchy AS h ON h.session_id = blocked.blocking_session_id  and h.session_id!=blocked.session_id --avoid infinite recursion for latch type of blocknig
        WHERE h.wait_type COLLATE Latin1_General_BIN NOT IN (''EXCHANGE'', ''CXPACKET'') or h.wait_type is null
      )'
      SET @sql = '
      SELECT CONVERT (varchar(30), @runtime, 126) AS runtime, 
        head_blocker_session_id, COUNT(*) AS blocked_task_count, SUM (ISNULL (wait_duration_ms, 0)) AS tot_wait_duration_ms, 
        LEFT (CASE 
          WHEN wait_type LIKE ''LCK%'' COLLATE Latin1_General_BIN AND wait_resource LIKE ''%\[COMPILE\]%'' ESCAPE ''\'' COLLATE Latin1_General_BIN 
            THEN ''COMPILE ('' + ISNULL (wait_resource, '''') + '')'' 
          WHEN wait_type LIKE ''LCK%'' COLLATE Latin1_General_BIN THEN ''LOCK BLOCKING'' 
          WHEN wait_type LIKE ''PAGELATCH%'' COLLATE Latin1_General_BIN THEN ''PAGELATCH_* WAITS'' 
          WHEN wait_type LIKE ''PAGEIOLATCH%'' COLLATE Latin1_General_BIN THEN ''PAGEIOLATCH_* WAITS'' 
          ELSE wait_type
        END, 40) AS blocking_resource_wait_type, AVG (ISNULL (wait_duration_ms, 0)) AS avg_wait_duration_ms, MAX(wait_duration_ms) AS max_wait_duration_ms, 
        MAX ([Level]) AS max_blocking_chain_depth, 
        MAX (ISNULL (CONVERT (nvarchar(60), CASE 
          WHEN sql.objectid IS NULL THEN NULL 
          ELSE REPLACE (REPLACE (SUBSTRING (sql.[text], CHARINDEX (''CREATE '', CONVERT (nvarchar(512), SUBSTRING (sql.[text], 1, 1000)) COLLATE Latin1_General_BIN), 50) COLLATE Latin1_General_BIN, CHAR(10), '' ''), CHAR(13), '' '')
        END), '''')) AS head_blocker_proc_name, 
        MAX (ISNULL (sql.objectid, 0)) AS head_blocker_proc_objid, MAX (ISNULL (CONVERT (nvarchar(1000), REPLACE (REPLACE (SUBSTRING (sql.[text], ISNULL (statement_start_offset, 0)/2 + 1, 
          CASE WHEN ISNULL (statement_end_offset, 8192) <= 0 THEN 8192 
          ELSE ISNULL (statement_end_offset, 8192)/2 - ISNULL (statement_start_offset, 0)/2 END + 1) COLLATE Latin1_General_BIN, 
        CHAR(13), '' ''), CHAR(10), '' '')), '''')) AS stmt_text, 
        CONVERT (varbinary (64), MAX (ISNULL (plan_handle, 0x))) AS head_blocker_plan_handle
      FROM BlockingHierarchy
      OUTER APPLY sys.dm_exec_sql_text (ISNULL (sql_handle, most_recent_sql_handle)) AS sql
      WHERE blocking_session_id != 0 AND [Level] > 0
      GROUP BY head_blocker_session_id, 
        LEFT (CASE 
          WHEN wait_type LIKE ''LCK%'' COLLATE Latin1_General_BIN AND wait_resource LIKE ''%\[COMPILE\]%'' ESCAPE ''\'' COLLATE Latin1_General_BIN 
            THEN ''COMPILE ('' + ISNULL (wait_resource, '''') + '')'' 
          WHEN wait_type LIKE ''LCK%'' COLLATE Latin1_General_BIN THEN ''LOCK BLOCKING'' 
          WHEN wait_type LIKE ''PAGELATCH%'' COLLATE Latin1_General_BIN THEN ''PAGELATCH_* WAITS'' 
          WHEN wait_type LIKE ''PAGEIOLATCH%'' COLLATE Latin1_General_BIN THEN ''PAGEIOLATCH_* WAITS'' 
          ELSE wait_type
        END, 40) 
      ORDER BY SUM (wait_duration_ms) DESC'
      IF '%runmode%' = 'REALTIME' SET @sql = @cte + '
        INSERT INTO tbl_HEADBLOCKERSUMMARY (
          runtime, head_blocker_session_id, blocked_task_count, tot_wait_duration_ms, blocking_resource_wait_type, avg_wait_duration_ms, 
          max_wait_duration_ms, max_blocking_chain_depth, head_blocker_proc_name, head_blocker_proc_objid, stmt_text, head_blocker_plan_handle) ' + @sql
      ELSE 
        SET @sql = @cte + @sql
      SET @querystarttime = GETDATE();
	  insert into [sqlmonitor].[tbl_HEADBLOCKERSUMMARY]
      EXEC sp_executesql @sql, N'@runtime datetime', @runtime = @runtime

GO
/********************************************************************************************
 * PROCEDURE: sp_Print_BlockingTree
 * PURPOSE: Displays blocking chains in a hierarchical tree visualization
 * DATA SOURCE: sqlmonitor.tbl_ResourceIntensiveQuery (collected by data collection job)
 *
 * OUTPUT FORMAT:
 *   Blocking Tree
 *   ==================
 *   2025-05-03 14:32:15  Head Blocker - 52 {(RUNNING) -> LCK_M_X -> ...} - UPDATE...
 *                        |-- 87 {(SUSPENDED) -> LCK_M_S -> ...} - SELECT...
 *                            |-- 93 {(SUSPENDED) -> LCK_M_S -> ...} - SELECT...
 *
 * INTERPRETATION:
 *   - Head Blocker: The session causing the block (not blocked by anyone)
 *   - Indented sessions: Blocked sessions (each level shows blocking chain depth)
 *   - Task Status: RUNNING, SUSPENDED, etc.
 *   - Wait Type: What the session is waiting for (LCK_M_X = exclusive lock)
 *   - SQL Text: The query being executed
 *
 * USE WHEN: Troubleshooting blocking issues
 ********************************************************************************************/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE Procedure [sqlmonitor].[sp_Print_BlockingTree]
AS
Begin
	SET NOCOUNT ON
	SET CONCAT_NULL_YIELDS_NULL OFF

	-- Build a temporary table with blocking information
	SELECT R.RUNTIME
	, R.SESSION_ID as SPID
	, R.blocking_session_id as BLOCKED
	, REPLACE (
	 REPLACE ('{('+r.Task_Status +') -> '+ R.wait_type + ' -> ' + r.wait_resource 
	  + ' (' + cast(R.wait_time as varchar) +'ms) -> OpenTranCnt='+ cast(r.open_transaction_count as varchar)+' } - ' 
	   + case when r.sql_text is not null and r.sql_text <> 'NULL' then r.sql_text + ' - ' else 'Cursor_Query: '+ r.Cursor_Text end 
	 , CHAR(10), ' ')
	  , CHAR (13), ' ') AS BATCH
	INTO #T
	FROM [sqlmonitor].[tbl_ResourceIntensiveQuery] R 

	-- Recursive CTE to build the blocking hierarchy
	;WITH BLOCKERS (RUNTIME, SPID, BLOCKED, LEVEL, BATCH)
	AS(
	-- Anchor: Find head blockers (sessions that block others but aren't blocked)
	SELECT RUNTIME,
	SPID, 
	BLOCKED, 
	CAST (REPLICATE ('0', 6-LEN (CAST (SPID AS VARCHAR))) + CAST (SPID AS VARCHAR) AS VARCHAR (1000)) AS LEVEL, 
	BATCH FROM #T R
	 where EXISTS (SELECT * FROM #T R2 WHERE R.RUNTIME = R2.RUNTIME AND R2.BLOCKED = R.SPID  AND R2.BLOCKED <> R2.SPID)
 
	UNION ALL
 
	-- Recursive: Find all sessions blocked by the head blocker
	SELECT R.RUNTIME, R.SPID, 
	R.BLOCKED, 
	CAST (BLOCKERS.LEVEL + RIGHT (CAST ((100000 + R.SPID) AS VARCHAR (100)), 6) AS VARCHAR (1000)) AS LEVEL, 
	R.BATCH 
	FROM #T AS R 
	INNER JOIN BLOCKERS 
	ON R.RUNTIME = BLOCKERS.RUNTIME AND R.BLOCKED = BLOCKERS.SPID 
	WHERE R.BLOCKED > 0 AND R.BLOCKED <> R.SPID
 
	)
	-- Format the output as a hierarchical tree
	SELECT case when (LEN (LEVEL)/6 - 1) = 0 then '
Blocking Tree
==================
' else '' END + convert(varchar,RUNTIME,121)
	 + CASE WHEN (LEN (LEVEL)/6) = 0 
	   THEN '  Head Blocker - ' 
	   ELSE '                 ' END 
	 + REPLICATE (N'|   ', LEN (LEVEL)/6 - 2) 
	 + CASE WHEN (LEN (LEVEL)/6 - 1) = 0 THEN '' ELSE '|-- ' END 
	 + CAST (SPID AS NVARCHAR (10)) + ' ' + BATCH 
	 AS BLOCKING_TREE 
	FROM BLOCKERS ORDER BY RUNTIME ASC , LEVEL ASC;
	DROP TABLE #T
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_Check_Disabled_Index_ifExists]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_SchAnalysis_Check_Disabled_Index_ifExists]
AS
BEGIN
	/***** Generate complete list of disabled indexes (if any) in your database ****/
	SELECT DISTINCT SCHEMA_NAME(a.schema_id) AS 'SchemaName', OBJECT_NAME(a.object_id) AS 'TableName', a.object_id AS 'object_id', b.name AS 'IndexName', b.index_id AS 'index_id', b.type AS 'Type', b.type_desc AS 'IndexType', b.is_disabled AS 'Disabled'
	FROM sys.objects a (NOLOCK)
	JOIN sys.indexes b (NOLOCK) ON b.object_id = a.object_id AND a.is_ms_shipped = 0 
	AND a.object_id NOT IN (SELECT major_id FROM sys.extended_properties (NOLOCK) WHERE name = N'microsoft_database_tools_support')
	WHERE b.is_disabled = 1
	ORDER BY 1,2
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_Check_Duplicate_Index_ifExists]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_SchAnalysis_Check_Duplicate_Index_ifExists]
AS
BEGIN
/***** Generate the complete list of duplicate indexes (if any) in your database   ****/
	;with IndexColumns AS(
	select distinct  schema_name (o.schema_id) as 'SchemaName',object_name(o.object_id) as TableName, i.Name as IndexName, o.object_id,i.index_id,i.type,
	(select case key_ordinal when 0 then NULL else '['+col_name(k.object_id,column_id) +'] ' + CASE WHEN is_descending_key=1 THEN 'Desc' ELSE 'Asc' END end as [data()]
	from sys.index_columns  (NOLOCK) as k
	where k.object_id = i.object_id
	and k.index_id = i.index_id
	order by key_ordinal, column_id
	for xml path('')) as cols,
	case when i.index_id=1 then 
	(select '['+name+']' as [data()]
	from sys.columns  (NOLOCK) as c
	where c.object_id = i.object_id
	and c.column_id not in (select column_id from sys.index_columns  (NOLOCK) as kk    where kk.object_id = i.object_id and kk.index_id = i.index_id)
	order by column_id
	for xml path(''))
	else (select '['+col_name(k.object_id,column_id) +']' as [data()]
	from sys.index_columns  (NOLOCK) as k
	where k.object_id = i.object_id
	and k.index_id = i.index_id and is_included_column=1 and k.column_id not in (Select column_id from sys.index_columns kk where k.object_id=kk.object_id and kk.index_id=1)
	order by key_ordinal, column_id
	for xml path('')) end as inc
	from sys.indexes  (NOLOCK) as i
	inner join sys.objects o  (NOLOCK) on i.object_id =o.object_id 
	inner join sys.index_columns ic  (NOLOCK) on ic.object_id =i.object_id and ic.index_id =i.index_id
	inner join sys.columns c  (NOLOCK) on c.object_id = ic.object_id and c.column_id = ic.column_id
	where  o.type = 'U' and i.index_id <>0 and i.type <>3 and i.type <>5 and i.type <>6 and i.type <>7 
	group by o.schema_id,o.object_id,i.object_id,i.Name,i.index_id,i.type
	),
	DuplicatesTable AS
	(SELECT    ic1.SchemaName,ic1.TableName,ic1.IndexName,ic1.object_id, ic2.IndexName as DuplicateIndexName, 
	CASE WHEN ic1.index_id=1 THEN ic1.cols + ' (Clustered)' WHEN ic1.inc = '' THEN ic1.cols  WHEN ic1.inc is NULL THEN ic1.cols ELSE ic1.cols + ' INCLUDE ' + ic1.inc END as IndexCols, 
	ic1.index_id
	from IndexColumns ic1 join IndexColumns ic2 on ic1.object_id = ic2.object_id
	and ic1.index_id < ic2.index_id and ic1.cols = ic2.cols
	and (ISNULL(ic1.inc,'') = ISNULL(ic2.inc,'')  OR ic1.index_id=1 )
	)
	SELECT SchemaName,TableName, IndexName,DuplicateIndexName, IndexCols, index_id, object_id, 0 AS IsXML
	FROM DuplicatesTable dt
	ORDER BY 1,2,3
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_Check_hypothetical_Index_ifExists]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_SchAnalysis_Check_hypothetical_Index_ifExists]
AS
BEGIN
	/**** Generate the complete list of hypothetical indexes (if any) in your database ****/
	SELECT DISTINCT
	SCHEMA_NAME(a.schema_id) AS 'SchemaName',OBJECT_NAME(a.object_id) AS 'TableName',a.object_id AS 'object_id',b.name AS 'IndexName',b.index_id AS 'index_id',b.type_desc AS 'IndexType', indexproperty(a.object_id, b.name, 'IsHypothetical') AS 'Hypothetical'
	FROM sys.objects a (NOLOCK)
	JOIN sys.indexes b (NOLOCK) ON b.object_id = a.object_id
	AND a.is_ms_shipped = 0
	AND a.object_id NOT IN (SELECT major_id FROM sys.extended_properties (NOLOCK) WHERE name = N'microsoft_database_tools_support')
	WHERE indexproperty(a.object_id, b.name, 'IsHypothetical') = 1
	ORDER BY 1,2,3
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_Check_Redundant_Index_ifExists]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_SchAnalysis_Check_Redundant_Index_ifExists]
AS
BEGIN
	/***** Generate complete list of redundant indexes (If any) in your database  ****/
	;with IndexColumns AS(
	select distinct  schema_name (o.schema_id) as 'SchemaName',object_name(o.object_id) as TableName, i.Name as IndexName, o.object_id,i.index_id,i.type,
	(select case key_ordinal when 0 then NULL else '['+col_name(k.object_id,column_id) +']' end as [data()]
	from sys.index_columns  (NOLOCK) as k
	where k.object_id = i.object_id
	and k.index_id = i.index_id
	order by key_ordinal, column_id
	for xml path('')) as cols,
	(select case key_ordinal when 0 then NULL else '['+col_name(k.object_id,column_id) +'] ' + CASE WHEN is_descending_key=1 THEN 'Desc' ELSE 'Asc' END end as [data()]
	from sys.index_columns  (NOLOCK) as k
	where k.object_id = i.object_id
	and k.index_id = i.index_id
	order by key_ordinal, column_id
	for xml path('')) as colsWithSortOrder,
	case when i.index_id=1 then 
	(select '['+name+']' as [data()]
	from sys.columns  (NOLOCK) as c
	where c.object_id = i.object_id
	and c.column_id not in (select column_id from sys.index_columns  (NOLOCK) as kk    where kk.object_id = i.object_id and kk.index_id = i.index_id)
	order by column_id for xml path(''))
	else
	(select '['+col_name(k.object_id,column_id) +']' as [data()]
	from sys.index_columns  (NOLOCK) as k
	where k.object_id = i.object_id
	and k.index_id = i.index_id and is_included_column=1 and k.column_id not in (Select column_id from sys.index_columns kk where k.object_id=kk.object_id and kk.index_id=1)
	order by key_ordinal, column_id for xml path('')) end as inc
	from sys.indexes  (NOLOCK) as i
	inner join sys.objects o  (NOLOCK) on i.object_id =o.object_id 
	inner join sys.index_columns ic  (NOLOCK) on ic.object_id =i.object_id and ic.index_id =i.index_id
	inner join sys.columns c  (NOLOCK) on c.object_id = ic.object_id and c.column_id = ic.column_id
	where  o.type = 'U' and i.index_id <>0 and i.type <>3 and i.type <>5 and i.type <>6 and i.type <>7
	group by o.schema_id,o.object_id,i.object_id,i.Name,i.index_id,i.type
	), ResultTable AS
	(SELECT    ic1.SchemaName,ic1.TableName,ic1.IndexName,ic1.object_id, ic2.IndexName as RedundantIndexName, CASE WHEN ic1.index_id=1 THEN ic1.colsWithSortOrder + ' (Clustered)' WHEN ic1.inc = '' THEN ic1.colsWithSortOrder  WHEN ic1.inc is NULL THEN ic1.colsWithSortOrder ELSE ic1.colsWithSortOrder + ' INCLUDE ' + ic1.inc END as IndexCols, 
	CASE WHEN ic2.index_id=1 THEN ic2.colsWithSortOrder + ' (Clustered)' WHEN ic2.inc = '' THEN ic2.colsWithSortOrder  WHEN ic2.inc is NULL THEN ic2.colsWithSortOrder ELSE ic2.colsWithSortOrder + ' INCLUDE ' + ic2.inc END as RedundantIndexCols, ic1.index_id
	,ic1.cols col1,ic2.cols col2
	from IndexColumns ic1 join IndexColumns ic2 on ic1.object_id = ic2.object_id
	and ic1.index_id <> ic2.index_id and not (ic1.colsWithSortOrder = ic2.colsWithSortOrder and ISNULL(ic1.inc,'') = ISNULL(ic2.inc,''))
	and not (ic1.index_id=1 AND ic1.cols = ic2.cols ) and ic1.cols like REPLACE (ic2.cols , '[','[[]') + '%'
	)
	SELECT SchemaName,TableName, IndexName, IndexCols, RedundantIndexName, RedundantIndexCols, object_id, index_id
	FROM ResultTable
	ORDER BY 1,2,3,5
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_Identify_WriteIntensive_Indexes]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

Create procedure [sqlmonitor].[sp_SchAnalysis_Identify_WriteIntensive_Indexes]
AS
BEGIN
	/**** Check index Read:Write to identify Write Intensive Indexes (reads <100) and writes > reads  *****/
	SELECT OBJECT_NAME(s.[object_id]) AS [ObjectName] , 
	i.name AS [IndexName] , i.index_id , 
	user_seeks + user_scans + user_lookups AS [Reads] , 
	user_updates AS [Writes] , 
	i.type_desc AS [IndexType] , 
	i.fill_factor AS [FillFactor]
	FROM sys.dm_db_index_usage_stats AS s 
	INNER JOIN sys.indexes AS i ON s.[object_id] = i.[object_id]
	WHERE OBJECTPROPERTY(s.[object_id], 'IsUserTable') = 1 
	AND i.index_id = s.index_id 
	AND s.database_id = DB_ID()
	AND (user_seeks + user_scans + user_lookups) < 100 and user_updates  > 1000
	ORDER BY writes DESC
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[sp_SchAnalysis_List_ForeignKeys_Without_Index]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


Create procedure [sqlmonitor].[sp_SchAnalysis_List_ForeignKeys_Without_Index]
AS
BEGIN

	/* Generate the list of Foreign keys with no supporting indexes in a your database */

	;WITH FKTable 
	as(
		SELECT schema_name(o.schema_id) AS 'parent_schema_name',object_name(FKC.parent_object_id) 'parent_table_name',
		object_name(constraint_object_id) AS 'constraint_name',schema_name(RO.Schema_id) AS 'referenced_schema',object_name(referenced_object_id) AS 'referenced_table_name',
		(SELECT '['+col_name(k.parent_object_id,parent_column_id) +']' AS [data()]
		  FROM sys.foreign_key_columns (NOLOCK) AS k
		  INNER JOIN sys.foreign_keys (NOLOCK)
		  ON k.constraint_object_id =object_id
		  AND k.constraint_object_id =FKC.constraint_object_id
		  ORDER BY constraint_column_id
		  FOR XML PATH('') 
		) AS 'parent_colums',
		(SELECT '['+col_name(k.referenced_object_id,referenced_column_id) +']' AS [data()]
		  FROM sys.foreign_key_columns (NOLOCK) AS k
		  INNER JOIN sys.foreign_keys (NOLOCK)
		  ON k.constraint_object_id =object_id
		  AND k.constraint_object_id =FKC.constraint_object_id
		  ORDER BY constraint_column_id
		  FOR XML PATH('') 
		) AS 'referenced_columns'
	  FROM sys.foreign_key_columns FKC (NOLOCK)
	  INNER JOIN sys.objects o (NOLOCK) ON FKC.parent_object_id = o.object_id
	  INNER JOIN sys.objects RO (NOLOCK) ON FKC.referenced_object_id = RO.object_id
	  WHERE o.object_id in (SELECT object_id FROM sys.objects (NOLOCK) WHERE type ='U') AND RO.object_id in (SELECT object_id FROM sys.objects (NOLOCK) WHERE type ='U')
	  group by o.schema_id,RO.schema_id,FKC.parent_object_id,constraint_object_id,referenced_object_id
	),
	/* Index Columns */
	IndexColumnsTable AS

	(
	SELECT distinct schema_name (o.schema_id) AS 'schema_name',object_name(o.object_id) AS TableName,
	  (SELECT case key_ordinal when 0 then NULL else '['+col_name(k.object_id,column_id) +']' end AS [data()]
		FROM sys.index_columns (NOLOCK) AS k
		WHERE k.object_id = i.object_id
		AND k.index_id = i.index_id
		ORDER BY key_ordinal, column_id
		FOR XML PATH('')
	  ) AS cols
	  FROM sys.indexes (NOLOCK) AS i
	  INNER JOIN sys.objects o (NOLOCK) ON i.object_id =o.object_id 
	  INNER JOIN sys.index_columns ic (NOLOCK) ON ic.object_id =i.object_id AND ic.index_id =i.index_id
	  INNER JOIN sys.columns c (NOLOCK) ON c.object_id = ic.object_id AND c.column_id = ic.column_id
	  WHERE i.object_id in (SELECT object_id FROM sys.objects (NOLOCK) WHERE type ='U') AND i.index_id > 0
	  group by o.schema_id,o.object_id,i.object_id,i.Name,i.index_id,i.type
	)
	SELECT 
	  fk.parent_schema_name AS SchemaName,
	  fk.parent_table_name AS TableName,
	  fk.constraint_name AS ConstraintName,
	  fk.referenced_schema AS ReferencedSchemaName,
	  fk.referenced_table_name AS ReferencedTableName
	FROM FKTable fk 
	WHERE (SELECT COUNT(*) AS NbIndexes  FROM IndexColumnsTable ict  WHERE fk.parent_schema_name = ict.schema_name AND fk.parent_table_name = ict.TableName      AND fk.parent_colums = ict.cols
	) = 0
END
GO
/****** Object:  StoredProcedure [sqlmonitor].[WaitStatsTop5Categories]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




/****** Object:  StoredProcedure [sqlmonitor].[WaitStatsTop5Categories]    Script Date: 13/08/2021 14:55:02 ******/
CREATE PROC [sqlmonitor].[WaitStatsTop5Categories] @StartTime datetime='19000101', @EndTime datetime='29990101' AS 
SET NOCOUNT ON
-- DECLARE @StartTime datetime
-- DECLARE @EndTime datetime
IF (@StartTime IS NOT NULL AND @StartTime != '19000101') SELECT @StartTime = MAX (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS] WHERE runtime <= @StartTime 
IF (@StartTime IS NULL OR @StartTime = '19000101') SELECT @StartTime = MIN (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS]

IF (@EndTime IS NOT NULL AND @EndTime != '29990101') SELECT @EndTime = MIN (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS] WHERE runtime >= @EndTime 
IF (@EndTime IS NULL OR @EndTime = '29990101') SELECT @EndTime = MAX (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS]

-- Get basic wait stats for the specified interval
SELECT 
  w_end.wait_category, 
case when (CONVERT (bigint, w_end.wait_time_ms) - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) <=0 then 0 else (CONVERT (bigint, w_end.wait_time_ms) - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) end  AS total_wait_time_ms,   
  (CONVERT (bigint, w_end.wait_time_ms) - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) / (DATEDIFF (s, @StartTime, @EndTime) + 1) AS wait_time_ms_per_sec
INTO #waitstats_categories
FROM [sqlmonitor].[vw_WAIT_CATEGORY_STATS] w_end
LEFT OUTER JOIN [sqlmonitor].[vw_WAIT_CATEGORY_STATS] w_start ON w_end.wait_category = w_start.wait_category AND w_start.runtime = @StartTime
WHERE w_end.runtime = @EndTime
  AND w_end.wait_category != 'IGNORABLE'
ORDER BY (w_end.wait_time_ms - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) DESC

-- Get number of available "CPU seconds" in the specified interval (seconds in collection interval times # CPUs on the system)
DECLARE @avail_cpu_time_sec int 
SELECT @avail_cpu_time_sec = (SELECT TOP 1 cpu_count FROM SYS.dm_os_sys_info) * DATEDIFF (s, @StartTime, @EndTime)

-- Get average % CPU utilization (this is the % of all CPUs on the box, ignoring affinity mask)
DECLARE @avg_sql_cpu int 
SELECT @avg_sql_cpu = AVG (sql_cpu_utilization) 
FROM (
  SELECT DISTINCT (SELECT TOP 1 EventTime FROM  [sqlmonitor].[tbl_SPU_Health] cpu2 WHERE cpu1.record_id = cpu2.record_id) AS EventTime, 
    record_id, system_idle_cpu, sql_cpu_utilization, 100 - sql_cpu_utilization - system_idle_cpu AS nonsql_cpu_utilization 
  FROM [sqlmonitor].[tbl_SPU_Health] cpu1
  WHERE EventTime BETWEEN @StartTime AND @EndTime
) AS sql_cpu

DECLARE @cpu_time_used_ms bigint
SET @cpu_time_used_ms = ISNULL ((0.01 * @avg_sql_cpu) * @avail_cpu_time_sec * 1000, 0)  -- CPU time used by SQL = (%CPU used by SQL) * (available CPU time)

-- Get total wait time for the specified interval
DECLARE @all_resources_wait_time_ms bigint
SELECT @all_resources_wait_time_ms = SUM (total_wait_time_ms) FROM #waitstats_categories
SET @all_resources_wait_time_ms = @all_resources_wait_time_ms + @cpu_time_used_ms

--this will prevent division by zero errors (bug 2119)
if @all_resources_wait_time_ms is null or @all_resources_wait_time_ms=0
begin
	
	return
end


-- Return stats for base wait cateries
SELECT * FROM 
( SELECT TOP 5 
    cat.wait_category, 
    DATEDIFF (s, @StartTime, @EndTime) AS time_interval_sec, 
    CONVERT (bigint, cat.total_wait_time_ms) AS total_wait_time_ms, 
    CONVERT (numeric(6,2), 100.0*CONVERT (bigint, cat.total_wait_time_ms)/@all_resources_wait_time_ms) AS percent_of_total_waittime, 
    cat.wait_time_ms_per_sec 
  FROM #waitstats_categories cat
  WHERE (cat.wait_time_ms_per_sec > 0 OR cat.total_wait_time_ms > 0)
    AND cat.wait_category NOT IN('SOS_SCHEDULER_YIELD','SP_SERVER_DIAGNOSTICS_SLEEP','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','HADR_FILESTREAM_IOMGR_IOCOMPLETION','DIRTY_PAGE_POLL','HADR_NOTIFICATION_DEQUEUE','HADR_WORK_QUEUE','HADR_CLUSAPI_CALL','HADR_TIMER_TASK','SOS_WORK_DISPATCHER','PWAIT_EXTENSIBILITY_CLEANUP_TASK','XE_LIVE_TARGET_TVF','QDS_ASYNC_QUEUE','HADR_FABRIC_CALLBACK','PVS_PREALLOCATE') -- don't include "waiting on CPU" time here; we'll include it in the next query
  ORDER BY wait_time_ms_per_sec DESC
) t
WHERE percent_of_total_waittime > 0
UNION ALL 
-- Add SOS_SCHEDULER_YIELD wait time (waiting to run on a CPU) to actual used CPU time to synthesize a "CPU" wait catery
SELECT 
  'CPU' AS wait_category, 
  DATEDIFF (s, @StartTime, @EndTime) AS time_interval_sec, 
  CONVERT (bigint, total_wait_time_ms) + @cpu_time_used_ms AS total_wait_time_ms, 
  100.0*(CONVERT (bigint, total_wait_time_ms) + @cpu_time_used_ms)/@all_resources_wait_time_ms AS percent_of_total_waittime, 
  wait_time_ms_per_sec + (@cpu_time_used_ms / (DATEDIFF (s, @StartTime, @EndTime) + 1)) AS wait_time_ms_per_sec
FROM #waitstats_categories cat
WHERE cat.wait_category = 'SOS_SCHEDULER_YIELD'
UNION ALL 
-- Add in an "other" catery
SELECT * FROM 
( SELECT 
    'Other' AS wait_category, 
    DATEDIFF (s, @StartTime, @EndTime) AS time_interval_sec, 
    SUM (CONVERT (bigint, cat.total_wait_time_ms)) AS total_wait_time_ms, 
    CONVERT (numeric(6,2), 100.0*SUM (CONVERT (bigint, cat.total_wait_time_ms))/@all_resources_wait_time_ms) AS percent_of_total_waittime, 
    SUM (cat.wait_time_ms_per_sec) AS wait_time_ms_per_sec
  FROM #waitstats_categories cat
  WHERE (cat.wait_time_ms_per_sec > 0 OR cat.total_wait_time_ms > 0) 
    -- don't include the cateries that we are already identifying in the top 5 
    AND cat.wait_category NOT IN (SELECT TOP 5 cat.wait_category FROM #waitstats_categories cat ORDER BY wait_time_ms_per_sec DESC) 
) AS t
WHERE percent_of_total_waittime > 0
ORDER BY wait_time_ms_per_sec DESC
GO
/****** Object:  StoredProcedure [sqlmonitor].[WaitStatsTopCategoriesOther]    Script Date: 03/05/2025 16:00:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



/****** Object:  StoredProcedure [sqlmonitor].[WaitStatsTopCategoriesOther]    Script Date: 13/08/2021 14:55:32 ******/

CREATE PROC [sqlmonitor].[WaitStatsTopCategoriesOther] @StartTime datetime='19000101', @EndTime datetime='29990101' AS 
SET NOCOUNT ON
-- DECLARE @StartTime datetime
-- DECLARE @EndTime datetime
IF (@StartTime IS NOT NULL AND @StartTime != '19000101') SELECT @StartTime = MAX (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS] WHERE runtime <= @StartTime 
IF (@StartTime IS NULL OR @StartTime = '19000101') SELECT @StartTime = MIN (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS]

IF (@EndTime IS NOT NULL AND @EndTime != '29990101') SELECT @EndTime = MIN (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS] WHERE runtime >= @EndTime 
IF (@EndTime IS NULL OR @EndTime = '29990101') SELECT @EndTime = MAX (runtime) FROM [sqlmonitor].[tbl_DB_WAIT_STATS]

-- Get basic wait stats for the specified interval
SELECT 
  w_end.wait_category, 
  (CONVERT (bigint, w_end.wait_time_ms) - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) AS total_wait_time_ms, 
  (CONVERT (bigint, w_end.wait_time_ms) - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) / (DATEDIFF (s, @StartTime, @EndTime) + 1) AS wait_time_ms_per_sec
INTO #waitstats_categories
FROM [sqlmonitor].[vw_WAIT_CATEGORY_STATS] w_end
LEFT OUTER JOIN [sqlmonitor].[vw_WAIT_CATEGORY_STATS] w_start ON w_end.wait_category = w_start.wait_category AND w_start.runtime = @StartTime
WHERE w_end.runtime = @EndTime
  AND w_end.wait_category != 'IGNORABLE'
ORDER BY (w_end.wait_time_ms - CASE WHEN w_start.wait_time_ms IS NULL THEN 0 ELSE w_start.wait_time_ms END) DESC

-- Get number of available "CPU seconds" in the specified interval (seconds in collection interval times # CPUs on the system)
DECLARE @avail_cpu_time_sec int 
SELECT @avail_cpu_time_sec = (SELECT TOP 1 cpu_count FROM sys.dm_os_sys_info) * DATEDIFF (s, @StartTime, @EndTime)

-- Get average % CPU utilization (this is the % of all CPUs on the box, ignoring affinity mask)
DECLARE @avg_sql_cpu int 
SELECT @avg_sql_cpu = AVG (sql_cpu_utilization) 
FROM (
  SELECT DISTINCT (SELECT TOP 1 EventTime FROM  tbl_SPU_Health cpu2 WHERE cpu1.record_id = cpu2.record_id) AS EventTime, 
    record_id, system_idle_cpu, sql_cpu_utilization, 100 - sql_cpu_utilization - system_idle_cpu AS nonsql_cpu_utilization 
  FROM [sqlmonitor].[tbl_SPU_Health] cpu1
  WHERE EventTime BETWEEN @StartTime AND @EndTime
) AS sql_cpu

DECLARE @cpu_time_used_ms bigint
SET @cpu_time_used_ms = ISNULL ((0.01 * @avg_sql_cpu) * @avail_cpu_time_sec * 1000, 0)  -- CPU time used by SQL = (%CPU used by SQL) * (available CPU time)

-- Get total wait time for the specified interval
DECLARE @all_resources_wait_time_ms bigint
SELECT @all_resources_wait_time_ms = SUM (total_wait_time_ms) FROM #waitstats_categories
SET @all_resources_wait_time_ms = @all_resources_wait_time_ms + @cpu_time_used_ms

--this will prevent division by zero errors (bug 2119)
if @all_resources_wait_time_ms is null or @all_resources_wait_time_ms=0
begin
	
	return
end

-- Add in an "other" category

SELECT TOP 10 
    cat.wait_category, 
    DATEDIFF (s, @StartTime, @EndTime) AS time_interval_sec, 
    CONVERT (bigint, cat.total_wait_time_ms) AS total_wait_time_ms, 
    CONVERT (numeric(6,2), 100.0*CONVERT (bigint, cat.total_wait_time_ms)/@all_resources_wait_time_ms) AS percent_of_total_waittime, 
    cat.wait_time_ms_per_sec 
  
  FROM #waitstats_categories cat
  WHERE (cat.wait_time_ms_per_sec > 0 OR cat.total_wait_time_ms > 0) 
    -- don't include the cateries that we are already identifying in the top 5 
    AND cat.wait_category NOT IN (SELECT TOP 5 cat.wait_category FROM #waitstats_categories cat ORDER BY wait_time_ms_per_sec DESC) 
     AND cat.wait_category != 'SOS_SCHEDULER_YIELD' 
ORDER BY wait_time_ms_per_sec DESC
GO


/********************************************************************************************
 * SECTION 5: ANALYSIS QUERIES AND USAGE EXAMPLES
 ********************************************************************************************
 * This section demonstrates how to query the collected performance data.
 * These queries should be run AFTER the SQL Agent Job has collected data for some time.
 *
 * RECOMMENDED: Wait at least 1-2 hours after deployment to accumulate meaningful data.
 ********************************************************************************************/

/********************************************************************************************
 * QUERY 1: Top 5 Wait Categories Analysis
 * PURPOSE: Identifies the top 5 resource bottlenecks in your database
 * PARAMETERS:
 *   @StartTime: Start of analysis window (NULL = earliest data)
 *   @EndTime: End of analysis window (NULL = latest data)
 *
 * INTERPRETATION:
 *   - High CPU: Queries are CPU-bound (check for missing indexes, non-SARGable queries)
 *   - Locks: Blocking issues (check tbl_HEADBLOCKERSUMMARY for details)
 *   - Page I/O Latch: Disk I/O bottleneck
 *   - Writelog: Transaction log bottleneck
 *   - Network I/O: Client not fetching results fast enough
 ********************************************************************************************/
exec [sqlmonitor].[WaitStatsTop5Categories] @StartTime = null ,@EndTime =null  
go

/********************************************************************************************
 * QUERY 2: Additional Wait Categories (Beyond Top 5)
 * PURPOSE: Shows wait categories ranked 6-15 for deeper analysis
 ********************************************************************************************/
exec [sqlmonitor].[WaitStatsTopCategoriesOther] @StartTime = null ,@EndTime =null
go

/********************************************************************************************
 * QUERY 3: Database Resource Utilization Analysis
 * PURPOSE: Analyzes CPU, IO, and Memory utilization trends (primarily for Azure SQL)
 * USEFUL FOR:
 *   - Identifying peak usage periods
 *   - DTU/vCore sizing decisions
 *   - Capacity planning
 ********************************************************************************************/
exec [sqlmonitor].[sp_Check_DBResourceStats] @StartTime = null ,@EndTime =null
go

/********************************************************************************************
 * QUERY 4: Blocking Chain Visualization
 * PURPOSE: Displays blocking sessions in a hierarchical tree structure
 * OUTPUT: Shows head blockers and all sessions blocked by them
 * USE WHEN: Investigating locking/blocking issues
 ********************************************************************************************/
exec [sqlmonitor].[sp_Print_BlockingTree]
go

/********************************************************************************************
 * QUERY 5: Plan Cache Pollution Analysis
 * PURPOSE: Identifies single-use query plans that waste memory
 * INTERPRETATION:
 *   - High "Percent Wasted" indicates lack of query parameterization
 *   - Consider implementing sp_executesql or stored procedures
 *   - Look for ad-hoc queries that should be parameterized
 ********************************************************************************************/
exec [sqlmonitor].[sp_CheckForPlanCachePollution]
go

/********************************************************************************************
 * QUERY 6: Resource-Intensive Queries Analysis
 * PURPOSE: Identifies queries consuming the most resources
 *
 * SORT OPTIONS (uncomment the desired ORDER BY clause):
 *
 * Option A: High Logical Reads (CPU Consumers)
 *   - High logical reads = high buffer pool usage = high CPU
 *   - These queries are often missing indexes or have inefficient plans
 ********************************************************************************************/
select * from [sqlmonitor].[tbl_ResourceIntensiveQuery]
order by logical_reads desc;   -- Option A: Find CPU-intensive queries

-- Option B: Long-Running Queries
-- order by duration_ms desc;

-- Option C: Memory-Intensive Queries  
-- order by granted_query_memory_kb desc

go

/********************************************************************************************
 * ADDITIONAL QUERY EXAMPLES
 ********************************************************************************************
 * Below are additional queries you can run to explore the collected data
 ********************************************************************************************/

-- Example 1: Find queries with high wait times
-- SELECT TOP 20 runtime, session_id, wait_type, wait_time, sql_text
-- FROM [sqlmonitor].[tbl_ResourceIntensiveQuery]
-- WHERE wait_time > 5000  -- Waits longer than 5 seconds
-- ORDER BY wait_time DESC

-- Example 2: Identify blocking victims and their blockers
-- SELECT runtime, session_id, blocking_session_id, wait_type, 
--        wait_time, open_transaction_count, sql_text
-- FROM [sqlmonitor].[tbl_ResourceIntensiveQuery]
-- WHERE blocking_session_id > 0
-- ORDER BY wait_time DESC

-- Example 3: Monitor CPU utilization trend over time
-- SELECT EventTime, sql_cpu_utilization, system_idle_cpu,
--        100 - sql_cpu_utilization - system_idle_cpu AS other_process_cpu
-- FROM [sqlmonitor].[tbl_SPU_HEALTH]
-- WHERE EventTime > DATEADD(HOUR, -4, GETDATE())
-- ORDER BY EventTime

-- Example 4: Analyze wait statistics for a specific time window
-- SELECT wait_category, SUM(wait_time_ms) AS total_wait_ms, 
--        COUNT(*) AS snapshot_count
-- FROM [sqlmonitor].[tbl_DB_WAIT_STATS]
-- WHERE runtime BETWEEN '2025-05-03 10:00:00' AND '2025-05-03 12:00:00'
--   AND wait_category != 'IGNORABLE'
-- GROUP BY wait_category
-- ORDER BY total_wait_ms DESC

-- Example 5: Find queries from a specific database or user
-- SELECT runtime, session_id, DBName, login_name, host_name,
--        cpu_time, logical_reads, duration_ms, sql_text
-- FROM [sqlmonitor].[tbl_ResourceIntensiveQuery]
-- WHERE DBName = 'YourDatabaseName'
--   -- OR login_name = 'YourLoginName'
-- ORDER BY cpu_time DESC



