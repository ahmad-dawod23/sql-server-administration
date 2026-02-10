<#
Azure PowerShell - SQL MI + SQL on Azure VM essentials

Safety:
- Most commands are read-only, but some are destructive (Remove-*) or disruptive (Failover/Stop).
- Prefer running discovery commands first and double-checking target names/IDs.

Modules:
- Az.Accounts, Az.Resources, Az.Sql, Az.SqlVirtualMachine, Az.Monitor
#>

# -----------------------------------------------------------------------------
# Authentication / context
# -----------------------------------------------------------------------------

# Install-Module Az -Scope CurrentUser
# Install-Module Az.Sql -Scope CurrentUser
# Install-Module Az.SqlVirtualMachine -Scope CurrentUser

# Connect-AzAccount
# Connect-AzAccount -Tenant <TenantId>

Get-AzContext
Get-AzSubscription | Select-Object Name, Id, TenantId | Format-Table -AutoSize

# Set subscription context
Set-AzContext -Subscription '<SubscriptionId>'

# Useful discovery helpers
Get-AzResourceGroup | Select-Object ResourceGroupName, Location | Sort-Object ResourceGroupName


# =============================================================================
# SQL Managed Instance (MI)
# =============================================================================

# -----------------------------------------------------------------------------
# Discovery / inventory
# -----------------------------------------------------------------------------

# List MI(s) in a subscription
Get-AzSqlInstance | Select-Object Name, ResourceGroupName, Location, SkuName, VCore, StorageSizeInGB, State | Format-Table -AutoSize

# Get one MI
$rg = '<resource_group_name>'
$miName = '<managed_instance_name>'
$mi = Get-AzSqlInstance -ResourceGroupName $rg -Name $miName
$mi | Select-Object Name, ResourceGroupName, Location, SkuName, VCore, StorageSizeInGB, State, SubnetId

# Operations / recent activity
Get-AzSqlInstanceOperation -ResourceGroupName $rg -Name $miName | Select-Object Operation, State, StartTime, PercentComplete | Sort-Object StartTime -Descending

# Databases on MI
Get-AzSqlInstanceDatabase -ResourceGroupName $rg -InstanceName $miName | Select-Object Name, Status, Collation, EarliestRestorePoint, CreationDate | Sort-Object Name


# -----------------------------------------------------------------------------
# Start / stop and schedules (cost control)
# -----------------------------------------------------------------------------

# Immediate start/stop (disruptive)
# Stop-AzSqlInstance -ResourceGroupName $rg -Name $miName
# Start-AzSqlInstance -ResourceGroupName $rg -Name $miName

# Create a start/stop schedule
# Example: start Monday 09:00 and stop Friday 17:00 (pick your TimeZone)
$newSchedule = New-AzSqlInstanceScheduleItem -StartDay Monday -StopDay Friday -StartTime '09:00' -StopTime '17:00'
# New-AzSqlInstanceStartStopSchedule -InstanceName $miName -ResourceGroupName $rg -ScheduleList $newSchedule -TimeZone 'Central Europe Standard Time'

# View / remove schedule
# Get-AzSqlInstanceStartStopSchedule -InstanceName $miName -ResourceGroupName $rg
# Remove-AzSqlInstanceStartStopSchedule -InstanceName $miName -ResourceGroupName $rg -Force


# -----------------------------------------------------------------------------
# Scale / configuration
# -----------------------------------------------------------------------------

# Scaling parameters vary by region/SKU/module version.
# Use this to inspect supported parameters in your environment:
# Get-Help Set-AzSqlInstance -Detailed

# Example pattern (verify parameters with Get-Help first):
# Set-AzSqlInstance -ResourceGroupName $rg -Name $miName -VCore 16 -StorageSizeInGB 2048

# DTC configuration (if you use MSDTC with MI)
# Get-AzSqlInstanceDtc -ResourceGroupName $rg -InstanceName $miName
# Set-AzSqlInstanceDtc -ResourceGroupName $rg -InstanceName $miName -DtcEnabled $true


# -----------------------------------------------------------------------------
# MI links (Distributed AG / link)
# -----------------------------------------------------------------------------

# List MI links
Get-AzSqlInstanceLink -ResourceGroupName $rg -InstanceName $miName | Format-Table -AutoSize

# Create MI link (fill in partner details)
# New-AzSqlInstanceLink -ResourceGroupName $rg -InstanceName $miName -Name '<link_name>' \
#   -PartnerResourceGroupName '<partner_rg>' -PartnerManagedInstanceName '<partner_mi_name>' \
#   -FailoverMode 'Manual' -ReplicationMode 'Async'

