---- deadlocks in SQL MI


WITH CTE AS (
       SELECT CAST(event_data AS XML)  AS [target_data_XML] 
       FROM sys.fn_xe_telemetry_blob_target_read_file('dl', null, null, null)
)
SELECT 
    target_data_XML.value('(/event/@timestamp)[1]', 'DateTime2') AS Timestamp,
    target_data_XML.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_xml,
    target_data_XML.query('/event/data[@name=''database_name'']/value').value('(/value)[1]', 'nvarchar(100)') AS db_name
FROM CTE

---- bad query finder with query hash

use [database_name]
go
SELECT
qt.query_sql_text,
cast(p.query_plan as xml) as [ExecutionPlan],
rs.last_execution_time
FROM sys.query_store_query_text AS qt
JOIN sys.query_store_query AS q ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan AS p ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
where q.query_hash in ()



---- find bad queries:


with query_ids as (
SELECT
q.query_hash,q.query_id,p.query_plan_hash,
SUM(qrs.count_executions) * AVG(qrs.avg_cpu_time)/1000. as total_cpu_time_ms,
SUM(qrs.count_executions) AS sum_executions,
AVG(qrs.avg_cpu_time)/1000. AS avg_cpu_time_ms,
AVG(qrs.avg_logical_io_reads)/1000. AS avg_logical_io_reads_ms,
AVG(qrs.avg_physical_io_reads)/1000. AS avg_physical_io_reads_ms
FROM sys.query_store_query q
JOIN sys.query_store_plan p on q.query_id=p.query_id
JOIN sys.query_store_runtime_stats qrs on p.plan_id = qrs.plan_id
JOIN [sys].[query_store_runtime_stats_interval] [qrsi] ON [qrs].[runtime_stats_interval_id] = [qrsi].[runtime_stats_interval_id]
WHERE q.query_hash in (0x8a432a31910d28f2) --update the query hash here
GROUP BY q.query_id, q.query_hash, p.query_plan_hash
)
SELECT qid.*,p.count_compiles,qt.query_sql_text,TRY_CAST(p.query_plan as XML) as query_plan
FROM query_ids as qid
JOIN sys.query_store_query AS q ON qid.query_id=q.query_id
JOIN sys.query_store_query_text AS qt on q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan AS p ON qid.query_id=p.query_id and qid.query_plan_hash=p.query_plan_hash
   /*WHERE qt.query_sql_text LIKE '%SQLTextHere%'*/
   /*WHERE OBJECT_NAME(q.object_id) = 'SPNameHere'*/
ORDER BY 
   avg_physical_io_reads_ms DESC
   /*,avg_logical_io_reads_ms*/;
GO

---- blocking query:


SELECT
	r.session_id,r.plan_handle,r.sql_handle,r.request_id,r.start_time, r.status,r.command, r.database_id,r.user_id, r.wait_type
	,r.wait_time,r.last_wait_type,r.wait_resource, r.total_elapsed_time,r.cpu_time, r.transaction_isolation_level,r.row_count,st.text 
FROM sys.dm_exec_requests r 
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) as st  
WHERE r.blocking_session_id = 0 and r.session_id in (SELECT distinct(blocking_session_id) FROM sys.dm_exec_requests) 
GROUP BY 
	r.session_id, r.plan_handle,r.sql_handle, r.request_id,r.start_time, r.status,r.command, r.database_id,r.user_id, r.wait_type
	,r.wait_time,r.last_wait_type,r.wait_resource, r.total_elapsed_time,r.cpu_time, r.transaction_isolation_level,r.row_count,st.text  
ORDER BY r.total_elapsed_time desc

--------------------------------------

---- head blocker finder:



SELECT
   [HeadBlocker] = 
        CASE 
            -- session has an active request, is blocked, but is blocking others
            -- or session is idle but has an open transaction and is blocking others 
            WHEN r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL) THEN '1' 
            -- session is either not blocking someone, or is blocking someone but is blocked by another party 
            ELSE '' 
        END, 
   [SessionID] = s.session_id, 
   [Login] = s.login_name,   
   [Database] = db_name(p.dbid), 
   [BlockedBy] = w.blocking_session_id, 
   [OpenTransactions] = r.open_transaction_count, 
   [Status] = s.status, 
   [WaitType] = w.wait_type, 
   [WaitTime_ms] = w.wait_duration_ms, 
   [WaitResource] = r.wait_resource, 
   [WaitResourceDesc] = w.resource_description, 
   [Command] = r.command, 
   [Application] = s.program_name, 
   [TotalCPU_ms] = s.cpu_time, 
   [TotalPhysicalIO_MB] = (s.reads + s.writes) * 8 / 1024, 
   [MemoryUse_KB] = s.memory_usage * 8192 / 1024, 
   [LoginTime] = s.login_time, 
   [LastRequestStartTime] = s.last_request_start_time, 
   [HostName] = s.host_name,
   [QueryHash] = r.query_hash, 
   [BlockerQuery_or_MostRecentQuery] = txt.text
