/*********************************************************************************************
 * LOGINS, SECURITY & PERMISSIONS AUDIT
 * Purpose : Comprehensive guide for managing and auditing SQL Server security including:
 *           - Logins, server & database roles, permissions
 *           - Troubleshooting login failures
 *           - Orphaned users detection and fixing
 *           - Security configuration checks
 * Safety  : Sections 1-9 are read-only diagnostics and are safe to run as-is.
 *           Sections 10-14 contain DDL and configuration changes. Every statement
 *           in those sections is COMMENTED OUT BY DESIGN. Replace the placeholder
 *           names, then uncomment one statement at a time, deliberately.
 *           Read-only queries that change session context (USE, EXECUTE AS) are
 *           also commented out.
 * Platform: Written for SQL Server (on-premises / IaaS). Where a query is
 *           unavailable or behaves differently on Azure SQL Managed Instance or
 *           Azure SQL Database, an inline NOTE calls it out.
 *********************************************************************************************/

/*********************************************************************************************
 * TABLE OF CONTENTS
 *********************************************************************************************
 * SECTION 1:  LOGIN TROUBLESHOOTING & DIAGNOSTICS         [read-only]
 * SECTION 2:  BASIC LOGIN INFORMATION                     [read-only]
 * SECTION 3:  SERVER-LEVEL SECURITY AUDITS                [read-only]
 * SECTION 4:  DATABASE-LEVEL SECURITY AUDITS              [read-only]
 * SECTION 5:  PERMISSION ANALYSIS & QUERIES               [read-only]
 * SECTION 6:  SERVER ROLES & MEMBERSHIPS                  [read-only + commented DDL]
 * SECTION 7:  DATABASE ROLES & MEMBERSHIPS                [read-only + commented DDL]
 * SECTION 8:  ORPHANED USERS DETECTION & FIXING           [read-only + commented DDL]
 * SECTION 9:  SECURITY CONFIGURATION CHECKS               [read-only + commented DDL]
 * SECTION 10: CREATING & MANAGING LOGINS                  *** ALL DDL - COMMENTED ***
 * SECTION 11: CREATING & MANAGING USERS                   *** ALL DDL - COMMENTED ***
 * SECTION 12: GRANTING & REVOKING PERMISSIONS             *** ALL DDL - COMMENTED ***
 * SECTION 13: APPLICATION ROLES                           *** ALL DDL - COMMENTED ***
 * SECTION 14: TESTING & VERIFICATION                      *** CONTEXT SWITCH - COMMENTED ***
 *********************************************************************************************/


