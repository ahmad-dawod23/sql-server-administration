/*******************************************************************************
 * SQL SERVER DANGEROUS ADMIN UTILITIES
 *
 * Purpose: High-risk administrative tooling that is NOT part of incident
 *          response — operating-system command execution, bulk object and
 *          principal removal, and database lifecycle operations that take
 *          databases offline or remove them from the instance.
 *
 * Sections:
 *   1. OPERATING SYSTEM COMMANDS (xp_cmdshell)
 *   2. DATABASE OBJECT & USER REMOVAL
 *   3. DATABASE LIFECYCLE OPERATIONS (OFFLINE / DETACH)
 *
 * Safety:  *** NOTHING IN THIS FILE IS SAFE TO RUN CASUALLY. ***
 *          Every block is commented out by default. The queries in Sections 2
 *          and 3 are generators: they return commands for review and do not
 *          execute them. Read every generated command before running it.
 *
 *          Requires an approved change/maintenance window, a verified restorable
 *          backup, and — for Section 1 — an approved justification for enabling
 *          xp_cmdshell.
 *
 * Related: Incident triage and corruption response live elsewhere. See
 *          advanced-administration-and-recovery.sql (error logs, startup
 *          failures, emergency recovery), database-integrity-checks.sql
 *          (DBCC / corruption), and other scripts/00-triage.sql.
 ******************************************************************************/


/*******************************************************************************
   SECTION 1: OPERATING SYSTEM COMMANDS (xp_cmdshell)

   WARNING: xp_cmdshell executes with SQL Server service-account privileges.
            Enable it only for an approved task and disable it immediately after.

            It is a well-known privilege-escalation path: any sysadmin (or any
            principal granted EXECUTE on it plus a proxy account) gains command
            execution on the host under the service account. Prefer a SQL Agent
            CmdExec job step with a dedicated, least-privileged proxy, or run
            the work from outside SQL Server entirely.
*******************************************************************************/

-----------------------------------------------------------------------
-- 1.1 CHECK CURRENT xp_cmdshell STATE (read-only)
--     Run this first. If it is already disabled, leave it that way unless
--     you have an approved reason to change it.
-----------------------------------------------------------------------
SELECT
    c.name,
    c.value       AS ConfiguredValue,
    c.value_in_use AS RunningValue,
    CASE WHEN c.value_in_use = 1
         THEN '*** ENABLED — confirm this is intentional ***'
         ELSE 'Disabled (desired state)'
    END           AS Assessment
FROM sys.configurations AS c
WHERE c.name IN ('xp_cmdshell', 'show advanced options', 'Ole Automation Procedures')
ORDER BY c.name;

-----------------------------------------------------------------------
-- 1.2 ENABLE xp_cmdshell
--     *** SECURITY-SENSITIVE INSTANCE CHANGE ***
--     Note the running value before you change it, so you can restore it.
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sys.sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
GO
*/

-----------------------------------------------------------------------
-- 1.3 RUN A DIRECTORY LISTING
--     Simple example of operating-system command execution
-----------------------------------------------------------------------
-- EXEC master.dbo.xp_cmdshell 'dir *.exe';
-- GO

-----------------------------------------------------------------------
-- 1.4 MAP, VERIFY, AND DISCONNECT A NETWORK SHARE
--     Prefer a UNC path when the calling feature supports it
--     *** DO NOT STORE REAL CREDENTIALS IN THIS SCRIPT ***
--     A password passed to 'net use' is visible in the SQL error log, in any
--     active trace or XEvent session, and to anyone reading this file. Prefer
--     granting the SQL Server service account access to the UNC path directly.
-----------------------------------------------------------------------
/*
-- Replace all placeholders before use.
EXEC master.dbo.xp_cmdshell 'net use T: \\<server>\<share> <password> /USER:<domain>\<account>';
GO

EXEC master.dbo.xp_cmdshell 'dir T:\';
GO

EXEC master.dbo.xp_cmdshell 'net use T: /delete';
GO
*/

