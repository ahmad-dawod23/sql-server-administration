/*********************************************************************************************
 * LOGINS, SECURITY & PERMISSIONS AUDIT
 * Purpose : Comprehensive guide for managing and auditing SQL Server security including:
 *           - Logins, server & database roles, permissions
 *           - Troubleshooting login failures
 *           - Orphaned users detection and fixing
 *           - Security configuration checks
 * Safety  : Most queries are read-only; modification queries are clearly marked
 *********************************************************************************************/

/*********************************************************************************************
 * TABLE OF CONTENTS
 *********************************************************************************************
 * SECTION 1:  LOGIN TROUBLESHOOTING & DIAGNOSTICS
 * SECTION 2:  BASIC LOGIN INFORMATION
 * SECTION 3:  SERVER-LEVEL SECURITY AUDITS
 * SECTION 4:  DATABASE-LEVEL SECURITY AUDITS
 * SECTION 5:  PERMISSION ANALYSIS & QUERIES
 * SECTION 6:  SERVER ROLES & MEMBERSHIPS
 * SECTION 7:  DATABASE ROLES & MEMBERSHIPS
 * SECTION 8:  ORPHANED USERS DETECTION & FIXING
 * SECTION 9:  SECURITY CONFIGURATION CHECKS
 * SECTION 10: CREATING & MANAGING LOGINS
 * SECTION 11: CREATING & MANAGING USERS
 * SECTION 12: GRANTING & REVOKING PERMISSIONS
 * SECTION 13: APPLICATION ROLES
 * SECTION 14: TESTING & VERIFICATION
 *********************************************************************************************/


/*********************************************************************************************
 * SECTION 1: LOGIN TROUBLESHOOTING & DIAGNOSTICS
 * Use these queries when investigating "Login failed" errors and connection issues
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 1.1 CAPTURE LOGIN FAILURE ERRORS FROM ERROR LOG
-----------------------------------------------------------------------
EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';

/*
Use Error_Code provided in Hex with "net helpmsg" cmd
For example Error_Code 0x139F -- net helpmsg 5023
*/

-----------------------------------------------------------------------
-- 1.2 CHECK FOR LOCKED ACCOUNTS AND BAD PASSWORD COUNTS
-----------------------------------------------------------------------
SELECT
    [name],
    LOGINPROPERTY([name], 'IsLocked')         AS IsLocked,
    LOGINPROPERTY([name], 'BadPasswordCount') AS BadPwdCount,
    LOGINPROPERTY([name], 'LockoutTime')      AS LockoutTime,
    default_database_name,
    is_disabled,
    create_date,
    modify_date
FROM sys.sql_logins
-- WHERE [name] = N'YourLoginName'
ORDER BY modify_date DESC;

-----------------------------------------------------------------------
-- 1.3 VERIFY DEFAULT DATABASE EXISTS AND IS ONLINE
-----------------------------------------------------------------------
SELECT
    sl.[name]                AS LoginName,
    sl.default_database_name AS DefaultDatabase,
    d.[name]                 AS ActualDatabaseName,
    d.state_desc             AS DatabaseState,
    CASE
        WHEN d.[name] IS NULL THEN '*** DEFAULT DB DOES NOT EXIST ***'
        WHEN d.state_desc <> 'ONLINE' THEN '*** DEFAULT DB IS OFFLINE ***'
        ELSE 'OK'
    END                      AS [Status]
FROM sys.sql_logins sl
    LEFT JOIN sys.databases d
        ON sl.default_database_name = d.[name]
-- WHERE sl.[name] = N'YourLoginName'
ORDER BY sl.[name];

-----------------------------------------------------------------------
-- 1.4 CHECK FOR DENIED CONNECT SQL PERMISSION
-----------------------------------------------------------------------
SELECT
    p.[name]           AS LoginName,
    perm.state_desc    AS PermissionState,
    perm.permission_name,
    CASE
        WHEN perm.state_desc = 'DENY' AND perm.permission_name = 'CONNECT SQL'
            THEN '*** LOGIN DENIED CONNECT SQL ***'
        ELSE 'OK'
    END                AS [Status]
FROM sys.server_permissions perm
    JOIN sys.server_principals p
        ON p.principal_id = perm.grantee_principal_id
WHERE perm.permission_name = 'CONNECT SQL'
  AND perm.state_desc = 'DENY'
-- AND p.[name] = N'YourLoginName'
ORDER BY p.[name];