/*********************************************************************************************
 * SECTION 1: LOGIN TROUBLESHOOTING & DIAGNOSTICS
 * Use these queries when investigating "Login failed" errors and connection issues
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 1.1 CAPTURE LOGIN FAILURE ERRORS FROM ERROR LOG
--     Params: LogNumber, LogType (1 = SQL Server), Search1, Search2,
--             StartDate, EndDate, SortOrder
--     NOTE: Available on SQL Server and Azure SQL Managed Instance.
--           Not available on Azure SQL Database.
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
--     NOTE: Ring buffers exist on SQL Server and Azure SQL Managed
--           Instance. They are not available on Azure SQL Database.
--     NOTE: The timestamp math deliberately works in SECONDS. DATEADD's
--           second argument is an int, and the millisecond difference
--           overflows int once server uptime exceeds ~24.8 days,
--           producing "Arithmetic overflow error converting expression
--           to data type int".
-----------------------------------------------------------------------
SELECT CONVERT (varchar(30), GETDATE(), 121) as [RunTime],
DATEADD (s, CONVERT(int, (rbf.[timestamp] - tme.ms_ticks) / 1000), GETDATE()) as [Notification_Time],
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
--     NOTE: See the two notes on 1.5 - same platform limits and same
--           int-overflow reason for using seconds in the DATEADD.
-----------------------------------------------------------------------
SELECT CONVERT (varchar(30), GETDATE(), 121) as [RunTime],
DATEADD (s, CONVERT(int, (rbf.[timestamp] - tme.ms_ticks) / 1000), GETDATE()) as Time_Stamp,
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
--     NOTE: master.dbo.syslogins is a deprecated backward-compatibility
--           view. Prefer sys.server_principals / sys.sql_logins.
-----------------------------------------------------------------------
DECLARE @LoginName sysname = N'YourLoginName';

SELECT * FROM master.sys.server_principals WHERE [name] = @LoginName;
SELECT * FROM master.sys.sql_logins        WHERE [name] = @LoginName;
SELECT * FROM master.dbo.syslogins         WHERE [name] = @LoginName;   -- deprecated
GO

-----------------------------------------------------------------------
-- 2.6 QUERY SECURITY IDS AT SERVER AND DATABASE LEVEL
--     A mismatch between the two SIDs is what makes a user orphaned.
--     See Section 8.
-----------------------------------------------------------------------
SELECT name, principal_id, sid 
FROM sys.server_principals 
WHERE name = N'YourLoginName';

SELECT name, principal_id, sid 
FROM sys.database_principals 
WHERE name = N'YourUserName';
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
--     Expands a Windows group into its members, which is the usual way
--     to find out who really has access through a group.
--     NOTE: Not supported on Azure SQL Managed Instance or Azure SQL
--           Database (no Windows authentication there - use Microsoft
--           Entra ID principals instead).
-----------------------------------------------------------------------
-- EXEC xp_logininfo 'DOMAIN\login';
-- EXEC xp_logininfo 'DOMAIN\groupname', 'members';
GO

-----------------------------------------------------------------------
-- 2.10 CURRENTLY CONNECTED LOGINS
--      Who is connected right now, from where, and under what
--      authentication scheme. Useful before disabling or dropping a
--      login, and for spotting shared/service accounts.
-----------------------------------------------------------------------
SELECT
    s.login_name                     AS LoginName,
    s.original_login_name            AS OriginalLoginName,   -- differs when EXECUTE AS is active
    s.[status]                       AS SessionStatus,
    c.auth_scheme                    AS AuthScheme,          -- SQL / NTLM / KERBEROS
    c.encrypt_option                 AS EncryptOption,
    s.[host_name]                    AS HostName,
    s.[program_name]                 AS ProgramName,
    c.client_net_address             AS ClientAddress,
    DB_NAME(s.database_id)           AS DatabaseName,
    COUNT(*) OVER (PARTITION BY s.login_name) AS SessionsForLogin,
    s.login_time                     AS LoginTime,
    s.last_request_end_time          AS LastRequestEnd
FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_connections c
        ON s.session_id = c.session_id
WHERE s.is_user_process = 1
ORDER BY s.login_name, s.login_time;
GO


/*********************************************************************************************
 * SECTION 3: SERVER-LEVEL SECURITY AUDITS
 * Critical queries for auditing server-level security and role memberships
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 3.1 SYSADMIN ROLE MEMBERS (REVIEW REGULARLY!)
--     Sysadmin should be tightly controlled.
--     CAVEAT 1: If a Windows GROUP is a member, every member of that
--               group is effectively a sysadmin. This query shows the
--               group, not its members - expand it with 2.9
--               (xp_logininfo 'DOMAIN\group', 'members').
--     CAVEAT 2: Sysadmin is not the only path to full control. Also
--               review CONTROL SERVER grants (see 3.3) and any login
--               with IMPERSONATE on a sysadmin.
-----------------------------------------------------------------------
SELECT
    sp.[name]              AS LoginName,
    sp.[type_desc]         AS LoginType,
    sp.is_disabled         AS IsDisabled,
    sp.create_date         AS CreatedDate,
    sp.modify_date         AS ModifiedDate,
    sl.default_database_name AS DefaultDatabase
FROM sys.server_role_members srm
    JOIN sys.server_principals sr ON srm.role_principal_id   = sr.principal_id
    JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
    LEFT JOIN sys.sql_logins   sl ON sp.principal_id = sl.principal_id
WHERE sr.[name] = N'sysadmin'
ORDER BY sp.[name];

-- Logins holding CONTROL SERVER (equivalent to sysadmin in practice)
SELECT
    sp.[name]          AS LoginName,
    sp.[type_desc]     AS LoginType,
    perm.state_desc    AS PermissionState
FROM sys.server_permissions perm
    JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id
WHERE perm.permission_name = 'CONTROL SERVER'
  AND perm.state_desc IN ('GRANT', 'GRANT_WITH_GRANT_OPTION')
  AND sp.[name] NOT LIKE '##%'
ORDER BY sp.[name];

-----------------------------------------------------------------------
-- 3.2 ALL SERVER ROLE MEMBERSHIPS
--     Canonical version. Sections 6.2 refers back to this query.
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
--     Canonical version. Section 7.2 refers back to this query.
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
--     NOTE: sp_MSforeachdb is undocumented and unsupported. It silently
--           skips databases in some builds and is not available on
--           Azure SQL Database. For anything you rely on, build the
--           loop yourself over sys.databases with sp_executesql, or use
--           Aaron Bertrand's sp_foreachdb replacement.
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
--     Uncomment the USE and set the database name, or just run the
--     SELECT against whatever database is currently selected.
-----------------------------------------------------------------------
-- USE YourDatabaseName;
-- GO
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
-- 5.1 COMPARE ROLES BETWEEN TWO DATABASES
--     Useful after a restore or migration. Rows where RoleInTarget is
--     NULL exist in the source but are MISSING in the target.
--     Replace SourceDatabase / TargetDatabase, then uncomment.
-----------------------------------------------------------------------
/*
SELECT 
    src.[name]          AS RoleInSource, 
    src.principal_id    AS SourcePrincipalId,
    src.[type_desc]     AS RoleType,
    tgt.[name]          AS RoleInTarget
FROM [SourceDatabase].sys.database_principals src
LEFT JOIN [TargetDatabase].sys.database_principals tgt
    ON tgt.[name] = src.[name]
WHERE src.[type] IN ('R', 'A')      -- R = database role, A = application role
  AND src.is_fixed_role = 0
  AND src.[name] <> 'public'
ORDER BY src.[name];
*/
GO

