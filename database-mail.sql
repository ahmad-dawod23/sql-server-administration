-----------------------------------------------------------------------
-- DATABASE MAIL DIAGNOSTICS
-- Purpose : Check Database Mail configuration, queues, and logs for 
--           issues. Review settings and troubleshoot send failures.
-- Safety  : All queries are read-only except for deletion commands
--           which are clearly marked.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- 0. SQL AGENT EMAIL TEST FROM POWERSHELL STEP (Reference)
-----------------------------------------------------------------------
/*
$SmtpServer = "your.smtp.server"
$Port = 587
$Username = "your_username@example.com" # if auth is needed
$Password = ConvertTo-SecureString "your_password" -AsPlainText -Force # if auth is needed
$Credential = New-Object System.Management.Automation.PSCredential($Username, $Password) # if auth is needed

Send-MailMessage -From "sender@example.com" -To "recipient@example.com" -Subject "Test Email from PowerShell" -Body "This is a test email." -SmtpServer $SmtpServer -Port $Port -UseSsl # Add -Credential $Credential if auth is needed
*/

-----------------------------------------------------------------------
-- 1. VERIFY DATABASE MAIL PREREQUISITES
-----------------------------------------------------------------------
USE msdb;
GO

-- Verify Service Broker is enabled on MSDB.
-- The is_broker_enabled value must be 1 for Database Mail to function.
SELECT is_broker_enabled 
FROM sys.databases 
WHERE name = 'msdb';
GO

-- Verify Database Mail XPs are enabled.
-- The run_value must be 1 for Database Mail to function.
-- Note: This configuration change does not require a server restart.
EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
EXEC sp_configure 'Database Mail XPs';
GO

-----------------------------------------------------------------------
-- 2. REVIEW DATABASE MAIL QUEUES AND STATUS
-----------------------------------------------------------------------
-- Review Database Mail queues.
-- This stored procedure displays both Database Mail queues (mail and status).
-- Use @queue_type parameter to filter to a specific queue.
-- Output includes: queue length, state (INACTIVE/NOTIFIED/RECEIVES_OCCURRING),
-- last empty time, and last active time.
EXEC msdb.dbo.sysmail_help_queue_sp; -- @queue_type = 'Mail'
GO

-- Check Database Mail queue status (STARTED or STOPPED).
-- EXEC msdb.dbo.sysmail_start_sp -- Start the queue
-- EXEC msdb.dbo.sysmail_stop_sp -- Stop the queue
EXEC msdb.dbo.sysmail_help_status_sp;
GO

-----------------------------------------------------------------------
-- 3. REVIEW DATABASE MAIL CONFIGURATION SETTINGS
-----------------------------------------------------------------------
-- The following stored procedures display configuration details,
-- accounts, profiles,account-profile associations, and
-- principal-profile permissions.
-- These settings are typically managed through the Database Mail 
-- Configuration Wizard.

EXEC msdb.dbo.sysmail_help_configure_sp;
GO

EXEC msdb.dbo.sysmail_help_account_sp;
--  Verify the server name, server type, and email address
--  are configured correctly for your account.
GO

EXEC msdb.dbo.sysmail_help_profile_sp;
--  Verify you are using a valid profile in your sp_send_dbmail calls.
GO

EXEC msdb.dbo.sysmail_help_profileaccount_sp;
--  Verify the account and profile associations are configured correctly.
GO

EXEC msdb.dbo.sysmail_help_principalprofile_sp;
GO

-----------------------------------------------------------------------
-- 4. REVIEW DATABASE MAIL EVENT LOG AND QUEUED EMAILS
-----------------------------------------------------------------------
-- The following queries use TOP 100 to limit results, as these tables
-- can contain large amounts of data. Adjust the row limit as needed.

-- Review the Database Mail event log.
-- Pay special attention to event_type = 'error' for troubleshooting 
-- send failures.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_event_log 
ORDER BY last_mod_date DESC;
GO

-- Review all queued emails.
-- Check sent_status for 'failed' or 'unsent' messages.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_allitems 
ORDER BY last_mod_date DESC;
GO

-- Review successfully sent emails.
-- This view filters sysmail_allitems WHERE sent_status = 'sent'.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_sentitems 
ORDER BY last_mod_date DESC;
GO

-- Review failed email deliveries.
-- This view filters sysmail_allitems WHERE sent_status = 'failed'.
SELECT TOP 100 * 
FROM msdb.dbo.sysmail_faileditems 
ORDER BY last_mod_date DESC;
GO


-----------------------------------------------------------------------
-- 5. TRACK MESSAGE DELIVERY STATUS
-----------------------------------------------------------------------
-- Track the delivery status of individual messages.
SELECT * FROM msdb.dbo.sysmail_unsentitems;
GO

SELECT * FROM msdb.dbo.sysmail_mailattachments;
GO

-- Query the Database Mail outgoing message log.
SELECT * FROM msdb.dbo.sysmail_mailitems;
GO

-----------------------------------------------------------------------
-- 6. DELETE OLD EMAILS FROM QUEUE
-----------------------------------------------------------------------
-- Delete old emails from the queue.
-- Use this before restarting the queue after resolving issues
-- to prevent sending outdated or accumulated messages.
-- Can be used to remove emails with any sent_status value.
EXEC msdb.dbo.sysmail_delete_mailitems_sp  
    @sent_before = '2017-03-16',
    @sent_status = 'failed';
GO
-----------------------------------------------------------------------
-- 7. ENABLE DATABASE MAIL AND SEND TEST EMAIL
-----------------------------------------------------------------------
-- To enable Database Mail extended stored procedures:
-- Option 1: Run the Database Mail Configuration Wizard
-- Option 2: Set sp_configure option 'Database Mail XPs' to 1

EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'Proseware Administrator',
    @recipients = 'admin@AdventureWorks.com',
    @body = 'Daily backup completed successfully.',
    @subject = 'Daily backup status';
GO

-----------------------------------------------------------------------
-- 8. IMPLEMENT RETENTION POLICY
-----------------------------------------------------------------------
-- Implement a retention policy to control msdb database growth.
-- This example deletes messages, attachments, and log entries 
-- older than one month.
USE msdb;
GO

DECLARE @CutoffDate DATETIME;
SET @CutoffDate = DATEADD(MONTH, -1, SYSDATETIME());

EXEC dbo.sysmail_delete_mailitems_sp
    @sent_before = @CutoffDate;

EXEC dbo.sysmail_delete_log_sp
    @logged_before = @CutoffDate;
GO