-----------------------------------------------------------------------
-- 1.5 QUERY RING BUFFER FOR LOGIN FAILURE DETAILS
-----------------------------------------------------------------------
SELECT CONVERT (varchar(30), GETDATE(), 121) as [RunTime],
dateadd (ms, rbf.[timestamp] - tme.ms_ticks, GETDATE()) as [Notification_Time],
cast(record as xml).value('(//SPID)[1]', 'bigint') as SPID,
cast(record as xml).value('(//ErrorCode)[1]', 'varchar(255)') as Error_Code,
cast(record as xml).value('(//CallingAPIName)[1]', 'varchar(255)') as [CallingAPIName],
cast(record as xml).value('(//APIName)[1]', 'varchar(255)') as [APIName],
cast(record as xml).value('(//Record/@id)[1]', 'bigint') AS [Record Id],
cast(record as xml).value('(//Record/@type)[1]', 'varchar(30)') AS [Type],
cast(record as xml).value('(//Record/@time)[1]', 'bigint') AS [Record Time],
tme.ms_ticks as [Current Time]
from sys.dm_os_ring_buffers rbf cross join sys.dm_os_sys_info tme
where rbf.ring_buffer_type = 'RING_BUFFER_SECURITY_ERROR' -- and cast(record as xml).value('(//SPID)[1]', 'int') = XspidNo
ORDER BY rbf.timestamp DESC;
GO

-----------------------------------------------------------------------
-- 1.6 QUERY CONNECTIVITY RING BUFFER FOR CONNECTION DETAILS
-----------------------------------------------------------------------
SELECT CONVERT (varchar(30), GETDATE(), 121) as [RunTime],
dateadd (ms, (rbf.[timestamp] - tme.ms_ticks), GETDATE()) as Time_Stamp,
cast(record as xml).value('(//Record/ConnectivityTraceRecord/RecordType)[1]', 'varchar(50)') AS [Action],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/RecordSource)[1]', 'varchar(50)') AS [Source],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/Spid)[1]', 'int') AS [SPID],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/RemoteHost)[1]', 'varchar(100)') AS [RemoteHost],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/RemotePort)[1]', 'varchar(25)') AS [RemotePort],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/LocalPort)[1]', 'varchar(25)') AS [LocalPort],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsBuffersInformation/TdsInputBufferError)[1]', 'varchar(25)') AS [TdsInputBufferError],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsBuffersInformation/TdsOutputBufferError)[1]', 'varchar(25)') AS [TdsOutputBufferError],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsBuffersInformation/TdsInputBufferBytes)[1]', 'varchar(25)') AS [TdsInputBufferBytes],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/PhysicalConnectionIsKilled)[1]', 'int') AS [isPhysConnKilled],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/DisconnectDueToReadError)[1]', 'int') AS [DisconnectDueToReadError],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/NetworkErrorFoundInInputStream)[1]', 'int') AS [NetworkErrorFound],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/ErrorFoundBeforeLogin)[1]', 'int') AS [ErrorBeforeLogin],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/SessionIsKilled)[1]', 'int') AS [isSessionKilled],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/NormalDisconnect)[1]', 'int') AS [NormalDisconnect],
cast(record as xml).value('(//Record/ConnectivityTraceRecord/TdsDisconnectFlags/NormalLogout)[1]', 'int') AS [NormalLogout],
cast(record as xml).value('(//Record/@id)[1]', 'bigint') AS [Record Id],
cast(record as xml).value('(//Record/@type)[1]', 'varchar(30)') AS [Type],
cast(record as xml).value('(//Record/@time)[1]', 'bigint') AS [Record Time],
tme.ms_ticks as [Current Time]
FROM sys.dm_os_ring_buffers rbf
cross join sys.dm_os_sys_info tme
where rbf.ring_buffer_type = 'RING_BUFFER_CONNECTIVITY' and cast(record as xml).value('(//Record/ConnectivityTraceRecord/Spid)[1]', 'int') <> 0
ORDER BY rbf.timestamp DESC;
GO


