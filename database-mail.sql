/*****************************************************************************************************
 * SQL SERVER DATABASE MAIL DIAGNOSTICS
 *
 * This file contains queries organized by functionality:
 *   1. FAST TRIAGE - is mail flowing, and if not, what is the actual error?
 *   2. PREREQUISITES AND PERMISSIONS
 *   3. CONFIGURATION REVIEW (parameters, profiles, accounts, SMTP servers)
 *   4. REMEDIATION (restart queue, enable features, send test) - COMMENTED OUT
 *   5. MAINTENANCE AND RETENTION - DELETES COMMENTED OUT
 *   6. REFERENCE - proving the SMTP path from outside SQL Server
 *
 * Background theory (how a message actually gets delivered, what each sent_status means, why
 * SQL Agent notifications are configured separately) is in the CONCEPTS REFERENCE block below.
 *
 * Related: sql-agent-jobs-troubleshooting.sql   job failures and notification setup
 *          logins-and-security.sql              principal and permission troubleshooting
 *          sqlmi-specific-queries.sql           Azure SQL Managed Instance specifics
 *****************************************************************************************************/
/*****************************************************************************************************
 * !! READ BEFORE RUNNING !!
 * Do NOT execute this file end-to-end.
 *   - Sections 1, 2 and 3 are read-only diagnostic queries and are safe to run.
 *   - Section 4 changes server state (starts/stops the mail queue, changes sp_configure, sends
 *     real email to real people) and is deliberately commented out.
 *   - Section 5 PERMANENTLY DELETES mail history and log rows from msdb. Deliberately commented
 *     out. There is no undo other than restoring msdb.
 * All Database Mail metadata lives in msdb only.
 *****************************************************************************************************/

/*=====================================================================================================
  CONCEPTS REFERENCE
=======================================================================================================

C1. HOW A MESSAGE ACTUALLY GETS DELIVERED
---------------------------------------------------------------------------------------------------
sp_send_dbmail does NOT talk to the SMTP server. The real path is:

    sp_send_dbmail   ->  row inserted into msdb.dbo.sysmail_mailitems and a message placed on the
                         Service Broker mail queue in msdb. This is the only transactional part.
                     ->  Service Broker activation launches DatabaseMail.exe, an EXTERNAL process
                         running under the SQL Server service account.
                     ->  DatabaseMail.exe reads the queue and connects to the SMTP server.
                     ->  Result is written back to the status queue, then to
                         sysmail_mailitems.sent_status and sysmail_log.

Consequences that matter during triage:
  - "Mail queued." from sp_send_dbmail says NOTHING about delivery. It only means the row was
    accepted onto the queue.
  - If Service Broker is disabled on msdb, mail queues forever and is never sent.
  - If DatabaseMail.exe cannot start (missing .NET, blocked by AV/policy, service account problem)
    items sit as 'unsent' and the event log shows activation errors.
  - Network, firewall, TLS and SMTP authentication problems surface as sent_status = 'failed' with
    the SMTP error text in sysmail_log - NOT as an error returned by sp_send_dbmail.

C2. sent_status VALUES
---------------------------------------------------------------------------------------------------
    unsent      Queued, not yet processed. A few seconds is normal. Persistently unsent means the
                queue is stopped, Service Broker is off, or DatabaseMail.exe is not starting.
    retrying    Delivery failed and Database Mail is retrying per AccountRetryAttempts /
                AccountRetryDelay.
    sent        Handed to the SMTP server successfully. This is NOT proof of inbox delivery - the
                relay can still drop, quarantine or bounce it afterwards.
    failed      All retry attempts against all accounts in the profile were exhausted. The error
                text is in sysmail_log, correlated by mailitem_id.

C3. PROFILES, ACCOUNTS AND FAILOVER
---------------------------------------------------------------------------------------------------
A profile contains one or more accounts, ordered by sysmail_profileaccount.sequence_number.
Database Mail tries the lowest sequence_number first and only falls through to the next account
after AccountRetryAttempts fail. A profile is either public (usable by any member of
DatabaseMailUserRole) or private (usable only by the principals in sysmail_principalprofile).
"Profile name is not valid" is almost always a private profile plus a caller who is neither
sysadmin nor mapped to it - not a typo in the profile name.

C4. SQL AGENT MAIL IS CONFIGURED SEPARATELY
---------------------------------------------------------------------------------------------------
Job and alert notifications do not call sp_send_dbmail directly. SQL Agent has its own setting
pointing at one profile. Classic symptom: sp_send_dbmail works interactively but job failure
notifications never arrive. Causes, in order of likelihood:
  1. Agent's "Enable mail profile" is off, or points at a different or nonexistent profile.
  2. Agent was not restarted after the mail profile was set. Agent reads this at startup ONLY.
  3. The job has no operator assigned, or the operator's email address is wrong.
  4. The job actually succeeded, so an "on failure" notification correctly never fired.

C5. LOGGING LEVEL
---------------------------------------------------------------------------------------------------
The sysmail_configuration parameter LoggingLevel controls what reaches sysmail_log:
    1 = Normal     errors only
    2 = Extended   errors, warnings and informational messages (default)
    3 = Verbose    the above plus success entries and internal detail
Raise it to 3 while actively troubleshooting, then put it back - Verbose grows msdb quickly.

C6. AZURE SQL PLATFORM DIFFERENCES
---------------------------------------------------------------------------------------------------
  - Azure SQL Managed Instance: Database Mail IS supported and is the mail mechanism behind MI
    Agent notifications. It needs an SMTP relay reachable from the MI subnet. Outbound port 25 is
    blocked in Azure, so use 587 (or whatever your relay exposes) with TLS.
  - Azure SQL Database (single database / elastic pool): Database Mail is NOT available. There is
    no msdb and no sp_send_dbmail. Use Logic Apps, Azure Automation or Functions instead.
=====================================================================================================*/

