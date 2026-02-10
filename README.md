SQL Server DBA Essential Queries

A practical collection of SQL Server / Azure SQL MI scripts for day-to-day operations: incident triage, performance troubleshooting, HA/DR monitoring, replication, backups, tempdb, and Extended Events.

## Quick start

- Start with 00 - Triage.sql for a fast, read-only snapshot.
- Then jump to the topic scripts below for deeper dives.

## Table of contents (by topic)

### Incident triage

- 00 - Triage.sql

### Performance and Query Store

- performance-checking-queries.sql
- sp_WhoIsActive.sql / who_is_active.sql
- SQL Server 2022 Diagnostic Information Queries.sql
- SQL Managed Instance Diagnostic Information Queries.sql
- qpi-master/ (Query Performance Insights)

### Blocking and deadlocks

- performance-checking-queries.sql (blocking + head blocker)
- extended events.sql (deadlock + performance monitoring templates)

### Backups, restores, recovery

- Administration commands V2.0.sql (backup history, restore progress)
- MaintenanceSolution.sql

### HA/DR (AG and MI link)

- AG and MI Link Monitoring scripts.sql

### Replication

- replication-troubleshooting-queries.sql
- Replication Topology (1).sql
- replication.txt

### tempdb, storage, I/O

- tempdb.sql
- IOPs and storage measuring script.sql

### Extended Events

- extended events.sql

### Agent and PowerShell

- SQLAgentMaintenace.sql
- powershell scripts.txt

### Misc utilities

- T-SQL commands.sql
- Administration commands V2.0.sql

## Conventions / safety notes

- Most scripts are intended to be read-only, but some include DDL (e.g., CREATE EVENT SESSION, job scripts) and DBCC commands. Scan before running.
- Some queries require elevated permissions (e.g., xp_readerrorlog, certain DMVs, msdb job history).
- Azure SQL MI has a slightly different DMV surface area than boxed SQL Server; if a section errors, skip it and continue.