/*********************************************************************************************
 * SECTION 2: BASIC LOGIN INFORMATION
 * Core queries for listing and examining logins in SQL Server
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 2.1 ALL LOGINS AND THEIR STATUS
-----------------------------------------------------------------------
SELECT
    sp.[name]                        AS LoginName,
    sp.[type_desc]                   AS LoginType,
    sp.is_disabled                   AS IsDisabled,
    sp.create_date                   AS CreatedDate,
    sl.is_policy_checked             AS PasswordPolicyEnforced,
    sl.is_expiration_checked         AS PasswordExpirationEnforced,
    sl.default_database_name         AS DefaultDatabase,
    sp.modify_date                   AS LastModified
FROM sys.server_principals sp
    LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
WHERE sp.[type] IN ('S', 'U', 'G')  -- SQL logins, Windows users, Windows groups
ORDER BY sp.[name];

-----------------------------------------------------------------------
-- 2.2 ALL SERVER PRINCIPALS (INCLUDING CERTIFICATES)
-----------------------------------------------------------------------
SELECT * FROM sys.server_principals;
GO

-----------------------------------------------------------------------
-- 2.3 SQL SERVER LOGINS ONLY
-----------------------------------------------------------------------
SELECT * FROM sys.sql_logins;
GO

-----------------------------------------------------------------------
-- 2.4 LIST OF EXISTING LOGINS (SQL, WINDOWS USERS, WINDOWS GROUPS)
-----------------------------------------------------------------------
SELECT * FROM sys.server_principals WHERE type IN ('S','U','G');
GO

-----------------------------------------------------------------------
-- 2.5 CHECK SPECIFIC LOGIN (MULTIPLE METHODS)
-----------------------------------------------------------------------
SELECT * FROM master.dbo.syslogins WHERE name = 'SOME_SUSER';
SELECT * FROM master.sys.server_principals WHERE name = 'SOME_USER';

-----------------------------------------------------------------------
-- 2.6 QUERY SECURITY IDS AT SERVER AND DATABASE LEVEL
-----------------------------------------------------------------------
SELECT name, principal_id, sid 
FROM sys.server_principals 
WHERE name = 'TestUser';

SELECT name, principal_id, sid 
FROM sys.database_principals 
WHERE name = 'TestUser';
GO

-----------------------------------------------------------------------
-- 2.7 QUERY AVAILABLE LOGON TOKENS
-----------------------------------------------------------------------
SELECT * FROM sys.login_token;
GO

-----------------------------------------------------------------------
-- 2.8 QUERY USER TOKENS (DATABASE LEVEL)
-----------------------------------------------------------------------
SELECT * FROM sys.user_token;
GO

-----------------------------------------------------------------------
-- 2.9 SHOW WINDOWS LOGIN DETAILS
-----------------------------------------------------------------------
EXEC xp_logininfo 'DOMAIN\login';
GO


/*********************************************************************************************
 * SECTION 3: SERVER-LEVEL SECURITY AUDITS
 * Critical queries for auditing server-level security and role memberships
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 3.1 SYSADMIN ROLE MEMBERS (REVIEW REGULARLY!)
--     Sysadmin should be tightly controlled
-----------------------------------------------------------------------
SELECT
    sp.[name]              AS LoginName,
    sp.[type_desc]         AS LoginType,
    sp.is_disabled         AS IsDisabled,
    sp.create_date         AS CreatedDate,
    sp.modify_date         AS ModifiedDate,
    sl.default_database_name AS DefaultDatabase
FROM sys.server_role_members srm
    JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
    LEFT JOIN sys.sql_logins   sl ON sp.principal_id = sl.principal_id
WHERE srm.role_principal_id = SUSER_ID('sysadmin')
ORDER BY sp.[name];

-----------------------------------------------------------------------
-- 3.2 ALL SERVER ROLE MEMBERSHIPS
-----------------------------------------------------------------------
SELECT
    sr.[name]              AS ServerRole,
    sp.[name]              AS MemberLogin,
    sp.[type_desc]         AS LoginType,
    sp.is_disabled         AS IsDisabled
FROM sys.server_role_members srm
    JOIN sys.server_principals sr ON srm.role_principal_id  = sr.principal_id
    JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
ORDER BY sr.[name], sp.[name];

-----------------------------------------------------------------------
-- 3.3 SERVER-LEVEL PERMISSIONS (EXPLICIT GRANT/DENY)
-----------------------------------------------------------------------
SELECT
    spe.state_desc                                AS PermissionState,
    spe.permission_name                           AS Permission,
    sp.[name]                                     AS Grantee,
    sp.[type_desc]                                AS GranteeType,
    sp2.[name]                                    AS Grantor
FROM sys.server_permissions spe
    JOIN sys.server_principals sp  ON spe.grantee_principal_id = sp.principal_id
    JOIN sys.server_principals sp2 ON spe.grantor_principal_id = sp2.principal_id
WHERE sp.[name] NOT LIKE '##%'           -- exclude internal certs
ORDER BY sp.[name], spe.permission_name;

-----------------------------------------------------------------------
-- 3.4 ALL SERVER-SCOPED PERMISSIONS
-----------------------------------------------------------------------
SELECT * FROM sys.server_permissions;
GO

-----------------------------------------------------------------------
-- 3.5 LIST SERVER PERMISSIONS GRANTED TO PRINCIPALS
-----------------------------------------------------------------------
SELECT 
    p.name AS PrincipalName,
    sp.permission_name AS PermissionName, 
    class_desc AS ClassDescription, 
    Major_id AS MajorID
FROM sys.server_permissions AS sp
INNER JOIN sys.server_principals AS p
    ON sp.grantee_principal_id = p.principal_id
ORDER BY p.name, sp.permission_name;
GO


/*********************************************************************************************
 * SECTION 4: DATABASE-LEVEL SECURITY AUDITS
 * Queries for auditing database-level security, roles, and permissions
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 4.1 ALL DATABASE PRINCIPALS (USERS, ROLES, ETC.)
-----------------------------------------------------------------------
SELECT * FROM sys.database_principals;
GO

-----------------------------------------------------------------------
-- 4.2 DATABASE USER-ROLE MEMBERSHIPS (CURRENT DATABASE)
-----------------------------------------------------------------------
SELECT
    DB_NAME()              AS DatabaseName,
    dp_role.[name]         AS DatabaseRole,
    dp_member.[name]       AS UserName,
    dp_member.[type_desc]  AS UserType,
    dp_member.create_date  AS CreatedDate
FROM sys.database_role_members drm
    JOIN sys.database_principals dp_role   ON drm.role_principal_id   = dp_role.principal_id
    JOIN sys.database_principals dp_member ON drm.member_principal_id = dp_member.principal_id
ORDER BY dp_role.[name], dp_member.[name];

-----------------------------------------------------------------------
-- 4.3 DATABASE-LEVEL PERMISSIONS (CURRENT DATABASE)
-----------------------------------------------------------------------
SELECT
    DB_NAME()                    AS DatabaseName,
    pe.state_desc                AS PermissionState,
    pe.permission_name           AS Permission,
    pe.class_desc                AS ObjectClass,
    ISNULL(SCHEMA_NAME(o.[schema_id]), '')
        + CASE WHEN o.[name] IS NOT NULL THEN '.' ELSE '' END
        + ISNULL(o.[name], '')   AS ObjectName,
    dp.[name]                    AS Grantee,
    dp.[type_desc]               AS GranteeType
FROM sys.database_permissions pe
    JOIN sys.database_principals dp ON pe.grantee_principal_id = dp.principal_id
    LEFT JOIN sys.objects o         ON pe.major_id = o.[object_id]
                                    AND pe.class_desc = 'OBJECT_OR_COLUMN'
WHERE dp.[name] NOT IN ('public', 'guest')
  AND dp.[name] NOT LIKE '##%'
ORDER BY dp.[name], pe.permission_name;

-----------------------------------------------------------------------
-- 4.4 ALL DATABASE PERMISSIONS (CURRENT DATABASE)
-----------------------------------------------------------------------
SELECT * FROM sys.database_permissions;
GO

-----------------------------------------------------------------------
-- 4.5 USERS WITH DB_OWNER ROLE (ALL DATABASES)
--     Similar to sysadmin audit but at database level
-----------------------------------------------------------------------
/*
EXEC sp_MSforeachdb '
USE [?];
SELECT
    DB_NAME()           AS DatabaseName,
    dp_member.[name]    AS UserName,
    dp_member.[type_desc] AS UserType
FROM sys.database_role_members drm
    JOIN sys.database_principals dp_role   ON drm.role_principal_id = dp_role.principal_id
    JOIN sys.database_principals dp_member ON drm.member_principal_id = dp_member.principal_id
WHERE dp_role.[name] = ''db_owner''
  AND dp_member.[name] <> ''dbo'';
';
*/