FROM sys.dm_exec_sessions s 
LEFT OUTER JOIN sys.dm_exec_connections c ON (s.session_id = c.session_id) 
LEFT OUTER JOIN sys.dm_exec_requests r ON (s.session_id = r.session_id) 
LEFT OUTER JOIN sys.dm_os_tasks t ON (r.session_id = t.session_id AND r.request_id = t.request_id) 
LEFT OUTER JOIN 
( 
    SELECT *, ROW_NUMBER() OVER (PARTITION BY waiting_task_address ORDER BY wait_duration_ms DESC) AS row_num 
    FROM sys.dm_os_waiting_tasks 
) w ON (t.task_address = w.waiting_task_address) AND w.row_num = 1 
LEFT OUTER JOIN sys.dm_exec_requests r2 ON (s.session_id = r2.blocking_session_id) 
LEFT OUTER JOIN sys.sysprocesses p ON (s.session_id = p.spid) 
OUTER APPLY sys.dm_exec_sql_text (ISNULL(r.[sql_handle], c.most_recent_sql_handle)) AS txt
WHERE s.is_user_process = 1 
AND (r2.session_id IS NOT NULL AND (r.blocking_session_id = 0 OR r.session_id IS NULL)) 
OR blocked > 0 
ORDER BY [HeadBlocker] desc, s.session_id; 



/*
[T1] Top 10 Active CPU queries by session 
*/
print '--top 10 Active CPU Consuming Queries by sessions--'  
SELECT 
	top 10 req.session_id, 
	req.start_time, 
	cpu_time 'cpu_time_ms', 
	object_name(st.objectid,st.dbid) 'ObjectName' ,  
	substring (REPLACE (REPLACE (SUBSTRING(ST.text, (req.statement_start_offset/2) + 1,   
	((
		CASE statement_end_offset    
			WHEN -1 THEN DATALENGTH(ST.text)   
			ELSE req.statement_end_offset 
			END - req.statement_start_offset)/2) + 1), CHAR(10), ' '), CHAR(13), ' '), 1, 512)  AS statement_text   
 FROM sys.dm_exec_requests AS req   
 CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) as ST 
 order by cpu_time desc 

 /*
 [T2] Top 10 Active CPU queries aggregated by query hash 
 */
 print '-- top 10 Active CPU Consuming Queries (aggregated)--'  
 select 
	top 10 getdate() runtime,  * 
from (
	SELECT query_stats.query_hash,    
	SUM(query_stats.cpu_time) 'Total_Request_Cpu_Time_Ms', 
	sum(logical_reads) 'Total_Request_Logical_Reads', 
	min(start_time) 'Earliest_Request_start_Time', 
	count(*) 'Number_Of_Requests', 
	substring (REPLACE (REPLACE (MIN(query_stats.statement_text),  CHAR(10), ' '), CHAR(13), ' '), 1, 256) AS "Statement_Text"   
 FROM (
	SELECT req.*,  
	SUBSTRING(ST.text, (req.statement_start_offset/2) + 1, 
	( (
		CASE statement_end_offset
			WHEN -1 THEN DATALENGTH(ST.text)   
			ELSE req.statement_end_offset 
			END - req.statement_start_offset)/2) + 1) AS statement_text   
	FROM sys.dm_exec_requests AS req   
	CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) as ST) as query_stats   
	group by query_hash) t 
	order by Total_Request_Cpu_Time_Ms desc 

