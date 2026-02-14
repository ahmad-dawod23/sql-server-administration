-----------------------------------------------------------------------
-- REPLICATION TROUBLESHOOTING QUERIES
-- Purpose : Diagnose replication agent failures, measure latency
--           with tracer tokens, and check undistributed commands.
-- Safety  : All queries are read-only (run against distribution DB).
-- Applies to : On-prem SQL Server with transactional replication
-----------------------------------------------------------------------

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-----------------------------------------------------------------------
-- 1. IDENTIFY REPLICATION AGENT JOBS
--    Find job IDs for Distribution, LogReader, and Snapshot agents.
--    Check the "command" column to confirm configuration.
-----------------------------------------------------------------------
SELECT
    sjv.job_id, sjv.name AS 'job_name', sjv.enabled, sjv.category_id, sjv.originating_server,
    sjs.subsystem, sjs.step_id, sjs.step_name, sjs.step_uid, sjs.server, sjs.database_name, sjs.retry_attempts, sjs.output_file_name, sjs.command, sjs.additional_parameters
FROM msdb.dbo.sysjobsteps sjs 
INNER JOIN msdb.dbo.sysjobs_view sjv ON sjv.job_id = sjs.job_id  
WHERE subsystem IN ('Distribution','LogReader','Snapshot')  

-- then feed that job ID to the stored procedure:  
exec msdb.dbo.sp_help_jobhistory @job_id = 'D55F576C-91B7-48D4-9F77-0C4F11105AD6', @mode='FULL'   


-- check what agents have been configured  
select * from MSlogreader_agents;
select * from MSsnapshot_agents;
select * from MSdistribution_agents;



-- replication errors
select top 1000 * from MSrepl_errors order by time desc;



-- get the recent output, sorted by start_date of the agent:
select top 1000 * from MSlogreader_history order by start_time desc, time desc;
select top 1000 * from MSsnapshot_history order by start_time desc, time desc;
select top 1000 * from MSdistribution_history order by start_time desc, time desc;

-- get the most recent output, sorted by event datetime:
select top 1000 * from MSlogreader_history order by time desc;
select top 1000 * from MSsnapshot_history order by time desc;
select top 1000 * from MSdistribution_history order by time desc;

-- get the output filtered on agent id:
-- agent id available from job name or from MSxxxx_agents table - see above
select * from Distribution..MSlogreader_history where agent_id = 1 order by start_time desc, time desc;
select * from Distribution..MSsnapshot_history where agent_id = 1 order by start_time desc, time desc;
select * from Distribution..MSdistribution_history where agent_id = 3 order by start_time desc, time desc;


/**********************************************************************************************/
USE [distribution]

/**********************************************************************************************/
-- Find publication
SELECT DISTINCT pb.publisher_db, da.subscriber_db, pb.publication, pd.id as pub_db_id,   da.id as agent_id,
                CASE ps.status
                    WHEN 0 THEN 'Inactive'
                    WHEN 1 THEN 'Subscribed'
                    WHEN 2 THEN 'Active'
                    END as subs_status
        , pb.description
FROM dbo.MSpublications pb
         LEFT JOIN dbo.MSdistribution_agents da on da.publication = pb.publication
    AND da.subscriber_db <> 'virtual'
         LEFT JOIN dbo.MSsubscriptions ps on ps.publisher_db = pb.publisher_db and ps.subscriber_db = da.subscriber_db
         JOIN dbo.MSpublisher_databases pd on pb.publisher_db = pd.publisher_db --just in case there is no record in agents table

/**********************************************************************************************/
-- Post tracer token
exec sp_posttracertoken 'publication_name'

/**********************************************************************************************/
-- Check the lag
SELECT
    ps.name						AS [publisher],
	p.publisher_db,
	p.publication,
	ss.name						AS [subscriber],
	da.subscriber_db,
	t.publisher_commit,
	t.distributor_commit,
	h.subscriber_commit,
	DATEDIFF(Second, t.publisher_commit, t.distributor_commit)	AS [pub to dist (s)],
	DATEDIFF(Second, t.distributor_commit ,h.subscriber_commit)	AS [dist to sub (s)],
	DATEDIFF(Second, t.publisher_commit, h.subscriber_commit)	AS [total latency (s)]