-----------------------------------------------------------------------
-- 4.6 SHOW ALL LOGINS AND MAPPINGS FOR SPECIFIC DATABASE
-----------------------------------------------------------------------
use DATABASE_NAME_HERE;
go
SELECT 
	susers.[name] AS LogInAtServerLevel,
	users.[name] AS UserAtDBLevel,
	DB_NAME() AS [Database],              
	roles.name AS DatabaseRoleMembership
 from sys.database_principals users
  inner join sys.database_role_members link
   on link.member_principal_id = users.principal_id
  inner join sys.database_principals roles
   on roles.principal_id = link.role_principal_id
   inner join sys.server_principals susers
   on susers.sid = users.sid
GO


/*********************************************************************************************
 * SECTION 5: PERMISSION ANALYSIS & QUERIES
 * Advanced permission analysis and effective permission testing
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 5.1 COMPARE ROLES BETWEEN DATABASES
-----------------------------------------------------------------------
SELECT 
    su.name AS 'RoleName', 
    su.uid AS 'RoleId', 
    su.isapprole AS 'IsAppRole',
    su2.name AS 'RoleName2'
FROM 
    [BizTalkDTADB.bak].dbo.sysusers su -- source
LEFT JOIN
    [BizTalkDTADB].dbo.sysusers su2
    ON su2.name = su.name
WHERE 
    su.issqlrole = 1
    OR su.isapprole = 1 
ORDER BY 
    su.name;
GO

-----------------------------------------------------------------------
-- 5.2 GENERATE SCRIPT TO COPY ROLE PERMISSIONS
-----------------------------------------------------------------------
DECLARE @RoleName VARCHAR(50);
SET @RoleName = 'HWS_ADMIN_USER';

DECLARE @Script VARCHAR(MAX);
SET @Script = 'CREATE ROLE ' + @RoleName + CHAR(13);

SELECT @script = @script + 'GRANT ' + prm.permission_name + ' ON ' 
    + OBJECT_NAME(major_id) + ' TO ' + rol.name + CHAR(13) COLLATE Latin1_General_CI_AS 
FROM sys.database_permissions prm
JOIN sys.database_principals rol 
    ON prm.grantee_principal_id = rol.principal_id
WHERE rol.name = @RoleName;

PRINT @script;
GO

-----------------------------------------------------------------------
-- 5.3 LIST ALL USER MAPPINGS WITH DATABASE ROLES/PERMISSIONS
-----------------------------------------------------------------------
CREATE TABLE #tempww (
    LoginName nvarchar(max),
    DBname nvarchar(max),
    Username nvarchar(max), 
    AliasName nvarchar(max)
)

INSERT INTO #tempww 
EXEC master..sp_msloginmappings 

-- display results
SELECT * 
FROM   #tempww 
ORDER BY dbname, username

-- cleanup
DROP TABLE #tempww;
GO

-----------------------------------------------------------------------
-- 5.4 TEST EFFECTIVE PERMISSIONS FOR A LOGIN
-----------------------------------------------------------------------
EXECUTE AS LOGIN = 'DOMAIN\login';
	SELECT * FROM fn_my_permissions(NULL, 'SERVER');
	GO
	
	use SKLFYOL01;
	GO
	
	SELECT * FROM fn_my_permissions (NULL, 'DATABASE');
	GO
	
	SELECT * FROM fn_my_permissions('SkySql.GetAllDataContext', 'OBJECT') 
    ORDER BY subentity_name, permission_name; 
    GO
REVERT;
GO

-----------------------------------------------------------------------
-- 5.5 CHECK ROLE MEMBERSHIP PROGRAMMATICALLY
--     IS_SRVROLEMEMBER tests for server role membership
--     IS_MEMBER tests for database role membership and Windows group membership
-----------------------------------------------------------------------
IF IS_MEMBER('BankManagers') = 0
BEGIN
    PRINT 'Operation is only for bank manager use';
    ROLLBACK;
END;
GO


/*********************************************************************************************
 * SECTION 6: SERVER ROLES & MEMBERSHIPS
 * Managing and auditing server-level roles
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 6.1 VIEW AVAILABLE FIXED SERVER ROLES
-----------------------------------------------------------------------
SELECT * FROM sys.server_principals WHERE type = 'R';
GO

-----------------------------------------------------------------------
-- 6.2 VIEW MEMBERS OF SERVER ROLES
-----------------------------------------------------------------------
SELECT 
    r.name AS RoleName,
    p.name AS PrincipalName 
FROM sys.server_role_members AS srm
INNER JOIN sys.server_principals AS r
    ON srm.role_principal_id = r.principal_id
INNER JOIN sys.server_principals AS p
    ON srm.member_principal_id = p.principal_id;
GO

-----------------------------------------------------------------------
-- 6.3 FIXED SERVER ROLES AND THEIR PERMISSIONS
-----------------------------------------------------------------------
/*
Fixed Server Roles:
    sysadmin      -- Perform any activity                    -- CONTROL SERVER (with GRANT option)
    dbcreator     -- Create and alter databases              -- ALTER ANY DATABASE
    diskadmin     -- Manage disk files                       -- ALTER RESOURCES
    serveradmin   -- Configure server-wide settings          -- ALTER ANY ENDPOINT, ALTER RESOURCES
                                                              -- ALTER SERVER STATE, ALTER SETTINGS
                                                              -- SHUTDOWN, VIEW SERVER STATE
    securityadmin -- Manage and audit server logins          -- ALTER ANY LOGIN
    processadmin  -- Manage SQL Server processes             -- ALTER ANY CONNECTION, ALTER SERVER STATE
    bulkadmin     -- Run the BULK INSERT statement           -- ADMINISTER BULK OPERATIONS
    setupadmin    -- Configure replication and linked servers -- ALTER ANY LINKED SERVER

Typical Server-Scoped Permissions:
    ALTER ANY DATABASE, BACKUP DATABASE, CONNECT SQL, CREATE DATABASE
    VIEW ANY DEFINITION, ALTER TRACE, BACKUP LOG, CONTROL SERVER
    SHUTDOWN, VIEW SERVER STATE
*/

