

--------------------------------------------------------------------------------
--QPI server level views (no query store views) 
--------------------------------------------------------------------------------
use master

SET QUOTED_IDENTIFIER OFF; -- Because I use "" as a string literal
GO

IF EXISTS (SELECT name FROM sys.databases WHERE name = 'QPI_Prefmon')
BEGIN
    PRINT 'QPI_Prefmon already exists. dropping it to recreate.';
    drop database QPI_Prefmon
END

GO

CREATE DATABASE [QPI_Prefmon]
GO
USE [QPI_Prefmon]


IF SCHEMA_ID('qpi') IS NULL
	EXEC ('CREATE SCHEMA qpi');
GO






-----------------------------------------------------------------------------
-- Generic utilities
-----------------------------------------------------------------------------

CREATE OR ALTER  FUNCTION qpi.us2min(@microseconds bigint)
RETURNS INT
AS BEGIN RETURN ( @microseconds /1000 /1000 /60 ) END;
GO
---
---	SELECT qpi.ago(2,10,15) => GETUTCDATE() - ( 2 days 10 hours 15 min)
---
CREATE OR ALTER  FUNCTION qpi.ago(@days tinyint, @hours tinyint, @min tinyint)
RETURNS datetime2
AS BEGIN RETURN DATEADD(day, - @days,
					DATEADD(hour, - @hours,
						DATEADD(minute, - @min, GETUTCDATE())
						)
					) END;
GO
---
---	SELECT qpi.utc(-21015) => GETUTCDATE() - ( 2 days 10 hours 15 min)
---
CREATE OR ALTER  FUNCTION qpi.utc(@time int)
RETURNS datetime2
AS BEGIN RETURN DATEADD(DAY, ((@time /10000) %100),
					DATEADD(HOUR, (@time /100) %100,
						DATEADD(MINUTE, (@time %100), GETUTCDATE())
						)
					) END;
GO

---
---	SELECT qpi.t(-21015) => GETDATE() - ( 2 days 10 hours 15 min)
---
CREATE OR ALTER  FUNCTION qpi.t(@time int)
RETURNS datetime2
AS BEGIN RETURN DATEADD(DAY, ((@time /10000) %100),
					DATEADD(HOUR, (@time /100) %100,
						DATEADD(MINUTE, (@time %100), GETDATE())
						)
					) END;
GO


CREATE OR ALTER  FUNCTION qpi.label(@sql VARCHAR(max))
RETURNS TABLE
AS RETURN (
    SELECT
        CASE
            WHEN CHARINDEX('(LABEL=', @sql COLLATE  Latin1_General_100_CI_AS ) > 0
                THEN CAST(SUBSTRING(
                    @sql,
                    CHARINDEX('(LABEL=', @sql  COLLATE  Latin1_General_100_CI_AS  ) + 8, -- Skip the length of '(LABEL='
                    CHARINDEX("')", @sql, CHARINDEX('(LABEL=', @sql COLLATE  Latin1_General_100_CI_AS ) + 8)
											- CHARINDEX('(LABEL=', @sql  COLLATE  Latin1_General_100_CI_AS  ) - 8
                ) AS VARCHAR(8000))
            ELSE NULL
        END AS label
);
GO

-----------------------------------------------------------------------------
-- Core Server-level functionalities
-----------------------------------------------------------------------------
-- The list of currently executing queries that are probably not in Query Store.
CREATE OR ALTER  VIEW qpi.queries
AS
SELECT
		text =   IIF(LEFT(text,1) = '(', TRIM(')' FROM SUBSTRING( text, (PATINDEX( '%)[^),]%', text))+1, LEN(text))), text) ,
		params =  IIF(LEFT(text,1) = '(', SUBSTRING( text, 2, (PATINDEX( '%)[^),]%', text+')'))-2), "") ,
		status,
		start_time,
		elapsed_time_s = total_elapsed_time /1000.0,
		database_id,
		connection_id  ,
		session_id,
		request_id  ,
		query_hash  ,
		command,
		interval_id = DATEPART(yyyy, (start_time)) * 1000000 +
				DATEPART(mm, (start_time)) * 10000 +
				DATEPART(dd, (start_time)) * 100 +
				DATEPART(hh, (start_time)),
		interval_mi = 60,
		execution_type_desc = status
		, sql_handle
FROM    sys.dm_exec_requests
		CROSS APPLY sys.dm_exec_sql_text(sql_handle)
WHERE session_id <> @@SPID
GO


CREATE OR ALTER  VIEW qpi.query_stats
AS
select  q.text, q.params, q.session_id, q.request_id, q.start_time,
		duration_s = CAST(ROUND( rs.total_elapsed_time/execution_count /1000.0 /1000.0, 2) AS NUMERIC(12,2)),
        cpu_time_ms = CAST(ROUND(rs.total_worker_time/execution_count, 1) AS NUMERIC(12,1)),
        logical_io_reads_kb = CAST(ROUND(rs.total_logical_reads/execution_count * 8 /1000.0, 2) AS NUMERIC(12,2)),
        logical_io_writes_kb = CAST(ROUND(rs.total_logical_writes/execution_count * 8 /1000.0, 2) AS NUMERIC(12,2)),
        physical_io_reads_kb = CAST(ROUND(rs.total_physical_reads/execution_count * 8 /1000.0, 2) AS NUMERIC(12,2)),
        clr_time_ms = CAST(ROUND(rs.total_clr_time/execution_count /1000.0, 1) AS NUMERIC(12,1)),
		granted_mb = rs.total_grant_kb/execution_count /1024,
		used_mb = rs.total_used_grant_kb/execution_count /1024,
		ideal_mb = rs.total_ideal_grant_kb/execution_count /1024
from qpi.queries q
left join sys.dm_exec_query_stats rs
on q.sql_handle = rs.sql_handle
GO

CREATE OR ALTER  VIEW qpi.query_mem_grants
AS
select q.text, q.params, q.session_id, q.request_id, q.start_time,
		required_mb = mg.required_memory_kb /1024,
		requested_mb = mg.requested_memory_kb /1024,
		granted_mb = mg.granted_memory_kb /1024,
		used_mb = mg.used_memory_kb /1024,
		max_used_mb = mg.max_used_memory_kb /1024,
		ideal_mb = mg.ideal_memory_kb /1024,
		timeout_s = mg.timeout_sec,
		mg.wait_time_ms,
		mg.is_next_candidate
from qpi.queries q
left join sys.dm_exec_query_memory_grants mg
on q.session_id = mg.session_id
and q.request_id = mg.request_id
GO


CREATE OR ALTER VIEW qpi.query_tempdb_details AS
SELECT 
SUBSTRING(st.text, er.statement_start_offset/2 + 1,(CASE WHEN er.statement_end_offset = -1 THEN LEN(CONVERT(nvarchar(max),st.text)) * 2 ELSE er.statement_end_offset END - er.statement_start_offset)/2) as Query_Text,
tsu.session_id ,
tsu.request_id,
tsu.exec_context_id,
(tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count) as OutStanding_user_objects_page_counts,
(tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) as OutStanding_internal_objects_page_counts,
er.start_time,
er.command,
er.open_transaction_count,
er.percent_complete,
er.estimated_completion_time,
er.cpu_time,
er.total_elapsed_time,
er.reads,
er.writes, 
er.logical_reads,
er.granted_query_memory,
es.host_name ,
es.login_name ,
es.program_name 
FROM sys.dm_db_task_space_usage tsu 
INNER JOIN sys.dm_exec_requests er ON ( tsu.session_id = er.session_id AND tsu.request_id = er.request_id) 
INNER JOIN sys.dm_exec_sessions es ON ( tsu.session_id = es.session_id ) 
CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) st 
WHERE (tsu.internal_objects_alloc_page_count+tsu.user_objects_alloc_page_count) > 0
go



CREATE OR ALTER  VIEW qpi.queries_history as
SELECT TOP 1000
    SUBSTRING(st.text, (qs.statement_start_offset/2) + 1,
        ((CASE qs.statement_end_offset
          WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset
         END - qs.statement_start_offset)/2) + 1) AS statement_text,
    qs.query_hash,
    qs.query_plan_hash,
    qs.execution_count,
    qs.total_logical_reads,
    qs.last_logical_reads,
    qs.total_elapsed_time / 1000000.0 AS total_elapsed_time_s,
    qs.last_elapsed_time / 1000000.0 AS last_elapsed_time_s,
    DB_NAME(st.dbid) as database_name
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp 
go


-----------------------------------------------------------------------------
-- Core Plan forcing functionalities
-----------------------------------------------------------------------------



CREATE OR ALTER  VIEW qpi.bre
AS
SELECT r.command,percent_complete = CONVERT(NUMERIC(6,2),r.percent_complete)
,CONVERT(VARCHAR(20),DATEADD(ms,r.estimated_completion_time,GetDate()),20) AS ETA,
CONVERT(NUMERIC(10,2),r.total_elapsed_time/1000.0/60.0) AS elapsed_mi,
CONVERT(NUMERIC(10,2),r.estimated_completion_time/1000.0/60.0/60.0) AS eta_h,
CONVERT(VARCHAR(1000),(SELECT SUBSTRING(text,r.statement_start_offset/2,
CASE WHEN r.statement_end_offset = -1 THEN 1000 ELSE (r.statement_end_offset-r.statement_start_offset)/2 END)
FROM sys.dm_exec_sql_text(sql_handle))) AS query,r.session_id
FROM sys.dm_exec_requests r WHERE command IN ('RESTORE DATABASE','BACKUP DATABASE','BACKUP LOG','RESTORE LOG')
GO

CREATE OR ALTER  VIEW qpi.query_locks
AS
SELECT
	text = q.text,
	session_id = q.session_id,
	tl.request_owner_type,
	tl.request_status,
	tl.request_mode,
	tl.request_type,
	locked_object_id = obj.object_id,
	locked_object_schema = SCHEMA_NAME(obj.schema_id),
	locked_object_name = obj.name,
	locked_object_type = obj.type_desc,
	locked_resource_type = tl.resource_type,
	locked_resource_db = DB_NAME(tl.resource_database_id),
	q.request_id,
	tl.resource_associated_entity_id
FROM qpi.queries q with(nolock)
	JOIN sys.dm_tran_locks as tl with(nolock)
		ON q.session_id = tl.request_session_id and q.request_id = tl.request_request_id
		LEFT JOIN
		(SELECT p.object_id, p.hobt_id, au.allocation_unit_id
		 FROM sys.partitions p with(nolock)
		 LEFT JOIN sys.allocation_units AS au with(nolock)
		 ON (au.type IN (1,3) AND au.container_id = p.hobt_id)
            	OR
            (au.type = 2 AND au.container_id = p.partition_id)
		)
		AS p ON
			tl.resource_type IN ('PAGE','KEY','RID','HOBT') AND p.hobt_id = tl.resource_associated_entity_id
			OR
			tl.resource_type = 'ALLOCATION_UNIT' AND p.allocation_unit_id = tl.resource_associated_entity_id
			LEFT JOIN sys.objects obj with(nolock) ON p.object_id = obj.object_id
