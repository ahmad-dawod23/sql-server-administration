
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





---search the logs:

USE MASTER
GO
xp_readerrorlog 0, 1, N'Login Failed'
GO

--find network protocol currently used

SELECT net_transport
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;

--- find out if TDS is enabled or not

SELECT DISTINCT net_transport AS [Transport Protocol],
               protocol_type AS [Protocol Type],
               endpoint_id   AS [Endpoint Id],
               auth_scheme   AS [Authentication Scheme]
FROM   sys.dm_exec_connections
WHERE  encrypt_option != 'TRUE'
      AND net_transport != 'Shared memory'
      AND (
           client_net_address COLLATE database_default not in (select ip_address_or_FQDN COLLATE database_default from sys.dm_hadr_fabric_nodes)
           AND protocol_type = 'Database Mirroring'
       )




--- shows the status of an indexed table statistics: 

DBCC SHOW_STATISTICS('HumanResources.Department','AK_Department_Name')

--- index physical status health query:


SELECT 
    dbschemas.name AS 'Schema',
    dbtables.name AS 'Table',
    dbindexes.name AS 'Index',
    indexstats.index_type_desc AS 'Index Type',
    indexstats.avg_fragmentation_in_percent AS 'Fragmentation (%)',
    indexstats.page_count AS 'Page Count'
	indexstats.alloc_unit_type_desc
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'DETAILED') AS indexstats
    INNER JOIN sys.tables AS dbtables ON indexstats.object_id = dbtables.object_id
    INNER JOIN sys.schemas AS dbschemas ON dbtables.schema_id = dbschemas.schema_id
    INNER JOIN sys.indexes AS dbindexes ON dbtables.object_id = dbindexes.object_id 
        AND indexstats.index_id = dbindexes.index_id
WHERE 
    indexstats.database_id = DB_ID()
ORDER BY 
    indexstats.avg_fragmentation_in_percent DESC;




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





---------- restores wait times



use master

SELECT
session_id as SPID,
command,
a.text AS Query,
start_time,
percent_complete,
CAST(((DATEDIFF(s,start_time,GETDATE()))/3600) AS VARCHAR) + ' hour(s), '
+ CAST((DATEDIFF(s,start_time,GETDATE())%3600)/60 AS VARCHAR) + 'min, '
+ CAST((DATEDIFF(s,start_time,GETDATE())%60) AS VARCHAR) + ' sec' AS running_time,
CAST((estimated_completion_time/3600000) AS VARCHAR) + ' hour(s), '
+ CAST((estimated_completion_time %3600000)/60000 AS VARCHAR) + 'min, '
+ CAST((estimated_completion_time %60000)/1000 as VARCHAR) + ' sec' AS est_time_to_go,
DATEADD(SECOND,estimated_completion_time/1000, GETDATE()) AS estimated_completion_time
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a
WHERE r.command IN ('BACKUP DATABASE','RESTORE DATABASE', 'BACKUP LOG','RESTORE LOG')





------ user level errors:


-- 1. Capture the exact error state
EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';

-- 2. Look for default-DB or lock-out issues
SELECT name,
       LOGINPROPERTY(name,'IsLocked')            AS IsLocked,
       LOGINPROPERTY(name,'BadPasswordCount')    AS BadPwdCnt,
       default_database_name
FROM sys.sql_logins
WHERE name = N'report_user';

-- 3. Does the default DB exist & is ONLINE?
SELECT name, state_desc
FROM sys.databases
WHERE name = (SELECT default_database_name FROM sys.sql_logins WHERE name=N'report_user');

-- 4. Any hidden DENY?
SELECT perm.state_desc
FROM sys.server_permissions AS perm
JOIN sys.server_principals  AS p ON p.principal_id = perm.grantee_principal_id
WHERE p.name = N'report_user' AND perm.permission_name = 'CONNECT SQL';




--- db encryption state

SELECT 	d.name,
 d.is_encrypted,
 dek.encryption_state,
 dek.percent_complete,
 dek.key_algorithm,
 dek.key_length
 FROM sys.databases as d 
 INNER JOIN sys.dm_database_encryption_keys AS dek 	ON d.database_id = dek.database_id
 
 
 
 
 --- email issues:
 
 
  USE msdb
 GO

-- Check that the service broker is enabled on MSDB. 
-- Is_broker_enabled must be 1 to use database mail.
SELECT is_broker_enabled FROM sys.databases WHERE name = 'msdb';
-- Check that Database mail is turned on. 
-- Run_value must be 1 to use database mail.
-- If you need to change it this option does not require
-- a server restart to take effect.
EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
EXEC sp_configure 'Database Mail XPs';

-- Check the Mail queues
-- This system stored procedure lists the two Database Mail queues.  
-- The optional @queue_type parameter tells it to only list that queue.
-- The list contains the length of the queue (number of emails waiting),
-- the state of the queue (INACTIVE, NOTIFIED, RECEIVES_OCCURRING, the 
-- last time the queue was empty and the last time the queue was active.
EXEC msdb.dbo.sysmail_help_queue_sp -- @queue_type = 'Mail' ;

-- Check the status (STARTED or STOPPED) of the sysmail database queues
-- EXEC msdb.dbo.sysmail_start_sp -- Start the queue
-- EXEC msdb.dbo.sysmail_stop_sp -- Stop the queue
EXEC msdb.dbo.sysmail_help_status_sp;

-- Check the different database mail settings.  
-- These are system stored procedures that list the general 
-- settings, accounts, profiles, links between the accounts
-- and profiles and the link between database principles and 
-- database mail profiles.
-- These are generally controlled by the database mail wizard.

EXEC msdb.dbo.sysmail_help_configure_sp;
EXEC msdb.dbo.sysmail_help_account_sp;
--  Check that your server name and server type are correct in the
--      account you are using.
--  Check that your email_address is correct in the account you are
--      using.
EXEC msdb.dbo.sysmail_help_profile_sp;
--  Check that you are using a valid profile in your dbmail command.
EXEC msdb.dbo.sysmail_help_profileaccount_sp;
--  Check that your account and profile are joined together
--      correctly in sysmail_help_profileaccount_sp.
EXEC msdb.dbo.sysmail_help_principalprofile_sp;

-- I’m doing a TOP 100 on these next several queries as they tend
-- to contain a great deal of data.  Obviously if you need to get
-- more than 100 rows this can be changed.
-- Check the database mail event log.
-- Particularly for the event_type of "error".  These are where you
-- will find the actual sending error.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_event_log 
ORDER BY last_mod_date DESC;

-- Check the actual emails queued
-- Look at sent_status to see 'failed' or 'unsent' emails.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_allitems 
ORDER BY last_mod_date DESC;

-- Check the emails that actually got sent. 
-- This is a view on sysmail_allitems WHERE sent_status = 'sent'
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_sentitems 
ORDER BY last_mod_date DESC;

-- Check the emails that failed to be sent.
-- This is a view on sysmail_allitems WHERE sent_status = 'failed'
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_faileditems 
ORDER BY last_mod_date DESC

-- Clean out unsent emails
-- Usually I do this before releasing the queue again after fixing the 
problem.
-- Assuming of course that I don't want to send out potentially thousands of 
-- emails that are who knows how old.
-- Obviously can be used to clean out emails of any status.
EXEC msdb.dbo.sysmail_delete_mailitems_sp  
  @sent_before =  '2017-03-16',
  @sent_status = 'failed';