USE msdb;
GO

-----------------------------------------------------------------------
-- SECTION 1: FAST TRIAGE
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 1.1 IS MAIL FLOWING? COUNTS BY STATUS
--     Start here. One row per status tells you which branch to follow:
--       mostly 'unsent'  -> queue stopped, Broker off, or the external
--                           process is not starting -> 1.2, then Sec. 2
--       mostly 'failed'  -> SMTP, TLS or auth problem -> 1.3
--       only 'sent'      -> Database Mail did its job. The problem is
--                           downstream (relay, spam filter) or the
--                           caller never sent - see C4 for Agent jobs.
-----------------------------------------------------------------------
SELECT
    i.sent_status,
    COUNT(*)                AS ItemCount,
    SUM(CASE WHEN i.send_request_date >= DATEADD(DAY, -1, SYSDATETIME())
             THEN 1 ELSE 0 END) AS Last24h,
    MIN(i.send_request_date) AS OldestRequest,
    MAX(i.send_request_date) AS NewestRequest,
    MAX(i.sent_date)         AS LastCompletedSend
FROM msdb.dbo.sysmail_allitems AS i
GROUP BY i.sent_status
ORDER BY ItemCount DESC;
GO

-----------------------------------------------------------------------
-- 1.2 QUEUE STATE AND ACTIVATION
--     sysmail_help_status_sp returns STARTED or STOPPED. STOPPED means
--     nothing will ever be sent until it is started again (see 4.1).
--
--     sysmail_help_queue_sp returns both queues (mail and status):
--       length   items waiting. Steadily growing = not draining.
--       state    INACTIVE            nothing to do (normal when idle)
--                NOTIFIED            activation fired, exe should be up
--                RECEIVES_OCCURRING  actively processing
--                A queue stuck in NOTIFIED with a non-zero length means
--                DatabaseMail.exe is failing to start - check 1.4.
--       last_empty_rowset_time / last_activated_time  when it last ran
-----------------------------------------------------------------------
EXEC msdb.dbo.sysmail_help_status_sp;

