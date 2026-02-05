--==============================

--sql agent email test from powershell step
$SmtpServer = "your.smtp.server"
$Port = 587
$Username = "your_username@example.com" # if auth is needed
$Password = ConvertTo-SecureString "your_password" -AsPlainText -Force # if auth is needed
$Credential = New-Object System.Management.Automation.PSCredential($Username, $Password) # if auth is needed

Send-MailMessage -From "sender@example.com" -To "recipient@example.com" -Subject "Test Email from PowerShell" -Body "This is a test email." -SmtpServer $SmtpServer -Port $Port -UseSsl # Add -Credential $Credential if auth is needed

--===============================

--SQL agent job on the problem MI server, follow the below steps:
 
--1- Create a job 
--2- Create a step with step name 'Test Connection' 
--3- Add the below PowerShell script:

tnc login.windows.net  -port 443 | select ComputerName, RemoteAddress, TcpTestSucceeded | Format-List

nslookup faultyendpoint.com

--4- Save and close job
--5- Goto jobs area in SQL Agent 
--6- Right-click on the created job and select 'Start Job at Step'
--7- After making sure the job executed successfully
--8- Run the below script and send the results to me:

--direct script-----------

USE [msdb]
GO

/****** Object:  Job [connectiontest]    Script Date: 5/11/2025 3:43:56 PM ******/
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
/****** Object:  JobCategory [[Uncategorized (Local)]]    Script Date: 5/11/2025 3:43:56 PM ******/
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'[Uncategorized (Local)]' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'[Uncategorized (Local)]'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'connectiontest', 
		@enabled=0, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'No description available.', 
		@category_name=N'[Uncategorized (Local)]', 
		--@owner_login_name=N'', 
		@job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
/****** Object:  Step [test 2nd mi]    Script Date: 5/11/2025 3:43:57 PM ******/
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'test 2nd mi', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'PowerShell', 
		@command=N'tnc test.blob.core.windows.net -port 443 | select ComputerName, RemoteAddress, TcpTestSucceeded | Format-List', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO


select [message] 
from [msdb].[dbo].[sysjobhistory]
where step_name like '%test'



---- find running sql agent jobs

SELECT
    ja.job_id,
    j.name AS job_name,
    ja.start_execution_date,
    DATEDIFF(SECOND, ja.start_execution_date, GETDATE()) AS elapsed_seconds,
    s.session_id,
    r.command
FROM msdb.dbo.sysjobactivity AS ja
INNER JOIN msdb.dbo.sysjobs AS j
    ON ja.job_id = j.job_id
INNER JOIN msdb.dbo.syssessions AS s
    ON ja.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests AS r
    ON r.session_id = s.session_id
WHERE ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL;
  
  
 