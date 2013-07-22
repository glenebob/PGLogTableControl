PGLogTableControl
=================
A set of stored procedures and control tables that will maintain partitioned tables in a PostgreSQL database in a way that is useful for very large event logs.

Information on Postgres table partitioning:
http://www.postgresql.org/docs/9.2/static/ddl-partitioning.html

Minimum Postgres version: 9.2.

Why it's useful:
  Once you have a log table set up, you can insert new event records into the base log table, and using the Postgres rule and inheritence systems, each record will be redirected to the current partition table.  No data will ever be stored in the base table.  Old data will be removed by dropping entire partitions, rather than deleting individual records.  As a concequence, the tables will never be vacuumed and will never become fragmented, and therefore good indexed query performance will be maintained even on extremely large datasets.

Tables:
  log_control: Describes log tables and basic control information.
    log: Name of the log.
    current_partition: The partition number of the current partition table.
    min_part_age: Minimum age of a partition before it will be superceded by a new one.
    max_part_age: Minimum age of a superceded partition (from it supercede timestamp) before it will be dropped.

  log_partitions: Describes all the partition tables assosciated with base log tables.
    log: Name of log.
    partition: Partition number.
    created: When the partition was created.
    superceded: When the partition was superceded (NULL for current partition).

Functions:
  maintain_log(text): Using log_control, creates new partitions and drops old ones as needed for one log.
  maintain_logs(): Calls maintain_log(text) for each log in log_control.
  clear_log(text): Drops all partitions of a log, resets the partition counter, and creates the first empty partition.
  delete_log(text): Drops all partitions of a log, and deletes its descriptor from log_control.

Usage:
  1) Install the software by executing "psql <log database> Init.sql".

  2) Create a log table. Example:
    CREATE TABLE mylog (time timestamp(0) without time zone, tag varchar(20), data json);
    CREATE INDEX mylog_ts_idx ON mylog (time);

  3) Create a log_control record. Example:
    INSERT INTO log_control (
      log, min_part_age, max_part_age
    ) VALUES (
      'mylog', interval '1 day', interval '3 months'
    );
   
  4) Call maintain_log(text) to initialize the log.  Example:
    SELECT maintain_log('mylog');
    The first partition table will be called "mylog_part_00000001".
   
  5) Set up a cron job that will cause maintain_logs() to be executed at least as often as the shortest log_control.min_part_age value.  Example: Call maintain_logs() every midnight.

  6) To see the table maintenance in action quickly, set min_part_age to interval '1 second', and max_part_age to interval '10 seconds', and then call maintain_logs() repeatedly.
  
