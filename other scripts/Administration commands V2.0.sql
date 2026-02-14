-----------------------------------------------------------------------
-- GENERAL ADMINISTRATION UTILITIES
-- Purpose : Miscellaneous admin queries that don't fit into specialized
--           categories ā error logs, network protocol checks, restore
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
-- 7. RING BUFFER ā XE LOG ERRORS
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
 
 
  