-----------------------------------------------------------------------
-- 6.4 PUBLIC SERVER ROLE DEFAULT PERMISSIONS
-----------------------------------------------------------------------
/*
The public server role by default is granted:
    - VIEW ANY DATABASE permission
    - CONNECT permission on default endpoints
*/

-----------------------------------------------------------------------
-- 6.5 CREATE USER-DEFINED SERVER ROLE (SQL Server 2012+)
-----------------------------------------------------------------------
USE master;
GO
CREATE SERVER ROLE srv_documenters;
GO

-----------------------------------------------------------------------
-- 6.6 ADD LOGIN TO SERVER ROLE
-----------------------------------------------------------------------
ALTER SERVER ROLE serveradmin ADD MEMBER SampleLogin;
GO

ALTER SERVER ROLE sysadmin ADD MEMBER [AdventureWorks\Jeff.Hay];
GO

-----------------------------------------------------------------------
-- 6.7 REMOVE LOGIN FROM SERVER ROLE
-----------------------------------------------------------------------
ALTER SERVER ROLE serveradmin DROP MEMBER SampleLogin;
GO


/*********************************************************************************************
 * SECTION 7: DATABASE ROLES & MEMBERSHIPS
 * Managing and auditing database-level roles
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 7.1 VIEW AVAILABLE DATABASE ROLES (CURRENT DATABASE)
-----------------------------------------------------------------------
SELECT * FROM sys.database_principals WHERE type = 'R';
GO

-----------------------------------------------------------------------
-- 7.2 VIEW MEMBERS OF DATABASE ROLES (CURRENT DATABASE)
-----------------------------------------------------------------------
SELECT 
    r.name AS RoleName,
    p.name AS PrincipalName 
FROM sys.database_role_members AS drm
INNER JOIN sys.database_principals AS r
    ON drm.role_principal_id = r.principal_id
INNER JOIN sys.database_principals AS p
    ON drm.member_principal_id = p.principal_id;
GO

-----------------------------------------------------------------------
-- 7.3 FIXED DATABASE ROLES AND THEIR PERMISSIONS
-----------------------------------------------------------------------
/*
Fixed Database Roles:
    db_owner           -- Perform any configuration and maintenance activities on the DB and can drop it
    db_securityadmin   -- Modify role membership and manage permissions
    db_accessadmin     -- Add or remove access to the DB for logins
    db_backupoperator  -- Back up the DB
    db_ddladmin        -- Run any DDL command in the DB
    db_datawriter      -- Add, delete, or change data in all user tables
    db_datareader      -- Read all data from all user tables
    db_denydatawriter  -- Cannot add, delete, or change data in user tables
    db_denydatareader  -- Cannot read any data in user tables
*/