FROM
    [dbo].[MStracer_tokens] t
    INNER JOIN
    [dbo].[MStracer_history] h ON h.parent_tracer_id = t.tracer_id
    INNER JOIN
    [dbo].[MSpublications] p ON p.publication_id = t.publication_id
    INNER JOIN
    [dbo].[MSdistribution_agents] da ON da.id = h.agent_id
    INNER JOIN
    sys.servers ps ON ps.server_id = p.publisher_id
    INNER JOIN
    sys.servers ss ON ss.server_id = da.subscriber_id
/*
WHERE
	p.publisher_db = @publisher_db
	-- Search by lag threshold
	AND DATEDIFF(Second, t.publisher_commit, h.subscriber_commit) > 60
	-- Search by date
	AND t.publisher_commit > '2011-02-01 17:30:01.067'
	-- Search by subscriber
	AND	ss.name = 'instance\name'
	-- Search by publication
	AND p.publication = 'publication1'
	AND p.publication = 'publication2'
	-- Eliminate a certain publication/subscriber combination
	AND	NOT (ss.name = 'instance\name' AND p.publication = 'publication3')
	-- Eliminate tracer tokens that have not passed through the system yet
	AND h.subscriber_commit IS NOT NULL
*/
ORDER BY
    ps.name,
    p.publisher_db,
    p.publication,
    ss.name,
    da.subscriber_db,
    t.publisher_commit DESC


/**********************************************************************************************/
-- check if there are large transactions processing
-- standard is up to 5 commands for regular OLTP
-- and 400/500 commands for batches
-- larger transactions usually are causing problems, especially for Schedule database

SELECT rt.entry_time, rt.xact_seqno, COUNT(*)  FROM distribution.dbo.MSrepl_commands rc
                                                        JOIN distribution.dbo.MSrepl_transactions rt ON rc.xact_seqno = rt.xact_seqno
                                                        JOIN distribution.dbo.MSpublisher_databases pd ON pd.id = rc.publisher_database_id
WHERE rt.entry_time >=  -- 2DO: [date] (*usually* the present day)
  AND pd.publisher_db = -- 2DO: [publisher database]
GROUP by rt.entry_time, rt.xact_seqno
HAVING COUNT(1) > 1000

-- remember [publisher database ID] ('id' column)
select * from distribution.dbo.MSpublisher_databases

-- remember [distribution agent ID] ('id' column)
select * from distribution.dbo.MSdistribution_agents where publisher_database_id = -- 2DO: [publisher database ID]

-- find [xact_seqno] of the last commited transaction (SECOND ONE FROM THE TOP!)
;WITH CTE1 AS (
    select top 10
        ROW_NUMBER() OVER (ORDER BY dh.Xact_seqno desc, dh.time desc) rownum,
        CONVERT(XML, dh.comments).value('(/stats/@cmds)[1]', 'int') stats_cmds,
        CONVERT(XML, dh.comments).value('(/stats/@state)[1]', 'int') stats_state,
        CONVERT(XML, dh.comments).value('(/stats/@work)[1]', 'int') stats_work,
        CONVERT(XML, dh.comments).value('(/stats/@idle)[1]', 'int') stats_idle,
        *
    from distribution.dbo.MSdistribution_history dh (NOLOCK)
    where dh.agent_id = 24 -- 2DO: [distribution agent ID]
    order by dh.Xact_seqno desc, dh.time desc
)
 select c1.stats_cmds - c2.stats_cmds cmd_diff, DATEDIFF(MINUTE, c2.time, c1.time) mins, c1.*
 from CTE1 c1
          left join CTE1 c2 on c1.rownum = c2.rownum -1

-- use [xact_seqno] of the last replicated transaction to find [xact_seqno]
-- of the transaction being replicationed right now:
select top 1 *
from distribution.dbo.MSrepl_transactions (NOLOCK)
where publisher_database_id = -- 2DO: [publisher_database_id]
  and
    xact_seqno > -- 2DO: [xact_seqno]
order by xact_seqno asc

-- use [xact_seqno] of the transaction being replicated to see how many commands it contains:
select COUNT(*) from distribution.dbo.MSrepl_commands
where xact_seqno = [xact_seqno] -- z MSrepl_transactions
  and publisher_database_id = [publisher_database_id]

/**********************************************************************************************/
-- replication errors
/*
	Command attempted:
	if @@trancount > 0 rollback tran
	(Transaction sequence number: 0x00CB2EBA000031B4001300000000, Command ID: 16)
*/

select * from dbo.MSrepl_transactions
where xact_seqno = 0x00CB2EBA000031B4001300000000

