
/*
installing from docker:

1) sql server run: docker run -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=ahmad@123' --name 'sql1' -p 1401:1433 -v sql1data:/var/opt/mssql -d mcr.microsoft.com/mssql/server:2022-latest
2) enable sql agent from exec menu on docker desktop: /opt/mssql/bin/mssql-conf set sqlagent.enabled true
3) copy backups into docker volumes, cd into the bak location then run this command: docker cp WideWorldImporters-Full.bak sql1:/var/opt/mssql/backup

*/

-- tranfer database logins: https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/security/transfer-logins-passwords-between-instances

-- enable column level encryption: https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/always-encrypted-wizard?view=sql-server-ver16
-- for opening encrypted column add the following in connection string: Column Encryption Setting=Enabled

-- data masking in sql server: https://learn.microsoft.com/en-us/sql/relational-databases/security/dynamic-data-masking?view=sql-server-ver16

-- row level security: https://www.sqlshack.com/introduction-to-row-level-security-in-sql-server/

-- sql server audits: https://learn.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-database-engine?view=sql-server-ver16

-- encrypting sql server connections: https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-sql-server-encryption?view=sql-server-ver16

-- log shipping: https://learn.microsoft.com/en-us/sql/database-engine/log-shipping/about-log-shipping-sql-server?view=sql-server-ver16

--change log capture: https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-data-capture-sql-server?view=sql-server-ver16
-- enable change log capture for a table:
 exec sys.sp_cdc_enable_db



/*trouble shooting tips for sql server issues:

1) use activity monitor to check for blocking queries and server utilization
2) use performance monitor to check which part of sql server is consuming the most resources.
3) use event viewer to check sql server service failures
4) check error logs from within sql server.
5) for slowness issues, check if resource governer is being used.
6) ask the customer to run the index query below
7) use live query statistics to check the source of the slowness.
7) check the query store
*/

---get port number:

USE MASTER
GO
xp_readerrorlog 0, 1, N'Server is listening on'
GO

--find network protocol currently used

SELECT net_transport
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;


---find recovery model:
select [name], DATABASEPROPERTYEX([name],'recovery') as RecoveryMode
from sysdatabases



---find location of tempdb

use master

EXEC sp_helpdb tempdb



---change location of tempdb:

Alter database tempdb
modify file
(NAME = tempdev, filename = 'C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\tempdb.mdf')

Alter database tempdb
modify file
(NAME = templog, filename = 'C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\templog.ldf')



--detaching a database from SQLCODE


Alter database AdventureWorks2014
set single_user with rollback immediate

exec master.dbo.sp_detach_db @dbname= N'AdventureWorks2014', @skipchecks = 'false'


--attaching a database from SQLCODE

USE MASTER
GO
create database AdventureWorks2014 ON
(filename = C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\AdventureWorks2014_Data.mdf),
(filename = C:\Program Files\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQL\DATA\AdventureWorks2014_Log.ldf)
for attach



---full back from SQLCODE
BACKUP DATABASE [AdventureWorks2014] TO  DISK = N'C:\backups\adventurework2014.bak' 
WITH NOFORMAT, NOINIT,  
NAME = N'AdventureWorks2014-Full Database Backup', 
SKIP, NOREWIND, NOUNLOAD,  STATS = 10
GO

--- DIFFERENTIAL BACKUP

BACKUP DATABASE [AdventureWorks2014] TO  DISK = N'C:\backups\adventurework2014.bak' 
WITH  DIFFERENTIAL , NOFORMAT, NOINIT,  
NAME = N'AdventureWorks2014-Full Database Backup', 
SKIP, NOREWIND, NOUNLOAD,  STATS = 10
GO

-- transaction log backup (only for full recovery databases):

BACKUP LOG [AdventureWorks2014] TO  DISK = N'C:\backups\adventurework2014.bak' 
WITH 
NAME = N'AdventureWorks2014-Full Database Backup', 
STATS = 10
GO

--page restore from a backup:

RESTORE DATABASE [LSDB] PAGE='1:100' FROM  DISK = N'\\WIN-8QTMHAQME88\logshipping\backup\LSDB.bak' WITH  FILE = 1,  NORECOVERY,  NOUNLOAD,  STATS = 5
BACKUP LOG [LSDB] TO  DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\LSDB_LogBackup_2024-07-03_09-21-09.bak' WITH NOFORMAT, NOINIT,  NAME = N'LSDB_LogBackup_2024-07-03_09-21-09', NOSKIP, NOREWIND, NOUNLOAD,  STATS = 5
RESTORE LOG [LSDB] FROM  DISK = N'\\WIN-8QTMHAQME88\logshipping\backup\LSDB_20240617215925.trn' WITH  FILE = 1,  NORECOVERY,  NOUNLOAD,  STATS = 5
RESTORE LOG [LSDB] FROM  DISK = N'\\WIN-8QTMHAQME88\logshipping\backup\LSDB_20240617220000.trn' WITH  FILE = 1,  NORECOVERY,  NOUNLOAD,  STATS = 5
RESTORE LOG [LSDB] FROM  DISK = N'\\WIN-8QTMHAQME88\logshipping\backup\LSDB_20240617220959.trn' WITH  FILE = 1,  NORECOVERY,  NOUNLOAD,  STATS = 5
RESTORE LOG [LSDB] FROM  DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\LSDB_LogBackup_2024-07-03_09-21-09.bak' WITH  NOUNLOAD,  STATS = 5

GO

---validating backup:

declare @backupSetId as int 
select @backupSetId = position
from msdb..backupset
where database_name=N'AdventureWorks2014'
and backup_set_id=(select max(backup_set_id)
from msdb..backupset where database_name=N'AdventureWorks2014')
if @backupSetId is null
begin
raiserror(N'Verify failed. Backup information for database ‘’BackupDatabase’’ not found.', 16, 1)
end
RESTORE VERIFYONLY
FROM
DISK = N'C:\backups\adventurework2014.bak'
WITH FILE = @backupSetid
Go



--another way to do the above:

BACKUP DATABASE [CARDS] TO  DISK = N''D:\backups\CARDS_backup_2024_05_11_181534_9917052.bak'' WITH NOFORMAT, NOINIT,  NAME = N''CARDS_backup_2024_05_11_181534_9917052'', SKIP, REWIND, NOUNLOAD,  STATS = 10
GO
declare @backupSetId as int
select @backupSetId = position from msdb..backupset where database_name=N''CARDS'' and backup_set_id=(select max(backup_set_id) from msdb..backupset where database_name=N''CARDS'' )
if @backupSetId is null begin raiserror(N''Verify failed. Backup information for database ''''CARDS'''' not found.'', 16, 1) end
RESTORE VERIFYONLY FROM  DISK = N''D:\backups\CARDS_backup_2024_05_11_181534_9917052.bak'' WITH  FILE = @backupSetId,  NOUNLOAD,  NOREWIND





---validating database integerity with DBCC:
-- https://learn.microsoft.com/en-us/sql/t-sql/database-console-commands/dbcc-transact-sql?view=sql-server-ver16

DBCC CHECKDB
    [ ( database_name | database_id | 0
        [ , NOINDEX
        | , { REPAIR_ALLOW_DATA_LOSS | REPAIR_FAST | REPAIR_REBUILD } ]
    ) ]
    [ WITH
        {
            [ ALL_ERRORMSGS ]
            [ , EXTENDED_LOGICAL_CHECKS ]
            [ , NO_INFOMSGS ]
            [ , TABLOCK ]
            [ , ESTIMATEONLY ]
            [ , { PHYSICAL_ONLY | DATA_PURITY } ]
            [ , MAXDOP = number_of_processors ]
        }
    ]
]

--check db integerty
use master
DBCC CHECKDB (Kahreedo)

--or from within the db, you dont have to specify it:

DBCC CHECKDB

-- repair corrupted database but it will allow data lose, might be a bit too crazy in some situations.

dbcc REPAIR_ALLOW_DATA_LOSS

-- repair with no data lose

dbcc REPAIR_REBUILD

-- fast repair with no data lose

dbcc REPAIR_FAST

-- check for damaged pages in a table:

dbcc checktable (tblEmployee)