/*
[T3] TOP 15 CPU consuming queries from query store 
-- top 15 CPU consuming queries by query hash 
-- note that a query  hash can have many query id if not parameterized or not parameterized properly 
-- it grabs a sample query text by min  
*/
WITH AggregatedCPU AS (
	SELECT q.query_hash, 
		SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, 
		SUM(count_executions * avg_cpu_time / 1000.0) /SUM(count_executions) as avg_cpu_millisec, 
		max(rs.max_cpu_time/1000.00) as max_cpu_millisec, 
		max(max_logical_io_reads) max_logical_reads, 
		COUNT (distinct p.plan_id) AS number_of_distinct_plans, 
		count (distinct p.query_id) as number_of_distinct_query_ids, 
		sum (case when rs.execution_type_desc='Aborted' then count_executions else 0 end) as Aborted_Execution_Count, 
		sum (case when rs.execution_type_desc='Regular' then count_executions else 0 end) as Regular_Execution_Count, 
		sum (case when rs.execution_type_desc='Exception' then count_executions else 0 end) as Exception_Execution_Count, 
		sum (count_executions) as total_executions, 
		min(qt.query_sql_text) as sampled_query_text 
	FROM sys.query_store_query_text AS qt JOIN sys.query_store_query AS q  
		ON qt.query_text_id = q.query_text_id 
		JOIN sys.query_store_plan AS p ON q.query_id = p.query_id 
		JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id 
		JOIN sys.query_store_runtime_stats_interval AS rsi  
		ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id 
	WHERE   
		rs.execution_type_desc in( 'Regular' , 'Aborted', 'Exception') and   
		rsi.start_time >= DATEADD(hour, -2, GETUTCDATE())  
	GROUP BY  q.query_hash 
) , 
OrderedCPU AS ( 
	SELECT query_hash, 
		total_cpu_millisec, 
		avg_cpu_millisec,
		max_cpu_millisec,  
		max_logical_reads, 
		number_of_distinct_plans, 
		number_of_distinct_query_ids,  
		total_executions, 
		Aborted_Execution_Count,
		Regular_Execution_Count, 
		Exception_Execution_Count, 
		sampled_query_text, 
		ROW_NUMBER () OVER (ORDER BY total_cpu_millisec DESC, query_hash asc) AS RN 
	FROM AggregatedCPU 
) 
SELECT * from OrderedCPU OD  
WHERE OD.RN <=15 ORDER BY total_cpu_millisec DESC 


-- run in affected user database

SELECT 
    req.session_id, 
    req.status, 
    req.start_time, 
    req.cpu_time AS 'cpu_time_ms', 
    req.query_hash,
    req.logical_reads,
    req.dop,s.login_name,
    s.host_name,
    s.program_name,
    object_name(st.objectid, st.dbid) as 'object_name',
    REPLACE (REPLACE (
        SUBSTRING (st.text, (req.statement_start_offset/2) + 1, 
            ((CASE req.statement_end_offset
             WHEN -1 THEN DATALENGTH(st.text) 
            ELSE req.statement_end_offset END - req.statement_start_offset)/2) + 1), 
        CHAR(10), ' '), CHAR(13), ' ') AS statement_text,
    qp.query_plan,
    qsx.query_plan as query_plan_with_in_flight_statistics
FROM sys.dm_exec_requests as req
INNER JOIN sys.dm_exec_sessions as s on req.session_id=s.session_id
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) as st
OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) as qp
OUTER APPLY sys.dm_exec_query_statistics_xml(req.session_id) as qsx
WHERE req.session_id <> @@SPID
ORDER BY req.cpu_time desc;




--Many individual queries that cumulatively consume high CPU:

PRINT '-- top 10 Active CPU Consuming Queries (aggregated)--';
SELECT TOP 10 GETDATE() runtime, *
FROM (SELECT query_stats.query_hash, SUM(query_stats.cpu_time) 'Total_Request_Cpu_Time_Ms', SUM(logical_reads) 'Total_Request_Logical_Reads', MIN(start_time) 'Earliest_Request_start_Time', COUNT(*) 'Number_Of_Requests', SUBSTRING(REPLACE(REPLACE(MIN(query_stats.statement_text), CHAR(10), ' '), CHAR(13), ' '), 1, 256) AS "Statement_Text"
    FROM (SELECT req.*, SUBSTRING(ST.text, (req.statement_start_offset / 2)+1, ((CASE statement_end_offset WHEN -1 THEN DATALENGTH(ST.text)ELSE req.statement_end_offset END-req.statement_start_offset)/ 2)+1) AS statement_text
          FROM sys.dm_exec_requests AS req
                CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST ) AS query_stats
    GROUP BY query_hash) AS t
ORDER BY Total_Request_Cpu_Time_Ms DESC;


--Long running queries that consume CPU are still running:

PRINT '--top 10 Active CPU Consuming Queries by sessions--';
SELECT TOP 10 req.session_id, req.start_time, cpu_time 'cpu_time_ms', OBJECT_NAME(ST.objectid, ST.dbid) 'ObjectName', SUBSTRING(REPLACE(REPLACE(SUBSTRING(ST.text, (req.statement_start_offset / 2)+1, ((CASE statement_end_offset WHEN -1 THEN DATALENGTH(ST.text)ELSE req.statement_end_offset END-req.statement_start_offset)/ 2)+1), CHAR(10), ' '), CHAR(13), ' '), 1, 512) AS statement_text
FROM sys.dm_exec_requests AS req
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS ST
ORDER BY cpu_time DESC;
GO