-----------------------------------------------------------------------
-- 5.2 GENERATE SCRIPT TO COPY ROLE PERMISSIONS
--     Prints (does not execute) a CREATE ROLE + GRANT/DENY script for
--     one database role, so you can replay it in another database.
--     Run in the database that owns the role.
--
--     The class filter is important: without it, database-scoped
--     permissions (class 0, major_id 0) make OBJECT_NAME() return NULL,
--     which nulls out the whole @Script variable and prints nothing.
-----------------------------------------------------------------------
DECLARE @RoleName sysname = N'YourRoleName';
DECLARE @Script   nvarchar(max);

SET @Script = N'CREATE ROLE ' + QUOTENAME(@RoleName) + N';' + CHAR(13) + CHAR(10);

SELECT @Script = @Script
     + CASE prm.state WHEN 'W' THEN N'GRANT'
                      ELSE prm.state_desc COLLATE DATABASE_DEFAULT END
     + N' ' + prm.permission_name COLLATE DATABASE_DEFAULT
     + CASE prm.class
           WHEN 0 THEN N''                                    -- database scope
           WHEN 1 THEN N' ON OBJECT::'
                       + QUOTENAME(OBJECT_SCHEMA_NAME(prm.major_id))
                       + N'.' + QUOTENAME(OBJECT_NAME(prm.major_id))
                       + ISNULL(N' (' + QUOTENAME(c.[name]) + N')', N'')
           WHEN 3 THEN N' ON SCHEMA::' + QUOTENAME(SCHEMA_NAME(prm.major_id))
       END
     + N' TO ' + QUOTENAME(rol.[name])
     + CASE prm.state WHEN 'W' THEN N' WITH GRANT OPTION' ELSE N'' END
     + N';' + CHAR(13) + CHAR(10)
FROM sys.database_permissions prm
JOIN sys.database_principals rol 
    ON prm.grantee_principal_id = rol.principal_id
LEFT JOIN sys.columns c
    ON prm.class = 1
   AND c.[object_id] = prm.major_id
   AND c.column_id  = prm.minor_id
WHERE rol.[name] = @RoleName
  AND prm.class IN (0, 1, 3)        -- database, object/column, schema
ORDER BY prm.class, prm.major_id, prm.permission_name;

PRINT @Script;
GO

-----------------------------------------------------------------------
-- 5.3 LIST ALL USER MAPPINGS WITH DATABASE ROLES/PERMISSIONS
--     NOTE: sp_msloginmappings is undocumented and unsupported. It is
--           not available on Azure SQL Database / Managed Instance.
--           Section 4.6 (run per database) is the supported equivalent.
-----------------------------------------------------------------------
IF OBJECT_ID('tempdb..#tempww') IS NOT NULL
    DROP TABLE #tempww;

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
--     Impersonates a login and reports what it can actually do.
--     *** CHANGES SESSION CONTEXT - UNCOMMENT AND RUN DELIBERATELY ***
--     Requires IMPERSONATE on the target login (sysadmin has it).
--     ALWAYS run REVERT afterwards, otherwise the rest of your session
--     keeps running as the impersonated login.
--     NOTE: EXECUTE AS LOGIN persists across GO batches in the same
--           session. Switching databases while impersonating requires
--           the impersonated login to have access to that database.
-----------------------------------------------------------------------
/*
EXECUTE AS LOGIN = 'DOMAIN\login';
GO

    -- Server-scoped effective permissions
    SELECT * FROM fn_my_permissions(NULL, 'SERVER');
    GO

    USE YourDatabaseName;
    GO

    -- Database-scoped effective permissions
    SELECT * FROM fn_my_permissions(NULL, 'DATABASE');
    GO

    -- Object-scoped effective permissions
    SELECT * FROM fn_my_permissions('YourSchema.YourObject', 'OBJECT')
    ORDER BY subentity_name, permission_name;
    GO

REVERT;
GO
*/

-----------------------------------------------------------------------
-- 5.5 CHECK ROLE MEMBERSHIP PROGRAMMATICALLY
--     IS_SRVROLEMEMBER tests for server role membership
--     IS_MEMBER tests for database role membership and Windows group
--     membership. Both return NULL if the role/group does not exist,
--     so test for = 0 AND IS NULL if you want to fail closed.
--
--     Pattern only - the bare ROLLBACK below would error outside an
--     explicit transaction, so this stays commented.
-----------------------------------------------------------------------
/*
IF IS_MEMBER('BankManagers') = 0
BEGIN
    RAISERROR('Operation is only for bank manager use.', 16, 1);
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    RETURN;
END;
*/
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
--     See 3.2 - same query, plus login type and disabled status.
--     Kept here as a pointer only, to avoid a duplicate maintained
--     in two places.
-----------------------------------------------------------------------
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
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
USE master;
GO
CREATE SERVER ROLE srv_documenters;
GO
*/

