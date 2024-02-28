---get port number:

USE MASTER
GO
xp_readerrorlog 0, 1, N'Server is listening on'
GO

SELECT net_transport
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;

----

---find recovery model:
select [name], DATABASEPROPERTYEX([name],'recovery') as RecoveryMode
from sysdatabases

