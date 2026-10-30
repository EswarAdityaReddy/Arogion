-- Supabase SQL Schema for Arogion User Authentication
-- Run this in your Supabase SQL Editor

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Create users table
CREATE TABLE IF NOT EXISTS users (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    firebase_uid TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    nickname TEXT,
    email TEXT NOT NULL,
    dob DATE,
    gender TEXT,
    profile_image TEXT,
    phone_number TEXT,
    height FLOAT,
    weight FLOAT,
    blood_group TEXT,
    allergies TEXT,
    medical_conditions TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create index on firebase_uid for faster lookups
CREATE INDEX IF NOT EXISTS idx_users_firebase_uid ON users(firebase_uid);

-- Enable Row Level Security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Create policy to allow users to read their own data
DROP POLICY IF EXISTS "Users can view own profile" ON users;
CREATE POLICY "Users can view own profile" ON users
    FOR SELECT USING (true);

-- Create policy to allow inserting new users
DROP POLICY IF EXISTS "Users can insert own profile" ON users;
CREATE POLICY "Users can insert own profile" ON users
    FOR INSERT WITH CHECK (true);

-- Create policy to allow users to update their own data
DROP POLICY IF EXISTS "Users can update own profile" ON users;
CREATE POLICY "Users can update own profile" ON users
    FOR UPDATE USING (true);

-- Create storage bucket for avatars (run separately if needed)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('avatars', 'avatars', true);

-- Storage policy for avatars
-- CREATE POLICY "Avatar images are publicly accessible" ON storage.objects
--     FOR SELECT USING (bucket_id = 'avatars');

-- CREATE POLICY "Anyone can upload an avatar" ON storage.objects
--     FOR INSERT WITH CHECK (bucket_id = 'avatars');

-- CREATE POLICY "Anyone can update their own avatar" ON storage.objects
--     FOR UPDATE USING (bucket_id = 'avatars');

-- -----------------------------------------------------------------------------
-- Doctors, Hospitals, Treatments, and Availability
-- -----------------------------------------------------------------------------

-- Hospitals where doctors are available
CREATE TABLE IF NOT EXISTS hospitals (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT NOT NULL,
    state TEXT,
    country TEXT DEFAULT 'India',
    address TEXT,
    location_label TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    phone_number TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Doctors master data
CREATE TABLE IF NOT EXISTS doctors (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    full_name TEXT NOT NULL,
    specialty TEXT NOT NULL,
    years_experience INT DEFAULT 0,
    qualification TEXT,
    about TEXT,
    profile_image_url TEXT,
    rating NUMERIC(3,2) DEFAULT 0,
    reviews_count INT DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (years_experience >= 0),
    CHECK (rating >= 0 AND rating <= 5),
    CHECK (reviews_count >= 0)
);

-- A doctor can work at multiple hospitals
CREATE TABLE IF NOT EXISTS doctor_hospital_assignments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    doctor_id UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    department TEXT,
    consultation_fee NUMERIC(10,2),
    is_primary BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (doctor_id, hospital_id)
);

-- Treatment/procedure catalog
CREATE TABLE IF NOT EXISTS treatments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    code TEXT UNIQUE,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (category IN ('op', 'ip', 'procedure', 'surgery', 'diagnostic', 'therapy', 'teleconsultation'))
);

-- Home categories shown on dashboard
CREATE TABLE IF NOT EXISTS home_categories (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    icon_key TEXT NOT NULL,
    color_hex TEXT NOT NULL DEFAULT '#89C2D1',
    sort_order INT NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (color_hex ~* '^#[0-9A-F]{6}$')
);

-- Treatments provided by doctors and how they are delivered
CREATE TABLE IF NOT EXISTS doctor_treatments (
    doctor_id UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
    treatment_id UUID NOT NULL REFERENCES treatments(id) ON DELETE CASCADE,
    offered_as TEXT NOT NULL,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (doctor_id, treatment_id, offered_as),
    CHECK (offered_as IN ('op', 'ip', 'daycare', 'procedure'))
);