-----------------------------------------------------------------------
-- 6.6 ADD LOGIN TO SERVER ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
--     Adding a login to sysadmin grants full control of the instance.
-----------------------------------------------------------------------
/*
ALTER SERVER ROLE serveradmin ADD MEMBER [YourLoginName];
GO

ALTER SERVER ROLE sysadmin ADD MEMBER [DOMAIN\YourLoginName];
GO
*/

-----------------------------------------------------------------------
-- 6.7 REMOVE LOGIN FROM SERVER ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
ALTER SERVER ROLE serveradmin DROP MEMBER [YourLoginName];
GO
*/


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
--     See 4.2 - same query, plus user type and create date.
--     Kept here as a pointer only, to avoid a duplicate maintained
--     in two places.
-----------------------------------------------------------------------
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
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
ALTER ROLE db_datareader ADD MEMBER [YourUserName];
GO
ALTER ROLE db_owner      ADD MEMBER [DOMAIN\ITSupport];
GO
*/

-----------------------------------------------------------------------
-- 7.5 REMOVE USER FROM DATABASE ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
ALTER ROLE db_backupoperator DROP MEMBER [YourUserName];
GO
*/

-----------------------------------------------------------------------
-- 7.6 CREATE USER-DEFINED DATABASE ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
--     Prefer granting permissions to roles, not directly to users.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO

CREATE ROLE YourRoleName AUTHORIZATION dbo;
GO
*/

-----------------------------------------------------------------------
-- 7.7 ADD MEMBERS TO USER-DEFINED DATABASE ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
ALTER ROLE YourRoleName ADD MEMBER [YourUserName];
GO
ALTER ROLE YourRoleName ADD MEMBER [DOMAIN\YourGroupName];
GO
*/

-----------------------------------------------------------------------
-- 7.8 REMOVE MEMBER FROM USER-DEFINED DATABASE ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
ALTER ROLE YourRoleName DROP MEMBER [YourUserName];
GO
*/

-----------------------------------------------------------------------
-- 7.9 DROP USER-DEFINED DATABASE ROLE
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
--     The role must have no members before it can be dropped.
-----------------------------------------------------------------------
/*
DROP ROLE YourRoleName;
GO
*/


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
-- 8.2 ORPHANED USERS - ALL DATABASES (via sp_MSforeachdb)
--     NOTE: sp_MSforeachdb is undocumented and can silently skip
--           databases. See the note on 4.5.
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
--     *** DDL - UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
--     Remaps an existing database user to an existing server login.
--     The login must already exist. If it does not, recreate it with
--     the ORIGINAL SID (see 10.4 / 10.5) instead of remapping.
--     8.1 generates the exact command for each orphan it finds.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
ALTER USER [YourUserName] WITH LOGIN = [YourLoginName];
GO
*/


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
--     *** SERVER CONFIGURATION CHANGE - UNCOMMENT DELIBERATELY ***
--     Message 229 is "The <permission> permission was denied...".
--     Turning WITH_LOG on writes every occurrence to the SQL Server
--     error log, which is useful while troubleshooting but can be very
--     noisy on a busy instance. Remember to turn it back off.
-----------------------------------------------------------------------
/*
-- Enable:
EXEC msdb.dbo.sp_altermessage 229, 'WITH_LOG', 'true';
GO

-- Disable again when finished:
-- EXEC msdb.dbo.sp_altermessage 229, 'WITH_LOG', 'false';
-- GO
*/

-----------------------------------------------------------------------
-- 9.5 SA ACCOUNT SECURITY CHECK
--     If Mixed Mode auth is enabled, the built-in sa account is a
--     prime brute-force target. Confirm it's disabled/renamed and,
--     if still enabled, that it has a strong password.
-----------------------------------------------------------------------
SELECT
    [name]                                     AS LoginName,
    is_disabled                                AS IsDisabled,
    LOGINPROPERTY([name], 'IsLocked')          AS IsLocked,
    LOGINPROPERTY([name], 'BadPasswordCount')  AS BadPwdCount,
    create_date,
    modify_date,
    CASE
        WHEN is_disabled = 0 THEN '*** ENABLED — disable or rename if not required ***'
        ELSE 'OK - disabled'
    END                                        AS Recommendation
FROM sys.sql_logins
WHERE principal_id = 1;   -- principal_id 1 is always the sa account, even if renamed

-----------------------------------------------------------------------
-- 9.6 AUTHENTICATION MODE CHECK
--     Windows Authentication is preferred over Mixed Mode; if Mixed
--     Mode is required, ensure sa (9.5) and all SQL logins (9.1) are
--     locked down.
-----------------------------------------------------------------------
SELECT
    SERVERPROPERTY('IsIntegratedSecurityOnly') AS WindowsAuthOnly,
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication only (recommended)'
        ELSE 'Mixed Mode enabled — lock down sa (9.5) and SQL logins (9.1)'
    END                                        AS Mode;

-----------------------------------------------------------------------
-- 9.7 POTENTIAL SQL INJECTION RISK — DYNAMIC SQL BUILT FROM CONCATENATION
--     Heuristic scan of stored procedure/function definitions for
--     string-concatenated EXEC() calls. Flags candidates for manual
--     review — always use parameterized dynamic SQL (sp_executesql
--     with parameters) rather than concatenating raw input into a
--     string.
-----------------------------------------------------------------------
SELECT
    OBJECT_SCHEMA_NAME(o.object_id)  AS SchemaName,
    o.[name]                         AS ObjectName,
    o.type_desc                      AS ObjectType
