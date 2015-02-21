--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

SET search_path = public, pg_catalog;

--
-- Name: clear_log(text); Type: FUNCTION;
--

CREATE FUNCTION clear_log(log_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
  control       record;
  partition     record;
  part_num      int;
  part_name     text;

BEGIN
  SELECT * INTO control FROM log_control WHERE log = log_name FOR UPDATE;

  IF control IS NULL THEN
    RAISE EXCEPTION 'Log % is not defined', log_name;
  END IF;

  UPDATE log_control SET current_partition = NULL WHERE log = log_name;

  FOR partition IN SELECT * FROM log_partitions WHERE log_partitions.log = log_name ORDER BY partition LOOP
    part_num = partition.partition;
    part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');

    EXECUTE 'DROP TABLE "' || part_name || '" CASCADE';
    DELETE FROM log_partitions WHERE log_partitions.log = log_name AND log_partitions.partition = part_num;
  END LOOP;

  part_num := 1;
  part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');

  EXECUTE 'CREATE TABLE "' || part_name || '" (LIKE "' || log_name || '" INCLUDING ALL) INHERITS ("' || log_name || '")';
  EXECUTE 'CREATE OR REPLACE RULE "' || log_name || '_insert_redirect" AS ON INSERT TO "' || log_name || '" DO INSTEAD INSERT INTO "' || part_name || '" SELECT new.*';
  EXECUTE 'CREATE OR REPLACE RULE "' || part_name || '_update_block" AS ON UPDATE TO "' || part_name || '" DO INSTEAD NOTIFY "' || part_name || '"';
  EXECUTE 'CREATE OR REPLACE RULE "' || part_name || '_delete_block" AS ON DELETE TO "' || part_name || '" DO INSTEAD NOTIFY "' || part_name || '"';

  EXECUTE 'INSERT INTO log_partitions (log, partition, created) VALUES (''' || log_name || ''', ''' || part_num || ''',  current_timestamp AT TIME ZONE ''UTC'')';
  EXECUTE 'UPDATE log_control SET current_partition = ' || part_num || ' WHERE log = ''' || log_name || '''';
END;
$$;


--
-- Name: delete_log(text); Type: FUNCTION;
--

CREATE FUNCTION delete_log(log_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
  control       record;
  partition     record;
  part_num      int;
  part_name     text;

BEGIN
  SELECT * INTO control FROM log_control WHERE log = log_name FOR UPDATE;

  IF control IS NULL THEN
    RAISE EXCEPTION 'Log % is not defined', log_name;
  END IF;

  UPDATE log_control SET current_partition = NULL WHERE log = log_name;

  FOR partition IN SELECT * FROM log_partitions WHERE log_partitions.log = log_name ORDER BY partition LOOP
    part_num = partition.partition;
    part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');

    EXECUTE 'DROP TABLE "' || part_name || '" CASCADE';
    DELETE FROM log_partitions WHERE log_partitions.log = log_name AND log_partitions.partition = part_num;
  END LOOP;

  EXECUTE 'DROP TABLE "' || log_name || '"';

  DELETE FROM log_control WHERE log = log_name;
END;
$$;


--
-- Name: maintain_log(text); Type: FUNCTION;
--

CREATE FUNCTION maintain_log(log_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
  control       record;
  partition     record;
  create_part   bool;
  delete_part   bool;
  part_num      int;
  part_name     text;
  record_count  int;

BEGIN
  SELECT * INTO control FROM log_control WHERE log = log_name FOR UPDATE;

  IF (control IS NULL) THEN
    RAISE EXCEPTION 'Log % is not defined', log_name;
  END IF;

  IF (control.current_partition IS NULL) THEN
    create_part := true;
    part_num := 1;

    SELECT * INTO partition FROM log_partitions WHERE log IS NULL LIMIT 0;
  ELSE
    part_num = control.current_partition;
    part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');

    SELECT * INTO partition FROM log_partitions WHERE log = log_name AND log_partitions.partition = part_num;

    IF (partition IS NULL) THEN
      RAISE EXCEPTION 'Partition record for current partition not found';
    END IF;

    IF (partition.superceded IS NOT NULL) THEN
      RAISE EXCEPTION 'Partition record for current partition already superceded';
    END IF;

    IF (partition.created + control.min_part_age - INTERVAL '10 minute' < current_timestamp AT TIME ZONE 'UTC') THEN
      create_part = true;
      part_num := control.current_partition + 1;
    END IF;
  END IF;

  IF (create_part) THEN
    IF (NOT partition IS NULL) THEN
      EXECUTE 'UPDATE log_partitions SET superceded = current_timestamp AT TIME ZONE ''UTC'' WHERE log = ''' || log_name || ''' AND partition = ' || partition.partition;
      EXECUTE 'CREATE OR REPLACE RULE ' || part_name || '_insert_block AS ON INSERT TO ' || part_name || ' DO INSTEAD NOTIFY ' || part_name;
    END IF;

    part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');
    control.current_partition = part_num;

    EXECUTE 'CREATE TABLE "' || part_name || '" (LIKE "' || log_name || '" INCLUDING ALL) INHERITS ("' || log_name || '")';
    EXECUTE 'CREATE OR REPLACE RULE "' || log_name || '_insert_redirect" AS ON INSERT TO "' || log_name || '" DO INSTEAD INSERT INTO "' || part_name || '" SELECT new.*';
    EXECUTE 'CREATE OR REPLACE RULE "' || part_name || '_update_block" AS ON UPDATE TO "' || part_name || '" DO INSTEAD NOTIFY "' || part_name || '"';
    EXECUTE 'CREATE OR REPLACE RULE "' || part_name || '_delete_block" AS ON DELETE TO "' || part_name || '" DO INSTEAD NOTIFY "' || part_name || '"';

    EXECUTE 'INSERT INTO log_partitions (log, partition, created) VALUES (''' || log_name || ''', ' || part_num || ',  current_timestamp AT TIME ZONE ''UTC'')';
    EXECUTE 'UPDATE log_control SET current_partition = ' || part_num || ' WHERE log = ''' || log_name || '''';
  END IF;

  FOR partition IN SELECT * FROM log_partitions WHERE log_partitions.log = log_name AND log_partitions.partition <> part_num ORDER BY partition LOOP
    delete_part := false;

    part_num = partition.partition;
    part_name := log_name || '_part_' || to_char(part_num, 'FM00000000');

    IF (partition.superceded + control.max_part_age < current_timestamp AT TIME ZONE 'UTC') THEN
      delete_part := true;
    END IF;

    IF (NOT delete_part) THEN
      EXECUTE 'SELECT count(*) FROM "' || part_name || '" LIMIT 1' INTO record_count;

      IF (record_count = 0) THEN
        delete_part = true;
      END IF;
    END IF;

    IF (delete_part) THEN
      EXECUTE 'DROP TABLE "' || part_name || '"';

      DELETE FROM log_partitions WHERE log_partitions.log = log_name AND log_partitions.partition = partition.partition;
    END IF;
  END LOOP;
END;
$$;


--
-- Name: maintain_logs(); Type: FUNCTION;
--

CREATE FUNCTION maintain_logs() RETURNS void
    LANGUAGE plpgsql
    AS $$DECLARE
  logs         record;

BEGIN

  FOR logs IN SELECT * FROM log_control ORDER BY log LOOP
    PERFORM maintain_log(logs.log);
  END LOOP;
  
END;
$$;


SET default_with_oids = false;


--
-- Name: log_control; Type: TABLE;
--

CREATE TABLE log_control (
    log character varying(20) NOT NULL,
    current_partition integer,
    min_part_age interval NOT NULL,
    max_part_age interval NOT NULL
);


--
-- Name: log_partitions; Type: TABLE;
--

CREATE TABLE log_partitions (
    log character varying(20) NOT NULL,
    partition integer NOT NULL,
    created timestamp(0) without time zone NOT NULL,
    superceded timestamp(0) without time zone
);


--
-- Name: log_control_pkey; Type: CONSTRAINT;
--

ALTER TABLE ONLY log_control
    ADD CONSTRAINT log_control_pkey PRIMARY KEY (log);


--
-- Name: log_partitions_pkey; Type: CONSTRAINT;
--

ALTER TABLE ONLY log_partitions
    ADD CONSTRAINT log_partitions_pkey PRIMARY KEY (log, partition);


--
-- Name: log_control_log_fkey; Type: FK CONSTRAINT;
--

ALTER TABLE ONLY log_control
    ADD CONSTRAINT log_control_log_fkey FOREIGN KEY (log, current_partition) REFERENCES log_partitions(log, partition) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: log_partitions_log_fkey; Type: FK CONSTRAINT;
--

ALTER TABLE ONLY log_partitions
    ADD CONSTRAINT log_partitions_log_fkey FOREIGN KEY (log) REFERENCES log_control(log);


--
-- Name: public; Type: ACL; Schema: -; Owner: postgres
--


--
-- PostgreSQL database dump complete
--