--check for damaged pages in a database:

dbcc checkdb (testdb) with PHYSICAL_ONLY

-- check which database the pages belongs to

dbcc checkalloc

--- shows the status of an indexed table statistics: 

DBCC SHOW_STATISTICS('HumanResources.Department','AK_Department_Name')

--- index physical status health query:

SELECT S.name as 'Schema',
T.name as 'Table',
I.name as 'Index',
DDIPS.avg_fragmentation_in_percent,
DDIPS.page_count
FROM sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL, NULL, NULL) AS DDIPS
INNER JOIN sys.tables T on T.object_id = DDIPS.object_id
INNER JOIN sys.schemas S on T.schema_id = S.schema_id
INNER JOIN sys.indexes I ON I.object_id = DDIPS.object_id
AND DDIPS.index_id = I.index_id
WHERE DDIPS.database_id = DB_ID()
and I.name is not null
AND DDIPS.avg_fragmentation_in_percent > 0
ORDER BY DDIPS.avg_fragmentation_in_percent desc

-- index REORGANIZE, less intrusive way to repair an index and can be done online under working hours

USE [WideWorldImporters]
GO
ALTER INDEX [FK_Sales_Orders_PickedByPersonID] ON [Sales].[Orders] REORGANIZE  WITH ( LOB_COMPACTION = ON )
GO

-- index rebuild, the below is a blocking offline operation and might effect database preformance,  

USE [WideWorldImporters]
GO
ALTER INDEX [IX_Sales_OrderLines_AllocatedStockItems] ON [Sales].[OrderLines] REBUILD PARTITION = ALL 
WITH 
(PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON)
GO

-- index rebuild, online non blocking version that is less impactful on the database

USE [WideWorldImporters]
GO
ALTER INDEX [IX_Sales_OrderLines_AllocatedStockItems] ON [Sales].[OrderLines] REBUILD PARTITION = ALL 
WITH 
(PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, 
ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 0 MINUTES, ABORT_AFTER_WAIT = NONE)), ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON)
GO

---check for changes on the database:

SELECT
tbl.name
,ius.last_user_update
,ius.user_updates
,ius.last_user_seek
,ius.last_user_scan
,ius.last_user_lookup
,ius.user_seeks
,ius.user_scans
,ius.user_lookups
FROM
sys.dm_db_index_usage_stats ius INNER JOIN
sys.tables tbl ON (tbl.OBJECT_ID = ius.OBJECT_ID)
WHERE ius.database_id = DB_ID()

--checking last modification date using information schema:

SELECT *
FROM sys.objects as so
INNER JOIN INFORMATION_SCHEMA.TABLES as ist
ON ist.TABLE_NAME=so.name 



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



-- resource governer classifyer function example:

CREATE FUNCTION fnTimeClassifier()  
RETURNS sysname  
WITH SCHEMABINDING  
AS  
BEGIN  
/* We recommend running the classifier function code under 
snapshot isolation level OR using NOLOCK hint to avoid blocking on 
lookup table. In this example, we are using NOLOCK hint. */
     DECLARE @strGroup sysname  
     DECLARE @loginTime time  
     SET @loginTime = CONVERT(time,GETDATE())  

	 if @loginTime > '6:15am' and @loginTime < '6:30pm'
	 begin 
	 return 'default'
	 end

	 ELSE
	 begin
	 return 'afterworkhours'
	 end

     RETURN N'gOffHoursProcessing'  
END;  
GO

ALTER RESOURCE GOVERNOR with (CLASSIFIER_FUNCTION = dbo.fnTimeClassifier);  
ALTER RESOURCE GOVERNOR RECONFIGURE;  
GO




---command to check for memory usage

