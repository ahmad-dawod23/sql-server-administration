-----------------------------------------------------------------------
-- SECURITY & PERMISSIONS AUDIT
-- Purpose : Audit server/database-level security: logins, roles,
--           permissions, orphaned users, and sysadmin membership.
-- Safety  : All queries are read-only.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. SERVER-LEVEL: SYSADMIN MEMBERS
--    Review regularly — sysadmin should be tightly controlled.
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
-- 2. ALL SERVER ROLE MEMBERSHIPS
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
-- 3. SERVER-LEVEL PERMISSIONS (explicit GRANT / DENY)
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
-- 4. ALL LOGINS AND THEIR STATUS
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
-- 5. DATABASE-LEVEL: USER-ROLE MEMBERSHIPS (current database)
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
-- 6. DATABASE-LEVEL PERMISSIONS (current database)
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
-- 7. ORPHANED USERS
--    Database users with no corresponding server login.
--    These accumulate after restores / migrations / login drops.
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
-- 8. ORPHANED USERS — ALL DATABASES (via sp_MSforeachdb)
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
-- 9. USERS WITH db_owner ROLE (all databases)
--    Similar to sysadmin audit but at database level.
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
-- 10. SQL LOGINS WITH WEAK PASSWORD POLICY
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
-- 11. GUEST ACCESS CHECK
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
-- 12. LINKED SERVER SECURITY AUDIT
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
-- 13. LOGIN TROUBLESHOOTING ("Login failed" diagnostics)
--     Use when investigating login failures.
-----------------------------------------------------------------------
-- Step 1: Capture the exact error state from error log
EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';

-- Step 2: Look for locked accounts, bad password counts, default DB issues
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

-- Step 3: Check if the default database exists and is ONLINE
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

-- Step 4: Check for hidden DENY on CONNECT SQL permission
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
