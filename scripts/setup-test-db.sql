-- Create separate test DB for xunit. Drops first if exists.
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = 'cc_sessions_coord_test'
   AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS cc_sessions_coord_test;
CREATE DATABASE cc_sessions_coord_test;