FROM sys.sql_modules m
INNER JOIN sys.objects o
    ON m.object_id = o.object_id
WHERE (m.definition LIKE '%EXEC(%+%' OR m.definition LIKE '%EXECUTE(%+%')
  AND m.definition NOT LIKE '%sp_executesql%'
ORDER BY SchemaName, ObjectName;

-----------------------------------------------------------------------
-- 9.8 SQL SERVER AUDIT TEMPLATE — FAILED LOGINS & PERMISSION CHANGES
--     Reference template for implementing SQL Server Audit to track
--     failed logins and schema/permission changes. Adjust the file
--     path and audited action groups as needed.
--     *** UNCOMMENT AND CUSTOMIZE BEFORE RUNNING ***
-----------------------------------------------------------------------
/*
CREATE SERVER AUDIT [ServerAudit_Security]
    TO FILE (FILEPATH = 'D:\Audits\')
    WITH (ON_FAILURE = CONTINUE);
GO
ALTER SERVER AUDIT [ServerAudit_Security] WITH (STATE = ON);
GO

CREATE SERVER AUDIT SPECIFICATION [ServerAuditSpec_Security]
FOR SERVER AUDIT [ServerAudit_Security]
    ADD (FAILED_LOGIN_GROUP),
    ADD (SERVER_PERMISSION_CHANGE_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP)
WITH (STATE = ON);
GO

-- Database-level audit specification example (per database):
-- CREATE DATABASE AUDIT SPECIFICATION [DbAuditSpec_Security]
-- FOR SERVER AUDIT [ServerAudit_Security]
--     ADD (SCHEMA_OBJECT_CHANGE_GROUP),
--     ADD (DATABASE_PERMISSION_CHANGE_GROUP)
-- WITH (STATE = ON);
-- GO
*/

-----------------------------------------------------------------------
-- 9.9 EXISTING AUDIT CONFIGURATION & STATUS
--     Confirms whether the audits defined in 9.8 (or elsewhere) are
--     actually defined, enabled, and running. An audit that exists but
--     is not started collects nothing.
--     NOTE: Server-level audit objects do not exist on Azure SQL
--           Database - use the database audit specification queries and
--           auditing settings there instead.
-----------------------------------------------------------------------
-- Defined server audits and their targets
--     max_file_size / max_rollover_files / log_file_path only exist on
--     sys.server_file_audits, so they are NULL for audits that write to
--     the Windows application or security log.
SELECT
    a.[name]                AS AuditName,
    a.type_desc             AS TargetType,          -- FILE / APPLICATION LOG / SECURITY LOG
    a.on_failure_desc       AS OnFailure,
    a.queue_delay           AS QueueDelayMs,
    a.is_state_enabled      AS IsEnabled,
    f.max_file_size         AS MaxFileSizeMB,
    f.max_rollover_files    AS MaxRolloverFiles,
    f.log_file_path         AS LogFilePath
FROM sys.server_audits a
    LEFT JOIN sys.server_file_audits f ON a.audit_id = f.audit_id
ORDER BY a.[name];

-- Runtime status of each audit
SELECT
    [name]                          AS AuditName,
    [status_desc]                   AS [Status],
    status_time                     AS StatusTime,
    audit_file_path                 AS CurrentFile,
    audit_file_size                 AS CurrentFileSizeBytes,
    event_session_address           AS SessionAddress
FROM sys.dm_server_audit_status
ORDER BY [name];

-- Which action groups are being captured, server level
SELECT
    a.[name]                        AS AuditName,
    s.[name]                        AS SpecificationName,
    s.is_state_enabled              AS SpecEnabled,
    d.audit_action_name             AS AuditedActionGroup
FROM sys.server_audit_specifications s
    JOIN sys.server_audits a                   ON s.audit_guid = a.audit_guid
    JOIN sys.server_audit_specification_details d ON s.server_specification_id = d.server_specification_id
ORDER BY a.[name], s.[name], d.audit_action_name;

-- Which action groups are being captured in the CURRENT database
SELECT
    DB_NAME()                       AS DatabaseName,
    s.[name]                        AS SpecificationName,
    s.is_state_enabled              AS SpecEnabled,
    d.audit_action_name             AS AuditedAction,
    d.class_desc                    AS ObjectClass,
    d.major_id                      AS MajorId
FROM sys.database_audit_specifications s
    JOIN sys.database_audit_specification_details d
        ON s.database_specification_id = d.database_specification_id
ORDER BY s.[name], d.audit_action_name;
GO

-----------------------------------------------------------------------
-- 9.10 CREDENTIALS, PROXIES & SERVICE ACCOUNTS
--      Credentials store external identities (Windows accounts, storage
--      keys, managed identities). Agent proxies let job steps run as
--      those identities, which is a common privilege-escalation path:
--      a low-privileged login with access to a proxy backed by a
--      high-privileged account effectively inherits that account.
-----------------------------------------------------------------------
-- Server-scoped credentials
SELECT
    c.[name]                AS CredentialName,
    c.credential_identity   AS CredentialIdentity,
    c.create_date           AS CreatedDate,
    c.modify_date           AS ModifiedDate