GO

------------------------------------------------------------------------------------
--	Query performance statistics.
------------------------------------------------------------------------------------

CREATE OR ALTER  VIEW qpi.blocked_queries
AS
SELECT
	text = blocked.text,
	session_id = blocked.session_id,
	blocked_by_session_id = conn.session_id,
	blocked_by_query = last_query.text,
	wait_time_s = w.wait_duration_ms /1000,
	w.wait_type,
	locked_object_id = obj.object_id,
	locked_object_schema = SCHEMA_NAME(obj.schema_id),
	locked_object_name = obj.name,
	locked_object_type = obj.type_desc,
	locked_resource_type = tl.resource_type,
	locked_resource_db = DB_NAME(tl.resource_database_id),
	tl.request_mode,
	tl.request_type,
	tl.request_status,
	tl.request_owner_type,
	w.resource_description
FROM qpi.queries blocked with(nolock)
	INNER JOIN sys.dm_os_waiting_tasks w with(nolock)
	ON blocked.session_id = w.session_id
		INNER JOIN sys.dm_exec_connections conn with(nolock)
		ON conn.session_id =  w.blocking_session_id
			CROSS APPLY sys.dm_exec_sql_text(conn.most_recent_sql_handle) AS last_query
	LEFT JOIN sys.dm_tran_locks as tl with(nolock)
	 ON tl.lock_owner_address = w.resource_address
	 LEFT JOIN
	 	(SELECT p.object_id, p.hobt_id, au.allocation_unit_id
		 FROM sys.partitions p with(nolock)
		 LEFT JOIN sys.allocation_units AS au with(nolock)
		 ON (au.type IN (1,3) AND au.container_id = p.hobt_id)
            	OR
            (au.type = 2 AND au.container_id = p.partition_id)
		)
		AS p ON
			tl.resource_type IN ('PAGE','KEY','RID','HOBT') AND p.hobt_id = tl.resource_associated_entity_id
			OR
			tl.resource_type = 'ALLOCATION_UNIT' AND p.allocation_unit_id = tl.resource_associated_entity_id
		LEFT JOIN sys.objects obj with(nolock) ON p.object_id = obj.object_id
WHERE w.session_id <> w.blocking_session_id
GO



---deadlocks (MI only, this is a default extended event that does not exist in other Sql server products but if a similar event is created, then i don't see why this view can't be used with it wth a few modifications):


create view qpi.deadlocks as
WITH DeadlockEvents AS (
    -- Read the Extended Event data from the blob target for SQL Managed Instance
    SELECT
        CAST(event_data AS XML) AS event_data_xml
    FROM sys.fn_xe_telemetry_blob_target_read_file('dl', null, null, null) -- 'dl' is often the default for telemetry.
                                                                        -- Replace 'dl' if you're using a custom XE session
                                                                        -- writing to blob storage with a different file prefix.
) ,DeadlockReports AS (
    -- Extract the core deadlock report XML and basic event info
    SELECT
        event_data_xml.value('(/event/@timestamp)[1]', 'datetime2') AS event_timestamp,
        event_data_xml.value('(/event/data[@name="database_name"]/value)[1]', 'sysname') AS database_name,
        event_data_xml.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_graph_xml
    FROM DeadlockEvents
    
),VictimInfo AS (
    -- Identify the victim process ID from the deadlock graph
    SELECT
        dr.event_timestamp,
        dr.database_name,
        dr.deadlock_graph_xml,
        victim_node.value('@id', 'varchar(50)') AS victim_process_id
    FROM DeadlockReports dr
    CROSS APPLY dr.deadlock_graph_xml.nodes('/deadlock/victim-list/victimProcess[1]') AS victims(victim_node) -- Get the first (usually only) victim
) SELECT
    vi.event_timestamp AS Timestamp,
    vi.database_name AS db_name,
    vi.deadlock_graph_xml AS deadlock_xml_report, -- The full XML of the deadlock graph

    -- Victim Process Details
    vi.deadlock_graph_xml.value('(/deadlock/process-list/process[@id=sql:column("vi.victim_process_id")]/inputbuf/text())[1]', 'NVARCHAR(MAX)') AS Victim_InputBuffer,
    -- To get the text from the most specific frame (often the last one in the stack if nested):
    vi.deadlock_graph_xml.value('(/deadlock/process-list/process[@id=sql:column("vi.victim_process_id")]/executionStack/frame[last()]/text())[1]', 'NVARCHAR(MAX)') AS Victim_QueryText_From_ExecutionStack,
    vi.deadlock_graph_xml.value('(/deadlock/process-list/process[@id=sql:column("vi.victim_process_id")]/@clientapp)[1]', 'NVARCHAR(128)') AS Victim_ClientApp,
    vi.deadlock_graph_xml.value('(/deadlock/process-list/process[@id=sql:column("vi.victim_process_id")]/@hostname)[1]', 'NVARCHAR(128)') AS Victim_Hostname,
    vi.deadlock_graph_xml.value('(/deadlock/process-list/process[@id=sql:column("vi.victim_process_id")]/@loginname)[1]', 'NVARCHAR(128)') AS Victim_LoginName,
    vi.victim_process_id,

    -- Other Process Details (the one that was NOT the victim but was part of the deadlock)
    -- This assumes a simple two-process deadlock. If more complex, this picks the first non-victim.
    other_process_node.value('(inputbuf/text())[1]', 'NVARCHAR(MAX)') AS OtherProcess_InputBuffer,
    other_process_node.value('(executionStack/frame[last()]/text())[1]', 'NVARCHAR(MAX)') AS OtherProcess_QueryText_From_ExecutionStack,
    other_process_node.value('(@clientapp)[1]', 'NVARCHAR(128)') AS OtherProcess_ClientApp,
    other_process_node.value('(@hostname)[1]', 'NVARCHAR(128)') AS OtherProcess_Hostname,
    other_process_node.value('(@loginname)[1]', 'NVARCHAR(128)') AS OtherProcess_LoginName,
    other_process_node.value('@id', 'varchar(50)') AS OtherProcess_Id

FROM VictimInfo vi
OUTER APPLY vi.deadlock_graph_xml.nodes('/deadlock/process-list/process[not(@id = sql:column("vi.victim_process_id"))][1]') AS other_processes(other_process_node)

go



---------------------------------------------------------------------------------------------------
--	Wait statistics
---------------------------------------------------------------------------------------------------
IF (OBJECT_ID(N'qpi.os_wait_stats_snapshot') IS NULL)
BEGIN
CREATE TABLE qpi.os_wait_stats_snapshot
	(
	[category_id] tinyint NULL,
	[wait_type] [nvarchar](60) NOT NULL,
	[waiting_tasks_count] [bigint] NOT NULL,
	[wait_time_s] [bigint] NOT NULL,
	[max_wait_time_ms] [bigint] NOT NULL,
	[signal_wait_time_s] [bigint] NOT NULL,
	[title] [nvarchar](50),
	start_time datetime2 GENERATED ALWAYS AS ROW START,
	end_time datetime2 GENERATED ALWAYS AS ROW END,
	PERIOD FOR SYSTEM_TIME (start_time, end_time),
	PRIMARY KEY (wait_type)
 ) WITH (SYSTEM_VERSIONING = ON ( HISTORY_TABLE = qpi.os_wait_stats_snapshot_history));

CREATE INDEX ix_dm_os_wait_stats_snapshot
	ON qpi.os_wait_stats_snapshot_history(end_time);
END;
GO

CREATE OR ALTER  FUNCTION qpi.__wait_stats_category_id(@wait_type varchar(128))
RETURNS TABLE
AS RETURN ( SELECT
	CASE
		WHEN @wait_type = 'Unknown'				THEN 0
		WHEN @wait_type = 'SOS_SCHEDULER_YIELD'	THEN 1
		--WHEN @wait_type = 'SOS_WORK_DISPATCHER'	THEN 1
		WHEN @wait_type = 'THREADPOOL'			THEN 2
		WHEN @wait_type LIKE 'LCK_M_%'			THEN 3
		WHEN @wait_type LIKE 'LATCH_%'			THEN 4
		WHEN @wait_type LIKE 'PAGELATCH_%'		THEN 5
		WHEN @wait_type LIKE 'PAGEIOLATCH_%'		THEN 6
		WHEN @wait_type = 'RESOURCE_SEMAPHORE_QUERY_COMPILE'
												THEN 7
		WHEN @wait_type LIKE 'CLR%'				THEN 8
		WHEN @wait_type LIKE 'SQLCLR%'			THEN 8
		WHEN @wait_type LIKE 'DBMIRROR%'			THEN 9
		WHEN @wait_type LIKE 'XACT%'				THEN 10
		WHEN @wait_type LIKE 'DTC%'				THEN 10
		WHEN @wait_type LIKE 'TRAN_MARKLATCH_%'	THEN 10
		WHEN @wait_type = 'TRANSACTION_MUTEX'	THEN 10
		WHEN @wait_type LIKE 'MSQL_XACT_%'		THEN 10
		WHEN @wait_type LIKE 'SLEEP_%'			THEN 11
		WHEN @wait_type IN ('LAZYWRITER_SLEEP', 'SQLTRACE_BUFFER_FLUSH',
							'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES',
							'FT_IFTS_SCHEDULER_IDLE_WAIT', 'XE_DISPATCHER_WAIT',
							'REQUEST_FOR_DEADLOCK_SEARCH', 'LOGMGR_QUEUE',
							'ONDEMAND_TASK_QUEUE', 'CHECKPOINT_QUEUE', 'XE_TIMER_EVENT')
												THEN 11
		WHEN @wait_type LIKE 'PREEMPTIVE_%'		THEN 12
		WHEN @wait_type LIKE 'BROKER_%' AND @wait_type <> 'BROKER_RECEIVE_WAITFOR'
												THEN 13
		WHEN @wait_type IN ('LOGMGR', 'LOGBUFFER', 'LOGMGR_RESERVE_APPEND', 'LOGMGR_FLUSH',
							'LOGMGR_PMM_LOG', 'CHKPT', 'WRITELOG')
														THEN 14
		WHEN @wait_type IN ('ASYNC_NETWORK_IO', 'NET_WAITFOR_PACKET', 'PROXY_NETWORK_IO',
							'EXTERNAL_SCRIPT_NETWORK_IO')
														THEN 15
		WHEN @wait_type IN ('CXPACKET', 'EXCHANGE')
														THEN 16
		WHEN @wait_type IN ('RESOURCE_SEMAPHORE', 'CMEMTHREAD', 'CMEMPARTITIONED', 'EE_PMOLOCK',
							'MEMORY_ALLOCATION_EXT', 'RESERVED_MEMORY_ALLOCATION_EXT', 'MEMORY_GRANT_UPDATE')
														THEN 17
		WHEN @wait_type IN ('WAITFOR', 'WAIT_FOR_RESULTS', 'BROKER_RECEIVE_WAITFOR')
														THEN 18
		WHEN @wait_type IN ('TRACEWRITE', 'SQLTRACE_LOCK', 'SQLTRACE_FILE_BUFFER', 'SQLTRACE_FILE_WRITE_IO_COMPLETION', 'SQLTRACE_FILE_READ_IO_COMPLETION', 'SQLTRACE_PENDING_BUFFER_WRITERS', 'SQLTRACE_SHUTDOWN', 'QUERY_TRACEOUT', 'TRACE_EVTNOTIFF')
														THEN 19
		WHEN @wait_type IN ('FT_RESTART_CRAWL', 'FULLTEXT GATHERER', 'MSSEARCH', 'FT_METADATA_MUTEX', 'FT_IFTSHC_MUTEX', 'FT_IFTSISM_MUTEX', 'FT_IFTS_RWLOCK', 'FT_COMPROWSET_RWLOCK', 'FT_MASTER_MERGE', 'FT_PROPERTYLIST_CACHE', 'FT_MASTER_MERGE_COORDINATOR', 'PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC')
														THEN 20
		WHEN @wait_type IN ('ASYNC_IO_COMPLETION', 'IO_COMPLETION', 'BACKUPIO',
							'WRITE_COMPLETION', 'IO_QUEUE_LIMIT', 'IO_RETRY')
														THEN 21
		WHEN @wait_type IN ('REPLICA_WRITES', 'FCB_REPLICA_WRITE', 'FCB_REPLICA_READ', 'PWAIT_HADRSIM')
														THEN 22
		WHEN @wait_type LIKE 'SE_REPL_%'					THEN 22
		WHEN @wait_type LIKE 'REPL_%'					THEN 22
		WHEN @wait_type LIKE 'HADR_%'
		AND	 @wait_type <> 'HADR_THROTTLE_LOG_RATE_GOVERNOR'
														THEN 22
		WHEN @wait_type LIKE 'PWAIT_HADR_%'				THEN 22
		WHEN @wait_type IN ('LOG_RATE_GOVERNOR', 'POOL_LOG_RATE_GOVERNOR',
							'HADR_THROTTLE_LOG_RATE_GOVERNOR', 'INSTANCE_LOG_RATE_GOVERNOR')
														THEN 23
		ELSE NULL
	END AS category_id
);
GO