EXEC msdb.dbo.sysmail_help_queue_sp;   -- @queue_type = 'mail' or 'status' to filter
GO

-----------------------------------------------------------------------
-- 1.3 FAILED ITEMS WITH THE ACTUAL ERROR TEXT      ** KEY QUERY **
--     Joins each failed message to its log entries on mailitem_id, so
--     the recipient and the SMTP error appear together. Reading
--     sysmail_faileditems on its own tells you THAT it failed, never WHY.
--
--     Common ErrorText values and what they actually mean:
--       "The operation has timed out"
--            firewall / NSG / wrong port. Nothing is listening as far
--            as the SQL Server host is concerned.
--       "The SMTP server requires a secure connection or the client was
--        not authenticated"
--            account credentials or enable_ssl mismatch - see 3.2.
--       "Mailbox unavailable" / "5.7.1 Unable to relay"
--            the relay refuses this sender or this recipient domain.
--       "Unable to connect to the remote server"
--            name resolution failure, or the relay is down.
--       "Attachment file ... is invalid" / size errors
--            MaxFileSize or ProhibitedExtensions - see 3.1.
-----------------------------------------------------------------------
SELECT TOP (100)
    i.mailitem_id,
    i.send_request_date,
    i.send_request_user,
    i.recipients,
    i.subject,
    p.name          AS ProfileUsed,
    a.name          AS AccountAttempted,
    l.log_date,
    l.event_type,
    l.description   AS ErrorText
FROM msdb.dbo.sysmail_faileditems AS i
LEFT JOIN msdb.dbo.sysmail_event_log AS l ON l.mailitem_id = i.mailitem_id
LEFT JOIN msdb.dbo.sysmail_profile   AS p ON p.profile_id  = i.profile_id
LEFT JOIN msdb.dbo.sysmail_account   AS a ON a.account_id  = l.account_id
ORDER BY i.send_request_date DESC, l.log_date DESC;
GO

-----------------------------------------------------------------------
-- 1.4 RECENT ERRORS AND WARNINGS FROM THE EVENT LOG
--     Activation failures, DatabaseMail.exe startup problems and
--     configuration errors have no mailitem_id, so query 1.3 will never
--     show them. This catches those.
-----------------------------------------------------------------------
SELECT TOP (100)
    l.log_id,
    l.event_type,
    l.log_date,
    l.mailitem_id,
    l.process_id,
    l.description
FROM msdb.dbo.sysmail_event_log AS l
WHERE l.event_type IN ('error', 'warning')
ORDER BY l.log_date DESC;
GO

-----------------------------------------------------------------------
-- 1.5 STUCK ITEMS - QUEUED BUT NOT DELIVERED
--     Anything more than a few minutes old here is a genuine backlog.
--     If MinutesWaiting keeps climbing, nothing is draining the queue:
--     go back to 1.2, then Section 2.
-----------------------------------------------------------------------
SELECT TOP (100)
    i.mailitem_id,
    i.send_request_date,
    DATEDIFF(MINUTE, i.send_request_date, SYSDATETIME()) AS MinutesWaiting,
    i.send_request_user,
    i.recipients,
    i.subject,
    i.sent_status
FROM msdb.dbo.sysmail_allitems AS i
WHERE i.sent_status IN ('unsent', 'retrying')
ORDER BY i.send_request_date ASC;
GO

-----------------------------------------------------------------------
-- 1.6 FULL HISTORY FOR ONE MESSAGE
--     Once 1.3 or 1.5 gives you a mailitem_id, this returns the message
--     and every log line it produced, in order.
--
--     Note on the catalog objects: sysmail_allitems, sysmail_sentitems,
--     sysmail_faileditems and sysmail_unsentitems are all VIEWS over the
--     sysmail_mailitems base table, filtered by sent_status. Query one
--     of them with your own filter rather than running four
--     near-identical queries. The body column is excluded below on
--     purpose - it is nvarchar(max) and makes the grid unreadable.
-----------------------------------------------------------------------
DECLARE @mailitem_id INT = 0;    -- <<< replace with the id from 1.3 / 1.5