FROM sys.credentials c
ORDER BY c.[name];

-- Database-scoped credentials (current database)
SELECT
    DB_NAME()               AS DatabaseName,
    dsc.[name]              AS CredentialName,
    dsc.credential_identity AS CredentialIdentity,
    dsc.create_date         AS CreatedDate,
    dsc.modify_date         AS ModifiedDate
FROM sys.database_scoped_credentials dsc
ORDER BY dsc.[name];

-- SQL Agent proxies, the credential behind them, and who can use them
SELECT
    p.[name]                AS ProxyName,
    p.enabled               AS ProxyEnabled,
    c.[name]                AS CredentialName,
    c.credential_identity   AS RunsAsIdentity,
    sp.[name]               AS GrantedToPrincipal,
    sp.[type_desc]          AS PrincipalType
FROM msdb.dbo.sysproxies p
    LEFT JOIN sys.credentials c            ON p.credential_id = c.credential_id
    LEFT JOIN msdb.dbo.sysproxylogin pl    ON p.proxy_id = pl.proxy_id
    LEFT JOIN sys.server_principals sp     ON pl.sid = sp.[sid]
ORDER BY p.[name], sp.[name];

-- Logins that own SQL Agent jobs (job owner determines execution context)
SELECT
    j.[name]                AS JobName,
    j.enabled               AS JobEnabled,
    SUSER_SNAME(j.owner_sid) AS JobOwner,
    CASE
        WHEN SUSER_SNAME(j.owner_sid) IS NULL
            THEN '*** OWNER SID HAS NO MATCHING LOGIN ***'
        WHEN IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(j.owner_sid)) = 1
            THEN '* Owned by a sysadmin - job steps run with full rights *'
        ELSE 'OK'
    END                     AS [Status]
FROM msdb.dbo.sysjobs j
ORDER BY j.[name];
GO


/*********************************************************************************************
 * SECTION 10: CREATING & MANAGING LOGINS
 * Examples for creating and managing server-level logins
 * *** EVERY STATEMENT IN THIS SECTION IS DDL AND IS COMMENTED OUT BY DESIGN ***
 * *** Replace the placeholder names and passwords, then uncomment one at a time ***
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 10.1 CREATE A WINDOWS LOGIN
-----------------------------------------------------------------------
/*
CREATE LOGIN [DOMAIN\user.name] FROM WINDOWS;
GO
*/

-----------------------------------------------------------------------
-- 10.2 CREATE A SQL SERVER LOGIN
--      Never commit a real password to source control. Use a strong,
--      unique password supplied at run time.
-----------------------------------------------------------------------
/*
CREATE LOGIN [YourLoginName]
    WITH PASSWORD = '<StrongPasswordHere>',
         CHECK_POLICY = ON,
         CHECK_EXPIRATION = ON;
GO
*/

-----------------------------------------------------------------------
-- 10.3 CREATE SQL SERVER LOGIN WITHOUT POLICY CHECK
--      CHECK_POLICY = OFF also disables CHECK_EXPIRATION and removes
--      account lockout. Only do this where an application genuinely
--      cannot cope with policy, and document the exception.
--      Query 9.1 reports every login created this way.
-----------------------------------------------------------------------
/*
CREATE LOGIN [YourAppLogin]
    WITH PASSWORD = '<StrongPasswordHere>',
         CHECK_POLICY = OFF;
GO
*/

-----------------------------------------------------------------------
-- 10.4 RECREATE LOGIN WITH A SPECIFIC SID
--      This is how you avoid orphaned users: recreating the login with
--      the ORIGINAL SID means existing database users map straight back
--      to it, with no ALTER USER ... WITH LOGIN needed.
--      Get the SID from the source server with query 2.6.
-----------------------------------------------------------------------
/*
IF EXISTS (
    SELECT 1
    FROM master.sys.server_principals
    WHERE [name] = N'YourLoginName'
)
BEGIN
    DROP LOGIN [YourLoginName];
END
GO

CREATE LOGIN [YourLoginName]
    WITH PASSWORD = '<StrongPasswordHere>',
         SID = 0x00000000000000000000000000000000,   -- original SID from 2.6
         DEFAULT_DATABASE = [YourDatabaseName],
         DEFAULT_LANGUAGE = us_english,
         CHECK_EXPIRATION = OFF,
         CHECK_POLICY = ON;
GO
*/