CREATE OR ALTER  FUNCTION qpi.__wait_stats_category(@category_id tinyint)
RETURNS TABLE
AS RETURN ( SELECT
			CASE @category_id
				WHEN 0 THEN 'Unknown'
				WHEN 1 THEN 'CPU'
				WHEN 2 THEN 'Worker Thread'
				WHEN 3 THEN 'Lock'
				WHEN 4 THEN 'Latch'
				WHEN 5 THEN 'Buffer Latch'
				WHEN 6 THEN 'Buffer IO'
				WHEN 7 THEN 'Compilation'
				WHEN 8 THEN 'SQL CLR'
				WHEN 9 THEN 'Mirroring'
				WHEN 10 THEN 'Transaction'
				WHEN 11 THEN 'Idle'
				WHEN 12 THEN 'Preemptive'
				WHEN 13 THEN 'Service Broker'
				WHEN 14 THEN 'Tran Log IO'
				WHEN 15 THEN 'Network IO'
				WHEN 16 THEN 'Parallelism'
				WHEN 17 THEN 'Memory'
				WHEN 18 THEN 'User Wait'
				WHEN 19 THEN 'Tracing'
				WHEN 20 THEN 'Full Text Search'
				WHEN 21 THEN 'Other Disk IO'
				WHEN 22 THEN 'Replication'
				WHEN 23 THEN 'Log Rate Governor'
			END AS category
);
GO

CREATE OR ALTER  PROCEDURE qpi.snapshot_wait_stats @title nvarchar(200) = NULL
AS BEGIN
MERGE qpi.os_wait_stats_snapshot AS Target
USING (
	SELECT *
	FROM qpi.wait_stats_ex
	) AS Source
ON (Target.wait_type  COLLATE Latin1_General_100_BIN2 = Source.wait_type COLLATE Latin1_General_100_BIN2)
WHEN MATCHED THEN
UPDATE SET
	-- docs.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-query-store-wait-stats-transact-sql?view=sql-server-2017#wait-categories-mapping-table
	Target.[category_id] = Source.[category_id],
	Target.[wait_type] = Source.[wait_type],
	Target.[waiting_tasks_count] = Source.[waiting_tasks_count],
	Target.[wait_time_s] = Source.[wait_time_s],
	Target.[max_wait_time_ms] = Source.[max_wait_time_ms],
	Target.[signal_wait_time_s] = Source.[signal_wait_time_s],
	Target.title = ISNULL(@title, CONVERT(VARCHAR(30), GETDATE(), 20))
	-- IMPORTANT: DO NOT subtract Source-Target because the source always has a diff.
	-- On each snapshot wait starts are reset to 0 - see DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
	-- Therefore, current snapshot is diff.
	-- #alzheimer
WHEN NOT MATCHED BY TARGET THEN
INSERT (category_id,
	[wait_type],
	[waiting_tasks_count],
	[wait_time_s],
	[max_wait_time_ms],
	[signal_wait_time_s], title)
VALUES (Source.category_id, Source.[wait_type],Source.[waiting_tasks_count],
		Source.[wait_time_s], Source.[max_wait_time_ms],
		Source.[signal_wait_time_s],
		ISNULL(@title, CONVERT(VARCHAR(30), GETDATE(), 20)) );

DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

END
GO