SELECT
    i.mailitem_id,
    i.profile_id,
    i.recipients,
    i.copy_recipients,
    i.blind_copy_recipients,
    i.subject,
    i.body_format,
    i.importance,
    i.file_attachments,
    i.[query],
    i.execute_query_database,
    i.send_request_date,
    i.send_request_user,
    i.sent_account_id,
    i.sent_status,
    i.sent_date
FROM msdb.dbo.sysmail_mailitems AS i
WHERE i.mailitem_id = @mailitem_id;

SELECT
    l.log_id,
    l.event_type,
    l.log_date,
    l.process_id,
    l.description
FROM msdb.dbo.sysmail_event_log AS l
WHERE l.mailitem_id = @mailitem_id
ORDER BY l.log_date ASC;
GO

-----------------------------------------------------------------------
-- SECTION 2: PREREQUISITES AND PERMISSIONS
-- All read-only. Run these when Section 1 shows items stuck 'unsent',
-- or when mail works for you but not for another account.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 2.1 SERVICE BROKER AND DATABASE MAIL XPs
--     Both must be enabled. Broker disabled on msdb means mail never
--     leaves the queue. Database Mail XPs = 0 makes sp_send_dbmail fail
--     immediately with a "blocked by sp_configure" error.
--
--     These read from sys.configurations rather than calling
--     sp_configure: running sp_configure 'show advanced options', 1 is a
--     server-wide WRITE and should never be a side effect of a
--     diagnostic script. Remediation is in 4.2 / 4.3.
-----------------------------------------------------------------------
SELECT
    d.name                  AS DatabaseName,
    d.is_broker_enabled,
    CASE WHEN d.is_broker_enabled = 1 THEN 'OK'
         ELSE 'PROBLEM - mail will queue and never send' END AS BrokerStatus,
    d.service_broker_guid
FROM sys.databases AS d
WHERE d.name = 'msdb';

SELECT
    c.name,
    c.value         AS ConfiguredValue,
    c.value_in_use  AS RunningValue,
    CASE WHEN c.value_in_use = 1 THEN 'OK'
         ELSE 'PROBLEM - sp_send_dbmail will be blocked' END AS XPStatus
FROM sys.configurations AS c
WHERE c.name = 'Database Mail XPs';
GO

-----------------------------------------------------------------------
-- 2.2 WHO IS ALLOWED TO SEND
--     To call sp_send_dbmail a principal must be a member of
--     DatabaseMailUserRole in msdb (sysadmin is implicitly allowed).
--     Missing membership is the usual cause of "profile name is not
--     valid" for an application or service account - see C3.
-----------------------------------------------------------------------
SELECT
    r.name      AS RoleName,
    m.name      AS MemberName,
    m.type_desc AS MemberType,
    m.create_date
FROM msdb.sys.database_role_members AS drm
INNER JOIN msdb.sys.database_principals AS r ON r.principal_id = drm.role_principal_id
INNER JOIN msdb.sys.database_principals AS m ON m.principal_id = drm.member_principal_id
WHERE r.name = 'DatabaseMailUserRole'
ORDER BY m.name;

-- Profile visibility. principal_sid 0x00 is the special "public" entry:
-- that profile is usable by anyone in DatabaseMailUserRole. Any other
-- row means the profile is private and restricted to that principal.
-- A profile with no rows at all can only be used by sysadmin.
SELECT
    p.profile_id,
    p.name                                   AS ProfileName,
    CASE WHEN pp.principal_sid IS NULL THEN 'sysadmin only'
         WHEN pp.principal_sid = 0x00   THEN 'PUBLIC'
         ELSE 'private' END                  AS Scope,
    COALESCE(dp.name, sp.name)               AS PrincipalName,
    pp.is_default
FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_principalprofile AS pp ON pp.profile_id = p.profile_id
LEFT JOIN msdb.sys.database_principals      AS dp ON dp.sid = pp.principal_sid
LEFT JOIN sys.server_principals             AS sp ON sp.sid = pp.principal_sid
ORDER BY p.name, PrincipalName;
GO

-----------------------------------------------------------------------
-- 2.3 SQL AGENT MAIL CONFIGURATION  (see C4)
--     Run this whenever "sp_send_dbmail works but job notifications do
--     not". In the output, check:
--       use_databasemail     must be 1
--       databasemail_profile must name a profile that exists and works
--     If you change either, RESTART SQL SERVER AGENT. It reads these
--     values at startup only.
-----------------------------------------------------------------------
EXEC msdb.dbo.sp_get_sqlagent_properties;
GO

-- Operators and the addresses notifications are actually sent to.
SELECT
    o.id,
    o.name,
    o.enabled,
    o.email_address,
    o.last_email_date,
    o.last_email_time
FROM msdb.dbo.sysoperators AS o
ORDER BY o.name;

-- Enabled jobs that will never notify anyone, whatever they do.
-- notify_level_email: 0 = never, 1 = on success, 2 = on failure, 3 = always.
SELECT
    j.name              AS JobName,
    j.enabled,
    j.notify_level_email,
    o.name              AS NotifyOperator,
    o.email_address
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.sysoperators AS o ON o.id = j.notify_email_operator_id
WHERE j.enabled = 1
  AND (j.notify_level_email = 0
       OR j.notify_email_operator_id IS NULL
       OR j.notify_email_operator_id = 0)
ORDER BY j.name;
GO

-----------------------------------------------------------------------
-- SECTION 3: CONFIGURATION REVIEW
-- Read-only. The same values the Database Mail Configuration Wizard
-- shows, without the clicking.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 3.1 SYSTEM PARAMETERS
--     Worth checking:
--       AccountRetryAttempts / AccountRetryDelay
--                              how long before an item goes 'failed'
--       MaxFileSize            attachment cap in BYTES (default 1000000)
--       ProhibitedExtensions   attachment types refused outright
--       LoggingLevel           1/2/3 - see C5
--       DatabaseMailExeMinimumLifeTime
--                              how long the external process stays alive
--                              waiting for more mail
-----------------------------------------------------------------------
SELECT
    c.paramname,
    c.paramvalue,
    c.description
FROM msdb.dbo.sysmail_configuration AS c
ORDER BY c.paramname;
GO

-----------------------------------------------------------------------
-- 3.2 PROFILES, ACCOUNTS AND SMTP SERVERS IN ONE RESULT SET
--     Replaces sysmail_help_account_sp / sysmail_help_profile_sp /
--     sysmail_help_profileaccount_sp.
--
--     AccountOrder is the failover sequence inside the profile (C3) -
--     the lowest number is tried first.
--     Check SmtpServer, port and enable_ssl against what the relay
--     actually requires; a mismatch is the single most common cause of
--     'failed' items.
--     A NULL AccountName means a profile with no account attached, which
--     can never send.
-----------------------------------------------------------------------
SELECT
    p.name                AS ProfileName,
    pa.sequence_number    AS AccountOrder,
    a.name                AS AccountName,
    a.email_address       AS SendsAs,
    a.display_name,
    a.replyto_address,
    s.servertype,
    s.servername          AS SmtpServer,
    s.port,
    s.enable_ssl,
    s.use_default_credentials,
    s.username            AS SmtpUser,
    CASE WHEN s.credential_id IS NULL THEN 'anonymous / default credentials'
         ELSE 'stored credential' END AS AuthMode,
    a.last_mod_datetime   AS AccountLastModified