-----------------------------------------------------------------------
-- 10.5 MIGRATE LOGINS BETWEEN SERVERS (SID + PASSWORD HASH)
--      Generates CREATE LOGIN statements that preserve both the SID and
--      the existing password hash, so applications keep working and no
--      users are orphaned. Run on the SOURCE server, review the output,
--      then run the generated script on the TARGET.
--
--      This is the same idea as Microsoft's sp_help_revlogin, without
--      needing to install the procedure first. If sp_help_revlogin is
--      already deployed, EXEC sp_help_revlogin; does the same job.
--
--      NOTE: Password hashes are portable only between servers with
--            compatible versions. Windows logins carry no hash - they
--            are recreated FROM WINDOWS and keep their AD SID anyway.
-----------------------------------------------------------------------
SELECT
    sp.[name] AS LoginName,
    CASE sp.[type]
        WHEN 'S' THEN
            'CREATE LOGIN ' + QUOTENAME(sp.[name])
            + ' WITH PASSWORD = ' + CONVERT(nvarchar(max), sl.password_hash, 1) + ' HASHED'
            + ', SID = ' + CONVERT(nvarchar(max), sp.[sid], 1)
            + ', DEFAULT_DATABASE = ' + QUOTENAME(sl.default_database_name)
            + ', DEFAULT_LANGUAGE = ' + QUOTENAME(ISNULL(sl.default_language_name, N'us_english'))
            + ', CHECK_POLICY = '     + CASE sl.is_policy_checked     WHEN 1 THEN 'ON' ELSE 'OFF' END
            + ', CHECK_EXPIRATION = ' + CASE sl.is_expiration_checked WHEN 1 THEN 'ON' ELSE 'OFF' END
            + ';'
        ELSE
            'CREATE LOGIN ' + QUOTENAME(sp.[name]) + ' FROM WINDOWS'
            + ' WITH DEFAULT_DATABASE = ' + QUOTENAME(sp.default_database_name) + ';'
    END
    + CASE WHEN sp.is_disabled = 1
           THEN CHAR(13) + CHAR(10) + 'ALTER LOGIN ' + QUOTENAME(sp.[name]) + ' DISABLE;'
           ELSE '' END AS CreateLoginScript
FROM sys.server_principals sp
    LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
WHERE sp.[type] IN ('S', 'U', 'G')
  AND sp.[name] NOT LIKE '##%'
  AND sp.[name] <> 'sa'
ORDER BY sp.[name];
GO


/*********************************************************************************************
 * SECTION 11: CREATING & MANAGING USERS
 * Examples for creating and managing database-level users
 * *** EVERY STATEMENT IN THIS SECTION IS DDL AND IS COMMENTED OUT BY DESIGN ***
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 11.1 CREATE USER FOR LOGIN
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
CREATE USER [YourUserName] FOR LOGIN [YourLoginName];
GO
*/

-----------------------------------------------------------------------
-- 11.2 CREATE USER NOT ASSOCIATED WITH A LOGIN (Contained Database User)
--      Requires the database to have containment enabled
--      (ALTER DATABASE ... SET CONTAINMENT = PARTIAL) and the server
--      option 'contained database authentication' set to 1.
--      Contained users move with the database, so they never orphan.
-----------------------------------------------------------------------
/*
CREATE USER [YourAppUser] WITH PASSWORD = '<StrongPasswordHere>';
GO
*/

-----------------------------------------------------------------------
-- 11.3 ENABLE GUEST ACCOUNT IN DATABASE
--      *** NOT RECOMMENDED - guest lets ANY login reach this database ***
--      Only msdb and the system databases should normally have it on.
--      Query 9.2 finds user databases where guest is enabled.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
GRANT CONNECT TO guest;
GO
*/

-----------------------------------------------------------------------
-- 11.4 DISABLE GUEST USER FROM ACCESSING A DATABASE
--      This is the recommended state for every user database.
--      Do NOT run this against master, tempdb or msdb.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO
REVOKE CONNECT FROM guest;
GO
*/

-----------------------------------------------------------------------
-- 11.5 CHANGE DATABASE OWNER
--      Databases owned by a personal account break when that account
--      is removed. Prefer sa or a dedicated service principal.
-----------------------------------------------------------------------
/*
ALTER AUTHORIZATION ON DATABASE::[YourDatabaseName]
  TO [sa];
GO
*/


/*********************************************************************************************
 * SECTION 12: GRANTING & REVOKING PERMISSIONS
 * Examples for managing object and schema-level permissions
 * *** EVERY STATEMENT IN THIS SECTION IS DDL AND IS COMMENTED OUT BY DESIGN ***
 * Best practice: grant to ROLES, not to individual users.
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 12.1 GRANT OBJECT PERMISSION
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO

GRANT SELECT ON OBJECT::YourSchema.YourTable TO YourRoleName;
GO

-- Alternative syntax (same result)
GRANT SELECT ON YourSchema.YourTable TO YourRoleName;
GO
*/

-----------------------------------------------------------------------
-- 12.2 GRANT COLUMN-LEVEL PERMISSIONS
-----------------------------------------------------------------------
/*
GRANT SELECT ON YourSchema.YourTable
    (Column1, Column2)
TO YourRoleName;
GO
*/

-----------------------------------------------------------------------
-- 12.3 GRANT WITH GRANT OPTION (USE WITH CAUTION!)
--      Allows grantee to grant permissions to others
--      Generally should be avoided
-----------------------------------------------------------------------
/*
GRANT UPDATE ON YourSchema.YourTable
TO YourRoleName
WITH GRANT OPTION;
GO
*/

