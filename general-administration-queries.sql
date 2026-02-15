/*******************************************************************************
   GENERAL ADMINISTRATION QUERIES
   
   Purpose: Miscellaneous administration queries for SQL Server that don't
            fit into specialized categories.
            
   Sections:
   1. Error Log & Diagnostics
   2. Network Protocol & Connection Security
   3. Database Information Queries
   4. DMV Reference Guide
   5. DBCC Commands & Page Analysis
   6. Troubleshooting & Recovery
   7. System Commands (xp_cmdshell)
   
   Note: For specialized topics (backups, security, TDE, performance, etc.),
         see the dedicated script files in the parent directory.
*******************************************************************************/

USE MASTER;
GO

/*******************************************************************************
   SECTION 1: ERROR LOG & DIAGNOSTICS
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 Search Error Log for Permission Issues
-----------------------------------------------------------------------
EXEC xp_readerrorlog 0, 1, N'permission', NULL, NULL, NULL, N'desc';
GO

-----------------------------------------------------------------------
-- 1.2 Search Error Log for Login Failures
--      Note: Also see security-and-permissions-audit.sql for detailed
--            login auditing queries
-----------------------------------------------------------------------
-- EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';
-- GO



/*******************************************************************************
   SECTION 2: NETWORK PROTOCOL & CONNECTION SECURITY
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 Current Session Network Protocol
--      Identify the transport protocol for your current connection
-----------------------------------------------------------------------
SELECT
    session_id,
    net_transport,
    protocol_type,
    auth_scheme,
    encrypt_option
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
GO

-----------------------------------------------------------------------
-- 2.2 Non-Encrypted TDS Connections (Azure SQL MI)
--      Find unencrypted connections that aren't using Shared Memory
--      and aren't internal AG/MI Link traffic
-----------------------------------------------------------------------
SELECT DISTINCT
    net_transport                AS [Transport Protocol],
    protocol_type                AS [Protocol Type],
    endpoint_id                  AS [Endpoint Id],
    auth_scheme                  AS [Authentication Scheme],
    COUNT(*)                     AS ConnectionCount
FROM sys.dm_exec_connections
WHERE encrypt_option != 'TRUE'
  AND net_transport != 'Shared memory'
  AND (
        client_net_address COLLATE database_default
            NOT IN (SELECT ip_address_or_FQDN COLLATE database_default
                    FROM sys.dm_hadr_fabric_nodes)
        OR protocol_type != 'Database Mirroring'
      )
GROUP BY net_transport, protocol_type, endpoint_id, auth_scheme
ORDER BY ConnectionCount DESC;
GO



/*******************************************************************************
   SECTION 3: DATABASE INFORMATION QUERIES
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 List All Databases
-----------------------------------------------------------------------
SELECT
    database_id,
    name AS database_name,
    state_desc,
    recovery_model_desc,
    compatibility_level
FROM sys.databases
ORDER BY name;
GO

-----------------------------------------------------------------------
-- 3.2 Get Database ID by Name
-----------------------------------------------------------------------
-- SELECT DB_ID('AdventureWorks2012');
-- GO

-----------------------------------------------------------------------
-- 3.3 Get Database Name by ID
-----------------------------------------------------------------------
-- SELECT DB_NAME(8);
-- GO


/*******************************************************************************
   SECTION 4: DMV REFERENCE GUIDE
   
   Quick reference for Dynamic Management Views and Functions organized by prefix.
*******************************************************************************/

/*
   sys.dm_exec_%  -- Execution and Connection
      Provides information about connections, sessions, requests, and query execution.
      Example: sys.dm_exec_sessions provides one row for every session currently
               connected to the server.

   sys.dm_os_%    -- SQL OS Related Information
      Provides access to SQL OS related information.
      Example: sys.dm_os_performance_counters provides access to SQL Server performance
               counters without the need to access them using operating system tools.

   sys.dm_tran_%  -- Transaction Management
      Provides access to transaction management information.
      Example: sys.dm_tran_active_transactions provides details of currently active
               transactions.

   sys.dm_io_%    -- I/O Related Information
      Provides information on I/O processes.
      Example: sys.dm_io_virtual_file_stats provides details of I/O performance and
               statistics for each database file.

   sys.dm_db_%    -- Database Scoped Information
      Provides database-scoped information.
      Example: sys.dm_db_index_usage_stats provides information about how each index
               in the database has been used.
*/



