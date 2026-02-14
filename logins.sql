-----------------------------------------------------------------------
-- LOGINS, SECURITY & PERMISSIONS AUDIT
-- Purpose : Audit server/database-level security: logins, roles,
--           permissions, orphaned users, and sysadmin membership.
-- Safety  : Most queries are read-only unless noted otherwise.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- SECTION 1: BASIC LOGIN INFORMATION
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.0 LOGIN TROUBLESHOOTING ("Login failed" diagnostics)
--     Use when investigating login failures.
-----------------------------------------------------------------------
-- Step 1: Capture the exact error state from error log
EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';

/*
Use Error_Code provided in Hex with "net helpmsg" cmd
For example Error_Code 0x139F -- net helpmsg 5023
*/

-- Step 2: Use Ring Buffer to find more information regarding login failures
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
ORDER BY rbf.timestamp DESC

-- Step 3: Pull out information from the connectivity ring buffer
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
ORDER BY rbf.timestamp DESC 

-- Step 4: Look for locked accounts, bad password counts, default DB issues
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

-- Step 5: Check if the default database exists and is ONLINE
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

-- Step 6: Check for hidden DENY on CONNECT SQL permission
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
-- 1.1 ALL LOGINS AND THEIR STATUS
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
-- 1.2 QUERY LIST OF EXISTING LOGINS
-----------------------------------------------------------------------
SELECT * FROM sys.server_principals WHERE type IN ('S','U','G');
GO

-----------------------------------------------------------------------
-- 1.3 QUERY LIST OF SQL SERVER LOGINS
-----------------------------------------------------------------------
SELECT * FROM sys.sql_logins;
GO

-----------------------------------------------------------------------
-- 1.4 QUERY AVAILABLE LOGON TOKENS
-----------------------------------------------------------------------
SELECT * FROM sys.login_token;
GO

-----------------------------------------------------------------------
-- 1.5 QUERY SECURITY IDs AT SERVER AND DATABASE LEVEL
-----------------------------------------------------------------------
SELECT name, principal_id, sid 
FROM sys.server_principals 
WHERE name = 'TestUser';

SELECT name, principal_id, sid 
FROM sys.database_principals 
WHERE name = 'TestUser';
GO

-----------------------------------------------------------------------
-- 1.6 CHECK SPECIFIC LOGIN
-----------------------------------------------------------------------
select * from master.dbo.syslogins where name = 'SOME_SUSER'
select * from master.sys.server_principals where name = 'SOME_USER'

-----------------------------------------------------------------------
-- 1.7 SHOW LOGIN INFO (Windows Login Details)
-----------------------------------------------------------------------
exec xp_logininfo 'DOMAIN\login'


-----------------------------------------------------------------------
-- SECTION 2: SERVER-LEVEL SECURITY AUDITS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 SYSADMIN MEMBERS
--     Review regularly — sysadmin should be tightly controlled.
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
-- 2.2 ALL SERVER ROLE MEMBERSHIPS
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
-- 2.3 SERVER-LEVEL PERMISSIONS (explicit GRANT / DENY)
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
-- SECTION 3: DATABASE-LEVEL SECURITY AUDITS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 DATABASE-LEVEL: USER-ROLE MEMBERSHIPS (current database)
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
-- 3.2 DATABASE-LEVEL PERMISSIONS (current database)
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
-- 3.3 USERS WITH db_owner ROLE (all databases)
--     Similar to sysadmin audit but at database level.
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
-- 3.4 SHOW ALL LOGINS AND MAPPINGS FOR SPECIFIC DATABASE
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


-----------------------------------------------------------------------
-- SECTION 4: PERMISSION ANALYSIS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.2 LIST ALL USER MAPPINGS WITH DATABASE ROLES/PERMISSIONS FOR A LOGIN
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
DROP TABLE #tempww


-----------------------------------------------------------------------
-- 4.4 TEST EFFECTIVE PERMISSIONS
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
REVERT


-----------------------------------------------------------------------
-- SECTION 5: ORPHANED USERS DETECTION & FIXING
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 ORPHANED USERS (current database)
--     Database users with no corresponding server login.
--     These accumulate after restores / migrations / login drops.
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
-- 5.2 ORPHANED USERS — ALL DATABASES (via sp_MSforeachdb)
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
-- 5.3 FIXING ORPHANED USERS
-----------------------------------------------------------------------
EXEC sp_change_users_login 'Report'
EXEC sp_change_users_login 'Auto_Fix', 'user'
ALTER USER dbuser WITH LOGIN = loginname; -- SQL Server 2005 SP2


-----------------------------------------------------------------------
-- SECTION 6: SECURITY CONFIGURATION CHECKS
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 6.1 SQL LOGINS WITH WEAK PASSWORD POLICY
--     Logins without CHECK_POLICY or CHECK_EXPIRATION.
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
-- 6.2 GUEST ACCESS CHECK
--     Guest should be disabled in all user databases.
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
-- 6.3 LINKED SERVER SECURITY AUDIT
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
-- 6.4 ENABLE LOGGING OF PERMISSION ERRORS TO THE ERROR LOG
-----------------------------------------------------------------------
EXEC msdb.dbo.sp_altermessage 229,'WITH_LOG','true';
GO

-----------------------------------------------------------------------
-- SECTION 7: CONFIGURATION EXAMPLES (Creating Logins & Users)
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 7.1 CREATE A WINDOWS LOGIN
-----------------------------------------------------------------------
CREATE LOGIN [ADVENTUREWORKS\user.name] FROM WINDOWS;
GO

-----------------------------------------------------------------------
-- 7.2 CREATE A SQL SERVER LOGIN
-----------------------------------------------------------------------
CREATE LOGIN James WITH PASSWORD = 'Pa$$w0rd';
GO

-----------------------------------------------------------------------
-- 7.3 CREATE SQL SERVER LOGIN WITHOUT POLICY CHECK
-----------------------------------------------------------------------
CREATE LOGIN HRApp WITH PASSWORD = 'Pa$$w0rd',
                        CHECK_POLICY = OFF;
GO

-----------------------------------------------------------------------
-- 7.4 ENABLE GUEST ACCOUNT
-----------------------------------------------------------------------
GRANT CONNECT TO guest;

-----------------------------------------------------------------------
-- 7.5 PREVENT GUEST USER FROM ACCESSING A DATABASE
-----------------------------------------------------------------------
REVOKE CONNECT FROM guest;

-----------------------------------------------------------------------
-- 7.6 MODIFY DATABASE OWNER
-----------------------------------------------------------------------
ALTER AUTHORIZATION ON DATABASE::MarketDev
  TO [ADVENTUREWORKS\Administrator];

-----------------------------------------------------------------------
-- 7.7 CREATE USER FOR LOGIN
-----------------------------------------------------------------------
CREATE USER James FOR LOGIN James;
GO

-----------------------------------------------------------------------
-- 7.8 CREATE USER NOT ASSOCIATED WITH A LOGIN (Contained Database User)
-----------------------------------------------------------------------
CREATE USER XRayApp WITH PASSWORD = 'Pa$$w0rd';
GO

