SQL Server DBA Essential Queries

A practical collection of SQL Server / Azure SQL MI scripts for day-to-day operations: incident triage, performance troubleshooting, HA/DR monitoring, replication, backups, security, maintenance, and more.

## Quick start

- Start with 00 - Triage.sql for a fast, read-only snapshot.
- Then jump to the topic scripts below for deeper dives.

## Table of contents (by topic)

### Incident triage

- 00 - Triage.sql

### Performance and Query Store

- performance-checking-queries.sql
- sp_WhoIsActive.sql
- plan-cache-analysis.sql (cache bloat, single-use plans, parameter sniffing, recompiles)
- SQL Server 2022 Diagnostic Information Queries.sql
- SQL Managed Instance Diagnostic Information Queries.sql
- qpi/ (Query Performance Insights)

### Blocking and deadlocks

- performance-checking-queries.sql (blocking + head blocker)
- extended events.sql (deadlock + performance monitoring templates)

### Index and statistics maintenance

- index-and-statistics-maintenance.sql (fragmentation, missing/unused indexes, stale stats, lock contention)

### Database integrity

- database-integrity-checks.sql (DBCC CHECKDB, CHECKTABLE, suspect pages, page verify audit)

### Backups, restores, recovery

- Administration commands V2.0.sql (backup history, restore progress)
- backup-verification.sql (RESTORE VERIFYONLY, backup chain integrity, checksum audit)

### Security and permissions

- security-and-permissions-audit.sql (sysadmin, roles, permissions, orphaned users, linked servers)

### Encryption (TDE / Always Encrypted)

- tde-and-encryption-status.sql (TDE status, certificate expiry, Always Encrypted keys, backup encryption)

### Memory and buffer pool

- buffer-pool-and-memory-analysis.sql (per-DB/object buffer usage, memory clerks, grants, PLE)

### Disk space, files, and transaction log

- disk-space-and-file-management.sql (volume free space, file sizes, autogrowth events, VLFs, log health)

### Configuration audit

- configuration-best-practice-audit.sql (sys.configurations review, DB settings, tempdb, deprecated features)

### HA/DR (AG and MI link)

- AG and MI Link Monitoring scripts.sql

### Replication

- replication-troubleshooting-queries.sql
- Replication Topology.sql

### tempdb, storage, I/O

- tempdb.sql
- IOPs and storage measuring script.sql

### Extended Events

- extended events.sql

### Agent and PowerShell

- SQLAgentMaintenace.sql
- powershell scripts.ps1

### Misc utilities

- T-SQL commands.sql
- Administration commands V2.0.sql

## Conventions / safety notes

- Most scripts are intended to be read-only, but some include DDL (e.g., CREATE EVENT SESSION, job scripts) and DBCC commands. Scan before running.
- Maintenance scripts (index rebuilds, stats updates, CHECKDB) should be run in maintenance windows.
- Some queries require elevated permissions (e.g., xp_readerrorlog, certain DMVs, msdb job history).
- Azure SQL MI has a slightly different DMV surface area than boxed SQL Server; if a section errors, skip it and continue.