# Manual failover (disruptive)
# Invoke-AzSqlInstanceFailover -ResourceGroupName $rg -Name $miName

# Link failover (disruptive)
# Start-AzSqlInstanceLinkFailover -ResourceGroupName $rg -InstanceName $miName -Name '<link_name>'

# Update link properties (verify parameters with Get-Help)
# Update-AzSqlInstanceLink -ResourceGroupName $rg -InstanceName $miName -Name '<link_name>' -FailoverMode 'Manual'

# Remove MI link (destructive)
# Remove-AzSqlInstanceLink -ResourceGroupName $rg -InstanceName $miName -Name '<link_name>' -Force


# -----------------------------------------------------------------------------
# Backup retention + restore (PITR / Geo / LTR)
# -----------------------------------------------------------------------------

$dbName = '<database_name>'

# Short-term retention policy
# Get-AzSqlInstanceDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $rg -InstanceName $miName -DatabaseName $dbName
# Set-AzSqlInstanceDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $rg -InstanceName $miName -DatabaseName $dbName -RetentionDays 14

# Long-term retention policy (LTR)
# Get-AzSqlInstanceDatabaseBackupLongTermRetentionPolicy -ResourceGroupName $rg -InstanceName $miName -DatabaseName $dbName
# Set-AzSqlInstanceDatabaseBackupLongTermRetentionPolicy -ResourceGroupName $rg -InstanceName $miName -DatabaseName $dbName -WeeklyRetention 'P4W' -MonthlyRetention 'P12M' -WeekOfYear 1

# List LTR backups
# Get-AzSqlInstanceDatabaseLongTermRetentionBackup -Location $mi.Location -ManagedInstanceName $miName -DatabaseName $dbName

# Point-in-time restore (creates a NEW database)
$pointInTime = (Get-Date).ToUniversalTime().AddMinutes(-10)
# Restore-AzSqlInstanceDatabase -FromPointInTimeBackup -ResourceGroupName $rg -InstanceName $miName -Name $dbName \
#   -PointInTime $pointInTime -TargetInstanceDatabaseName "${dbName}_restored"

# Geo-restore example pattern
# $geoBackup = Get-AzSqlInstanceDatabaseGeoBackup -ResourceGroupName $rg -InstanceName $miName -Name $dbName
# $geoBackup | Restore-AzSqlInstanceDatabase -FromGeoBackup -TargetInstanceDatabaseName "${dbName}_geo_restored" -TargetInstanceName '<target_mi>' -TargetResourceGroupName '<target_rg>'


# -----------------------------------------------------------------------------
# Security posture (AAD admin, Defender, VA)
# -----------------------------------------------------------------------------

# AAD admin
# Get-AzSqlInstanceActiveDirectoryAdministrator -ResourceGroupName $rg -InstanceName $miName
# Set-AzSqlInstanceActiveDirectoryAdministrator -ResourceGroupName $rg -InstanceName $miName -DisplayName '<AAD Group Name>'
# Remove-AzSqlInstanceActiveDirectoryAdministrator -ResourceGroupName $rg -InstanceName $miName

# Defender for SQL / Advanced Threat Protection
# Get-AzSqlInstanceAdvancedThreatProtectionSetting -ResourceGroupName $rg -InstanceName $miName
# Update-AzSqlInstanceAdvancedThreatProtectionSetting -ResourceGroupName $rg -InstanceName $miName -State Enabled

# Vulnerability Assessment (VA)
# Get-AzSqlInstanceVulnerabilityAssessmentSetting -ResourceGroupName $rg -InstanceName $miName
# Update-AzSqlInstanceVulnerabilityAssessmentSetting -ResourceGroupName $rg -InstanceName $miName -StorageAccountName '<storage_account>' -ScanResultsContainerName 'vulnerability-assessment'


# -----------------------------------------------------------------------------
# Monitoring (metrics + diagnostics)
# -----------------------------------------------------------------------------

# Metrics: discover available metric names first
# Get-AzMetricDefinition -ResourceId $mi.Id | Select-Object Name, Unit | Format-Table -AutoSize

# Pull metrics (example; choose metric names from Get-AzMetricDefinition)
# Get-AzMetric -ResourceId $mi.Id -TimeGrain 00:05:00 -DetailedOutput -StartTime (Get-Date).AddHours(-1) | Select-Object TimeStamp, Name, Average

