
-- installing from docker:
-- 1) sql server run: docker run -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=ahmad@123' --name 'sql1' -p 1401:1433 -v sql1data:/var/opt/mssql -d mcr.microsoft.com/mssql/server:2022-latest
-- 2) enable sql agent from exec menu on docker desktop: /opt/mssql/bin/mssql-conf set sqlagent.enabled true
-- 3) copy backups into docker volumes, cd into the bak location then run this command: docker cp WideWorldImporters-Full.bak sql1:/var/opt/mssql/backup

-- tranfer database logins: https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/security/transfer-logins-passwords-between-instances

-- enable encryption in connection string: Column Encryption Setting=Enabled

-- data masking in sql server: https://learn.microsoft.com/en-us/sql/relational-databases/security/dynamic-data-masking?view=sql-server-ver16

-- row level security: https://www.sqlshack.com/introduction-to-row-level-security-in-sql-server/

-- sql server audits: https://learn.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-database-engine?view=sql-server-ver16

-- encrypting sql server connections: https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/configure-sql-server-encryption?view=sql-server-ver16

---get port number:

USE MASTER
GO
xp_readerrorlog 0, 1, N'Server is listening on'
GO

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

-- transaction log backup:

BACKUP LOG [AdventureWorks2014] TO  DISK = N'C:\backups\adventurework2014.bak' 
WITH 
NAME = N'AdventureWorks2014-Full Database Backup', 
STATS = 10
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

DBCC CHECKDB (Kahreedo)






--- enable target servers:



--CHANGE ENCRYPTION

DECLARE @encryptvalue int

DECLARE @keyinput varchar(200)

SET @keyinput = 'SOFTWARE\Microsoft\MSSQLSERVER\SQLServerAgent'

EXECUTE xp_instance_regread @rootkey='HKEY_LOCAL_MACHINE',@key=@keyinput,@value_name='MsxEncryptChannelOptions',@value =@encryptvalue OUTPUT

SELECT @encryptvalue

IF @encryptvalue = 2

BEGIN

PRINT 'SQL agent encryption level set to '+CONVERT(VARCHAR(1),@encryptvalue)+'. This will be changed to 1 for multi-server administration.'

EXECUTE xp_instance_regwrite @rootkey='HKEY_LOCAL_MACHINE', @key=@keyinput, @value_name='MsxEncryptChannelOptions',@type='REG_DWORD', @value=1

END

ELSE

BEGIN

PRINT 'SQL agent encryption level already set to '+CONVERT(VARCHAR(1),@encryptvalue)+'. Ready for multi-server administration.'

END

--ENLIST TARGET SERVER

USE msdb

GO

sp_msx_enlist @msx_server_name = 'yourmasterinstance'