-----------------------------------------------------------------------
-- 1.5 DISABLE xp_cmdshell
--     Restore the secure configuration immediately after use.
--     Only reset 'show advanced options' to 0 if it was 0 beforehand (1.1).
-----------------------------------------------------------------------
/*
EXEC sys.sp_configure 'xp_cmdshell', 0;
RECONFIGURE;
GO

EXEC sys.sp_configure 'show advanced options', 0;
RECONFIGURE;
GO
*/


/*******************************************************************************
   SECTION 2: DATABASE OBJECT & USER REMOVAL

   *** EXTREME CAUTION REQUIRED ***

   Run these generators in the intended user database, not [master]. They return
   commands for review; they do not execute the generated commands directly.

   Script out the objects first. A generated DROP list is not a backup.
*******************************************************************************/

-----------------------------------------------------------------------
-- 2.1 GENERATE DROP COMMANDS FOR ALL USER-DEFINED FUNCTIONS
--     Includes scalar, inline table-valued, and table-valued functions.
--     Dependency order is not resolved — functions referenced by other
--     objects (or schema-bound) will fail until the dependant is dropped.
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP FUNCTION ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' +
       QUOTENAME(o.name) + N';' AS drop_command
FROM sys.objects AS o
WHERE o.type IN ('FN', 'IF', 'TF')
  AND o.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(o.schema_id),
         o.name;
*/

-----------------------------------------------------------------------
-- 2.2 GENERATE DROP COMMANDS FOR ALL USER-DEFINED STORED PROCEDURES
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP PROCEDURE ' + QUOTENAME(SCHEMA_NAME(p.schema_id)) + N'.' +
       QUOTENAME(p.name) + N';' AS drop_command
FROM sys.procedures AS p
WHERE p.is_ms_shipped = 0
ORDER BY SCHEMA_NAME(p.schema_id),
         p.name;
*/

-----------------------------------------------------------------------
-- 2.3 GENERATE DROP COMMANDS FOR NON-SYSTEM DATABASE USERS
--     Excludes fixed roles and system principals. A user that owns a schema
--     or any other securable cannot be dropped until ownership is
--     transferred (error 15138), so expect some generated commands to fail.
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT N'DROP USER ' + QUOTENAME(dp.name) + N';' AS drop_command
FROM sys.database_principals AS dp
WHERE dp.principal_id > 4                    -- skips dbo, guest, INFORMATION_SCHEMA, sys
  AND dp.is_fixed_role = 0
  AND dp.type NOT IN ('R', 'A')              -- excludes roles and application roles
  AND dp.name NOT LIKE '##%'                 -- excludes built-in certificate/key principals
ORDER BY dp.name;
*/

-----------------------------------------------------------------------
-- 2.4 FIND SCHEMA OWNERSHIP BLOCKING A DROP USER (read-only)
--     Run this before 2.3 to see which users will fail with error 15138,
--     and generate the ownership transfers that unblock them.
-----------------------------------------------------------------------
/*
USE [<TargetDatabase>];
GO

SELECT
    dp.name                                   AS OwningPrincipal,
    s.name                                    AS OwnedSchema,
    N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(s.name)
        + N' TO [dbo];'                       AS TransferCommand
FROM sys.schemas AS s
INNER JOIN sys.database_principals AS dp
        ON dp.principal_id = s.principal_id
WHERE dp.principal_id > 4
  AND dp.is_fixed_role = 0
ORDER BY dp.name, s.name;
*/


/*******************************************************************************
   SECTION 3: DATABASE LIFECYCLE OPERATIONS (OFFLINE / DETACH)

   *** EXTREME CAUTION REQUIRED ***

   These queries generate commands that cause service disruption or remove
   databases from the instance. Review every generated command, maintain verified
   backups, and execute only during an approved maintenance window.

   Before detaching anything, record the full physical file paths (3.1) — you
   need them to reattach, and sp_detach_db does not keep them for you.
*******************************************************************************/

