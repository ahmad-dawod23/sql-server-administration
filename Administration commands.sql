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



---validating backup set is valid:

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
















