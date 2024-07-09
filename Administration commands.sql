
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

--------------------------------------------------------------------------


--replication
-- https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/replication-transactional-overview?view=azuresql

/*
 very important: You must connect to MSSMS with [server\instance] using the proper server name otherwise you will get the error: The Distributor has not been installed correctly. Could not enable database for publishing.
important: primary key is needed for transactional replication
important: is prone to domain user problems during initial creation for some reason. Use sql agent proccess user at first, then change it later.
update: above domain user errors were caused by the domain users not having permissons to run services. in an isolated controled domain, it worked fine. might need to enable tcp/ip and named aliases.
creating a publication from the gui is super easy, below script is for creating a publication using sql code.
*/
--==============================================================
-- replication - create publication - complete
-- marcelo miorelli
-- 06-Oct-2015
--==============================================================

select @@servername
select @@version
select @@spid
select @@servicename

--==============================================================
-- step 00 --  configuring the distributor
-- if there is already a distributor AND it is not healthy, 
-- you can have a look at the jobs related to this distributor and
-- MAYBE, if you need to get rid of it, run this step
-- generally you need to run this when adding a publication it says there is a problem with the distributor
--==============================================================

use master
go
sp_dropdistributor 
-- Could not drop the Distributor 'QG-V-SQL-TS\AIFS_DEVELOPMENT'. This Distributor has associated distribution databases.

EXEC sp_dropdistributor 
     @no_checks = 1
    ,@ignore_distributor = 1
GO

--==============================================================
-- step 01 --  configuring the distributor
-- tell this server who is the distributor and the admin password to connect there

-- create the distributor database
--==============================================================

use master
exec sp_adddistributor 
 @distributor = N'the_same_server'
,@heartbeat_interval=10
,@password='#J4g4nn4th4_the_password#'

USE master
EXEC sp_adddistributiondb 
    @database = 'dist1', 
    @security_mode = 1;
GO

exec sp_adddistpublisher @publisher = N'the_same_server', 
                         @distribution_db = N'dist1';
GO

--==============================================================
-- check thing out before going ahead and create the publications
--==============================================================

USE master;  
go  

--Is the current server a Distributor?  
--Is the distribution database installed?  
--Are there other Publishers using this Distributor?  
EXEC sp_get_distributor  

--Is the current server a Distributor?  
SELECT is_distributor FROM sys.servers WHERE name='repl_distributor' AND data_source=@@servername;  

--Which databases on the Distributor are distribution databases?  
SELECT name FROM sys.databases WHERE is_distributor = 1  

--What are the Distributor and distribution database properties?  
EXEC sp_helpdistributor;  
EXEC sp_helpdistributiondb;  
EXEC sp_helpdistpublisher;  

--==============================================================
-- here you need to have a distributor in place

-- Enabling the replication database
-- the name of the database we want to replicate is COLAFinance
--==============================================================
use master
exec sp_get_distributor


use master
exec sp_replicationdboption @dbname = N'the_database_to_publish', 
                            @optname = N'publish', 
                            @value = N'true'
GO


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