--If The CPU issue occurred in the past:


-- Top 15 CPU consuming queries by query hash
-- note that a query  hash can have many query id if not parameterized or not parameterized properly
-- it grabs a sample query text by min
WITH AggregatedCPU AS (SELECT q.query_hash, SUM(count_executions * avg_cpu_time / 1000.0) AS total_cpu_millisec, SUM(count_executions * avg_cpu_time / 1000.0)/ SUM(count_executions) AS avg_cpu_millisec, MAX(rs.max_cpu_time / 1000.00) AS max_cpu_millisec, MAX(max_logical_io_reads) max_logical_reads, COUNT(DISTINCT p.plan_id) AS number_of_distinct_plans, COUNT(DISTINCT p.query_id) AS number_of_distinct_query_ids, SUM(CASE WHEN rs.execution_type_desc='Aborted' THEN count_executions ELSE 0 END) AS Aborted_Execution_Count, SUM(CASE WHEN rs.execution_type_desc='Regular' THEN count_executions ELSE 0 END) AS Regular_Execution_Count, SUM(CASE WHEN rs.execution_type_desc='Exception' THEN count_executions ELSE 0 END) AS Exception_Execution_Count, SUM(count_executions) AS total_executions, MIN(qt.query_sql_text) AS sampled_query_text
                       FROM sys.query_store_query_text AS qt
                            JOIN sys.query_store_query AS q ON qt.query_text_id=q.query_text_id
                            JOIN sys.query_store_plan AS p ON q.query_id=p.query_id
                            JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id=p.plan_id
                            JOIN sys.query_store_runtime_stats_interval AS rsi ON rsi.runtime_stats_interval_id=rs.runtime_stats_interval_id
                       WHERE rs.execution_type_desc IN ('Regular', 'Aborted', 'Exception')AND rsi.start_time>=DATEADD(HOUR, -2, GETUTCDATE())
                       GROUP BY q.query_hash), OrderedCPU AS (SELECT query_hash, total_cpu_millisec, avg_cpu_millisec, max_cpu_millisec, max_logical_reads, number_of_distinct_plans, number_of_distinct_query_ids, total_executions, Aborted_Execution_Count, Regular_Execution_Count, Exception_Execution_Count, sampled_query_text, ROW_NUMBER() OVER (ORDER BY total_cpu_millisec DESC, query_hash ASC) AS RN
                                                              FROM AggregatedCPU)
SELECT OD.query_hash, OD.total_cpu_millisec, OD.avg_cpu_millisec, OD.max_cpu_millisec, OD.max_logical_reads, OD.number_of_distinct_plans, OD.number_of_distinct_query_ids, OD.total_executions, OD.Aborted_Execution_Count, OD.Regular_Execution_Count, OD.Exception_Execution_Count, OD.sampled_query_text, OD.RN
FROM OrderedCPU AS OD
WHERE OD.RN<=15
ORDER BY total_cpu_millisec DESC;



---command to check for memory usage

SELECT SUBSTRING(st.text, er.statement_start_offset/2 + 1,(CASE WHEN er.statement_end_offset = -1 THEN LEN(CONVERT(nvarchar(max),st.text)) * 2 ELSE er.statement_end_offset END - er.statement_start_offset)/2) as Query_Text,tsu.session_id ,tsu.request_id, tsu.exec_context_id, (tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count) as OutStanding_user_objects_page_counts,(tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) as OutStanding_internal_objects_page_counts,er.start_time, er.command, er.open_transaction_count, er.percent_complete, er.estimated_completion_time, er.cpu_time, er.total_elapsed_time, er.reads,er.writes, er.logical_reads, er.granted_query_memory,es.host_name , es.login_name , es.program_name FROM sys.dm_db_task_space_usage tsu INNER JOIN sys.dm_exec_requests er ON ( tsu.session_id = er.session_id AND tsu.request_id = er.request_id) INNER JOIN sys.dm_exec_sessions es ON ( tsu.session_id = es.session_id ) CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) st WHERE (tsu.internal_objects_alloc_page_count+tsu.user_objects_alloc_page_count) > 0
ORDER BY (tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count)+ (tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) DESC



-----log file contention:

SELECT 
  io_stall_write_ms / NULLIF(num_of_writes, 0) AS avg_write_latency_ms
FROM sys.dm_io_virtual_file_stats(1, NULL);  -- Filter for log files [2]



-- wait types monitoring

SELECT session_id, wait_duration_ms, resource_description, wait_type
FROM sys.dm_os_waiting_tasks
--WHERE wait_type like 'PAGE%LATCH_%' AND resource_description like '2:%'