# Diagnostics (send to Log Analytics)
# $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName '<law_rg>' -Name '<law_name>'
# Get-AzDiagnosticSettingCategory -ResourceId $mi.Id
# Set-AzDiagnosticSetting -Name 'sqlmi-to-law' -ResourceId $mi.Id -WorkspaceId $ws.ResourceId -Enabled $true


# -----------------------------------------------------------------------------
# Networking pointers (MI lives in a subnet)
# -----------------------------------------------------------------------------

# Inspect the subnet Id and look up VNet/subnet details
# $mi.SubnetId
# $subnetIdParts = $mi.SubnetId -split '/'
# $vnetName = $subnetIdParts[$subnetIdParts.IndexOf('virtualNetworks') + 1]
# $subnetName = $subnetIdParts[$subnetIdParts.IndexOf('subnets') + 1]
# $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rg
# Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet


# =============================================================================
# SQL Server on Azure VM (SQL IaaS extension)
# =============================================================================

# -----------------------------------------------------------------------------
# Discovery / registration
# -----------------------------------------------------------------------------

# List registered SQL VMs
Get-AzSqlVM | Select-Object Name, ResourceGroupName, Location, SqlManagementType, LicenseType, Offer, Sku | Format-Table -AutoSize

# Register an existing compute VM with SQL IaaS agent (LightWeight)
$vmName = '<vm_name>'
$vmRg = '<vm_resource_group>'
$vm = Get-AzVM -Name $vmName -ResourceGroupName $vmRg

# New-AzSqlVM registers the SQL VM resource
# New-AzSqlVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Location $vm.Location -LicenseType PAYG -SqlManagementType LightWeight

# Update registration (e.g., change management type)
# Update-AzSqlVM -Name $vmName -ResourceGroupName $vmRg -SqlManagementType Full

# Remove SQL VM registration (does NOT delete the compute VM, but removes SQL IaaS resource)
# Remove-AzSqlVM -Name $vmName -ResourceGroupName $vmRg -Force


# -----------------------------------------------------------------------------
# Troubleshooting and platform operations
# -----------------------------------------------------------------------------

# Redeploy SQL VM (host move; disruptive)
# Invoke-AzRedeploySqlVM -Name $vmName -ResourceGroupName $vmRg

# Run troubleshooting (collects diagnostics)
# Invoke-AzSqlVMTroubleshoot -Name $vmName -ResourceGroupName $vmRg

# Run SQL VM assessment
# Start-AzSqlVMAssessment -Name $vmName -ResourceGroupName $vmRg


# -----------------------------------------------------------------------------
# Always On (SQL VM Group / Listener)
# -----------------------------------------------------------------------------

# SQL VM groups
# Get-AzSqlVMGroup
# New-AzSqlVMGroup -Name '<sqlvm_group>' -ResourceGroupName $vmRg -Location $vm.Location -DomainFqdn '<domain.fqdn>' -ClusterOperatorAccount '<domain\\account>' -SqlServiceAccount '<domain\\account>'
# Update-AzSqlVMGroup -Name '<sqlvm_group>' -ResourceGroupName $vmRg
# Remove-AzSqlVMGroup -Name '<sqlvm_group>' -ResourceGroupName $vmRg -Force

# Availability Group listeners
# Get-AzAvailabilityGroupListener -ResourceGroupName $vmRg -SqlVMGroupName '<sqlvm_group>'
# New-AzAvailabilityGroupListener -Name '<listener_name>' -ResourceGroupName $vmRg -SqlVMGroupName '<sqlvm_group>' -AvailabilityGroupName '<ag_name>'
# Remove-AzAvailabilityGroupListener -Name '<listener_name>' -ResourceGroupName $vmRg -SqlVMGroupName '<sqlvm_group>' -Force


# -----------------------------------------------------------------------------
# In-guest Windows service helper (SQL VM)
# -----------------------------------------------------------------------------

# Note: Save as something like C:\SQL-startup.ps1 and run with admin rights.
$SQLService = 'SQL Server (MSSQLSERVER)'
$SQLAgentService = 'SQL Server Agent (MSSQLSERVER)'
$TempdbData = 'D:\Tempdb\Data'
$TempdbLog = 'D:\Tempdb\Log'

if (-not (Test-Path -Path $TempdbData)) { New-Item -ItemType Directory -Path $TempdbData | Out-Null }
if (-not (Test-Path -Path $TempdbLog)) { New-Item -ItemType Directory -Path $TempdbLog | Out-Null }

Start-Service $SQLService
Start-Service $SQLAgentService

# Check availability group resource type from Windows Failover Cluster (inside the VM)
# Get-ClusterResourceType | Where-Object Name -like 'SQL Server Availability Group'