select * from dbo.MSrepl_commands
where xact_seqno = 0x00CB2EBA000031B4001300000000

    sp_browsereplcmds  @xact_seqno_start = '0x00CB2EBA000031B4001300000000',
 @xact_seqno_end = '0x00CB2EBA000031B4001300000000',
  @command_id=16, @publisher_database_id = 2

/**********************************************************************************************/
-- replication lag 1

-- Step 1: find the last replicated transaction
select max(xact_seqno) from MSsubscriptions
                                inner join MSpublications on MSpublications.publication_id = MSsubscriptions.publication_id
                                inner join MSdistribution_history on MSdistribution_history.agent_id = MSsubscriptions.agent_id
Where subscriber_db = 'my_database_name'

-- Step 2: find the send time
select entry_time from dbo.MSrepl_transactions
where xact_seqno = 0x0005D665000015750080000000000000

-- Step 3: find how many transactions are waiting and how many commands there are
select xact_seqno, COUNT(*)  from dbo.MSrepl_commands
where xact_seqno in (select xact_seqno from dbo.MSrepl_transactions
                     where entry_time > '2013-04-09 07:37:49.887'
                       and publisher_database_id = 3)
group by xact_seqno
having COUNT(1) > 15

/**********************************************************************************************/
-- replication lag 2

-- latency counters
select *, round(cntr_value/1000,0) as latency_sec  from sys.dm_os_performance_counters
where counter_name IN
      ('Logreader:Delivery Latency', -- The latency from Publisher to Distributor
       'Dist:Delivery Latency')       -- latency from Distributor to Subscriber
order by instance_name


-- show replication latency
    ;WITH Replication_Tracers AS
    (
    SELECT
    ps.name						AS [publisher],
    p.publisher_db,
    p.publication,
    ss.name						AS [subscriber],
    da.subscriber_db,
    t.publisher_commit,
    t.distributor_commit,
    h.subscriber_commit,
    DATEDIFF(Second, t.publisher_commit, t.distributor_commit)	AS [pub to dist (s)],
    DATEDIFF(Second, t.distributor_commit ,h.subscriber_commit)	AS [dist to sub (s)],
    DATEDIFF(Second, t.publisher_commit, h.subscriber_commit)	AS [total latency (s)]
    FROM
    [distribution].[dbo].[MStracer_tokens] t
    INNER JOIN
    [distribution].[dbo].[MStracer_history] h ON h.parent_tracer_id = t.tracer_id
    INNER JOIN
    [distribution].[dbo].[MSpublications] p ON p.publication_id = t.publication_id
    INNER JOIN
    [distribution].[dbo].[MSdistribution_agents] da ON da.id = h.agent_id
    INNER JOIN
    sys.servers ps ON ps.server_id = p.publisher_id
    INNER JOIN
    sys.servers ss ON ss.server_id = da.subscriber_id
    ),
    Replication_Latency AS
    (
    SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    publisher_commit,
    [total latency (s)]
    FROM
    Replication_Tracers
    WHERE
    publisher_commit > DATEADD(Hour, -1, GETDATE())
    AND	[total latency (s)] IS NOT NULL
    UNION
    SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    publisher_commit,
    [total latency (s)]
    FROM
    (
    SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    publisher_commit,
    [total latency (s)],
    RANK() OVER (PARTITION BY publisher, publisher_db, publication, subscriber, subscriber_db ORDER BY publisher_commit ASC) AS rn
    FROM
    Replication_Tracers
    WHERE
    [total latency (s)] IS NULL
    ) tmp
    WHERE
    tmp.rn = 1
    )
SELECT
    publisher,
    publisher_db,
    publication,
    subscriber,
    subscriber_db,
    publisher_commit,
    ISNULL([total latency (s)], DATEDIFF(Second, publisher_commit, GETDATE())) AS lag,
    RANK() OVER (PARTITION BY publisher, publisher_db, publication, subscriber, subscriber_db ORDER BY publisher_commit DESC) AS rn,
    CAST (0 AS float) AS [weight],
    CAST (0 AS float) AS [normalized weight],
    CAST (0 AS float) AS [weighted lag]
FROM
    Replication_Latency

/**********************************************************************************************/
-- Get tracer_id of the faulty tracer token using the [publisher_commit] time as reference
-- (see the above script)
exec sp_helptracertokens @publisher='instance\name'
    , @publication = 'publication_TABLES'
    , @publisher_db = 'publisher_database'

/*
	Tracer_Id          Publisher_Commit
	'-2147483634'      2013-01-10 11:27:55.710
*/