FROM msdb.dbo.sysmail_profile AS p
LEFT JOIN msdb.dbo.sysmail_profileaccount AS pa ON pa.profile_id = p.profile_id
LEFT JOIN msdb.dbo.sysmail_account        AS a  ON a.account_id  = pa.account_id
LEFT JOIN msdb.dbo.sysmail_server         AS s  ON s.account_id  = a.account_id
ORDER BY p.name, pa.sequence_number;
GO

-----------------------------------------------------------------------
-- 3.3 BUILT-IN HELPER PROCEDURES
--     Equivalent to 3.1 and 3.2, one result set each. All read-only.
--     Kept for parity with the documentation and because they are what
--     Microsoft support will usually ask you to run.
-----------------------------------------------------------------------
EXEC msdb.dbo.sysmail_help_configure_sp;        -- system parameters
EXEC msdb.dbo.sysmail_help_account_sp;          -- accounts and SMTP servers
EXEC msdb.dbo.sysmail_help_profile_sp;          -- profiles
EXEC msdb.dbo.sysmail_help_profileaccount_sp;   -- profile/account mapping and order
EXEC msdb.dbo.sysmail_help_principalprofile_sp; -- who may use which profile
GO

-----------------------------------------------------------------------
-- SECTION 4: REMEDIATION
-- NOTE: every command below is commented out on purpose. Each one
--       changes server state or sends real email to real recipients.
--       Uncomment one at a time, deliberately.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 4.1 RESTART THE MAIL QUEUE
--     Use when 1.2 reports STOPPED, or after fixing an SMTP problem.
--     Stopping does NOT discard queued items - they resume on start.
--     If you do not want a backlog of stale alerts delivered, purge it
--     (5.2) BEFORE starting the queue again.
-----------------------------------------------------------------------
-- EXEC msdb.dbo.sysmail_stop_sp;
-- EXEC msdb.dbo.sysmail_start_sp;

-----------------------------------------------------------------------
-- 4.2 ENABLE DATABASE MAIL XPs
--     Only if 2.1 shows RunningValue = 0. Takes effect immediately; no
--     service restart required. If 'show advanced options' was 0 before
--     you started, set it back afterwards.
-----------------------------------------------------------------------
-- EXEC sp_configure 'show advanced options', 1;
-- RECONFIGURE;
-- EXEC sp_configure 'Database Mail XPs', 1;
-- RECONFIGURE;

-----------------------------------------------------------------------
-- 4.3 ENABLE SERVICE BROKER ON msdb
--     Only if 2.1 shows is_broker_enabled = 0. This needs exclusive
--     access to msdb, so SQL Server Agent must be stopped first and
--     WITH ROLLBACK IMMEDIATE will kill any other msdb session.
--     Plan this one - it is not a "just run it" change.
-----------------------------------------------------------------------
-- 1) Stop SQL Server Agent.
-- 2) ALTER DATABASE msdb SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
-- 3) Start SQL Server Agent.

-----------------------------------------------------------------------
-- 4.4 SEND A TEST MESSAGE
--     Replace every placeholder. @profile_name must be a profile from
--     3.2 that the CURRENT login is allowed to use (2.2).
--     "Mail queued." is not success - go back to 1.1 and 1.3 to confirm
--     the item actually reached sent_status = 'sent'.
-----------------------------------------------------------------------
-- EXEC msdb.dbo.sp_send_dbmail
--     @profile_name = N'<ProfileName>',
--     @recipients   = N'<you@yourdomain.com>',
--     @subject      = N'Database Mail test',
--     @body         = N'Test message from Database Mail.',
--     @importance   = 'Normal';

-----------------------------------------------------------------------
-- 4.5 RAISE LOGGING TO VERBOSE WHILE TROUBLESHOOTING  (see C5)
--     Set it back to 2 as soon as you are done - Verbose grows msdb
--     quickly on a busy instance.
-----------------------------------------------------------------------
-- EXEC msdb.dbo.sysmail_configure_sp 'LoggingLevel', '3';   -- verbose
-- EXEC msdb.dbo.sysmail_configure_sp 'LoggingLevel', '2';   -- back to default

