-- ICT371 Q5: Hostel Room Allocation (schema q5)
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
 ('2026001','Chanda Mwila'), ('2026002','Mutale Banda'), ('2026003','Natasha Phiri'),
 ('2026004','Joseph Zulu'),  ('2026005','Mercy Tembo'),  ('2026006','Peter Lungu');
INSERT INTO rooms (room_number, capacity) VALUES
 ('R101', 2),   -- will be full
 ('R102', 3),   -- partly occupied
 ('R103', 2),   -- empty
 ('R104', 1);   -- only ended history

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql SET search_path = q5 AS $$
DECLARE v_cap INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;
    RETURN v_cap - (SELECT COUNT(*) FROM allocations
                     WHERE room_id = p_room_id AND status = 'ACTIVE');
END $$;

-- (c) Procedure (capacity and one-active rules are enforced again by the trigger)
CREATE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql SET search_path = q5 AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- lock the room
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END $$;

-- (d) Trigger: same rules for direct SQL; the row being changed is excluded ------
CREATE FUNCTION trg_allocation_rules() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q5 AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF EXISTS (SELECT 1 FROM allocations a
                    WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
                      AND a.allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
        SELECT COUNT(*) INTO v_used FROM allocations a
         WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
           AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;
        IF v_used >= v_cap THEN
            RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (e) View: LEFT JOIN keeps rooms that have no allocations --------------------
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
 GROUP BY r.room_id, r.room_number, r.capacity
 ORDER BY r.room_id;

-- Seed allocations -------------------------------------------------------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);   -- R101 full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);   -- R102 partly occupied
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
 (4, 2, CURRENT_DATE - 120, CURRENT_DATE - 70, 'ENDED'),   -- history: no bed used
 (5, 4, CURRENT_DATE - 100, CURRENT_DATE - 40, 'ENDED');   -- R104 empty again

-- Tests
SELECT fn_free_beds(1) AS r101, fn_free_beds(2) AS r102, fn_free_beds(3) AS r103, fn_free_beds(4) AS r104;
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);         -- full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);         -- already active
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (6, 1, CURRENT_DATE, 'ACTIVE');             -- direct SQL, trigger blocks it
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM v_room_occupancy;

-- (f) Index -----------------------------------------------------------------
-- Partial index on ACTIVE rows only: occupancy checks (function, trigger, view)
-- only ever count ACTIVE rows per room, and ENDED history can grow without
-- making this index bigger or slower.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- Guard against concurrent double-allocation of one student (optional safety net)
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

-- (g) Scheduled job -----------------------------------------------------------
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql SET search_path = q5 AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
      FROM rooms r
      LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
     GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();     -- rerun: values replaced, still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q5_refresh_occupancy', '55 23 * * *',
        $cmd$CALL q5.pr_refresh_occupancy()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 55 23 * * *  CALL q5.pr_refresh_occupancy()';
  END IF;
END $do$;