/*******************************************************************************
   SECTION 5: DBCC COMMANDS & PAGE ANALYSIS
*******************************************************************************/

-----------------------------------------------------------------------
-- 5.1 DBCC Trace Status
--      View current trace flag settings
-----------------------------------------------------------------------
-- View all trace flags applying to the connection
DBCC TRACESTATUS(-1);
GO

-- View specific trace flag (3604 - enables output to console)
-- DBCC TRACESTATUS(3604);
-- GO

-----------------------------------------------------------------------
-- 5.2 Enable DBCC Output
--      Enable trace flag 3604 to show hidden DBCC output
-----------------------------------------------------------------------
-- DBCC TRACEON(3604);
-- GO

-----------------------------------------------------------------------
-- 5.3 DBCC PAGE - Analyze Page Data
--      Format: DBCC PAGE(database_id, file_id, page_number, output_option)
--      Output Options: 0=header only, 1=header+hex, 2=header+detailed, 3=all
-----------------------------------------------------------------------
-- Example: View page 1472 from file 1 in database ID 8
-- DBCC PAGE(8, 1, 1472, 3);
-- GO

-----------------------------------------------------------------------
-- 5.4 Physical Location Formatter
--      Display physical location of rows in a table
--      Format: (file_id:page_id:slot_id)
-----------------------------------------------------------------------
/*
-- Example using AdventureWorks2012
SELECT
    sys.fn_PhysLocFormatter(%%physloc%%) AS [Physical Location],
    BusinessEntityID,
    FirstName,
    LastName
FROM [AdventureWorks2012].[Person].[Person]
WHERE BusinessEntityID < 100
ORDER BY [Physical Location];
GO
*/



/*******************************************************************************
   SECTION 6: TROUBLESHOOTING & RECOVERY
*******************************************************************************/

-----------------------------------------------------------------------
-- 6.1 Emergency SA Password Recovery
--      Use when SQL Server instance is inaccessible and no one remembers
--      the sa password. Requires local Administrator access.
-----------------------------------------------------------------------
/*
   PROCEDURE:
   
   1. Stop SQL Server service (if running)
   
   2. Start SQL Server in single-user mode with SQLCMD parameter:
      C:\Windows\system32> net start MSSQLSERVER /mSQLCMD
      
      Output:
      The SQL Server (MSSQLSERVER) service is starting.
      The SQL Server (MSSQLSERVER) service was started successfully.
   
   3. Connect using Windows Authentication and create/promote login:
      C:\Windows\system32> sqlcmd -S. -E
      1> CREATE LOGIN [domain\username] FROM WINDOWS;
      2> ALTER SERVER ROLE sysadmin ADD MEMBER [domain\username];
      3> GO
   
   4. Restart SQL Server normally:
      C:\Windows\system32> net stop MSSQLSERVER
      C:\Windows\system32> net start MSSQLSERVER
*/


/*******************************************************************************
   SECTION 7: SYSTEM COMMANDS (xp_cmdshell)
   
   Warning: xp_cmdshell must be enabled and should only be used by authorized
            administrators. These commands execute with SQL Server service account
            privileges.
*******************************************************************************/

-----------------------------------------------------------------------
-- 7.1 Enable xp_cmdshell (if needed)
-----------------------------------------------------------------------
/*
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO
EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 7.2 Execute Directory Listing
-----------------------------------------------------------------------
-- EXEC xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 7.3 Map Network Share
--      Map a network drive for backup/restore operations
-----------------------------------------------------------------------
/*
-- Map network share T: with credentials
EXEC xp_cmdshell 'net use T: \\10.216.224.25\shared password123 /USER:builtin\dbbackup';
GO

-- Verify mapping
EXEC xp_cmdshell 'dir T:\';
GO

-- Disconnect mapped drive
EXEC xp_cmdshell 'net use T: /delete';
GO
*/


/*******************************************************************************
   END OF FILE
*******************************************************************************/