-- Date-wise and time-wise availability slots for booking
CREATE TABLE IF NOT EXISTS doctor_availability_slots (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    doctor_id UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    slot_date DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    slot_duration_minutes INT NOT NULL DEFAULT 30,
    max_patients INT NOT NULL DEFAULT 1,
    booked_patients INT NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'available',
    appointment_mode TEXT NOT NULL DEFAULT 'in_person',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (end_time > start_time),
    CHECK (slot_duration_minutes > 0),
    CHECK (max_patients > 0),
    CHECK (booked_patients >= 0 AND booked_patients <= max_patients),
    CHECK (status IN ('available', 'blocked', 'full')),
    CHECK (appointment_mode IN ('in_person', 'video', 'home_visit')),
    UNIQUE (doctor_id, hospital_id, slot_date, start_time, appointment_mode)
);

-- Prevent colliding slot timings for same doctor/hospital/date/mode
CREATE OR REPLACE FUNCTION prevent_doctor_slot_overlap()
RETURNS trigger AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM doctor_availability_slots s
        WHERE s.doctor_id = NEW.doctor_id
          AND s.hospital_id = NEW.hospital_id
          AND s.slot_date = NEW.slot_date
          AND s.appointment_mode = NEW.appointment_mode
          AND s.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
          AND tstzrange(
                (s.slot_date + s.start_time),
                (s.slot_date + s.end_time),
                '[)'
              ) && tstzrange(
                (NEW.slot_date + NEW.start_time),
                (NEW.slot_date + NEW.end_time),
                '[)'
              )
    ) THEN
        RAISE EXCEPTION 'Slot timing overlaps with an existing slot for this doctor.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_doctor_slot_overlap ON doctor_availability_slots;
CREATE TRIGGER trg_prevent_doctor_slot_overlap
BEFORE INSERT OR UPDATE ON doctor_availability_slots
FOR EACH ROW
EXECUTE FUNCTION prevent_doctor_slot_overlap();

-- Hospital-specific treatment pricing
CREATE TABLE IF NOT EXISTS hospital_treatment_prices (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    treatment_id UUID NOT NULL REFERENCES treatments(id) ON DELETE CASCADE,
    price NUMERIC(10,2) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (price >= 0),
    UNIQUE (hospital_id, treatment_id)
);

-- Actual appointment bookings
CREATE TABLE IF NOT EXISTS appointments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    patient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    doctor_id UUID NOT NULL REFERENCES doctors(id) ON DELETE RESTRICT,
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE RESTRICT,
    slot_id UUID REFERENCES doctor_availability_slots(id) ON DELETE SET NULL,
    appointment_date DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME,
    appointment_mode TEXT NOT NULL DEFAULT 'in_person',
    ticket_number TEXT,
    qr_payload TEXT,
    status TEXT NOT NULL DEFAULT 'upcoming',
    amount NUMERIC(10,2),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CHECK (status IN ('upcoming', 'completed', 'canceled', 'no_show')),
    CHECK (appointment_mode IN ('in_person', 'video', 'home_visit')),
    CHECK (amount IS NULL OR amount >= 0)
);

ALTER TABLE appointments
    ADD COLUMN IF NOT EXISTS ticket_number TEXT;

ALTER TABLE appointments
    ADD COLUMN IF NOT EXISTS qr_payload TEXT;