CREATE OR ALTER   function qpi.wait_stats_as_of(@date datetime2)
returns table
as return (
select
			category = c.category,
			wait_type,
			wait_time_s = wait_time_s,
			wait_per_task_ms = 100. * wait_time_s / case when waiting_tasks_count = 0 then null else waiting_tasks_count end,
			avg_wait_time = wait_time_s / DATEDIFF(s, start_time, GETUTCDATE()),
			signal_wait_time_s = signal_wait_time_s,
			avg_signal_wait_time = signal_wait_time_s / DATEDIFF(s, start_time, GETUTCDATE()),
			max_wait_time_s = CAST(ROUND(max_wait_time_ms /1000.,1) AS NUMERIC(12,1)),
			category_id,
			snapshot_time = start_time
from qpi.os_wait_stats_snapshot for system_time all rsi
	cross apply qpi.__wait_stats_category(category_id) as c
where @date is null or @date between rsi.start_time and rsi.end_time
);
go
CREATE OR ALTER
VIEW qpi.wait_stats_ex
AS SELECT
	category = c.category,
	wait_type = [wait_type],
	[waiting_tasks_count],
	[wait_time_s] = CAST(ROUND([wait_time_ms] / 1000.,1) AS NUMERIC(12,1)),
	[wait_per_task_ms] = wait_time_ms / case when waiting_tasks_count = 0 then null else waiting_tasks_count end,
	[max_wait_time_ms],
	[signal_wait_time_s] = [signal_wait_time_ms] / 1000,
	category_id = cid.category_id,
	info = 'www.sqlskills.com/help/waits/' + [wait_type]
	FROM sys.dm_os_wait_stats
		cross apply qpi.__wait_stats_category_id(wait_type) as cid
			cross apply qpi.__wait_stats_category(cid.category_id) as c
	-- see: www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/
	-- Last updated June 13, 2018
	where [wait_type] NOT IN (
        -- These wait types are almost 100% never a problem and so they are
        -- filtered out to avoid them skewing the results. Click on the URL
        -- for more information.
        N'BROKER_EVENTHANDLER', -- www.sqlskills.com/help/waits/BROKER_EVENTHANDLER
        N'BROKER_RECEIVE_WAITFOR', -- www.sqlskills.com/help/waits/BROKER_RECEIVE_WAITFOR
        N'BROKER_TASK_STOP', -- www.sqlskills.com/help/waits/BROKER_TASK_STOP
        N'BROKER_TO_FLUSH', -- www.sqlskills.com/help/waits/BROKER_TO_FLUSH
        N'BROKER_TRANSMITTER', -- www.sqlskills.com/help/waits/BROKER_TRANSMITTER
        N'CHECKPOINT_QUEUE', -- www.sqlskills.com/help/waits/CHECKPOINT_QUEUE
        N'CHKPT', -- www.sqlskills.com/help/waits/CHKPT
        N'CLR_AUTO_EVENT', -- www.sqlskills.com/help/waits/CLR_AUTO_EVENT
        N'CLR_MANUAL_EVENT', -- www.sqlskills.com/help/waits/CLR_MANUAL_EVENT
        N'CLR_SEMAPHORE', -- www.sqlskills.com/help/waits/CLR_SEMAPHORE
        N'CXCONSUMER', -- www.sqlskills.com/help/waits/CXCONSUMER

        -- Maybe comment these four out if you have mirroring issues
        N'DBMIRROR_DBM_EVENT', -- www.sqlskills.com/help/waits/DBMIRROR_DBM_EVENT
        N'DBMIRROR_EVENTS_QUEUE', -- www.sqlskills.com/help/waits/DBMIRROR_EVENTS_QUEUE
        N'DBMIRROR_WORKER_QUEUE', -- www.sqlskills.com/help/waits/DBMIRROR_WORKER_QUEUE
        N'DBMIRRORING_CMD', -- www.sqlskills.com/help/waits/DBMIRRORING_CMD

        N'DIRTY_PAGE_POLL', -- www.sqlskills.com/help/waits/DIRTY_PAGE_POLL
        N'DISPATCHER_QUEUE_SEMAPHORE', -- www.sqlskills.com/help/waits/DISPATCHER_QUEUE_SEMAPHORE
        N'EXECSYNC', -- www.sqlskills.com/help/waits/EXECSYNC
        N'FSAGENT', -- www.sqlskills.com/help/waits/FSAGENT
        N'FT_IFTS_SCHEDULER_IDLE_WAIT', -- www.sqlskills.com/help/waits/FT_IFTS_SCHEDULER_IDLE_WAIT
        N'FT_IFTSHC_MUTEX', -- www.sqlskills.com/help/waits/FT_IFTSHC_MUTEX

        -- Maybe comment these six out if you have AG issues
        N'HADR_CLUSAPI_CALL', -- www.sqlskills.com/help/waits/HADR_CLUSAPI_CALL
        N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', -- www.sqlskills.com/help/waits/HADR_FILESTREAM_IOMGR_IOCOMPLETION
        N'HADR_LOGCAPTURE_WAIT', -- www.sqlskills.com/help/waits/HADR_LOGCAPTURE_WAIT
        N'HADR_NOTIFICATION_DEQUEUE', -- www.sqlskills.com/help/waits/HADR_NOTIFICATION_DEQUEUE
        N'HADR_TIMER_TASK', -- www.sqlskills.com/help/waits/HADR_TIMER_TASK
        N'HADR_WORK_QUEUE', -- www.sqlskills.com/help/waits/HADR_WORK_QUEUE

        N'KSOURCE_WAKEUP', -- www.sqlskills.com/help/waits/KSOURCE_WAKEUP
        N'LAZYWRITER_SLEEP', -- www.sqlskills.com/help/waits/LAZYWRITER_SLEEP
        N'LOGMGR_QUEUE', -- www.sqlskills.com/help/waits/LOGMGR_QUEUE
        N'MEMORY_ALLOCATION_EXT', -- www.sqlskills.com/help/waits/MEMORY_ALLOCATION_EXT
        N'ONDEMAND_TASK_QUEUE', -- www.sqlskills.com/help/waits/ONDEMAND_TASK_QUEUE
        N'PARALLEL_REDO_DRAIN_WORKER', -- www.sqlskills.com/help/waits/PARALLEL_REDO_DRAIN_WORKER
        N'PARALLEL_REDO_LOG_CACHE', -- www.sqlskills.com/help/waits/PARALLEL_REDO_LOG_CACHE
        N'PARALLEL_REDO_TRAN_LIST', -- www.sqlskills.com/help/waits/PARALLEL_REDO_TRAN_LIST
        N'PARALLEL_REDO_WORKER_SYNC', -- www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_SYNC
        N'PARALLEL_REDO_WORKER_WAIT_WORK', -- www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_WAIT_WORK
        N'PREEMPTIVE_XE_GETTARGETSTATE', -- www.sqlskills.com/help/waits/PREEMPTIVE_XE_GETTARGETSTATE
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', -- www.sqlskills.com/help/waits/PWAIT_ALL_COMPONENTS_INITIALIZED
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', -- www.sqlskills.com/help/waits/PWAIT_DIRECTLOGCONSUMER_GETNEXT
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', -- www.sqlskills.com/help/waits/QDS_PERSIST_TASK_MAIN_LOOP_SLEEP
        N'QDS_ASYNC_QUEUE', -- www.sqlskills.com/help/waits/QDS_ASYNC_QUEUE
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
            -- www.sqlskills.com/help/waits/QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP
        N'QDS_SHUTDOWN_QUEUE', -- www.sqlskills.com/help/waits/QDS_SHUTDOWN_QUEUE
        N'REDO_THREAD_PENDING_WORK', -- www.sqlskills.com/help/waits/REDO_THREAD_PENDING_WORK
        N'REQUEST_FOR_DEADLOCK_SEARCH', -- www.sqlskills.com/help/waits/REQUEST_FOR_DEADLOCK_SEARCH
        N'RESOURCE_QUEUE', -- www.sqlskills.com/help/waits/RESOURCE_QUEUE
        N'SERVER_IDLE_CHECK', -- www.sqlskills.com/help/waits/SERVER_IDLE_CHECK
        N'SLEEP_BPOOL_FLUSH', -- www.sqlskills.com/help/waits/SLEEP_BPOOL_FLUSH
        N'SLEEP_DBSTARTUP', -- www.sqlskills.com/help/waits/SLEEP_DBSTARTUP
        N'SLEEP_DCOMSTARTUP', -- www.sqlskills.com/help/waits/SLEEP_DCOMSTARTUP
        N'SLEEP_MASTERDBREADY', -- www.sqlskills.com/help/waits/SLEEP_MASTERDBREADY
        N'SLEEP_MASTERMDREADY', -- www.sqlskills.com/help/waits/SLEEP_MASTERMDREADY
        N'SLEEP_MASTERUPGRADED', -- www.sqlskills.com/help/waits/SLEEP_MASTERUPGRADED
        N'SLEEP_MSDBSTARTUP', -- www.sqlskills.com/help/waits/SLEEP_MSDBSTARTUP
        N'SLEEP_SYSTEMTASK', -- www.sqlskills.com/help/waits/SLEEP_SYSTEMTASK
        N'SLEEP_TASK', -- www.sqlskills.com/help/waits/SLEEP_TASK
        N'SLEEP_TEMPDBSTARTUP', -- www.sqlskills.com/help/waits/SLEEP_TEMPDBSTARTUP
        N'SNI_HTTP_ACCEPT', -- www.sqlskills.com/help/waits/SNI_HTTP_ACCEPT
        N'SP_SERVER_DIAGNOSTICS_SLEEP', -- www.sqlskills.com/help/waits/SP_SERVER_DIAGNOSTICS_SLEEP
        N'SQLTRACE_BUFFER_FLUSH', -- www.sqlskills.com/help/waits/SQLTRACE_BUFFER_FLUSH
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', -- www.sqlskills.com/help/waits/SQLTRACE_INCREMENTAL_FLUSH_SLEEP
        N'SQLTRACE_WAIT_ENTRIES', -- www.sqlskills.com/help/waits/SQLTRACE_WAIT_ENTRIES
        N'WAIT_FOR_RESULTS', -- www.sqlskills.com/help/waits/WAIT_FOR_RESULTS
        N'WAITFOR', -- www.sqlskills.com/help/waits/WAITFOR
        N'WAITFOR_TASKSHUTDOWN', -- www.sqlskills.com/help/waits/WAITFOR_TASKSHUTDOWN
        N'WAIT_XTP_RECOVERY', -- www.sqlskills.com/help/waits/WAIT_XTP_RECOVERY
        N'WAIT_XTP_HOST_WAIT', -- www.sqlskills.com/help/waits/WAIT_XTP_HOST_WAIT
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', -- www.sqlskills.com/help/waits/WAIT_XTP_OFFLINE_CKPT_NEW_LOG
        N'WAIT_XTP_CKPT_CLOSE', -- www.sqlskills.com/help/waits/WAIT_XTP_CKPT_CLOSE
        N'XE_DISPATCHER_JOIN', -- www.sqlskills.com/help/waits/XE_DISPATCHER_JOIN
        N'XE_DISPATCHER_WAIT', -- www.sqlskills.com/help/waits/XE_DISPATCHER_WAIT
        N'XE_TIMER_EVENT' -- www.sqlskills.com/help/waits/XE_TIMER_EVENT
        )
	and waiting_tasks_count > 0
	and [wait_time_ms] > 1000
	and [max_wait_time_ms] > 5

GO

CREATE OR ALTER
VIEW qpi.wait_stats
AS SELECT * FROM qpi.wait_stats_ex
WHERE category_id IS NOT NULL
GO

CREATE OR ALTER
VIEW qpi.wait_stats_history
AS SELECT * FROM  qpi.wait_stats_as_of(null);
GO



-----------------------------------------------------------------------------
-- Core Server File statistic functionalities
-----------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------
-- www.sqlskills.com/blogs/paul/how-to-examine-io-subsystem-latencies-from-within-sql-server/
---------------------------------------------------------------------------------------------------
IF (OBJECT_ID(N'qpi.io_virtual_file_stats_snapshot') IS NULL)
BEGIN
CREATE TABLE qpi.io_virtual_file_stats_snapshot (
	[db_name] sysname NULL,
	[database_id] [smallint] NOT NULL,
	[file_name] [sysname] NOT NULL,
	[size_gb] int NOT NULL,
	[file_id] [smallint] NOT NULL,
	[io_stall_read_ms] [bigint] NOT NULL,
	[io_stall_write_ms] [bigint] NOT NULL,
	[io_stall_queued_read_ms] [bigint] NOT NULL,
	[io_stall_queued_write_ms] [bigint] NOT NULL,
	[io_stall] [bigint] NOT NULL,
	[num_of_bytes_read] [bigint] NOT NULL,
	[num_of_bytes_written] [bigint] NOT NULL,
	[num_of_reads] [bigint] NOT NULL check (num_of_reads >= 0),
	[num_of_writes] [bigint] NOT NULL check (num_of_writes >= 0),
	title nvarchar(500),
	interval_mi bigint,
	start_time datetime2 GENERATED ALWAYS AS ROW START,
	end_time datetime2 GENERATED ALWAYS AS ROW END,
	PERIOD FOR SYSTEM_TIME (start_time, end_time),
	PRIMARY KEY (database_id, file_id),
	INDEX UQ_snapshot_title UNIQUE (title, database_id, file_id)
 ) WITH (SYSTEM_VERSIONING = ON ( HISTORY_TABLE = qpi.io_virtual_file_stats_snapshot_history));

CREATE INDEX ix_file_snapshot_interval_history
	ON qpi.io_virtual_file_stats_snapshot_history(end_time);
END;
GO

