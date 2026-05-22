-- Reset cc_sessions_coord database completely.
-- Run as postgres superuser against the postgres DB (not cc_sessions_coord).

SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = 'cc_sessions_coord'
   AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS cc_sessions_coord;
DROP ROLE     IF EXISTS ccsc_bridge;
DROP ROLE     IF EXISTS ccsc_hook;
DROP ROLE     IF EXISTS ccsc_worker;

CREATE DATABASE cc_sessions_coord;
