-- Q4(a) Tables & Seed Data
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date   DATE PRIMARY KEY,
    booked_count   INTEGER NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count INTEGER NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

-- Q4(b) Function: fn_daily_load
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_cnt
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN COALESCE(v_cnt, 0);
END;
$$;

-- Q4(d) Trigger: BEFORE INSERT OR UPDATE clash check
CREATE OR REPLACE FUNCTION fn_trg_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot conflict for doctor % on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_appointments_no_clash();

-- Q4(c) Procedure: pr_book_appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id  INT,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % cannot be in the past', p_day;
    END IF;

    IF p_slot NOT IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time: %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Seed 3 patients, 3 doctors & 6 non-clashing appointments
INSERT INTO patients (full_name) VALUES ('Mapalo Siwale'), ('Daka Chibwe'), ('Zimba Kangwa');
INSERT INTO doctors (full_name) VALUES ('Dr. Mumba'), ('Dr. Sakala'), ('Dr. Phiri');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, '10:00:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, '11:00:00', 'ATTENDED'),
    (1, 1, CURRENT_DATE, '09:00:00', 'BOOKED'),
    (2, 2, CURRENT_DATE, '10:00:00', 'BOOKED'),
    (3, 3, CURRENT_DATE, '12:00:00', 'BOOKED');

-- Q4(e) View: today's BOOKED appointments without unrelated patient data
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time;

-- Q4(f) Composite Index & EXPLAIN
-- Speeds up filtering a doctor's appointments on a given day
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
-- Expected plan node: Index Scan using idx_appointments_day_doctor on appointments

-- Q4(g) Procedure & Scheduled Job (01:00 daily for previous day)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, COALESCE(v_booked, 0), COALESCE(v_attended, 0), COALESCE(v_cancelled, 0))
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule(
    'refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);$$
);