SELECT SUBSTRING(st.text, er.statement_start_offset/2 + 1,(CASE WHEN er.statement_end_offset = -1 THEN LEN(CONVERT(nvarchar(max),st.text)) * 2 ELSE er.statement_end_offset END - er.statement_start_offset)/2) as Query_Text,tsu.session_id ,tsu.request_id, tsu.exec_context_id, (tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count) as OutStanding_user_objects_page_counts,(tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) as OutStanding_internal_objects_page_counts,er.start_time, er.command, er.open_transaction_count, er.percent_complete, er.estimated_completion_time, er.cpu_time, er.total_elapsed_time, er.reads,er.writes, er.logical_reads, er.granted_query_memory,es.host_name , es.login_name , es.program_name FROM sys.dm_db_task_space_usage tsu INNER JOIN sys.dm_exec_requests er ON ( tsu.session_id = er.session_id AND tsu.request_id = er.request_id) INNER JOIN sys.dm_exec_sessions es ON ( tsu.session_id = es.session_id ) CROSS APPLY sys.dm_exec_sql_text(er.sql_handle) st WHERE (tsu.internal_objects_alloc_page_count+tsu.user_objects_alloc_page_count) > 0
ORDER BY (tsu.user_objects_alloc_page_count - tsu.user_objects_dealloc_page_count)+ (tsu.internal_objects_alloc_page_count - tsu.internal_objects_dealloc_page_count) DESC



--- create azure storage secret:

CREATE CREDENTIAL [https://xxxx.blob.core.windows.net/xxxxx] 
WITH IDENTITY='SHARED ACCESS SIGNATURE', 
SECRET = 'sv=2018-03-28&ss=b&srt=sco&spxxxxxxxxxxxxxxxxxx'

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


--- finding backup history from msdb:

SELECT TOP 5000 bcks.database_name, bckMF.device_type, BackD.type_desc, BackD.physical_name, bckS.type, CASE bckS.[type] WHEN 'D' THEN 'Full'
WHEN 'I' THEN 'Differential'
WHEN 'L' THEN 'Transaction Log'
END AS BackupType, bckS.backup_start_date, bckS.backup_finish_date, 
convert(char(8),dateadd(s,datediff(s,bckS.backup_start_date, bckS.backup_finish_date),'1900-1-1'),8) AS BackupTimeFull,
convert(decimal(19,2),(bckS.backup_size *1.0) / power(2,20)) as [Backup Size(MB)],CAST(bcks.backup_size / 1073741824.0E AS DECIMAL(10, 2)) as [Backup Size(GB)] ,Convert(decimal(19,2),(bckS.compressed_backup_size *1.0) / power(2,20)) as [Compressed Backup Size(MB)]
, CAST(bcks.compressed_backup_size / 1073741824.0E AS DECIMAL(10, 2)) as [Compressed Backup Size(GB)],
software_name, is_compressed, is_copy_only, is_encrypted, physical_device_name,first_lsn, last_lsn, checkpoint_lsn, database_backup_lsn, user_name, @@SERVERNAME
FROM  msdb.dbo.backupset bckS INNER JOIN msdb.dbo.backupmediaset bckMS
ON bckS.media_set_id = bckMS.media_set_id
INNER JOIN msdb.dbo.backupmediafamily bckMF 
ON bckMS.media_set_id = bckMF.media_set_id
Left join sys.backup_devices BackD on bckMF.device_type = BackD.type
--where database_name='DBName'
ORDER BY bckS.backup_start_date DESC





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


-----find isolation level for locking

SELECT transaction_sequence_num,
       commit_sequence_num,
       is_snapshot,
       t.session_id,
       first_snapshot_sequence_num,
       max_version_chain_traversed,
       elapsed_time_seconds,
       host_name,
       login_name,
       CASE transaction_isolation_level
           WHEN '0' THEN
               'Unspecified'
           WHEN '1' THEN
               'ReadUncomitted'
           WHEN '2' THEN
               'ReadCommitted'
           WHEN '3' THEN
               'Repeatable'
           WHEN '4' THEN
               'Serializable'
           WHEN '5' THEN
               'Snapshot'
       END AS transaction_isolation_level
FROM sys.dm_tran_active_snapshot_database_transactions t
    JOIN sys.dm_exec_sessions s
        ON t.session_id = s.session_id;



---active transactions:

SELECT SP.SPID,[text] as SQLCode FROM
SYS.SYSPROCESSES SP
CROSS APPLY
SYS.dm_exec_sql_text(SP.[SQL_HANDLE])AS DEST WHERE OPEN_TRAN >= 1



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