-----------------------------------------------------------------------
-- 7.4 ADD USER TO FIXED DATABASE ROLE
-----------------------------------------------------------------------
USE AdventureWorks;
GO
ALTER ROLE db_datareader ADD MEMBER James;
GO

USE MarketDev;
GO
ALTER ROLE db_owner ADD MEMBER [AdventureWorks\ITSupport];
GO
ALTER ROLE db_datareader ADD MEMBER DBMonitorApp;
GO

-----------------------------------------------------------------------
-- 7.5 REMOVE USER FROM DATABASE ROLE
-----------------------------------------------------------------------
USE AdventureWorks;
GO
ALTER ROLE db_backupoperator DROP MEMBER Mod10Login;
GO

-----------------------------------------------------------------------
-- 7.6 CREATE USER-DEFINED DATABASE ROLE
-----------------------------------------------------------------------
USE MarketDev;
GO

CREATE ROLE MarketingReaders AUTHORIZATION dbo;
GO

CREATE ROLE SalesTeam;
GO

CREATE ROLE SalesManagers;
GO

CREATE ROLE HR_LimitedAccess AUTHORIZATION dbo;
GO

-----------------------------------------------------------------------
-- 7.7 ADD MEMBERS TO USER-DEFINED DATABASE ROLE
-----------------------------------------------------------------------
ALTER ROLE MarketingReaders ADD MEMBER James;
GO

ALTER ROLE SalesTeam ADD MEMBER [AdventureWorks\SalesPeople];
GO
ALTER ROLE SalesTeam ADD MEMBER [AdventureWorks\CreditManagement];
GO
ALTER ROLE SalesTeam ADD MEMBER [AdventureWorks\CorporateManagers];
GO
ALTER ROLE SalesManagers ADD MEMBER [AdventureWorks\Darren.Parker];
GO

ALTER ROLE HR_LimitedAccess ADD MEMBER Mod10Login;
GO

-----------------------------------------------------------------------
-- 7.8 REMOVE MEMBER FROM USER-DEFINED DATABASE ROLE
-----------------------------------------------------------------------
ALTER ROLE HR_LimitedAccess DROP MEMBER Mod10Login;
GO

-----------------------------------------------------------------------
-- 7.9 DROP USER-DEFINED DATABASE ROLE
-----------------------------------------------------------------------
DROP ROLE HR_LimitedAccess;
GO


/*********************************************************************************************
 * SECTION 8: ORPHANED USERS DETECTION & FIXING
 * Identify and fix orphaned database users after restores/migrations
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 8.1 ORPHANED USERS (CURRENT DATABASE)
--     Database users with no corresponding server login
-----------------------------------------------------------------------
SELECT
    DB_NAME()           AS DatabaseName,
    dp.[name]           AS OrphanedUser,
    dp.[type_desc]      AS UserType,
    dp.create_date      AS CreatedDate,
    dp.[sid]            AS UserSID,
    'ALTER USER ' + QUOTENAME(dp.[name])
        + ' WITH LOGIN = ' + QUOTENAME(dp.[name]) + ';'
                        AS FixCommand
FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.[sid] = sp.[sid]
WHERE dp.[type] IN ('S', 'U')       -- SQL and Windows users
  AND sp.[sid] IS NULL
  AND dp.[name] NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
  AND dp.authentication_type <> 0   -- skip users without login (contained DB users)
ORDER BY dp.[name];

-----------------------------------------------------------------------
-- 8.2 ORPHANED USERS — ALL DATABASES (via sp_MSforeachdb)
-----------------------------------------------------------------------
/*
EXEC sp_MSforeachdb '
USE [?];
SELECT
    DB_NAME()   AS DatabaseName,
    dp.[name]   AS OrphanedUser,
    dp.[type_desc] AS UserType
FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.[sid] = sp.[sid]
WHERE dp.[type] IN (''S'', ''U'')
  AND sp.[sid] IS NULL
  AND dp.[name] NOT IN (''dbo'', ''guest'', ''INFORMATION_SCHEMA'', ''sys'')
  AND dp.authentication_type <> 0;
';
*/