-----------------------------------------------------------------------
-- 3.1 RECORD FILE LAYOUT BEFORE ANY DETACH (read-only — run this first)
--     Save this output. Without it, reattaching is guesswork.
-----------------------------------------------------------------------
SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.[file_id],
    mf.[name]               AS LogicalName,
    mf.[type_desc]          AS FileType,
    mf.physical_name        AS PhysicalPath,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(18, 2)) AS SizeMB,
    mf.state_desc           AS FileState
FROM sys.master_files AS mf
WHERE mf.database_id > 4
ORDER BY DatabaseName, mf.[file_id];

-----------------------------------------------------------------------
-- 3.2 GENERATE OFFLINE COMMANDS FOR ALL USER DATABASES
--     *** TAKES EVERY ONLINE USER DATABASE OFFLINE ***
-----------------------------------------------------------------------
/*
SELECT N'USE [master];' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET OFFLINE WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) AS offline_command
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name <> N'distribution'
  AND d.state_desc = N'ONLINE'         -- already offline/restoring databases are not candidates
  AND d.source_database_id IS NULL     -- excludes database snapshots
  AND d.replica_id IS NULL             -- excludes availability group databases
ORDER BY d.name;
*/

-----------------------------------------------------------------------
-- 3.3 GENERATE THE MATCHING BRING-ONLINE COMMANDS (rollback for 3.2)
-----------------------------------------------------------------------
/*
SELECT N'ALTER DATABASE ' + QUOTENAME(d.name) + N' SET ONLINE;' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) + N' SET MULTI_USER;' + CHAR(13) + CHAR(10)
           AS online_command
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.state_desc = N'OFFLINE'
ORDER BY d.name;
*/

-----------------------------------------------------------------------
-- 3.4 GENERATE DETACH COMMANDS FOR ALL USER DATABASES
--     *** REMOVES EVERY USER DATABASE FROM THE INSTANCE ***
--     Detaching leaves the files on disk but discards the instance-level
--     metadata. Confirm you have captured 3.1 output first.
-----------------------------------------------------------------------
/*
SELECT N'USE [master];' + CHAR(13) + CHAR(10) +
       N'ALTER DATABASE ' + QUOTENAME(d.name) +
       N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10) +
       N'EXEC master.dbo.sp_detach_db @dbname = N''' +
       REPLACE(d.name, N'''', N'''''') + N''';' + CHAR(13) + CHAR(10) AS detach_command
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.name <> N'distribution'
  AND d.state_desc = N'ONLINE'
  AND d.source_database_id IS NULL     -- snapshots must be dropped, not detached
  AND d.replica_id IS NULL             -- availability group databases cannot be detached
  AND d.is_published = 0               -- replicated databases must be unpublished first
  AND d.is_subscribed = 0
ORDER BY d.name;
*/

-----------------------------------------------------------------------
-- 3.5 GENERATE REATTACH COMMANDS (rollback for 3.4)
--     Run this BEFORE detaching — once the database is detached its files
--     no longer appear in sys.master_files and this returns nothing.
-----------------------------------------------------------------------
/*
SELECT
    N'CREATE DATABASE ' + QUOTENAME(DB_NAME(mf.database_id)) + N' ON ' + CHAR(13) + CHAR(10) +
    STUFF((
        SELECT N',' + CHAR(13) + CHAR(10) + N'    (FILENAME = N''' + i.physical_name + N''')'
        FROM sys.master_files AS i
        WHERE i.database_id = mf.database_id
        ORDER BY i.[type], i.[file_id]
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 3, N'')
    + CHAR(13) + CHAR(10) + N'FOR ATTACH;' AS attach_command
FROM sys.master_files AS mf
WHERE mf.database_id > 4
GROUP BY mf.database_id
ORDER BY DB_NAME(mf.database_id);
*/


/*******************************************************************************
   END OF FILE

   Split out of advanced-administration-and-recovery.sql (Sections 5-7) so that
   the recovery file stays focused on incident response.

   Last reorganized: July 28, 2026
*******************************************************************************/
