-----------------------------------------------------------------------
-- GENERAL ADMINISTRATION UTILITIES
-- Purpose : Miscellaneous admin queries that don't fit into specialized
--           categories — error logs, network protocol checks, restore
--           progress, transaction monitoring, Database Mail diagnostics.
-- Note    : For specialized topics (security, backups, TDE, etc.),
--           see the dedicated script files.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1. ERROR LOG SEARCH
--    Search SQL Server error log for specific patterns.
-----------------------------------------------------------------------
USE MASTER;
GO
-- Search for permission errors
EXEC xp_readerrorlog 0, 1, N'permission', NULL, NULL, NULL, N'desc';
GO

-- Search for login failures (also see security-and-permissions-audit.sql)
-- EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, NULL, N'desc';

-----------------------------------------------------------------------
-- 2. CURRENT SESSION NETWORK PROTOCOL
--    Identify the transport protocol for your current connection.
-----------------------------------------------------------------------
SELECT
    session_id,
    net_transport,
    protocol_type,
    auth_scheme,
    encrypt_option
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;

-----------------------------------------------------------------------
-- 3. NON-ENCRYPTED TDS CONNECTIONS (Azure SQL MI)
--    Find unencrypted connections that aren't using Shared Memory
--    and aren't internal AG/MI Link traffic.
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

-----------------------------------------------------------------------
-- 4. SNAPSHOT ISOLATION LEVEL — ACTIVE TRANSACTIONS
--    Shows which sessions are using snapshot isolation and their
--    version chain traversal.
-----------------------------------------------------------------------
SELECT
    transaction_sequence_num,
    commit_sequence_num,
    is_snapshot,
    t.session_id,
    first_snapshot_sequence_num,
    max_version_chain_traversed,
    elapsed_time_seconds,
    host_name,
    login_name,
    CASE transaction_isolation_level
        WHEN '0' THEN 'Unspecified'
        WHEN '1' THEN 'ReadUncommitted'
        WHEN '2' THEN 'ReadCommitted'
        WHEN '3' THEN 'Repeatable'
        WHEN '4' THEN 'Serializable'
        WHEN '5' THEN 'Snapshot'
    END                          AS transaction_isolation_level
FROM sys.dm_tran_active_snapshot_database_transactions t
    JOIN sys.dm_exec_sessions s
        ON t.session_id = s.session_id
ORDER BY elapsed_time_seconds DESC;

-----------------------------------------------------------------------
-- 5. ACTIVE OPEN TRANSACTIONS
--    Find sessions with uncommitted transactions (potential blocking).
-----------------------------------------------------------------------
SELECT
    SP.SPID,
    SP.open_tran                 AS OpenTransactions,
    SP.status,
    SP.cmd,
    SP.waittype,
    SP.waittime,
    SP.blocked,
    DEST.[text]                  AS SQLCode
FROM sys.sysprocesses SP
    CROSS APPLY sys.dm_exec_sql_text(SP.[SQL_HANDLE]) AS DEST
WHERE SP.open_tran >= 1
ORDER BY SP.open_tran DESC, SP.waittime DESC;

-----------------------------------------------------------------------
-- 6. BACKUP / RESTORE PROGRESS
--    Monitor running backup or restore operations.
-----------------------------------------------------------------------
USE master;
GO
SELECT
    session_id                   AS SPID,
    command,
    a.[text]                     AS Query,
    start_time,
    percent_complete,
    CAST(((DATEDIFF(s, start_time, GETDATE())) / 3600) AS VARCHAR) + ' hour(s), '
        + CAST((DATEDIFF(s, start_time, GETDATE()) % 3600) / 60 AS VARCHAR) + ' min, '
        + CAST((DATEDIFF(s, start_time, GETDATE()) % 60) AS VARCHAR) + ' sec'
                                 AS running_time,
    CAST((estimated_completion_time / 3600000) AS VARCHAR) + ' hour(s), '
        + CAST((estimated_completion_time % 3600000) / 60000 AS VARCHAR) + ' min, '
        + CAST((estimated_completion_time % 60000) / 1000 AS VARCHAR) + ' sec'
                                 AS est_time_to_go,
    DATEADD(SECOND,
        estimated_completion_time / 1000,
        GETDATE())               AS estimated_completion_time
FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a
WHERE r.command IN (
    'BACKUP DATABASE',
    'RESTORE DATABASE',
    'BACKUP LOG',
    'RESTORE LOG'
)
ORDER BY start_time;

-----------------------------------------------------------------------
-- 7. RING BUFFER — XE LOG ERRORS
--    Recent Extended Event errors from the ring buffer.
-----------------------------------------------------------------------
SELECT
    record_id,
    DATEADD(ms,
        (-1 * (SELECT ms_ticks FROM sys.dm_os_sys_info) - [timestamp]),
        GETDATE())               AS event_time,
    [timestamp],
    record
FROM sys.dm_os_ring_buffers
WHERE ring_buffer_type = 'RING_BUFFER_XE_LOG'
ORDER BY [timestamp] DESC;
 
 
 
 
-----------------------------------------------------------------------
-- 8. Database Mail Diagnostics
--   Check Database Mail configuration, queues, and logs for issues.
-----------------------------------------------------------------------
 
 
  USE msdb
 GO

-- Check that the service broker is enabled on MSDB. 
-- Is_broker_enabled must be 1 to use database mail.
SELECT is_broker_enabled FROM sys.databases WHERE name = 'msdb';
-- Check that Database mail is turned on. 
-- Run_value must be 1 to use database mail.
-- If you need to change it this option does not require
-- a server restart to take effect.
EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
EXEC sp_configure 'Database Mail XPs';

-- Check the Mail queues
-- This system stored procedure lists the two Database Mail queues.  
-- The optional @queue_type parameter tells it to only list that queue.
-- The list contains the length of the queue (number of emails waiting),
-- the state of the queue (INACTIVE, NOTIFIED, RECEIVES_OCCURRING, the 
-- last time the queue was empty and the last time the queue was active.
EXEC msdb.dbo.sysmail_help_queue_sp -- @queue_type = 'Mail' ;

-- Check the status (STARTED or STOPPED) of the sysmail database queues
-- EXEC msdb.dbo.sysmail_start_sp -- Start the queue
-- EXEC msdb.dbo.sysmail_stop_sp -- Stop the queue
EXEC msdb.dbo.sysmail_help_status_sp;

-- Check the different database mail settings.  
-- These are system stored procedures that list the general 
-- settings, accounts, profiles, links between the accounts
-- and profiles and the link between database principles and 
-- database mail profiles.
-- These are generally controlled by the database mail wizard.

EXEC msdb.dbo.sysmail_help_configure_sp;
EXEC msdb.dbo.sysmail_help_account_sp;
--  Check that your server name and server type are correct in the
--      account you are using.
--  Check that your email_address is correct in the account you are
--      using.
EXEC msdb.dbo.sysmail_help_profile_sp;
--  Check that you are using a valid profile in your dbmail command.
EXEC msdb.dbo.sysmail_help_profileaccount_sp;
--  Check that your account and profile are joined together
--      correctly in sysmail_help_profileaccount_sp.
EXEC msdb.dbo.sysmail_help_principalprofile_sp;

-- I’m doing a TOP 100 on these next several queries as they tend
-- to contain a great deal of data.  Obviously if you need to get
-- more than 100 rows this can be changed.
-- Check the database mail event log.
-- Particularly for the event_type of "error".  These are where you
-- will find the actual sending error.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_event_log 
ORDER BY last_mod_date DESC;

-- Check the actual emails queued
-- Look at sent_status to see 'failed' or 'unsent' emails.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_allitems 
ORDER BY last_mod_date DESC;

-- Check the emails that actually got sent. 
-- This is a view on sysmail_allitems WHERE sent_status = 'sent'
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_sentitems 
ORDER BY last_mod_date DESC;

-- Check the emails that failed to be sent.
-- This is a view on sysmail_allitems WHERE sent_status = 'failed'
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_faileditems 
ORDER BY last_mod_date DESC

-- Clean out unsent emails
-- Usually I do this before releasing the queue again after fixing the problem.
-- Assuming of course that I don't want to send out potentially thousands of 
-- emails that are who knows how old.
-- Obviously can be used to clean out emails of any status.
EXEC msdb.dbo.sysmail_delete_mailitems_sp  
  @sent_before =  '2017-03-16',
  @sent_status = 'failed';