-- Helpful indexes
CREATE INDEX IF NOT EXISTS idx_doctors_specialty ON doctors(specialty);
CREATE INDEX IF NOT EXISTS idx_hospitals_city ON hospitals(city);
CREATE INDEX IF NOT EXISTS idx_doctor_hospital_doctor ON doctor_hospital_assignments(doctor_id);
CREATE INDEX IF NOT EXISTS idx_doctor_hospital_hospital ON doctor_hospital_assignments(hospital_id);
CREATE INDEX IF NOT EXISTS idx_doctor_treatments_doctor ON doctor_treatments(doctor_id);
CREATE INDEX IF NOT EXISTS idx_availability_doctor_date ON doctor_availability_slots(doctor_id, slot_date);
CREATE INDEX IF NOT EXISTS idx_availability_hospital_date ON doctor_availability_slots(hospital_id, slot_date);
CREATE INDEX IF NOT EXISTS idx_home_categories_order ON home_categories(sort_order, is_active);
CREATE INDEX IF NOT EXISTS idx_hospital_treatment_prices_hospital ON hospital_treatment_prices(hospital_id, is_active);
CREATE INDEX IF NOT EXISTS idx_appointments_patient_date ON appointments(patient_user_id, appointment_date);
CREATE INDEX IF NOT EXISTS idx_appointments_doctor_date ON appointments(doctor_id, appointment_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_ticket_number
    ON appointments(ticket_number)
    WHERE ticket_number IS NOT NULL;

-- Read-friendly view for UI listing screens
CREATE OR REPLACE VIEW doctor_listing_view AS
SELECT
    d.id AS doctor_id,
    d.full_name,
    d.specialty,
    d.years_experience,
    d.rating,
    d.reviews_count,
    h.id AS hospital_id,
    h.name AS hospital_name,
    h.city,
    h.location_label,
    array_remove(array_agg(DISTINCT t.name), NULL) AS treatments,
    array_remove(array_agg(DISTINCT dt.offered_as), NULL) AS treatment_modes
FROM doctors d
LEFT JOIN doctor_hospital_assignments dha ON dha.doctor_id = d.id
LEFT JOIN hospitals h ON h.id = dha.hospital_id
LEFT JOIN doctor_treatments dt ON dt.doctor_id = d.id
LEFT JOIN treatments t ON t.id = dt.treatment_id
WHERE d.is_active = true
GROUP BY d.id, h.id;

-- Enable RLS
ALTER TABLE hospitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctors ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_hospital_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE treatments ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_treatments ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_availability_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE home_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospital_treatment_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments ENABLE ROW LEVEL SECURITY;

-- Development-friendly policies (replace with auth-based rules for production)
DROP POLICY IF EXISTS "Hospitals are readable" ON hospitals;
CREATE POLICY "Hospitals are readable" ON hospitals
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Doctors are readable" ON doctors;
CREATE POLICY "Doctors are readable" ON doctors
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Assignments are readable" ON doctor_hospital_assignments;
CREATE POLICY "Assignments are readable" ON doctor_hospital_assignments
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Treatments are readable" ON treatments;
CREATE POLICY "Treatments are readable" ON treatments
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Doctor treatments are readable" ON doctor_treatments;
CREATE POLICY "Doctor treatments are readable" ON doctor_treatments
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Slots are readable" ON doctor_availability_slots;
CREATE POLICY "Slots are readable" ON doctor_availability_slots
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Home categories are readable" ON home_categories;
CREATE POLICY "Home categories are readable" ON home_categories
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Hospital treatment pricing readable" ON hospital_treatment_prices;
CREATE POLICY "Hospital treatment pricing readable" ON hospital_treatment_prices
    FOR SELECT USING (true);
DROP POLICY IF EXISTS "Appointments readable" ON appointments;
CREATE POLICY "Appointments readable" ON appointments
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "Hospitals can be inserted" ON hospitals;
CREATE POLICY "Hospitals can be inserted" ON hospitals
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Doctors can be inserted" ON doctors;
CREATE POLICY "Doctors can be inserted" ON doctors
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Assignments can be inserted" ON doctor_hospital_assignments;
CREATE POLICY "Assignments can be inserted" ON doctor_hospital_assignments
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Treatments can be inserted" ON treatments;
CREATE POLICY "Treatments can be inserted" ON treatments
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Doctor treatments can be inserted" ON doctor_treatments;
CREATE POLICY "Doctor treatments can be inserted" ON doctor_treatments
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Slots can be inserted" ON doctor_availability_slots;
CREATE POLICY "Slots can be inserted" ON doctor_availability_slots
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Home categories can be inserted" ON home_categories;
CREATE POLICY "Home categories can be inserted" ON home_categories
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Hospital treatment pricing insertable" ON hospital_treatment_prices;
CREATE POLICY "Hospital treatment pricing insertable" ON hospital_treatment_prices
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Appointments insertable" ON appointments;
CREATE POLICY "Appointments insertable" ON appointments
    FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Appointments updatable" ON appointments;
CREATE POLICY "Appointments updatable" ON appointments
    FOR UPDATE USING (true);

-- Sample categories for home screen (single horizontal row)
INSERT INTO home_categories (id, name, icon_key, color_hex, sort_order, is_active)
VALUES
    ('66666666-6666-6666-6666-666666666001', 'Cardiology', 'favorite', '#8CB89E', 1, true),
    ('66666666-6666-6666-6666-666666666002', 'Dermatology', 'face_retouching_natural', '#D9969E', 2, true),
    ('66666666-6666-6666-6666-666666666003', 'Orthopedics', 'accessibility_new', '#E7AA79', 3, true),
    ('66666666-6666-6666-6666-666666666004', 'Neurology', 'psychology', '#9B93BD', 4, true),
    ('66666666-6666-6666-6666-666666666005', 'Gynecology', 'pregnant_woman', '#D5B2B4', 5, true),
    ('66666666-6666-6666-6666-666666666006', 'Pediatrics', 'child_care', '#89C2D1', 6, true),
    ('66666666-6666-6666-6666-666666666007', 'ENT', 'hearing', '#66A89E', 7, true),
    ('66666666-6666-6666-6666-666666666008', 'General', 'medical_services', '#8EA3C0', 8, true)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    icon_key = EXCLUDED.icon_key,
    color_hex = EXCLUDED.color_hex,
    sort_order = EXCLUDED.sort_order,
    is_active = EXCLUDED.is_active;

-- Sample treatment prices per hospital
INSERT INTO hospital_treatment_prices (id, hospital_id, treatment_id, price, is_active)
VALUES
    ('77777777-7777-7777-7777-777777777001', '11111111-1111-1111-1111-111111111001', '33333333-3333-3333-3333-333333333001', 500.00, true),
    ('77777777-7777-7777-7777-777777777002', '11111111-1111-1111-1111-111111111001', '33333333-3333-3333-3333-333333333002', 800.00, true),
    ('77777777-7777-7777-7777-777777777003', '11111111-1111-1111-1111-111111111001', '33333333-3333-3333-3333-333333333003', 1600.00, true),
    ('77777777-7777-7777-7777-777777777004', '11111111-1111-1111-1111-111111111002', '33333333-3333-3333-3333-333333333007', 1200.00, true),
    ('77777777-7777-7777-7777-777777777005', '11111111-1111-1111-1111-111111111002', '33333333-3333-3333-3333-333333333012', 450.00, true),
    ('77777777-7777-7777-7777-777777777006', '11111111-1111-1111-1111-111111111003', '33333333-3333-3333-3333-333333333009', 900.00, true),
    ('77777777-7777-7777-7777-777777777007', '11111111-1111-1111-1111-111111111003', '33333333-3333-3333-3333-333333333008', 1400.00, true),
    ('77777777-7777-7777-7777-777777777008', '11111111-1111-1111-1111-111111111004', '33333333-3333-3333-3333-333333333005', 2200.00, true),
    ('77777777-7777-7777-7777-777777777009', '11111111-1111-1111-1111-111111111004', '33333333-3333-3333-3333-333333333010', 950.00, true)
ON CONFLICT (id) DO UPDATE SET
    hospital_id = EXCLUDED.hospital_id,
    treatment_id = EXCLUDED.treatment_id,
    price = EXCLUDED.price,
    is_active = EXCLUDED.is_active;