CREATE OR ALTER
PROCEDURE qpi.snapshot_file_stats @title nvarchar(200) = NULL, @db_name sysname = null, @file_name sysname = null
AS BEGIN
MERGE qpi.io_virtual_file_stats_snapshot AS Target
USING (
	SELECT db_name = DB_NAME(vfs.database_id),vfs.database_id,
		file_name = [mf].[name],size_gb = 8. * mf.size /1024/ 1024,[vfs].[file_id],
		[io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
		[num_of_bytes_read], [num_of_bytes_written],
		[num_of_reads], [num_of_writes]
	FROM sys.dm_io_virtual_file_stats (db_id(@db_name),NULL) AS [vfs]



	JOIN sys.master_files AS [mf] ON

		[vfs].[database_id] = [mf].[database_id] AND [vfs].[file_id] = [mf].[file_id]
		AND (@file_name IS NULL OR [mf].[name] = @file_name)
	) AS Source
ON (Target.file_id = Source.file_id AND Target.database_id = Source.database_id)
WHEN MATCHED THEN
UPDATE SET
	Target.[size_gb] = Source.[size_gb], -- Target.[io_stall_read_ms],
	Target.[io_stall_read_ms] = Source.[io_stall_read_ms], -- Target.[io_stall_read_ms],
	Target.[io_stall_write_ms] = Source.[io_stall_write_ms], -- Target.[io_stall_write_ms],
	Target.[io_stall_queued_read_ms] = Source.[io_stall_queued_read_ms], -- Target.[io_stall_read_ms],
	Target.[io_stall_queued_write_ms] = Source.[io_stall_queued_write_ms], -- Target.[io_stall_write_ms],
	Target.[io_stall] = Source.[io_stall] ,-- Target.[io_stall],
	Target.[num_of_bytes_read] = Source.[num_of_bytes_read] ,-- Target.[num_of_bytes_read],
	Target.[num_of_bytes_written] = Source.[num_of_bytes_written] ,-- Target.[num_of_bytes_written],
	Target.[num_of_reads] = Source.[num_of_reads] ,-- Target.[num_of_reads],
	Target.[num_of_writes] = Source.[num_of_writes] ,-- Target.[num_of_writes],
	Target.title = ISNULL(@title, CONVERT(VARCHAR(30), GETDATE(), 20)) ,
	Target.interval_mi = DATEDIFF_BIG(mi, Target.start_time, GETUTCDATE())
WHEN NOT MATCHED BY TARGET THEN
INSERT (db_name,database_id,file_name,size_gb,[file_id],
    [io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
    [num_of_bytes_read], [num_of_bytes_written],
    [num_of_reads], [num_of_writes], title)
VALUES (Source.db_name,Source.database_id,Source.file_name,Source.size_gb,Source.[file_id],Source.[io_stall_read_ms],Source.[io_stall_write_ms],Source.[io_stall_queued_read_ms],Source.[io_stall_queued_write_ms],Source.[io_stall],Source.[num_of_bytes_read],Source.[num_of_bytes_written],Source.[num_of_reads],Source.[num_of_writes], ISNULL(@title, CONVERT(VARCHAR(30), GETDATE(), 20)) );
END
GO

CREATE OR ALTER  FUNCTION qpi.fn_file_stats(@database_id int, @end_date datetime2 = null, @milestone nvarchar(100) = null)
RETURNS TABLE
AS RETURN (
	-- for testing: DECLARE @database_id int = DB_ID(), @end_date datetime2 = null, @milestone nvarchar(100) = null;
with cur (	[database_id],[file_id],[size_gb],[io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
				[num_of_bytes_read], [num_of_bytes_written], [num_of_reads], [num_of_writes], title, start_time, end_time)
	as (
			SELECT	s.database_id, [file_id],[size_gb],[io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
					[num_of_bytes_read], [num_of_bytes_written], [num_of_reads], [num_of_writes],
					title, start_time, end_time
			FROM qpi.io_virtual_file_stats_snapshot for system_time as of @end_date s
			WHERE @end_date is not null
			AND (@database_id is null or s.database_id = @database_id)
			UNION ALL
			SELECT	database_id,[file_id],[size_gb],[io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
					[num_of_bytes_read], [num_of_bytes_written], [num_of_reads], [num_of_writes],
					title, start_time, end_time
			FROM qpi.io_virtual_file_stats_snapshot for system_time all as s
			WHERE @milestone is not null
			AND title = @milestone
			AND (@database_id is null or s.database_id = @database_id)
			UNION ALL
			SELECT	s.database_id,s.[file_id],[size_gb]=8.*mf.size/1024/1024,[io_stall_read_ms],[io_stall_write_ms],[io_stall_queued_read_ms],[io_stall_queued_write_ms],[io_stall],
						[num_of_bytes_read], [num_of_bytes_written], [num_of_reads], [num_of_writes],
						title = 'Latest', start_time = GETUTCDATE(), end_time = CAST('9999-12-31T00:00:00.0000' AS DATETIME2)

				FROM sys.dm_io_virtual_file_stats (@database_id, null) s
					JOIN sys.master_files mf ON mf.database_id = s.database_id AND mf.file_id = s.file_id
			WHERE @milestone is null AND @end_date is null
		)
		SELECT
		db_name = prev.db_name,
		file_name = prev.file_name,
		cur.size_gb,
		throughput_mbps
			= CAST((cur.num_of_bytes_read - prev.num_of_bytes_read)/1024.0/1024.0 / (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,2))
			+ CAST((cur.num_of_bytes_written - prev.num_of_bytes_written)/1024.0/1024.0 / (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,2)),
		read_mbps
			= CAST((cur.num_of_bytes_read - prev.num_of_bytes_read)/1024.0/1024.0 / (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,2)),
		write_mbps
			= CAST((cur.num_of_bytes_written - prev.num_of_bytes_written)/1024.0/1024.0 / (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,2)),
		iops
			= CAST((cur.num_of_reads - prev.num_of_reads + cur.num_of_writes - prev.num_of_writes)/ (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,0)),
		read_iops
			= CAST((cur.num_of_reads - prev.num_of_reads)/ (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,0)),
		write_iops
			= CAST((cur.num_of_writes - prev.num_of_writes)/ (DATEDIFF(millisecond, prev.start_time, cur.start_time) / 1000.) AS numeric(10,0)),
		latency_ms
			= CASE WHEN ( (cur.num_of_reads - prev.num_of_reads) = 0 AND (cur.num_of_writes - prev.num_of_writes) = 0)
				THEN NULL ELSE (CAST(ROUND(1.0 * (cur.io_stall - prev.io_stall) / ((cur.num_of_reads - prev.num_of_reads) + (cur.num_of_writes - prev.num_of_writes)), 1) AS numeric(10,1))) END,
		read_latency_ms
			= CASE WHEN (cur.num_of_reads - prev.num_of_reads) = 0
				THEN NULL ELSE (CAST(ROUND(1.0 * (cur.io_stall_read_ms - prev.io_stall_read_ms) / (cur.num_of_reads - prev.num_of_reads), 1) AS numeric(10,1))) END,
		write_latency_ms
			= CASE WHEN (cur.num_of_writes - prev.num_of_writes) = 0
				THEN NULL ELSE (CAST(ROUND(1.0 * (cur.io_stall_write_ms - prev.io_stall_write_ms) / (cur.num_of_writes - prev.num_of_writes), 1) AS numeric(10,1))) END,
		read_io_latency_ms =
			CASE WHEN (cur.num_of_reads - prev.num_of_reads) = 0
				THEN NULL ELSE
			CAST(ROUND(((cur.io_stall_read_ms-cur.io_stall_queued_read_ms) - (prev.io_stall_read_ms - prev.io_stall_queued_read_ms))/(cur.num_of_reads - prev.num_of_reads),2) AS NUMERIC(10,2))
			END,
		write_io_latency_ms =
		CASE WHEN (cur.num_of_writes - prev.num_of_writes) = 0
				THEN NULL
				ELSE CAST(ROUND(((cur.io_stall_write_ms-cur.io_stall_queued_write_ms) - (prev.io_stall_write_ms - prev.io_stall_queued_write_ms))/(cur.num_of_writes - prev.num_of_writes),2) AS NUMERIC(10,2))
			END,
		kb_per_read
			= CASE WHEN (cur.num_of_reads - prev.num_of_reads) = 0
				THEN NULL ELSE CAST(((cur.num_of_bytes_read - prev.num_of_bytes_read) / (cur.num_of_reads - prev.num_of_reads))/1024.0 AS numeric(10,1)) END,
		kb_per_write
			= CASE WHEN (cur.num_of_writes - prev.num_of_writes) = 0
				THEN NULL ELSE CAST(((cur.num_of_bytes_written - prev.num_of_bytes_written) / (cur.num_of_writes - prev.num_of_writes))/1024.0 AS numeric(10,1)) END,
		kb_per_io
			= CASE WHEN ((cur.num_of_reads - prev.num_of_reads) = 0 AND (cur.num_of_writes - prev.num_of_writes) = 0)
				THEN NULL ELSE CAST(
					(((cur.num_of_bytes_read - prev.num_of_bytes_read) + (cur.num_of_bytes_written - prev.num_of_bytes_written)) /
					((cur.num_of_reads - prev.num_of_reads) + (cur.num_of_writes - prev.num_of_writes)))/1024.0
					 AS numeric(10,1)) END,
		read_mb = CAST((cur.num_of_bytes_read - prev.num_of_bytes_read)/1024.0/1024 AS numeric(10,2)),
		write_mb = CAST((cur.num_of_bytes_written - prev.num_of_bytes_written)/1024.0/1024 AS numeric(10,2)),
		num_of_reads = cur.num_of_reads - prev.num_of_reads,
		num_of_writes = cur.num_of_writes - prev.num_of_writes,
		interval_mi = DATEDIFF(minute, prev.start_time, cur.start_time),
		[type] = mf.type_desc
	FROM cur
		JOIN qpi.io_virtual_file_stats_snapshot for system_time all as prev
			ON cur.file_id = prev.file_id
			AND cur.database_id = prev.database_id
			AND (
				((@end_date is not null or @milestone is not null) and cur.start_time = prev.end_time)	-- cur is snapshot history => get the previous snapshot history record
				OR
				((@end_date is null and @milestone is null) and prev.end_time > GETUTCDATE())				-- cur is dm_io_virtual_file_stats => get the latest snapshot history record
			)

		JOIN sys.master_files mf ON cur.database_id = mf.database_id AND cur.file_id = mf.file_id
	WHERE (@database_id is null or @database_id = prev.database_id)
)
GO

CREATE OR ALTER  VIEW qpi.file_stats
AS SELECT * from qpi.fn_file_stats(null, null, null);
GO


CREATE OR ALTER  FUNCTION qpi.file_stats_as_of(@when datetime2(0))
RETURNS TABLE
AS RETURN (SELECT fs.* FROM qpi.fn_file_stats(null, @when, null) fs
);
GO

CREATE OR ALTER  FUNCTION qpi.db_file_stats_as_of(@when datetime2(0))
RETURNS TABLE
AS RETURN (SELECT fs.* FROM qpi.fn_file_stats(DB_ID(), @when, null) fs
);
GO

CREATE OR ALTER  FUNCTION qpi.file_stats_at(@milestone nvarchar(100))
RETURNS TABLE
AS RETURN (
	SELECT * FROM qpi.fn_file_stats(null, null, @milestone)
);
GO

CREATE OR ALTER  FUNCTION qpi.db_file_stats_at(@milestone nvarchar(100))
RETURNS TABLE
AS RETURN (
	SELECT * FROM qpi.fn_file_stats(DB_ID(), null, @milestone)
);
GO

CREATE OR ALTER  VIEW qpi.file_stats_snapshots
AS
SELECT DISTINCT snapshot_name = title, start_time, end_time
FROM qpi.io_virtual_file_stats_snapshot FOR SYSTEM_TIME ALL
GO

CREATE OR ALTER  VIEW qpi.file_stats_history
AS
select s.snapshot_name, s.start_time, fs.*
from qpi.file_stats_snapshots s
cross apply qpi.file_stats_at(s.snapshot_name) fs;
GO

CREATE OR ALTER  VIEW qpi.db_file_stats_history
AS
select s.snapshot_name, s.start_time, fs.*
from qpi.file_stats_snapshots s
cross apply qpi.db_file_stats_at(s.snapshot_name) fs;
GO
CREATE OR ALTER  FUNCTION qpi.memory_mb()
RETURNS int AS
BEGIN
 RETURN (SELECT process_memory_limit_mb FROM sys.dm_os_job_object);
END
GO




CREATE OR ALTER  VIEW qpi.volumes
AS
SELECT	volume_mount_point,
		used_gb = CAST(MIN(total_bytes / 1024. / 1024 / 1024) AS NUMERIC(10,1)),
		available_gb = CAST(MIN(available_bytes / 1024. / 1024 / 1024) AS NUMERIC(10,1)),
		total_gb = CAST(MIN((total_bytes+available_bytes) / 1024. / 1024 / 1024) AS NUMERIC(10,1))
FROM sys.master_files AS f
CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.file_id)
GROUP BY volume_mount_point;
GO



CREATE OR ALTER  VIEW qpi.sys_info
AS
SELECT

	cpu_count = virtual_core_count, service_tier, hardware_generation, max_storage_gb,
	memory_gb = ROUND(qpi.memory_mb() /1024.,1),
	sqlserver_start_time
FROM sys.dm_os_sys_info

	, (select top 1 service_tier = sku, virtual_core_count, hardware_generation, max_storage_gb = reserved_storage_mb/1024
	from master.sys.server_resource_stats
	where start_time > DATEADD(mi, -7, GETUTCDATE())) as srs

GO



CREATE OR ALTER  VIEW qpi.cpu_usage
AS
SELECT
	cpu_count,
	[sql_perc] = cpu_sql,
	[idle_perc] = cpu_idle,
    [other_perc] = 100 - cpu_sql - cpu_idle,
	[time]
   FROM sys.dm_os_sys_info,
   ( SELECT [time] = GETUTCDATE(),
         cpu_idle = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int'),
         cpu_sql = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')
               FROM (
         SELECT TOP 1 CONVERT(XML, record) AS record
         FROM sys.dm_os_ring_buffers
         WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
         AND record LIKE '% %'
		 ORDER BY TIMESTAMP DESC
		 ) as x(record)

		UNION ALL
		 select top 100 [time] = start_time,
					cpu_idle = null,
					cpu_sql = avg_cpu_percent
		from sys.server_resource_stats
		order by start_time desc

		 ) as y
GO


CREATE OR ALTER  VIEW qpi.mem_plan_cache_info
AS
SELECT  cached_object = objtype,
        memory_gb = SUM(size_in_bytes /1024 /1024 /1024),
		plan_count = COUNT_BIG(*),
		used_plans = SUM(usecounts),
		[references] = SUM(refcounts)
    FROM sys.dm_exec_cached_plans
    GROUP BY objtype
GO

CREATE OR ALTER  VIEW qpi.memory
AS
SELECT memory = REPLACE(ISNULL([type],'-->  TOTAL USED:'), 'MEMORYCLERK_', "")
     , gb = CAST(sum(pages_kb)/1024.1/1024 AS NUMERIC(6,1))
	 , perc = CAST(sum(pages_kb)/10.24/ qpi.memory_mb() AS TINYINT)
   FROM sys.dm_os_memory_clerks
   GROUP BY type WITH ROLLUP
   HAVING sum(pages_kb) /1024. /1024 > 0.1
UNION ALL
	SELECT memory = '-->  TOTAL AVAILABLE:',
		gb = CAST(ROUND(qpi.memory_mb() /1024., 1) AS NUMERIC(6,1)),
		perc = 100;
GO

-- www.mssqltips.com/sqlservertip/2393/determine-sql-server-memory-use-by-database-and-object/
CREATE OR ALTER  VIEW qpi.memory_buffers
AS
WITH src AS
(
SELECT
database_id, db_buffer_pages = COUNT_BIG(*),
			read_time_ms = AVG(read_microsec)/1000.,
			modified_perc = (100*SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END))/COUNT_BIG(*)
FROM sys.dm_os_buffer_descriptors
--WHERE database_id BETWEEN 5 AND 32766 --> to exclude system databases
GROUP BY database_id WITH ROLLUP
)
SELECT
[db_name] = CASE WHEN [database_id] = 32767 THEN 'Resource DB'
WHEN [database_id] IS NULL THEN '--> TOTAL:'
ELSE DB_NAME([database_id]) END,
buffer_gb = db_buffer_pages / 128 /1024,
buffer_percent = CONVERT(DECIMAL(6,3),
db_buffer_pages * 100.0 / (SELECT top 1 cntr_value
							FROM sys.dm_os_performance_counters
							WHERE RTRIM([object_name]) LIKE '%Buffer Manager'
							AND counter_name = 'Database Pages')
),
read_time_ms,
modified_perc
FROM src
GO

CREATE OR ALTER  VIEW
qpi.recommendations
AS
SELECT
name = 'HIGH_VLF_COUNT',
reason = CAST(count(*) AS VARCHAR(6)) + ' VLF in ' + name + ' file',
score = CAST(1-EXP(-count(*)/100.) AS NUMERIC(6,2))*100,
[state] = null,
script = CONCAT("USE [", DB_NAME(mf.database_id),"];DBCC SHRINKFILE (N'",name,"', 1, TRUNCATEONLY);"),
details = (SELECT [file] = name, db = DB_NAME(mf.database_id), vlf_count = count(*), recommended_script = 'https://github.com/Microsoft/tigertoolbox/tree/master/Fixing-VLFs' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)



from sys.master_files mf

cross apply sys.dm_db_log_info(mf.database_id) li
where li.file_id = mf.file_id
group by mf.database_id, mf.file_id, name
having count(*) > 50
UNION ALL
select	name = 'MEMORY_PRESSURE',
		reason = CONCAT('Low page life expectancy ', v.cntr_value,' on ', RTRIM(v.object_name), '. Should be greater than: ',
		(((l.cntr_value*8/1024)/1024)/4)*300)
		, score = 100 -- something like 1 - EXP (CASE WHEN l.cntr_value > 0 THEN (((l.cntr_value*8./1024)/1024)/4)*300 ELSE NULL END) / v.cntr_value
		, state = null
		, script = 'N/A: Add more memory or find the queries that use most of memory.'
		, details = null
from sys.dm_os_performance_counters v
join sys.dm_os_performance_counters l on v.object_name = l.object_name
where v.counter_name = 'Page Life Expectancy'
and l.counter_name = 'Database pages'
and l.object_name like '%Buffer Node%'
and (CASE WHEN l.cntr_value > 0 THEN (((l.cntr_value*8./1024)/1024)/4)*300 ELSE NULL END) / v.cntr_value > 1

UNION ALL
SELECT	name, reason, score,
		[state] = JSON_VALUE(state, '$.currentValue'),
        script = JSON_VALUE(details, '$.implementationDetails.script'),
        details
FROM sys.dm_db_tuning_recommendations


UNION ALL
SELECT	name = 'AZURE_STORAGE_35_TB_LIMIT',
		reason = 'Remaining number of database files is low',
		score = (alloc.size_tb/35.)*100,
		[state] = NULL, script = NULL,
		details = CONCAT( 'You cannot create more than ', (35 - alloc.size_tb) * 8, ' additional database files.')
FROM
( SELECT
SUM(CASE WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 128 THEN 128
WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  > 128 AND  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 256 THEN 256
WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  > 256 AND  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 512 THEN 512
WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  > 512 AND  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 1024 THEN 1024
WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  > 1024 AND  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 2048 THEN 2048
WHEN  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  > 2048 AND  CAST(size * 8. / 1024 / 1024 AS decimal(12,4))  <= 4096 THEN 4096
ELSE 8192
END)/1024
FROM master.sys.master_files
WHERE physical_name LIKE 'https:%') AS alloc(size_tb)
WHERE alloc.size_tb > 30
UNION ALL
SELECT name =
	 CASE CAST(volume_mount_point as CHAR(1))
		WHEN 'C' THEN 'Reaching TempDB size limit on local storage.'
		ELSE 'Reaching storage size limit on instance.'
	END,
		reason = 'STORAGE_LIMIT',
		score = used_gb/total_gb,
		[state] = NULL, script = NULL,
		details = CONCAT( 'You are using ' , used_gb,'GB out of ', total_gb, 'GB')
from qpi.volumes
WHERE used_gb/total_gb > .8
UNION ALL
SELECT name = 'Reaching storage size limit on instance',
		reason = 'STORAGE_LIMIT',
		score = 100*storage_usage_perc*storage_usage_perc,
		[state] = NULL, script = NULL,
		details = CONCAT( 'In 2 hours the instance will reach ' , CAST(storage_usage_perc AS NUMERIC(4,2)), '% of your storage - increase the instance storage now.')
from (
select top 1 storage_usage_perc =
(storage_space_used_mb +
((storage_space_used_mb - lead (storage_space_used_mb, 100) over (order by start_time desc))
	/
DATEDIFF(mi, lead (start_time, 100) over (order by start_time desc), start_time))  * 120)
/ reserved_storage_mb
from master.sys.server_resource_stats
where storage_space_used_mb > (.8 * reserved_storage_mb) -- ignore if the current storage is less than 80%
order by start_time desc
) a(storage_usage_perc)
WHERE a.storage_usage_perc > .8
UNION ALL
SELECT	name = 'CPU_PRESSURE',
		reason = CONCAT('High CPU usage ', cpu ,' on the instance in past hour.'),
		score = cpu/100.,
		[state] = NULL, script = 'N/A: Find top queries that are using a lot of CPU and optimize them or add more cores by upgrading the instance.',
		details = CONCAT( 'Instance is using ', cpu, '% of CPU.')
FROM (select cpu = AVG(avg_cpu_percent)
	from master.sys.server_resource_stats
	where start_time > DATEADD(hour , -1, GETUTCDATE())) as usage(cpu)
where cpu > .85
UNION ALL
select
        name = wait_type COLLATE Latin1_General_100_CI_AS,
		reason = CASE wait_type
                    WHEN 'INSTANCE_LOG_RATE_GOVERNOR' THEN CONCAT('Reaching ',
                     (SELECT TOP 1 CASE WHEN sku = 'General Purpose' THEN '22'
                                ELSE '48' END
                        from master.sys.server_resource_stats
                        where start_time > DATEADD(minute , -10, GETUTCDATE())), ' MB/s instance log rate limit.' )
                    WHEN 'WRITELOG' THEN 'Potentially reaching the IO limits of log file.'
                    ELSE 'Potentially reaching the IO limit of data file.'
                END COLLATE Latin1_General_100_CI_AS,
        score = 80.,
		[state] = NULL,
        script = 'N/A - this is Managed Instance limit' COLLATE Latin1_General_100_CI_AS,
		details = null
 from (select top 10 *
from sys.dm_os_wait_stats
order by wait_time_ms desc) as ws
where wait_type in ('INSTANCE_LOG_RATE_GOVERNOR', 'WRITELOG')
or wait_type like 'PAGEIOLATCH%'

GO
---------------------------------------------------------------------------------------------------------
--			High availability
---------------------------------------------------------------------------------------------------------

CREATE OR ALTER  VIEW
qpi.nodes
AS
with nodes as (
	select db_name = DB_NAME(database_id),
		minlsn = CONVERT(NUMERIC(38,0), ISNULL(truncation_lsn, 0)),
		maxlsn = CONVERT(NUMERIC(38,0), ISNULL(last_hardened_lsn, 0)),
		seeding_state =
			CASE WHEN seedStats.internal_state_desc NOT IN ('Success', 'Failed') OR synchronization_health = 1
						THEN 'Warning' ELSE
                     (CASE WHEN synchronization_state = 0 OR synchronization_health != 2
							THEN 'ERROR' ELSE 'OK' END)
			END,
		replication_endpoint_url =
		CASE WHEN replication_endpoint_url IS NULL AND (synchronization_state = 1  OR fccs.partner_server IS NOT NULL)
			THEN fccs.partner_server + ' - ' + fccs.partner_database -- Geo replicas will be in Synchronizing state
        ELSE replication_endpoint_url END,
		repl_states.* , seedStats.internal_state_desc, frs.fabric_replica_role
		from sys.dm_hadr_database_replica_states repl_states
              LEFT JOIN sys.dm_hadr_fabric_replica_states frs
                     ON repl_states.replica_id = frs.replica_id
              LEFT OUTER JOIN sys.dm_hadr_physical_seeding_stats seedStats
                     ON seedStats.remote_machine_name = replication_endpoint_url
                     AND (seedStats.local_database_name = repl_states.group_id OR seedStats.local_database_name = DB_NAME(database_id))
                     AND seedStats.internal_state_desc NOT IN ('Success', 'Failed')
              LEFT OUTER JOIN sys.dm_hadr_fabric_continuous_copy_status fccs
                     ON repl_states.group_database_id = fccs.copy_guid
),
nodes_progress AS (
SELECT *, logprogresssize_p =
                     CASE WHEN maxlsn - minlsn != 0 THEN maxlsn - minlsn
                           ELSE 0 END
FROM nodes
),
nodes_progress_size as (
select
	log_progress_size = CASE WHEN last_hardened_lsn > minlsn AND logprogresssize_p > 0
				THEN (CONVERT(NUMERIC(38,0), last_hardened_lsn) - minlsn)*100.0/logprogresssize_p
    ELSE 0 END,
	*
	from nodes_progress
)
SELECT
	database_id, db_name,
	replication_endpoint_url,
	catchup_progress = CASE WHEN internal_state_desc IS NOT NULL -- Check for active seeding
                           THEN 'Seeding'
                     WHEN logprogresssize_p > 0
                           THEN CONVERT(VARCHAR(100), CONVERT(NUMERIC(20,2),log_progress_size)) + '%'
                     ELSE 'Select the Primary Node' END,
	is_local,
	is_primary_replica,
	seeding_state,
	synchronization_health_desc,
	synchronization_state_desc,
	secondary_lag_seconds,
	suspend_reason_desc,
	send_rate_kbps = log_send_rate,
	redo_rate_kbps = redo_rate,
	send_queue_size_kb = log_send_queue_size,
	redo_queue_size_kb = redo_queue_size,
	last_sent_time,
	last_received_time,
	last_hardened_time,
	last_redone_time,
	recovery_lsn,
	truncation_lsn,
	last_sent_lsn,
	last_received_lsn,
	last_hardened_lsn,
	last_redone_lsn,
	end_of_log_lsn,
	last_commit_lsn,
	minlsn, maxlsn
	FROM nodes_progress_size;
GO



---------------------------------------------------------------------------------------------------
--				Performance counters
---------------------------------------------------------------------------------------------------
IF (OBJECT_ID(N'qpi.os_performance_counters_snapshot') IS NULL)
BEGIN
CREATE TABLE qpi.os_performance_counters_snapshot (
	[name] nvarchar(128) NOT NULL,
	[value] decimal NOT NULL,
	[object] nvarchar(128) NOT NULL,
	[instance_name] nvarchar(128) NOT NULL,
	[type] int NOT NULL,
	start_time datetime2 GENERATED ALWAYS AS ROW START,
	end_time datetime2 GENERATED ALWAYS AS ROW END,
	PERIOD FOR SYSTEM_TIME (start_time, end_time),
	PRIMARY KEY (type,name,object,instance_name)
 ) WITH (SYSTEM_VERSIONING = ON ( HISTORY_TABLE = qpi.os_performance_counters_snapshot_history));
END;
GO

-- See for math: blogs.msdn.microsoft.com/psssql/2013/09/23/interpreting-the-counter-values-from-sys-dm_os_performance_counters/
CREATE OR ALTER  FUNCTION
qpi.fn_perf_counters(@as_of DATETIME2)
RETURNS TABLE
RETURN (
WITH
perf_counters AS
(
	select counter_name = counter_name COLLATE Latin1_General_100_CI_AS, cntr_value,
	 object_name = object_name COLLATE Latin1_General_100_CI_AS,
	 instance_name = instance_name COLLATE Latin1_General_100_CI_AS,
	  cntr_type, start_time = '9999-12-31 23:59:59.9999999' -- #hack used to join with prev.end_time
	from sys.dm_os_performance_counters
	WHERE @as_of is null
	union all
	select	counter_name = name COLLATE Latin1_General_100_CI_AS, cntr_value = value,
	object_name = object COLLATE Latin1_General_100_CI_AS,
	instance_name = instance_name COLLATE Latin1_General_100_CI_AS, cntr_type = type, start_time
	from qpi.os_performance_counters_snapshot for system_time as of @as_of
	WHERE @as_of is not null
),
perf_counters_prev AS
(
	select	counter_name = name, cntr_value = value, object_name = object, instance_name, cntr_type = type, start_time, end_time
	from qpi.os_performance_counters_snapshot for system_time all
	-- WHERE @as_of is null
	-- union all
	-- select	counter_name = name, cntr_value = value, object_name = object, instance_name, cntr_type = type, start_time, end_time
	-- from qpi.os_performance_counters_snapshot_history -- for system_time as of @as_of
	-- WHERE @as_of is not null
),
perf_counter_calculation AS (
--  PERF_COUNTER_RAWCOUNT, PERF_COUNTER_LARGE_RAWCOUNT -> NO PERF_LARGE_RAW_BASE (1073939712) because it is used just to calculate others.
select	name = counter_name, value = cntr_value, object = object_name, instance_name = pc.instance_name,
		type = cntr_type
from perf_counters pc
where cntr_type in (65536, 65792)
and pc.cntr_value > 0
--  /End:	PERF_COUNTER_RAWCOUNT, PERF_COUNTER_LARGE_RAWCOUNT
union all
-- PERF_LARGE_RAW_FRACTION
select	name = pc.counter_name,
		value =
			CASE
				WHEN base.cntr_value = 0 THEN NULL
				ELSE 100*pc.cntr_value/base.cntr_value
			END, object = pc.object_name,
		instance_name = pc.instance_name,
		type = pc.cntr_type
from (
	select counter_name, cntr_value, object_name, instance_name, cntr_type
	from perf_counters
	where cntr_type = 537003264 -- PERF_LARGE_RAW_FRACTION
	) as pc
	join (
	select counter_name, cntr_value, object_name, instance_name, cntr_type
	from perf_counters
	where cntr_type = 1073939712 -- PERF_LARGE_RAW_BASE
	) as base
		on  (rtrim(pc.counter_name) + ' base') COLLATE Latin1_General_100_CI_AS = (base.counter_name) COLLATE Latin1_General_100_CI_AS
		and  (pc.instance_name) COLLATE Latin1_General_100_CI_AS = (base.instance_name) COLLATE Latin1_General_100_CI_AS
		and  (pc.object_name) COLLATE Latin1_General_100_CI_AS = (base.object_name) COLLATE Latin1_General_100_CI_AS
-- /End: PERF_LARGE_RAW_FRACTION
union all
-- PERF_COUNTER_BULK_COUNT
select	name = pc.counter_name,
		value = (pc.cntr_value-prev.cntr_value)
				/(DATEDIFF_BIG(millisecond, prev.start_time, CASE prev.end_time
																WHEN '9999-12-31 23:59:59.9999999' THEN GETUTCDATE()
																ELSE prev.end_time	END) / 1000.),
		object = pc.object_name,
		instance_name = pc.instance_name,
		type = pc.cntr_type
from perf_counters pc
	join perf_counters_prev prev
		on  (pc.counter_name) COLLATE Latin1_General_100_CI_AS = (prev.counter_name) COLLATE Latin1_General_100_CI_AS
		and  (pc.object_name) COLLATE Latin1_General_100_CI_AS = (prev.object_name) COLLATE Latin1_General_100_CI_AS
		and  (pc.instance_name) COLLATE Latin1_General_100_CI_AS = (prev.instance_name) COLLATE Latin1_General_100_CI_AS
		and pc.cntr_type = prev.cntr_type
		and pc.start_time = prev.end_time
where pc.cntr_type = 272696576 -- PERF_COUNTER_BULK_COUNT
union ALL
-- PERF_AVERAGE_BULK
select	name = A1.counter_name,
		value =  CASE
		WHEN (B2.cntr_value = B1.cntr_value) THEN NULL
		ELSE (A2.cntr_value - A1.cntr_value) / (B2.cntr_value - B1.cntr_value)
		END,
		object = A1.object_name,
		A1.instance_name,
		type = A1.cntr_type
from perf_counters A1
	join perf_counters B1
		on CHARINDEX( REPLACE(REPLACE(RTRIM(B1.counter_name COLLATE Latin1_General_100_CI_AS), ' base',""), ' bs', ""), A1.counter_name) > 0
		and  (A1.instance_name) COLLATE Latin1_General_100_CI_AS = (B1.instance_name) COLLATE Latin1_General_100_CI_AS
		and  (A1.object_name) COLLATE Latin1_General_100_CI_AS = (B1.object_name) COLLATE Latin1_General_100_CI_AS
	join perf_counters A2
		on  (A1.counter_name) COLLATE Latin1_General_100_CI_AS = (A2.counter_name) COLLATE Latin1_General_100_CI_AS
		and  (A1.object_name) COLLATE Latin1_General_100_CI_AS = (A2.object_name) COLLATE Latin1_General_100_CI_AS
		and  (A1.instance_name) COLLATE Latin1_General_100_CI_AS = (A2.instance_name) COLLATE Latin1_General_100_CI_AS
		and A1.cntr_type = A2.cntr_type
	join perf_counters B2
		on CHARINDEX( REPLACE(REPLACE(RTRIM(B2.counter_name COLLATE Latin1_General_100_CI_AS), ' base',""), ' bs', ""), A2.counter_name) > 0
		and  (A2.instance_name) COLLATE Latin1_General_100_CI_AS = (B2.instance_name) COLLATE Latin1_General_100_CI_AS
		and  (A2.object_name) COLLATE Latin1_General_100_CI_AS = (B2.object_name) COLLATE Latin1_General_100_CI_AS
where A1.cntr_type = 1073874176 -- PERF_AVERAGE_BULK
and B1.cntr_type = 1073939712 -- PERF_LARGE_RAW_BASE
and A2.cntr_type = 1073874176 -- PERF_AVERAGE_BULK
and B2.cntr_type = 1073939712 -- PERF_LARGE_RAW_BASE
)
SELECT	name= RTRIM(pc.name), pc.value, type = RTRIM(pc.type), category = RTRIM(pc.object),
		instance_name =

			RTRIM(ISNULL(d.name, pc.instance_name))
FROM perf_counter_calculation pc

left join sys.databases d
			on  (pc.instance_name) COLLATE Latin1_General_100_CI_AS = (d.physical_database_name) COLLATE Latin1_General_100_CI_AS

WHERE value > 0
)
GO

CREATE OR ALTER  VIEW
qpi.perf_counters
AS
SELECT * FROM qpi.fn_perf_counters(NULL);
GO

CREATE OR ALTER  VIEW
qpi.db_perf_counters
AS
SELECT * FROM qpi.perf_counters
WHERE instance_name = db_name()
GO

CREATE OR ALTER  PROCEDURE qpi.snapshot_perf_counters
AS BEGIN
MERGE qpi.os_performance_counters_snapshot AS Target
USING (
	SELECT object = object_name, name = counter_name, value = cntr_value, type = cntr_type,
	instance_name
	FROM sys.dm_os_performance_counters
	-- Do not use the trick with joining instance name with sys.databases.physical_name
	-- because there are duplicate key insert error on system database
	) AS Source
ON (	 (Target.object) COLLATE Latin1_General_100_CI_AS = (Source.object) COLLATE Latin1_General_100_CI_AS
	AND  (Target.name) COLLATE Latin1_General_100_CI_AS = (Source.name) COLLATE Latin1_General_100_CI_AS
	AND  (Target.instance_name) COLLATE Latin1_General_100_CI_AS = (Source.instance_name) COLLATE Latin1_General_100_CI_AS
	AND Target.type = Source.type)
WHEN MATCHED THEN
UPDATE SET
	Target.value = Source.value
WHEN NOT MATCHED BY TARGET THEN
INSERT (name, value, object, instance_name, type)
VALUES (Source.name,Source.value,Source.object,instance_name,Source.type)
;
END
GO
SET QUOTED_IDENTIFIER ON;
GO


---------------------------------------------------------------------------------------------------
--				tempdb specific views
---------------------------------------------------------------------------------------------------


--  Find Queries with High TempDB Usage (Task Level)
CREATE OR ALTER VIEW qpi.tempdb_task_usage_current
AS
SELECT 
    s.session_id,
    r.request_id,
    t.user_objects_alloc_page_count AS total_user_obj_allocated_pages,
    t.user_objects_dealloc_page_count AS total_user_obj_deallocated_pages,
    (t.user_objects_alloc_page_count - t.user_objects_dealloc_page_count) AS net_user_obj_tempdb_pages,
    t.internal_objects_alloc_page_count AS total_internal_obj_allocated_pages,
    t.internal_objects_dealloc_page_count AS total_internal_obj_deallocated_pages,
    (t.internal_objects_alloc_page_count - t.internal_objects_dealloc_page_count) AS net_internal_obj_tempdb_pages,
    -- Summing them up for a total net for the task
    (t.user_objects_alloc_page_count - t.user_objects_dealloc_page_count) +
    (t.internal_objects_alloc_page_count - t.internal_objects_dealloc_page_count) AS net_total_task_tempdb_pages,
    ( (t.user_objects_alloc_page_count - t.user_objects_dealloc_page_count) +
      (t.internal_objects_alloc_page_count - t.internal_objects_dealloc_page_count)
    ) * 8.0 / 1024 AS net_total_task_tempdb_mb,
    r.sql_handle,
    r.plan_handle,
    st.text AS query_text,
    qp.query_plan
FROM sys.dm_db_task_space_usage AS t WITH (NOLOCK)
JOIN sys.dm_exec_sessions AS s WITH (NOLOCK) ON t.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests AS r WITH (NOLOCK) ON t.session_id = r.session_id AND t.request_id = r.request_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) AS qp
WHERE t.session_id > 50 
  AND ( (t.user_objects_alloc_page_count - t.user_objects_dealloc_page_count) +
        (t.internal_objects_alloc_page_count - t.internal_objects_dealloc_page_count)
      ) > 0; -- Only show tasks with net positive tempdb usage
GO

--  Aggregate TempDB Usage by Session

CREATE OR ALTER VIEW qpi.tempdb_session_usage_current
AS
SELECT 
    tsu.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    SUM(tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) AS total_allocated_pages,
    SUM(tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count) AS total_deallocated_pages,
    SUM((tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) -
        (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count)) AS net_tempdb_pages,
    SUM((tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) -
        (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count)) * 8 AS net_tempdb_kb -- Added KB
FROM sys.dm_db_session_space_usage AS tsu WITH (NOLOCK)
JOIN sys.dm_exec_sessions AS s WITH (NOLOCK) ON tsu.session_id = s.session_id
WHERE tsu.session_id > 50 -- Exclude system sessions
GROUP BY tsu.session_id, s.login_name, s.host_name, s.program_name
HAVING SUM((tsu.user_objects_alloc_page_count + tsu.internal_objects_alloc_page_count) -
           (tsu.user_objects_dealloc_page_count + tsu.internal_objects_dealloc_page_count)) > 0; -- Only show active consumers
GO


---Identify Queries with Hash Match or Sort Operators (Potential TempDB Spills)

--*When querying this view, use order by `total_cpu_ms DESC` or `execution_count DESC`.*

CREATE OR ALTER VIEW qpi.tempdb_cached_plans_with_hash_or_sort
AS
SELECT
    DB_NAME(qp.dbid) AS database_name,
    OBJECT_NAME(qp.objectid, qp.dbid) AS object_name,
    qs.plan_handle,
    qs.sql_handle,
    qt.text AS query_text,
    qs.creation_time,
    qs.last_execution_time,
    qs.execution_count,
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.total_elapsed_time / 1000 AS total_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_writes,
	qp.query_plan.value('count(//RelOp[@PhysicalOp="Hash Match"])', 'int') AS hash_match_operation_count,
    qp.query_plan.value('count(//RelOp[@PhysicalOp="Sort"])', 'int') AS sort_operation_count,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs WITH (NOLOCK)
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE
    qp.query_plan.exist('//RelOp[@PhysicalOp="Hash Match" or @PhysicalOp="Sort"]') = 1
    AND qp.dbid > 4; -- Optional: Exclude system databases if desired for plan cache pollution check
GO


---Check Current TempDB Space Usage by Category
--Note: The `FROM tempdb.sys.dm_db_file_space_usage AS fs` is key here.*
--This view provides a live snapshot. If you want historical TempDB space usage, you'd need a separate job to snapshot this data into a table over time. An idea for another time 

CREATE OR ALTER VIEW qpi.tempdb_space_usage_current
AS
SELECT 
    DB_NAME(fs.database_id) AS database_name, -- Will always be 'tempdb'
    SUM(fs.user_object_reserved_page_count) * 8.0 / 1024 AS user_objects_mb,
    SUM(fs.internal_object_reserved_page_count) * 8.0 / 1024 AS internal_objects_mb,
    SUM(fs.version_store_reserved_page_count) * 8.0 / 1024 AS version_store_mb,
    SUM(fs.unallocated_extent_page_count) * 8.0 / 1024 AS free_space_mb,
    SUM(fs.mixed_extent_page_count) * 8.0 / 1024 AS mixed_extent_mb, -- Added for completeness
    (SUM(fs.user_object_reserved_page_count +
         fs.internal_object_reserved_page_count +
         fs.version_store_reserved_page_count +
         fs.unallocated_extent_page_count +
         fs.mixed_extent_page_count) * 8.0 / 1024) AS total_space_mb_in_files -- Approximation of total allocated space in data files
FROM tempdb.sys.dm_db_file_space_usage AS fs -- Querying tempdb's DMV explicitly
GROUP BY fs.database_id; -- Grouping by database_id though it will only be tempdb
GO





































--- unused and optional stuff

--- backup info, rarely useful with Mi.


--CREATE OR ALTER VIEW qpi.backups as
--SELECT TOP 5000 bcks.database_name, bckMF.device_type, BackD.type_desc, BackD.physical_name, bckS.type, 
--CASE bckS.[type] WHEN 'D' THEN 'Full'
--WHEN 'I' THEN 'Differential'
--WHEN 'L' THEN 'Transaction Log'
--END AS BackupType, bckS.backup_start_date, bckS.backup_finish_date, 
--convert(char(8),dateadd(s,datediff(s,bckS.backup_start_date, bckS.backup_finish_date),'1900-1-1'),8) AS BackupTimeFull,
--convert(decimal(19,2),(bckS.backup_size *1.0) / power(2,20)) as [Backup Size(MB)],CAST(bcks.backup_size / 1073741824.0E AS DECIMAL(10, 2)) as [Backup Size(GB)] ,Convert(decimal(19,2),(bckS.compressed_backup_size *1.0) / power(2,20)) as [Compressed Backup Size(MB)]
--, CAST(bcks.compressed_backup_size / 1073741824.0E AS DECIMAL(10, 2)) as [Compressed Backup Size(GB)],
--software_name, is_compressed, is_copy_only, is_encrypted, physical_device_name,first_lsn, last_lsn, checkpoint_lsn, database_backup_lsn, user_name, @@SERVERNAME
--FROM  msdb.dbo.backupset bckS INNER JOIN msdb.dbo.backupmediaset bckMS
--ON bckS.media_set_id = bckMS.media_set_id
--INNER JOIN msdb.dbo.backupmediafamily bckMF 
--ON bckMS.media_set_id = bckMF.media_set_id
--Left join sys.backup_devices BackD on bckMF.device_type = BackD.type
--go




--CREATE OR ALTER VIEW qpi.backup_durations as
--SELECT
--session_id as SPID,
--command,
--a.text AS Query,
--start_time,
--percent_complete,
--CAST(((DATEDIFF(s,start_time,GETDATE()))/3600) AS VARCHAR) + ' hour(s), '
--+ CAST((DATEDIFF(s,start_time,GETDATE())%3600)/60 AS VARCHAR) + 'min, '
--+ CAST((DATEDIFF(s,start_time,GETDATE())%60) AS VARCHAR) + ' sec' AS running_time,
--CAST((estimated_completion_time/3600000) AS VARCHAR) + ' hour(s), '
--+ CAST((estimated_completion_time %3600000)/60000 AS VARCHAR) + 'min, '
--+ CAST((estimated_completion_time %60000)/1000 as VARCHAR) + ' sec' AS est_time_to_go,
--DATEADD(SECOND,estimated_completion_time/1000, GETDATE()) AS estimated_completion_time
--FROM sys.dm_exec_requests r
--CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a
--WHERE r.command IN ('BACKUP DATABASE','RESTORE DATABASE', 'BACKUP LOG','RESTORE LOG')
--go




--CREATE OR ALTER  VIEW qpi.db_file_stats
--AS SELECT * from qpi.fn_file_stats(DB_ID(), null, null);
--GO