-----------------------------------------------------------------------
-- 12.4 REVOKE PERMISSIONS WITH CASCADE
--      CASCADE also revokes permissions granted by the grantee
--      Required when the original grant used WITH GRANT OPTION
--      Can also apply to DENY
-----------------------------------------------------------------------
/*
REVOKE UPDATE ON YourSchema.YourTable
FROM YourRoleName
CASCADE;
GO
*/

-----------------------------------------------------------------------
-- 12.5 GRANT PERMISSIONS AT SCHEMA LEVEL
--      Schema-level grants cover objects created later, so they need
--      far less maintenance than per-object grants.
-----------------------------------------------------------------------
/*
GRANT EXECUTE
	ON SCHEMA::YourSchema
	TO YourRoleName;
GO

GRANT SELECT
	ON SCHEMA::YourSchema
	TO YourRoleName;
GO
*/

-----------------------------------------------------------------------
-- 12.6 DENY PERMISSIONS AT SCHEMA LEVEL
--      DENY always beats GRANT, at every scope.
-----------------------------------------------------------------------
/*
DENY SELECT ON SCHEMA::YourSchema TO [DOMAIN\user.name];
GO
*/

-----------------------------------------------------------------------
-- 12.7 GRANT MULTIPLE PERMISSIONS AT SCHEMA LEVEL AND ON OBJECTS
-----------------------------------------------------------------------
/*
GRANT EXECUTE ON SCHEMA::YourSchema TO YourRoleName;
GO

GRANT SELECT, UPDATE ON YourSchema.YourTable TO [DOMAIN\YourGroupName];
GO
*/

-----------------------------------------------------------------------
-- 12.8 GRANT EXECUTE PERMISSION ON STORED PROCEDURE
--      Ownership chaining means callers usually need only EXECUTE on
--      the procedure, not direct rights on the underlying tables.
-----------------------------------------------------------------------
/*
GRANT EXECUTE ON YourSchema.YourProcedure TO YourRoleName;
GO
*/


/*********************************************************************************************
 * SECTION 13: APPLICATION ROLES
 * Managing application roles for application-specific permissions
 * *** EVERY STATEMENT IN THIS SECTION IS DDL AND IS COMMENTED OUT BY DESIGN ***
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 13.1 CREATE APPLICATION ROLE
--      Application roles enable permissions only when running specific applications
--      NOTE: Activating an application role REPLACES the user's own
--            permissions for the rest of the session - it does not add
--            to them. The session also loses its server-level identity
--            for permission checks in other databases.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO

CREATE APPLICATION ROLE YourAppRole WITH PASSWORD = '<StrongPasswordHere>';
GO
*/

-----------------------------------------------------------------------
-- 13.2 ASSIGN PERMISSIONS TO APPLICATION ROLE
-----------------------------------------------------------------------
/*
GRANT SELECT ON SCHEMA::YourSchema TO YourAppRole;
GO
*/

-----------------------------------------------------------------------
-- 13.3 ACTIVATE APPLICATION ROLE
--      sp_setapprole activates, sp_unsetapprole deactivates.
--      Pass @fCreateCookie/@cookie if you need to revert cleanly.
--      *** CHANGES SESSION CONTEXT ***
-----------------------------------------------------------------------
/*
-- View current user tokens
SELECT * FROM sys.user_token;
GO

-- Set the application role, keeping a cookie so it can be unset
DECLARE @cookie varbinary(8000);
EXEC sp_setapprole 'YourAppRole', '<StrongPasswordHere>',
     @fCreateCookie = true, @cookie = @cookie OUTPUT;

-- View updated user tokens (should show the application role)
SELECT * FROM sys.user_token;

-- Revert back to the original security context
EXEC sp_unsetapprole @cookie;
GO
*/


/*********************************************************************************************
 * SECTION 14: TESTING & VERIFICATION
 * Queries for testing role assignments and verifying permissions
 *********************************************************************************************/

-----------------------------------------------------------------------
-- 14.1 TEST USER TOKENS AND LOGIN CONTEXT
--      *** CHANGES SESSION CONTEXT - UNCOMMENT AND RUN DELIBERATELY ***
--      sys.login_token shows the server-level identities in effect,
--      sys.user_token the database-level ones. Between them they
--      explain why a principal does or does not have access.
--      Always REVERT when finished. See also 5.4.
-----------------------------------------------------------------------
/*
USE YourDatabaseName;
GO

EXECUTE AS LOGIN = 'DOMAIN\user.name';
GO

SELECT * FROM sys.login_token;
GO

SELECT * FROM sys.user_token;
GO

REVERT;
GO
*/

-- Confirm you are back in your own context
SELECT
    SUSER_SNAME()          AS EffectiveLogin,
    ORIGINAL_LOGIN()       AS OriginalLogin,
    USER_NAME()            AS EffectiveDatabaseUser,
    DB_NAME()              AS CurrentDatabase;
GO

-----------------------------------------------------------------------
-- END OF FILE
-----------------------------------------------------------------------