-- Tracer token history details shows NULL for the subscriber and overall latency, causing the monitors to report a lag
exec sp_helptracertokenhistory @publisher='instance\name'
    , @publication = 'publication_TABLES'
    , @publisher_db = 'publisher_database'
    , @tracer_id = '-2147483634'

-- Delete the faulty tracer token history
    sp_deletetracertokenhistory @publisher='instance\name'
, @publication = 'publication_TABLES'
, @publisher_db = 'publisher_database'
, @tracer_id = '-2147483634'

/**********************************************************************************************/
-- sets the history retention period to 72 hours.
EXEC dbo.sp_MShistory_cleanup @history_retention = 72

/**********************************************************************************************/
-- Error 'Cannot insert explicit value for identity column':
/*
	Command attempted:
	if @@trancount > 0 rollback tran
	(Transaction sequence number: 0x0000004B00002B90001100000000, Command ID: 6)

	Error messages:
	-	Cannot insert explicit value for identity column in table 'BookingSearchName' when IDENTITY_INSERT is set to OFF. (Source: MSSQLServer, Error number: 544)
	Get help: http://help/544
	-	Cannot insert explicit value for identity column in table 'BookingSearchName' when IDENTITY_INSERT is set to OFF. (Source: MSSQLServer, Error number: 544)
	Get help: http://help/544
*/

-- Run this Query:
EXEC sp_msforeachtable @command1 = ' declare @int int set @int =object_id("?") EXEC sys.sp_identitycolumnforreplication @int, 1'



/*****************************************************************************************************/
-- Replication agent waits / Find wait_types for specific session

-- [ 1 ] -- Find Distribution Agent Session ID
SELECT session_id, program_name, reads, writes, logical_reads, db_name(database_id)
FROM sys.dm_exec_sessions
WHERE program_name LIKE 'Replication%';
GO

-- [ 2 ] -- Event session to track waits by session
CREATE EVENT SESSION Replication_AGT_Waits
ON SERVER
ADD EVENT sqlos.wait_info(
	ACTION (sqlserver.session_id)
	WHERE (
	-- [package0].[equal_uint64]([sqlserver].[session_id],(61)) OR
	   [package0].[equal_uint64]([sqlserver].[session_id],(61)))) -- Distribution Agent Session ID
	ADD TARGET package0.asynchronous_file_target
	(SET FILENAME = N'C:\SQLskills\ReplAGTStats.xel', -- CHECK that these are cleared
	METADATAFILE = N'C:\SQLskills\ReplAGTStats.xem');

-- [ 3 ] --
ALTER EVENT SESSION Replication_AGT_Waits
ON SERVER STATE = START;
GO
ALTER EVENT SESSION Replication_AGT_Waits
ON SERVER STATE = STOP;
GO

-- DROP EVENT SESSION Replication_AGT_Waits ON SERVER

-- [ 4 ] --

-- Raw data into intermediate table
-- (Make sure you've cleared out previous target files!)
SELECT CAST(event_data as XML) event_data
INTO #ReplicationAgentWaits_Stage_1
FROM sys.fn_xe_file_target_read_file
	('C:\SQLskills\ReplAGTStats*.xel',
	 'C:\SQLskills\ReplAGTStats*.xem',
	 NULL, NULL);

-- [ 5 ] --
	 
-- Aggregated data into intermediate table
-- #ReplicationAgentWaits
SELECT
	event_data.value
	('(/event/action[@name=''session_id'']/value)[1]', 'smallint') as session_id, event_data.value
	('(/event/data[@name=''wait_type'']/text)[1]', 'varchar(100)') as wait_type, event_data.value
	('(/event/data[@name=''duration'']/value)[1]', 'bigint') as duration, event_data.value
	('(/event/data[@name=''signal_duration'']/value)[1]', 'bigint') as signal_duration, event_data.value
	('(/event/data[@name=''completed_count'']/value)[1]', 'bigint') as completed_count
INTO #ReplicationAgentWaits_Stage_2
FROM #ReplicationAgentWaits_Stage_1;

-- [ 6 ] --

-- Final result set
SELECT session_id,
	wait_type,
	SUM(duration) total_duration,
	SUM(signal_duration) total_signal_duration,
	SUM(completed_count) total_wait_count
FROM #ReplicationAgentWaits_Stage_2
GROUP BY session_id, wait_type
ORDER BY session_id, SUM(duration) DESC;
GO

/*****************************************************************************************************/