-----------------------------------------------------------------------
-- 8.3 FIX ORPHANED USER
-----------------------------------------------------------------------
ALTER USER dbuser WITH LOGIN = loginname;
GO


/*********************************************************************************************
 * SECTION 9: SECURITY CONFIGURATION CHECKS
 * Auditing security configurations and potential vulnerabilities
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 9.1 SQL LOGINS WITH WEAK PASSWORD POLICY
--     Logins without CHECK_POLICY or CHECK_EXPIRATION
-----------------------------------------------------------------------
SELECT
    [name]                      AS LoginName,
    is_policy_checked           AS PasswordPolicyEnforced,
    is_expiration_checked       AS PasswordExpirationEnforced,
    create_date,
    modify_date,
    CASE
        WHEN is_policy_checked = 0 AND is_expiration_checked = 0
            THEN '*** BOTH DISABLED ***'
        WHEN is_policy_checked = 0
            THEN '* Policy off *'
        WHEN is_expiration_checked = 0
            THEN '* Expiration off *'
    END                         AS Warning
FROM sys.sql_logins
WHERE (is_policy_checked = 0 OR is_expiration_checked = 0)
  AND [name] NOT LIKE '##%'
  AND is_disabled = 0
ORDER BY [name];

-----------------------------------------------------------------------
-- 9.2 GUEST ACCESS CHECK
--     Guest should be disabled in all user databases
-----------------------------------------------------------------------
SELECT
    DB_NAME()   AS DatabaseName,
    dp.[name]   AS [Principal],
    pe.permission_name,
    pe.state_desc
FROM sys.database_permissions pe
    JOIN sys.database_principals dp ON pe.grantee_principal_id = dp.principal_id
WHERE dp.[name] = 'guest'
  AND pe.permission_name = 'CONNECT'
  AND pe.state_desc = 'GRANT'
  AND DB_ID() > 4;       -- skip system databases

-----------------------------------------------------------------------
-- 9.3 LINKED SERVER SECURITY AUDIT
-----------------------------------------------------------------------
SELECT
    s.[name]                         AS LinkedServerName,
    s.product                        AS Product,
    s.provider                       AS [Provider],
    s.data_source                    AS DataSource,
    ll.remote_name                   AS MappedRemoteLogin,
    ll.uses_self_credential          AS UsesSelfCredential,
    sp.[name]                        AS LocalLogin
FROM sys.servers s
    LEFT JOIN sys.linked_logins ll   ON s.server_id = ll.server_id
    LEFT JOIN sys.server_principals sp ON ll.local_principal_id = sp.principal_id
WHERE s.is_linked = 1
ORDER BY s.[name];

-----------------------------------------------------------------------
-- 9.4 ENABLE LOGGING OF PERMISSION ERRORS TO ERROR LOG
-----------------------------------------------------------------------
EXEC msdb.dbo.sp_altermessage 229,'WITH_LOG','true';
GO


/*********************************************************************************************
 * SECTION 10: CREATING & MANAGING LOGINS
 * Examples for creating and managing server-level logins
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 10.1 CREATE A WINDOWS LOGIN
-----------------------------------------------------------------------
CREATE LOGIN [ADVENTUREWORKS\user.name] FROM WINDOWS;
GO

-----------------------------------------------------------------------
-- 10.2 CREATE A SQL SERVER LOGIN
-----------------------------------------------------------------------
CREATE LOGIN James WITH PASSWORD = 'Pa$$w0rd';
GO

-----------------------------------------------------------------------
-- 10.3 CREATE SQL SERVER LOGIN WITHOUT POLICY CHECK
-----------------------------------------------------------------------
CREATE LOGIN HRApp WITH PASSWORD = 'Pa$$w0rd',
                        CHECK_POLICY = OFF;
GO

-----------------------------------------------------------------------
-- 10.4 RECREATE LOGIN FOR EXISTING USER (WITH SPECIFIC SID)
-----------------------------------------------------------------------
--IF EXISTS (
--    SELECT 1
--    FROM master.sys.server_principals
--    WHERE name = 'testuser'
--)
BEGIN
--    DROP LOGIN testuser;
--END
--
--CREATE LOGIN testuser
--    WITH PASSWORD = 'T5yqz7SP',
--    SID = 0x81341CD7A514D746A59712F660F31DE2,
--    DEFAULT_DATABASE = testdb,
--    DEFAULT_LANGUAGE = English,
--    CHECK_EXPIRATION = OFF,
--    CHECK_POLICY = ON;
GO


/*********************************************************************************************
 * SECTION 11: CREATING & MANAGING USERS
 * Examples for creating and managing database-level users
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 11.1 CREATE USER FOR LOGIN
-----------------------------------------------------------------------
CREATE USER James FOR LOGIN James;
GO

-----------------------------------------------------------------------
-- 11.2 CREATE USER NOT ASSOCIATED WITH A LOGIN (Contained Database User)
-----------------------------------------------------------------------
CREATE USER XRayApp WITH PASSWORD = 'Pa$$w0rd';
GO

-----------------------------------------------------------------------
-- 11.3 ENABLE GUEST ACCOUNT IN DATABASE
-----------------------------------------------------------------------
GO

-----------------------------------------------------------------------
-- 11.4 DISABLE GUEST USER FROM ACCESSING A DATABASE
-----------------------------------------------------------------------
REVOKE CONNECT FROM guest;
GO

-----------------------------------------------------------------------
-- 11.5 CHANGE DATABASE OWNER
-----------------------------------------------------------------------
ALTER AUTHORIZATION ON DATABASE::MarketDev
  TO [ADVENTUREWORKS\Administrator];
GO


/*********************************************************************************************
 * SECTION 12: GRANTING & REVOKING PERMISSIONS
 * Examples for managing object and schema-level permissions
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 12.1 GRANT OBJECT PERMISSION
-----------------------------------------------------------------------
USE MarketDev;
GO

GRANT SELECT ON OBJECT::Marketing.Salesperson TO HRApp;
GO

-- Alternative syntax (same result)
GRANT SELECT ON Marketing.Salesperson TO HRApp;
GO

-----------------------------------------------------------------------
-- 12.2 GRANT COLUMN-LEVEL PERMISSIONS
-----------------------------------------------------------------------
GRANT SELECT ON Marketing.Salesperson
    (SalespersonID, EmailAlias)
TO James;
GO

-----------------------------------------------------------------------
-- 12.3 GRANT WITH GRANT OPTION (USE WITH CAUTION!)
--      Allows grantee to grant permissions to others
--      Generally should be avoided
-----------------------------------------------------------------------
GRANT UPDATE ON Marketing.Salesperson
TO James
WITH GRANT OPTION;
GO

-----------------------------------------------------------------------
-- 12.4 REVOKE PERMISSIONS WITH CASCADE
--      CASCADE also revokes permissions granted by the grantee
--      Can also apply to DENY
-----------------------------------------------------------------------
REVOKE UPDATE ON Marketing.Salesperson
FROM James
CASCADE;
GO

-----------------------------------------------------------------------
-- 12.5 GRANT PERMISSIONS AT SCHEMA LEVEL
-----------------------------------------------------------------------
GRANT EXECUTE 
	ON SCHEMA::Marketing
	TO Mod11User;
GO

GRANT SELECT
	ON SCHEMA::DirectMarketing
	TO Mod11User;
GO

-----------------------------------------------------------------------
-- 12.6 DENY PERMISSIONS AT SCHEMA LEVEL
-----------------------------------------------------------------------
DENY SELECT ON SCHEMA::DirectMarketing TO [AdventureWorks\April.Reagan];
GO

-----------------------------------------------------------------------
-- 12.7 GRANT MULTIPLE PERMISSIONS AT SCHEMA LEVEL AND ON OBJECTS
-----------------------------------------------------------------------

GRANT EXECUTE ON SCHEMA::DirectMarketing TO SalesTeam;
GO

GRANT SELECT, UPDATE ON Marketing.SalesPerson TO [AdventureWorks\HumanResources];
GO

-----------------------------------------------------------------------
-- 12.8 GRANT EXECUTE PERMISSION ON STORED PROCEDURE
-----------------------------------------------------------------------
GRANT EXECUTE ON Marketing.MoveCampaignBalance TO SalesManagers;
GO


/*********************************************************************************************
 * SECTION 13: APPLICATION ROLES
 * Managing application roles for application-specific permissions
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 13.1 CREATE APPLICATION ROLE
--      Application roles enable permissions only when running specific applications
--      NOTE: Application role permissions replace user permissions!
-----------------------------------------------------------------------
USE MarketDev;
GO

CREATE APPLICATION ROLE MarketingApp WITH PASSWORD = 'Pa$$w0rd';
GO

-----------------------------------------------------------------------
-- 13.2 ASSIGN PERMISSIONS TO APPLICATION ROLE
-----------------------------------------------------------------------
GRANT SELECT ON SCHEMA::Marketing TO MarketingApp;
GO

-----------------------------------------------------------------------
-- 13.3 ACTIVATE APPLICATION ROLE
--      Use sp_setapprole to activate
--      Use sp_unsetapprole to deactivate
-----------------------------------------------------------------------
-- View current user tokens
SELECT * FROM sys.user_token;
GO

-- Set the application role
EXEC sp_setapprole MarketingApp, 'Pa$$w0rd';
GO

-- View updated user tokens (should show application role)
SELECT * FROM sys.user_token;
GO


/*********************************************************************************************
 * SECTION 14: TESTING & VERIFICATION
 * Queries for testing role assignments and verifying permissions
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 14.1 TEST USER TOKENS AND LOGIN CONTEXT
-----------------------------------------------------------------------
USE MarketDev;
GO

EXECUTE AS LOGIN = 'AdventureWorks\Darren.Parker';
GO

SELECT * FROM sys.login_token;
GO

SELECT * FROM sys.user_token;
GO

REVERT;
GO

-----------------------------------------------------------------------
-- END OF FILE
-----------------------------------------------------------------------