-----------------------------------------------------------------------
-- SECTION 5: MAINTENANCE AND RETENTION
-- NOTE: 5.1 is read-only. 5.2 and 5.3 DELETE DATA PERMANENTLY and are
--       commented out on purpose. The only undo is an msdb restore.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 5.1 HOW MUCH SPACE IS DATABASE MAIL USING IN msdb?
--     Database Mail keeps every message body and attachment forever
--     unless something deletes them. On busy instances this is one of
--     the largest contributors to msdb growth. Run this before choosing
--     a retention period.
-----------------------------------------------------------------------
SELECT
    t.name                            AS TableName,
    SUM(ps.row_count)                 AS [RowCount],
    CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18, 2)) AS ReservedMB
FROM msdb.sys.dm_db_partition_stats AS ps
INNER JOIN msdb.sys.tables AS t ON t.object_id = ps.object_id
WHERE t.name IN ('sysmail_mailitems', 'sysmail_attachments', 'sysmail_log',
                 'sysmail_send_retries', 'sysmail_attachments_transfer')
  AND ps.index_id IN (0, 1)
GROUP BY t.name
ORDER BY ReservedMB DESC;
GO

-----------------------------------------------------------------------
-- 5.2 PURGE THE QUEUE AFTER AN INCIDENT
--     Use before restarting the queue (4.1) when you do not want a
--     backlog of stale alerts delivered.
--     @sent_status accepts 'sent' | 'unsent' | 'retrying' | 'failed';
--     omit it to delete items of every status.
--     Omitting @sent_before deletes ALL matching items regardless of age.
--     THIS IS PERMANENT.
-----------------------------------------------------------------------
-- EXEC msdb.dbo.sysmail_delete_mailitems_sp
--     @sent_before = '<yyyymmdd>',
--     @sent_status = 'failed';

-----------------------------------------------------------------------
-- 5.3 RETENTION POLICY
--     Deleting mail items also removes their attachments.
--     sysmail_delete_log_sp trims sysmail_log separately - log rows are
--     NOT removed by the item delete, so both calls are needed.
--     Schedule this as an Agent job rather than running it by hand.
--     Keep enough history to still be useful for triage: 90 days is a
--     reasonable default, one month is aggressive.
--     THIS IS PERMANENT.
-----------------------------------------------------------------------
-- DECLARE @CutoffDate DATETIME = DATEADD(DAY, -90, SYSDATETIME());
--
-- EXEC msdb.dbo.sysmail_delete_mailitems_sp @sent_before   = @CutoffDate;
-- EXEC msdb.dbo.sysmail_delete_log_sp       @logged_before = @CutoffDate;

-----------------------------------------------------------------------
-- SECTION 6: REFERENCE - PROVE THE SMTP PATH WITHOUT SQL SERVER
-- Run this from the SQL Server host itself, ideally as the SQL Server
-- service account. It separates "SQL Server is misconfigured" from
-- "this host cannot reach or authenticate to the relay at all".
-----------------------------------------------------------------------
/*
# 1. Can this host even reach the relay? Do this first.
Test-NetConnection -ComputerName "your.smtp.server" -Port 587

# 2. Try a real send. Never hardcode credentials in a script - prompt for them.
#    Send-MailMessage is obsolete but remains the quickest one-liner for a test;
#    use MailKit for anything permanent.
$cred = Get-Credential      # omit this and -Credential if the relay is anonymous

Send-MailMessage `
    -From       "sender@example.com" `
    -To         "recipient@example.com" `
    -Subject    "SMTP relay test from $env:COMPUTERNAME" `
    -Body       "If this arrives, the relay path is fine and the fault is inside SQL Server." `
    -SmtpServer "your.smtp.server" `
    -Port       587 `
    -UseSsl `
    -Credential $cred

# 3. As a SQL Agent job step (PowerShell subsystem) this runs under the Agent
#    service account or a proxy, whose network path and permissions can differ
#    from your interactive session. Test both before concluding anything.
*/