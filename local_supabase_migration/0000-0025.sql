-- Local Supabase Consolidator Database Migration Schema

-- 1. Heartbeat & Client Metadata Table
CREATE TABLE IF NOT EXISTS pos_clients (
    client_id TEXT PRIMARY KEY,
    client_name TEXT NOT NULL,
    last_heartbeat TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    app_version TEXT,
    os_info TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 2. Sales Header (sales_m1 - Based strictly on v_sales_m1 columns)
CREATE TABLE IF NOT EXISTS sales_m1 (
    pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
    tseq_no BIGINT NOT NULL,
    seq_no INTEGER NOT NULL,
    account_amt NUMERIC(12, 2) NOT NULL,
    actual_date TIMESTAMP WITH TIME ZONE NOT NULL,
    atm_amt NUMERIC(12, 2) NOT NULL,
    authorized INTEGER NOT NULL,
    balance NUMERIC(12, 2) NOT NULL,
    branch INTEGER NOT NULL,
    c_bal NUMERIC(12, 2) NOT NULL,
    card_amt NUMERIC(12, 2) NOT NULL,
    cash_amt NUMERIC(12, 2) NOT NULL,
    cashier INTEGER NOT NULL,
    change NUMERIC(12, 2) NOT NULL,
    charge_amt NUMERIC(12, 2) NOT NULL,
    check_amt NUMERIC(12, 2) NOT NULL,
    checker INTEGER NOT NULL,
    customer TEXT,
    d_tran_date TIMESTAMP WITH TIME ZONE NOT NULL,
    def_amt NUMERIC(12, 2) NOT NULL,
    del_member TEXT,
    demog TEXT,
    disc_code INTEGER NOT NULL,
    discount_a NUMERIC(12, 2) NOT NULL,
    discount_p NUMERIC(12, 2) NOT NULL,
    discountable NUMERIC(12, 2) NOT NULL,
    doc_num TEXT,
    dump INTEGER NOT NULL,
    free_reason INTEGER NOT NULL,
    gift_amt NUMERIC(12, 2) NOT NULL,
    guest_count INTEGER NOT NULL,
    i_disc_amt NUMERIC(12, 2) NOT NULL,
    l_end TEXT,
    l_nonvat INTEGER NOT NULL,
    lay_amt NUMERIC(12, 2) NOT NULL,
    lay_no INTEGER NOT NULL,
    lc NUMERIC(12, 2) NOT NULL,
    local_tax NUMERIC(12, 2) NOT NULL,
    location INTEGER NOT NULL,
    machine INTEGER NOT NULL,
    member TEXT,
    member_area TEXT,
    misc NUMERIC(12, 2) NOT NULL,
    nonvat_seq INTEGER NOT NULL,
    order_no INTEGER NOT NULL,
    order_type INTEGER NOT NULL,
    other_amt NUMERIC(12, 2) NOT NULL,
    qty INTEGER NOT NULL,
    ref_no TEXT,
    ret_ex_amt NUMERIC(12, 2) NOT NULL,
    ret_exch INTEGER NOT NULL,
    sales_m1_date TEXT NOT NULL,
    sales_m1_time TEXT NOT NULL,
    salesman INTEGER NOT NULL,
    salesman_2 INTEGER NOT NULL,
    sen_count INTEGER NOT NULL,
    seq_loc TEXT,
    status INTEGER NOT NULL,
    surcharge_a NUMERIC(12, 2) NOT NULL,
    surcharge_p NUMERIC(12, 2),
    t_price NUMERIC(12, 2) NOT NULL,
    timestamp_column TIMESTAMP WITH TIME ZONE,
    tips NUMERIC(12, 2) NOT NULL,
    tot_free_16 NUMERIC(12, 2) NOT NULL,
    trans_no INTEGER NOT NULL,
    updated TEXT,
    v_tran_type INTEGER NOT NULL,
    vat_seq INTEGER NOT NULL,
    vat_tax NUMERIC(12, 2) NOT NULL,
    vc_table TEXT,
    vip_card TEXT,
    void_seq_no INTEGER NOT NULL,
    z_amount NUMERIC(12, 2) NOT NULL,
    z_number INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (pos_client_id, tseq_no)
);

-- 3. Sales Details / Tenders (sales_m2)
CREATE TABLE IF NOT EXISTS sales_m2 (
    pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
    id BIGINT NOT NULL,
    tseq_no BIGINT NOT NULL,
    seq_no INTEGER NOT NULL,
    si_no INTEGER NOT NULL,
    date TIMESTAMP WITH TIME ZONE NOT NULL,
    time TIMESTAMP WITH TIME ZONE NOT NULL,
    barcode VARCHAR(50) NOT NULL,
    category TEXT,
    supp_code TEXT,
    dept TEXT,
    qty NUMERIC(12, 2) NOT NULL,
    price NUMERIC(12, 2) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    gross_price NUMERIC(12, 2) NOT NULL,
    gross_amount NUMERIC(12, 2) NOT NULL,
    cost_price NUMERIC(12, 2) DEFAULT 0.0,
    machine INTEGER NOT NULL,
    location INTEGER NOT NULL,
    branch INTEGER NOT NULL,
    cashier INTEGER NOT NULL,
    d_tran_date TIMESTAMP WITH TIME ZONE NOT NULL,
    date_out TIMESTAMP WITH TIME ZONE NOT NULL,
    deduct NUMERIC(12, 2) NOT NULL,
    add_amt NUMERIC(12, 2) NOT NULL,
    status INTEGER NOT NULL,
    disc_type INTEGER DEFAULT 0,
    coupon_code INTEGER DEFAULT 0,
    disc_code INTEGER DEFAULT 0,
    disc_fix_amt NUMERIC(12, 2) DEFAULT 0.0,
    disc_percent NUMERIC(12, 2) DEFAULT 0.0,
    is_disc_exempt BOOLEAN DEFAULT FALSE,
    item_type INTEGER NOT NULL,
    order_type INTEGER NOT NULL,
    vat_seq INTEGER NOT NULL,
    nonvat_seq INTEGER NOT NULL,
    box_barcode VARCHAR(50),
    v_surch NUMERIC(12, 2) NOT NULL,
    timestamp_column TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    actual_date TIMESTAMP WITH TIME ZONE NOT NULL,
    rec_ctr INTEGER NOT NULL,
    vat_sale NUMERIC(12, 2) NOT NULL,
    tax_code INTEGER NOT NULL,
    vat NUMERIC(12, 2) DEFAULT 0.0,
    nonvat NUMERIC(12, 2) DEFAULT 0.0,
    vat12 NUMERIC(12, 2) DEFAULT 0.0,
    vatPriv NUMERIC(12, 2) DEFAULT 0.0,
    zero_rated NUMERIC(12, 2) DEFAULT 0.0,
    x_read_stat INTEGER NOT NULL,
    z_number INTEGER NOT NULL,
    trans_no INTEGER NOT NULL,
    posting_date TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    payment_deposit_amt NUMERIC(12, 2),
    customization_sequence INTEGER,
    customization_key TEXT,
    charge_code INTEGER DEFAULT 0,
    bank_code INTEGER DEFAULT 0,
    guest_count INTEGER DEFAULT 1,
    eligible_guest_count INTEGER DEFAULT 0,
    shift_number INTEGER DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (pos_client_id, id)
);

-- 4. Order Header (sales_order_2)
CREATE TABLE IF NOT EXISTS sales_order_2 (
    pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
    sales_order_id BIGINT NOT NULL,
    table_id INTEGER NOT NULL,
    tseq_no BIGINT,
    guest_count INTEGER NOT NULL,
    therapist TEXT,
    eligible_guest_count INTEGER DEFAULT 0,
    order_type INTEGER NOT NULL,
    payment_status INTEGER NOT NULL DEFAULT 0,
    applied_discount_id INTEGER,
    is_split_bill INTEGER DEFAULT 0,
    is_combine BOOLEAN DEFAULT FALSE,
    payment_deposit_id INTEGER,
    parent_sales_order_id INTEGER,
    timestamp_column TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    posting_date TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    disc_fix_amt NUMERIC(12, 2) DEFAULT 0.0,
    disc_percent NUMERIC(12, 2) DEFAULT 0.0,
    applied_coupon_id INTEGER,
    coupon_serial TEXT,
    coupon_type INTEGER,
    coupon_value NUMERIC(12, 2),
    is_redeemed INTEGER DEFAULT 0,
    remarks TEXT,
    paid_at TIMESTAMP WITH TIME ZONE,
    stardeals_serial TEXT,
    supabase_sales_order_id BIGINT,
    PRIMARY KEY (pos_client_id, sales_order_id)
);

-- 5. Order Item (sales_order_item)
CREATE TABLE IF NOT EXISTS sales_order_item (
    pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
    order_item_id BIGINT NOT NULL,
    sales_order_id BIGINT NOT NULL,
    item_barcode TEXT,
    quantity NUMERIC(12, 2) NOT NULL,
    amount NUMERIC(12, 2) NOT NULL,
    timestamp_column TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    item_modifiers TEXT,
    customization TEXT,
    is_disc_exempt BOOLEAN NOT NULL DEFAULT FALSE,
    item_discount NUMERIC(12, 2),
    special_price NUMERIC(12, 2) DEFAULT 0.0,
    posting_date TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (pos_client_id, order_item_id),
    FOREIGN KEY (pos_client_id, sales_order_id) REFERENCES sales_order_2(pos_client_id, sales_order_id) ON DELETE CASCADE
);

-- 6. Indexes for optimal query performance
CREATE INDEX IF NOT EXISTS idx_pos_clients_last_heartbeat ON pos_clients(last_heartbeat);
CREATE INDEX IF NOT EXISTS idx_sales_m1_client_tseq ON sales_m1(pos_client_id, tseq_no);
CREATE INDEX IF NOT EXISTS idx_sales_m2_client_tseq ON sales_m2(pos_client_id, tseq_no);
CREATE INDEX IF NOT EXISTS idx_sales_order_2_client_id ON sales_order_2(pos_client_id, sales_order_id);
CREATE INDEX IF NOT EXISTS idx_sales_order_item_client_order ON sales_order_item(pos_client_id, sales_order_id);
-- Incremental Migration: Enable REPLICA IDENTITY FULL for Real-Time Deletes
-- This ensures delete events publish the complete old row contents (including primary key fields) to subscribers.

ALTER TABLE sales_order_2 REPLICA IDENTITY FULL;
ALTER TABLE sales_order_item REPLICA IDENTITY FULL;
-- Incremental Migration: Cascade Delete from sales_order_2 to sales_order_item on Supabase
-- Enforces that deleting an active sales order header cascades to delete all of its items.
-- First, remove any existing constraint with the same name or definition
ALTER TABLE sales_order_item DROP CONSTRAINT IF EXISTS fk_sales_order_item_sales_order_2;
-- Now add the constraint
ALTER TABLE sales_order_item
ADD CONSTRAINT fk_sales_order_item_sales_order_2 FOREIGN KEY (pos_client_id, sales_order_id) REFERENCES sales_order_2(pos_client_id, sales_order_id) ON DELETE CASCADE;-- Incremental Migration: Add buffet item-discount tracking fields to sales_order_item
-- Mirrors the local SQLite schema so consolidator sync can persist item-level discounts.

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_id BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_name TEXT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_discount_amount NUMERIC(12, 2);

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS applied_vat_priv NUMERIC(12, 2);
-- Incremental Migration: Add order creation, item punching, and discount application tracking fields.
-- Track who created the order, who punched the item, and who applied the discount.

ALTER TABLE sales_order_2
ADD COLUMN IF NOT EXISTS created_by BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS added_by BIGINT;

ALTER TABLE sales_order_item
ADD COLUMN IF NOT EXISTS discounted_by BIGINT;
-- Adds a globally-unique, auto-incrementing SO Number on the consolidator.
-- Used by terminals (when connected with sync_sales_orders enabled) to print
-- a non-colliding "SO Number" on receipts. Terminals without the consolidator
-- continue to fall back to the local sales_order_id.

ALTER TABLE sales_order_2
  ADD COLUMN IF NOT EXISTS so_number BIGINT GENERATED BY DEFAULT AS IDENTITY UNIQUE;
-- Mirrors ground / tables / table_layout_items on the consolidator so the
-- floor plan can sync across terminals. Each row carries a monotonic
-- `revision` (bumped by the trigger on every UPDATE) plus the
-- `pos_client_id` that originated the change. Terminals use revision for
-- the per-row "what changed while I was offline" reconciliation, and
-- pos_client_id to skip the realtime echo of their own writes.

CREATE TABLE IF NOT EXISTS ground (
  ground_id BIGINT PRIMARY KEY,
  ground_desc TEXT NOT NULL,
  ground_status BOOLEAN DEFAULT TRUE,
  is_custom_layout BOOLEAN DEFAULT FALSE,
  table_size REAL NOT NULL DEFAULT 64,
  canvas_width REAL DEFAULT 1200.0,
  canvas_height REAL DEFAULT 800.0,
  initial_zoom REAL DEFAULT 1.0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT
);

CREATE TABLE IF NOT EXISTS tables (
  table_id BIGINT PRIMARY KEY,
  table_desc TEXT NOT NULL,
  table_status BOOLEAN DEFAULT TRUE,
  ground BIGINT,
  x_loc REAL NOT NULL DEFAULT 0,
  y_loc REAL NOT NULL DEFAULT 0,
  rotation REAL DEFAULT 0.0,
  table_shape TEXT DEFAULT 'square',
  capacity INTEGER DEFAULT 4,
  grid_width INTEGER DEFAULT 1,
  grid_height INTEGER DEFAULT 1,
  seat_layout TEXT DEFAULT 'all',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT,
  FOREIGN KEY (ground) REFERENCES ground(ground_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS table_layout_items (
  layout_item_id BIGINT PRIMARY KEY,
  layout_item_desc TEXT NOT NULL,
  layout_item_type TEXT NOT NULL,
  ground BIGINT NOT NULL,
  x_loc REAL NOT NULL DEFAULT 0,
  y_loc REAL NOT NULL DEFAULT 0,
  width REAL DEFAULT 100.0,
  height REAL DEFAULT 20.0,
  rotation REAL DEFAULT 0.0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  revision BIGINT NOT NULL DEFAULT 1,
  pos_client_id TEXT,
  FOREIGN KEY (ground) REFERENCES ground(ground_id) ON DELETE CASCADE
);

-- Revision bump trigger: on every UPDATE, bump revision and refresh
-- updated_at. INSERT defaults to 1.
CREATE OR REPLACE FUNCTION bump_layout_revision() RETURNS TRIGGER AS $$
BEGIN
  NEW.revision := COALESCE(OLD.revision, 0) + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ground_bump_revision ON ground;
CREATE TRIGGER trg_ground_bump_revision BEFORE UPDATE ON ground
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

DROP TRIGGER IF EXISTS trg_tables_bump_revision ON tables;
CREATE TRIGGER trg_tables_bump_revision BEFORE UPDATE ON tables
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

DROP TRIGGER IF EXISTS trg_table_layout_items_bump_revision ON table_layout_items;
CREATE TRIGGER trg_table_layout_items_bump_revision BEFORE UPDATE ON table_layout_items
  FOR EACH ROW EXECUTE FUNCTION bump_layout_revision();

ALTER TABLE ground REPLICA IDENTITY FULL;
ALTER TABLE tables REPLICA IDENTITY FULL;
ALTER TABLE table_layout_items REPLICA IDENTITY FULL;

ALTER PUBLICATION supabase_realtime ADD TABLE ground;
ALTER PUBLICATION supabase_realtime ADD TABLE tables;
ALTER PUBLICATION supabase_realtime ADD TABLE table_layout_items;
-- Cross-terminal table locks. When a terminal selects a table on the
-- Sales Order screen with the lock feature enabled, it upserts a row
-- here. A heartbeat (every 10s) bumps expires_at; other terminals treat
-- the lock as released once expires_at < now() so a crashed holder
-- doesn't pin a table forever (TTL = ~30s).

CREATE TABLE IF NOT EXISTS table_locks (
  table_id BIGINT PRIMARY KEY,
  locked_by_client_id TEXT NOT NULL,
  locked_by_client_name TEXT,
  locked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  sales_order_id BIGINT
);

ALTER TABLE table_locks REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE table_locks;
-- Mirrors usage_logs on the consolidator so the Usage Logs & Audit Trail
-- report combines logs from every terminal. Each row carries the
-- `pos_client_id` that produced it (FK to pos_clients) plus the originating
-- terminal's local sqlite id for reference. Unlike the table-layout tables
-- these are append-only audit records: no revision trigger and no realtime
-- publication are needed.

CREATE TABLE IF NOT EXISTS usage_logs (
  log_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pos_client_id TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
  local_id      BIGINT,            -- originating terminal's sqlite id (informational)
  "user"        TEXT NOT NULL,
  grantor       TEXT,
  role          TEXT,
  module        TEXT NOT NULL,
  action        TEXT,
  description   TEXT,
  details       TEXT,
  severity      TEXT,
  datetime      TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_usage_logs_datetime ON usage_logs (datetime DESC);
CREATE INDEX IF NOT EXISTS idx_usage_logs_client ON usage_logs (pos_client_id);
-- Mirrors the maintenance / master-data tables on the consolidator so every
-- terminal shares one catalog when the `sync_maintenance_data` flag is on:
-- departments, categories, items, users + access levels, discounts, charges
-- and banks.
--
-- Unlike the table-layout / usage-log tables these are a SHARED catalog: rows
-- are not owned per-terminal, so there is no `pos_client_id` column and no
-- revision trigger — every terminal reads and writes the same rows by primary
-- key. Identity PKs use GENERATED BY DEFAULT so the app can upsert rows with an
-- explicit key (updates + one-time catalog seeding) as well as let the server
-- assign new ones.
--
-- discount / charge_payment / bank keep sqlite's "code = id" convention. sqlite
-- does this with an AFTER INSERT trigger; here we use a BEFORE INSERT trigger
-- fed by the column's default sequence so the value is present in the INSERT ...
-- RETURNING the client reads back.

-- ── Departments ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "Department" (
  dept_id          BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  dept_code        TEXT,
  dept_desc        TEXT NOT NULL,
  dept_status      INTEGER DEFAULT 1,
  timestamp_column TIMESTAMPTZ DEFAULT now(),
  d_tran_date      TIMESTAMPTZ DEFAULT now()
);

-- ── Categories ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "Category" (
  category_id              BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  category_code            TEXT,
  dept_code                TEXT,
  category_desc            TEXT NOT NULL,
  category_status          INTEGER DEFAULT 1,
  recommended_category_id  INTEGER,
  department               BIGINT,
  ordering_index           INTEGER,
  is_available_in_web_table INTEGER DEFAULT 1,
  timestamp_column         TIMESTAMPTZ DEFAULT now(),
  d_tran_date              TIMESTAMPTZ DEFAULT now()
);

-- ── Items ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS item (
  id                         BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  barcode                    TEXT UNIQUE,
  item_code                  TEXT UNIQUE,
  item_desc                  TEXT NOT NULL,
  item_details               TEXT,
  label_name                 TEXT,
  is_label_same_with_receipt INTEGER DEFAULT 1,
  item_status                INTEGER DEFAULT 1,
  print_desc                 TEXT,
  category                   BIGINT,
  dept                       BIGINT,
  cost_price                 REAL,
  mark_up                    REAL,
  price                      REAL,
  special_price              REAL,
  price_1                    REAL,
  price_2                    REAL,
  price_3                    REAL,
  price_4                    REAL,
  price_5                    REAL,
  conv_qty                   REAL DEFAULT 1.0,
  d_tran_date                TIMESTAMPTZ DEFAULT now(),
  date_change                TIMESTAMPTZ DEFAULT now(),
  disc_amt                   REAL DEFAULT 0.0,
  assigned_printer           TEXT,
  disc_exempt                INTEGER DEFAULT 0,
  non_vat                    INTEGER DEFAULT 0,
  finished_good              INTEGER DEFAULT 0,
  composition                INTEGER DEFAULT 0,
  raw_material               INTEGER DEFAULT 0,
  is_combo                   INTEGER DEFAULT 0,
  disp_image                 TEXT,
  button_index               INTEGER,
  is_gift_check              INTEGER DEFAULT 0,
  gift_check_code            INTEGER,
  min_lvl                    REAL DEFAULT 0,
  max_lvl                    REAL DEFAULT 0,
  unit                       INTEGER DEFAULT 1,
  disc_cap_amt               REAL DEFAULT 0.0,
  disc_cap_perc              REAL DEFAULT 0.0,
  can_be_grams               INTEGER DEFAULT 0,
  can_be_pcs                 INTEGER DEFAULT 0,
  can_be_ml                  INTEGER DEFAULT 0,
  show_on_kds                INTEGER DEFAULT 1,
  estimated_prep_time        INTEGER,
  area                       INTEGER DEFAULT 0,
  bulk_units                 TEXT,
  bulk_conversion            REAL DEFAULT 0.0,
  is_solid                   INTEGER DEFAULT 0,
  is_liquid                  INTEGER DEFAULT 0,
  is_bundle                  INTEGER DEFAULT 0,
  is_hidden                  INTEGER DEFAULT 0,
  is_buffet                  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_item_category ON item (category);
CREATE INDEX IF NOT EXISTS idx_item_dept ON item (dept);

-- ── Access levels + users ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users_access_level (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  name             TEXT NOT NULL,
  sales_entry      INTEGER NOT NULL DEFAULT 0,
  sales_order      INTEGER NOT NULL DEFAULT 0,
  sales_reading    INTEGER NOT NULL DEFAULT 0,
  sales_inquiry    INTEGER NOT NULL DEFAULT 0,
  file_maintenance INTEGER NOT NULL DEFAULT 0,
  admin_mode       INTEGER NOT NULL DEFAULT 0,
  dtr_menu         INTEGER NOT NULL DEFAULT 0,
  self_order_kiosk INTEGER NOT NULL DEFAULT 0,
  inventory        INTEGER NOT NULL DEFAULT 0,
  status           INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS user_access (
  id              BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  access_level_id BIGINT NOT NULL REFERENCES users_access_level(id) ON DELETE CASCADE,
  access_key      TEXT NOT NULL,
  access_value    INTEGER NOT NULL DEFAULT 0,
  timestamp_column TIMESTAMPTZ DEFAULT now(),
  UNIQUE (access_level_id, access_key)
);

CREATE TABLE IF NOT EXISTS "user" (
  id              BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  access_level_id BIGINT NOT NULL,
  name            TEXT NOT NULL,
  password        TEXT NOT NULL,
  status          INTEGER NOT NULL DEFAULT 1
);

-- ── Discounts (disc_code = id) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS "Discount" (
  id                       BIGINT GENERATED BY DEFAULT AS IDENTITY,
  disc_code                BIGINT PRIMARY KEY DEFAULT nextval(pg_get_serial_sequence('"Discount"', 'id')),
  disc_name                TEXT,
  disc_perc                REAL,
  disc_amt                 REAL,
  disc_limit               TEXT,
  timestamp_column         TIMESTAMPTZ DEFAULT now(),
  d_tran_date              TIMESTAMPTZ DEFAULT now(),
  disc_limit_expr          TEXT,
  vip_disc                 INTEGER DEFAULT 0,
  l_disc_1                 INTEGER DEFAULT 0,
  l_employee               INTEGER DEFAULT 0,
  l_pwd                    INTEGER DEFAULT 0,
  l_gpc                    INTEGER DEFAULT 0,
  disc_type                INTEGER DEFAULT 0,
  l_custom                 INTEGER DEFAULT 0,
  disc_status              INTEGER DEFAULT 1,
  should_ask_details       INTEGER DEFAULT 1,
  include_vat_priv         INTEGER DEFAULT 0,
  vat_priv_percent         REAL DEFAULT 12,
  recompute_vat            INTEGER DEFAULT 0,
  use_guest_prorate        INTEGER DEFAULT 0,
  use_special_price        INTEGER DEFAULT 0,
  is_zero_rated            INTEGER DEFAULT 0,
  bypass_nonvat            INTEGER DEFAULT 0,
  min_guests               INTEGER,
  max_guests               INTEGER,
  is_transaction_discount  INTEGER DEFAULT 0
);

-- ── Charges (charge_code = id) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS charge_payment (
  id                  BIGINT GENERATED BY DEFAULT AS IDENTITY,
  charge_code         BIGINT PRIMARY KEY DEFAULT nextval(pg_get_serial_sequence('charge_payment', 'id')),
  charge_desc         TEXT,
  charge_no           INTEGER,
  date                TIMESTAMPTZ,
  tseq_no             INTEGER,
  timestamp_column    TIMESTAMPTZ DEFAULT now(),
  d_tran_date         TIMESTAMPTZ DEFAULT now(),
  charge_amt          NUMERIC(10, 2),
  z_number            INTEGER,
  cashier             INTEGER,
  approv_no           TEXT,
  charge_status       INTEGER DEFAULT 1,
  charge_payment_type INTEGER
);

-- ── Banks (bank_code = id) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS bank (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY,
  bank_code        BIGINT PRIMARY KEY DEFAULT nextval(pg_get_serial_sequence('bank', 'id')),
  bank_name        TEXT NOT NULL,
  timestamp_column TIMESTAMPTZ DEFAULT now(),
  d_tran_date      TIMESTAMPTZ DEFAULT now(),
  bank_status      INTEGER DEFAULT 1,
  card_type        INTEGER
);

-- ── Holidays ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS holidays (
  id           BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  holiday_date TEXT UNIQUE NOT NULL,  -- YYYY-MM-DD
  description  TEXT,
  is_active    INTEGER DEFAULT 1
);

-- ── Discount availability rules ──────────────────────────────────
-- FK to Discount(disc_code) with ON DELETE CASCADE so "Clear Discounts"
-- also clears the rules tied to each discount.
CREATE TABLE IF NOT EXISTS discount_availability (
  id            BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  discount_code BIGINT NOT NULL REFERENCES "Discount"(disc_code) ON DELETE CASCADE,
  day           TEXT,  -- Monday, Tuesday, etc.
  week_of_month TEXT,  -- 1,2,3,4,5,L
  start_time    TEXT,  -- HH:mm
  end_time      TEXT,  -- HH:mm
  date_start    TEXT,  -- YYYY-MM-DD
  date_end      TEXT,  -- YYYY-MM-DD
  is_active     INTEGER DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_discount_availability_code ON discount_availability (discount_code);

-- The PRIMARY KEY (code) shares the identity column's sequence via its DEFAULT,
-- so a plain INSERT gets a fresh code automatically and the client can read it
-- back through RETURNING. `id` mirrors the same value for row-shape parity with
-- the sqlite model (updateStatus filters charge_payment / bank by `id`).
CREATE OR REPLACE FUNCTION sync_code_from_id() RETURNS TRIGGER AS $$
BEGIN
  -- Whichever of (id, <code>) the caller supplied, fill in the other.
  IF TG_TABLE_NAME = 'Discount' THEN
    IF NEW.id IS NULL THEN NEW.id := NEW.disc_code; END IF;
    IF NEW.disc_code IS NULL THEN NEW.disc_code := NEW.id; END IF;
  ELSIF TG_TABLE_NAME = 'charge_payment' THEN
    IF NEW.id IS NULL THEN NEW.id := NEW.charge_code; END IF;
    IF NEW.charge_code IS NULL THEN NEW.charge_code := NEW.id; END IF;
  ELSIF TG_TABLE_NAME = 'bank' THEN
    IF NEW.id IS NULL THEN NEW.id := NEW.bank_code; END IF;
    IF NEW.bank_code IS NULL THEN NEW.bank_code := NEW.id; END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_discount_code ON "Discount";
CREATE TRIGGER trg_discount_code BEFORE INSERT ON "Discount"
  FOR EACH ROW EXECUTE FUNCTION sync_code_from_id();

DROP TRIGGER IF EXISTS trg_charge_payment_code ON charge_payment;
CREATE TRIGGER trg_charge_payment_code BEFORE INSERT ON charge_payment
  FOR EACH ROW EXECUTE FUNCTION sync_code_from_id();

DROP TRIGGER IF EXISTS trg_bank_code ON bank;
CREATE TRIGGER trg_bank_code BEFORE INSERT ON bank
  FOR EACH ROW EXECUTE FUNCTION sync_code_from_id();

-- ── Realtime for the menu master tables ──────────────────────────
-- departments / categories / items drive the in-app menu, which every
-- terminal reads from MasterFileBloc. Publish their changes so a catalog edit
-- on one terminal live-refreshes the others (ConsolidatorRealtimeListener).
-- The other maintenance tables (users, discounts, charges, banks) are not
-- published — their screens refresh on entry, which is enough for rarely-edited
-- config.
ALTER TABLE "Department" REPLICA IDENTITY FULL;
ALTER TABLE "Category" REPLICA IDENTITY FULL;
ALTER TABLE item REPLICA IDENTITY FULL;

-- Add to the realtime publication. Wrapped so re-running this migration is a
-- no-op instead of erroring on "table is already member of publication".
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE "Department";
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE "Category";
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE item;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Server-authoritative sales order / item IDs.
--
-- Previously each terminal picked its own sales_order_id / order_item_id
-- (MAX per pos_client_id + 1), so ids were only unique *per terminal* and the
-- tables used a composite PK (pos_client_id, id). That forced owner-resolution
-- logic on every read/write and was race-prone.
--
-- This migration makes the consolidator the single source of ids: both columns
-- become globally-unique IDENTITY sequences (same mechanism as so_number in
-- 0005) and the SOLE primary key. pos_client_id is demoted to a plain
-- ownership/audit column (still FK to pos_clients, just no longer part of the
-- key). Terminals stop sending ids on insert and read the assigned value back.
--
-- NOTE: this wipes existing sales-order data (test data) so the fresh IDENTITY
-- sequences start clean and there are no leftover per-terminal duplicates.

BEGIN;

-- 1. Wipe existing sales-order data. RESTART IDENTITY resets so_number too.
TRUNCATE TABLE sales_order_item, sales_order_2 RESTART IDENTITY CASCADE;

-- 2. Drop every FK from sales_order_item → sales_order_2, then both composite
--    primary keys. There are two such FKs: the one added in 0002
--    (fk_sales_order_item_sales_order_2) and the original inline composite FK
--    auto-named by Postgres when the table was created
--    (sales_order_item_pos_client_id_sales_order_id_fkey). Both depend on the
--    composite PK index, so both must go before the PK can be dropped. The
--    DO block also catches any other differently-named FK between the two
--    tables so this works regardless of how the constraint was named.
ALTER TABLE sales_order_item DROP CONSTRAINT IF EXISTS fk_sales_order_item_sales_order_2;
ALTER TABLE sales_order_item DROP CONSTRAINT IF EXISTS sales_order_item_pos_client_id_sales_order_id_fkey;
DO $$
DECLARE
  con RECORD;
BEGIN
  FOR con IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'sales_order_item'::regclass
      AND confrelid = 'sales_order_2'::regclass
      AND contype = 'f'
  LOOP
    EXECUTE format('ALTER TABLE sales_order_item DROP CONSTRAINT %I', con.conname);
  END LOOP;
END $$;

ALTER TABLE sales_order_item DROP CONSTRAINT IF EXISTS sales_order_item_pkey;
ALTER TABLE sales_order_2   DROP CONSTRAINT IF EXISTS sales_order_2_pkey;

-- 3. Make the id columns server-assigned IDENTITY (Postgres allows more than
--    one identity column per table, so this coexists with so_number).
ALTER TABLE sales_order_2   ALTER COLUMN sales_order_id ADD GENERATED BY DEFAULT AS IDENTITY;
ALTER TABLE sales_order_item ALTER COLUMN order_item_id ADD GENERATED BY DEFAULT AS IDENTITY;

-- 4. New sole primary keys on the now-global ids.
ALTER TABLE sales_order_2    ADD CONSTRAINT sales_order_2_pkey   PRIMARY KEY (sales_order_id);
ALTER TABLE sales_order_item ADD CONSTRAINT sales_order_item_pkey PRIMARY KEY (order_item_id);

-- 5. Re-add the header→item cascade FK as a single-column reference.
ALTER TABLE sales_order_item
  ADD CONSTRAINT fk_sales_order_item_sales_order_2
  FOREIGN KEY (sales_order_id) REFERENCES sales_order_2(sales_order_id) ON DELETE CASCADE;

-- 6. Swap the composite ownership indexes for ones that still make the
--    pos_client_id / sales_order_id lookups fast now that the key changed.
DROP INDEX IF EXISTS idx_sales_order_2_client_id;
DROP INDEX IF EXISTS idx_sales_order_item_client_order;
CREATE INDEX IF NOT EXISTS idx_sales_order_2_pos_client_id ON sales_order_2(pos_client_id);
CREATE INDEX IF NOT EXISTS idx_sales_order_item_sales_order_id ON sales_order_item(sales_order_id);
CREATE INDEX IF NOT EXISTS idx_sales_order_item_pos_client_id ON sales_order_item(pos_client_id);

COMMIT;

-- RLS REVIEW: policies that referenced (pos_client_id, id) as the row key still
-- work as plain row filters, but re-verify any policy that assumed the composite
-- PK. pos_client_id remains a real column and its pos_clients FK is untouched.
-- Idempotency key for the durable usage-logs outbox: a terminal re-pushing
-- the same local row (retry after a network blip) upserts the same
-- consolidator row instead of duplicating it. Required by the
-- `upsert(onConflict: 'pos_client_id,local_id')` in
-- ConsolidatorOnlyUsageLogsRepository.
--
-- Idempotent: safe to run on the 0008 table that already exists.

ALTER TABLE usage_logs
  ADD CONSTRAINT usage_logs_pos_client_local_id_key UNIQUE (pos_client_id, local_id);
-- Per-ground toggle for whether the sales-order floor plan allows the
-- operator to zoom + pan the blueprint. Mirrors the local sqlite
-- `allow_zoom_pan` column added in DB V52. Default TRUE preserves the
-- existing zoom-and-pan behavior for grounds created before this flag.
--
-- The revision-bump trigger (0006) already fires on any UPDATE, so no
-- extra trigger wiring is needed for this column.

ALTER TABLE ground
  ADD COLUMN IF NOT EXISTS allow_zoom_pan BOOLEAN DEFAULT TRUE;
-- Adds the item_availability table to the consolidator (shared catalog) so an
-- item's per-item scheduling rules travel with it under the
-- `sync_maintenance_data` flag, mirroring discount_availability (0009).
--
-- Keyed by item_barcode; FK to item(barcode) with ON DELETE CASCADE so
-- "Clear Master File" (which removes items) also clears the rules tied to each
-- item. Identity PK uses GENERATED BY DEFAULT for upsert parity with the rest
-- of the maintenance tables.

CREATE TABLE IF NOT EXISTS item_availability (
  id                  BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  item_barcode        TEXT NOT NULL REFERENCES item(barcode) ON DELETE CASCADE,
  day                 TEXT,  -- Monday, Tuesday, etc.
  week_of_month       TEXT,  -- 1,2,3,4,5,L
  start_time          TEXT,  -- HH:mm
  end_time            TEXT,  -- HH:mm
  date_start          TEXT,  -- YYYY-MM-DD
  date_end            TEXT,  -- YYYY-MM-DD
  is_active           INTEGER DEFAULT 1,
  available_on_holiday INTEGER DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_item_availability_barcode ON item_availability (item_barcode);
-- Publishes charge_payment / bank / Discount changes so every terminal keeps a
-- live LOCAL sqlite MIRROR of these tables (ConsolidatorRealtimeListener re-pulls
-- into local on each change). Unlike the menu master tables, these don't drive a
-- bloc — the listener just refreshes the offline mirror so another terminal's
-- edits/deletes land within seconds.

ALTER TABLE charge_payment REPLICA IDENTITY FULL;
ALTER TABLE bank REPLICA IDENTITY FULL;
ALTER TABLE "Discount" REPLICA IDENTITY FULL;

-- Add to the realtime publication. Wrapped so re-running this migration is a
-- no-op instead of erroring on "table is already member of publication".
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE charge_payment;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE bank;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE "Discount";
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Web table-ordering identifies a table by an opaque UUID carried in the
-- URL/QR code (parity with the hosted schema). The consolidator `tables`
-- table is keyed by numeric table_id, so add a stable UUID the web app can
-- look up by. Backfilled for existing rows via the DEFAULT.

ALTER TABLE tables
  ADD COLUMN IF NOT EXISTS table_uuid UUID NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS idx_tables_table_uuid ON tables(table_uuid);
-- Ensure the order tables are broadcast over Supabase realtime.
--
-- The POS (kwikpos_lite) ConsolidatorRealtimeListener subscribes to
-- `sales_order_2` and `sales_order_item` via onPostgresChanges and reloads the
-- floor plan on every change. That only fires when the tables are members of
-- the `supabase_realtime` publication. 0001 set REPLICA IDENTITY FULL on both
-- (needed so DELETE/UPDATE payloads carry the old row), but neither this repo's
-- migrations nor the POS's ever added them to the publication — so unless the
-- publication was created FOR ALL TABLES, web-ordering writes are never pushed
-- to the POS.
--
-- Idempotent: the DO/EXCEPTION blocks make re-runs (and the FOR ALL TABLES
-- case, where the table is already a member) a no-op instead of an error.

ALTER TABLE sales_order_2 REPLICA IDENTITY FULL;
ALTER TABLE sales_order_item REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sales_order_2;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sales_order_item;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Wristband serials tied to a buffet sales order (one row per guest).
-- Mirrors the local SQLite `wristband_serial` table so the wristband/guest
-- report works the same whether orders live locally or on the consolidator.
--
-- Keyed by the globally-unique `sales_order_id` (server IDENTITY on
-- sales_order_2). `pos_client_id` is stamped for ownership/audit. No FK to
-- sales_order_2 so a serial write never races the order upsert; the report
-- joins on sales_order_id in Dart.

CREATE TABLE IF NOT EXISTS wristband_serial (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pos_client_id TEXT,
  sales_order_id BIGINT NOT NULL,
  table_id INTEGER NOT NULL,
  serial TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wristband_serial_sales_order_id
  ON wristband_serial (sales_order_id);

ALTER TABLE wristband_serial REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE wristband_serial;
-- Auto-print order slips for web-table-ordering orders (print-master model).
--
-- The web table-ordering app writes orders straight into the consolidator
-- (`sales_order_2` / `sales_order_item`). Those orders never reach a physical
-- printer today, because slip printing is a client-side action driven by the
-- POS that punches an order. This migration adds the columns that let exactly
-- ONE elected POS ("print master") react to a web order's insert and print it
-- locally, without double-printing orders punched on a real terminal.
--
--   pos_clients.is_web_ordering  — marks the web app's client row. A
--     `sales_order_2` row is a web order iff its pos_client_id points at a
--     pos_clients row with this flag set. No change is needed in the web app's
--     write path; the flag is set once on its client row (see the one-time
--     UPDATE at the bottom, run by hand for your web client id).
--   pos_clients.master_eligible  — this terminal is allowed to serve as print
--     master. Toggled per-terminal from Consolidator Settings and pushed up on
--     each heartbeat. Election picks one live, eligible, non-web client.
--   sales_order_2.order_slip_printed — print-claim guard. The master claims a
--     row atomically (UPDATE ... WHERE order_slip_printed = false) before
--     printing, so reconnect replays and brief dual-master overlap never
--     produce a duplicate slip.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE pos_clients
  ADD COLUMN IF NOT EXISTS is_web_ordering BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE pos_clients
  ADD COLUMN IF NOT EXISTS master_eligible BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE sales_order_2
  ADD COLUMN IF NOT EXISTS order_slip_printed BOOLEAN NOT NULL DEFAULT FALSE;

-- One-time (run by hand, substituting the web app's consolidator client id):
--   UPDATE pos_clients SET is_web_ordering = TRUE WHERE client_id = '<web-client-id>';
-- Per-item print tracking for web-order auto-print (fixes re-added items not
-- printing).
--
-- 0018 added a one-shot `sales_order_2.order_slip_printed` header guard, which
-- printed an order once and then blocked every later addition to the same order.
-- Kitchens need a slip for each newly-added quantity (same as a POS re-punch), so
-- dedup moves to the item level:
--
--   sales_order_item.printed_quantity — how much of this line has already been
--     printed on a slip. The print master prints the delta (quantity -
--     printed_quantity) and then bumps printed_quantity up to quantity, using an
--     optimistic-concurrency claim (WHERE printed_quantity = <observed>) so
--     replays and brief dual-master overlap never double-print a delta.
--
-- Works whether the web app represents a re-add as a new item row
-- (printed_quantity 0 → prints full line) or by bumping an existing line's
-- quantity (prints only the increase). The header `order_slip_printed` column
-- from 0018 is left in place but is no longer used by the app.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS makes re-runs a no-op.

ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS printed_quantity NUMERIC(12, 2) NOT NULL DEFAULT 0;

-- Per-item orderer/customer name. The web table-ordering app stamps who ordered
-- each line (nullable); orders punched on a POS leave it NULL. Shown per item on
-- the sales-order table details and on the web order slip when present. POS write
-- paths never set it, so no local sqlite column is needed — the value is read
-- from the consolidator where web orders live.
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS customer_name TEXT;
-- Per-item "special instructions" — user-defined questions attached to a menu
-- item (e.g. steak → "How done? rare/well-done", "What cut?"). Distinct from the
-- POS's priced option-group/modifier system: these are non-priced, support plain
-- suggested choices AND/OR free text, single or multiple selection, and can be
-- required via min/max.
--
-- Definitions are a shared catalog (like "Department"/"Category"/item in 0009):
-- identity PK, no pos_client_id, realtime-published so edits live-refresh on both
-- the POS and the web table-ordering app. Answers ride on each order line in a new
-- sales_order_item.special_instructions JSON column.
--
-- Idempotent: CREATE ... IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / guarded
-- publication adds make re-runs a no-op.

-- ── Question (group) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS item_instruction_group (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  item_barcode     TEXT NOT NULL REFERENCES item(barcode) ON DELETE CASCADE,
  label            TEXT NOT NULL,
  -- Required ⇔ min_select > 0. Single-select ⇔ max_select = 1; multiple ⇔ > 1
  -- (NULL = unlimited). allow_free_text adds a typed-answer field (on its own for
  -- a free-text-only question, or alongside choices for "both").
  min_select       INTEGER DEFAULT 0,
  max_select       INTEGER DEFAULT 1,
  allow_free_text  INTEGER DEFAULT 0,
  display_order    INTEGER DEFAULT 0,
  group_status     INTEGER DEFAULT 1,
  timestamp_column TIMESTAMPTZ DEFAULT now(),
  d_tran_date      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_item_instruction_group_barcode
  ON item_instruction_group (item_barcode);

-- ── Suggested choice (plain label, no backing product / price) ───
CREATE TABLE IF NOT EXISTS item_instruction_choice (
  id               BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  group_id         BIGINT NOT NULL REFERENCES item_instruction_group(id) ON DELETE CASCADE,
  label            TEXT NOT NULL,
  display_order    INTEGER DEFAULT 0,
  choice_status    INTEGER DEFAULT 1,
  timestamp_column TIMESTAMPTZ DEFAULT now(),
  d_tran_date      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_item_instruction_choice_group
  ON item_instruction_choice (group_id);

-- ── Answers on the order line ────────────────────────────────────
-- JSON array: [{ "group_id": <int>, "label": <str>, "choices": [<str>,...],
--               "free_text": <str|null> }, ...]. Nullable; POS-punched lines
-- without answers leave it NULL. Part of the "don't combine" key so two same-
-- barcode lines with different instructions stay separate.
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS special_instructions TEXT;

-- ── Realtime for the definition tables ───────────────────────────
ALTER TABLE item_instruction_group REPLICA IDENTITY FULL;
ALTER TABLE item_instruction_choice REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE item_instruction_group;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE item_instruction_choice;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Serving status for order lines, tracked per printed TICKET.
--
-- Web-order tickets printed by the print master (0018/0019) carry a CODE128
-- barcode. A separate scanning app scans it when the item is handed over and the
-- served quantity advances.
--
-- Why a ticket table and not a code on the line: the web app COMBINES the same
-- item barcode into one `sales_order_item` row, so "Item A x2" followed later by
-- "Item A x1" is a single row of qty 3. A per-line code would print once and one
-- scan would serve all three. Each *printed instance* needs its own record, so
-- the print master mints one `order_item_ticket` per delta it prints (the delta
-- being `quantity - printed_quantity`, the same boundary 0019 already claims
-- atomically). Scanning a ticket advances the line by THAT ticket's quantity.
--
--   order_item_ticket.ticket_code     — the barcode payload, assigned by
--     Postgres from a sequence ('T000123'). Opaque and short (7 chars) so it
--     stays readable on 58mm paper; the scanner must never parse ids out of it.
--   order_item_ticket.quantity        — how much of the line this ticket covers.
--   sales_order_item.item_status      — 'preparing' (default) | 'served'.
--     'served' only once served_quantity reaches the line's full quantity.
--   sales_order_item.served_quantity  — rollup of the served tickets, so a
--     partly-served line reads e.g. 2 of 3.
--
-- The scanning app's only entry point is serve_ticket(p_ticket_code) below; it
-- passes the scanned value verbatim and gets back everything its confirmation UI
-- needs. sales_order_item is already REPLICA IDENTITY FULL and published to
-- supabase_realtime (0016); order_item_ticket is published below, so scans reach
-- POS terminals live.
--
-- Idempotent: CREATE ... IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / CREATE OR
-- REPLACE / guarded publication add make re-runs a no-op.

-- ── Rollup on the order line ─────────────────────────────────────
-- served_quantity first: item_status is GENERATED from it below.
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS served_quantity NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS served_at       TIMESTAMPTZ;

-- item_status is DERIVED, never stored independently. If it were a plain column
-- it would go stale the moment a line's quantity changed without a scan — the
-- web app merges a re-order of the same item into the existing line, so a fully
-- served "3x A" becomes "4x A" with served_quantity still 3, and a stored status
-- would keep claiming 'served' while a unit was still in the kitchen. As a
-- generated column it cannot disagree with the numbers, whoever changes them.
-- (quantity > 0 keeps a zero-quantity line from reading as served.)
ALTER TABLE sales_order_item
  ADD COLUMN IF NOT EXISTS item_status TEXT
    GENERATED ALWAYS AS (
      CASE WHEN quantity > 0 AND served_quantity >= quantity THEN 'served'
           ELSE 'preparing' END
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_sales_order_item_status
  ON sales_order_item (sales_order_id, item_status);

-- ── One row per printed ticket ───────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS order_item_ticket_code_seq;

CREATE TABLE IF NOT EXISTS order_item_ticket (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  ticket_code    TEXT UNIQUE NOT NULL
                 DEFAULT ('T' || to_char(nextval('order_item_ticket_code_seq'), 'FM000000')),
  order_item_id  BIGINT NOT NULL REFERENCES sales_order_item(order_item_id) ON DELETE CASCADE,
  sales_order_id BIGINT,
  -- How much of the line THIS ticket covers: the delta that was printed.
  quantity       NUMERIC(12, 2) NOT NULL,
  ticket_status  TEXT NOT NULL DEFAULT 'preparing',
  printed_at     TIMESTAMPTZ DEFAULT now(),
  served_at      TIMESTAMPTZ,
  -- Which scanner device served it. The scanning app drains a queue in the
  -- background, so served_at alone can't tell you who scanned it.
  served_by      TEXT
);

-- For databases that already created the table without served_by.
ALTER TABLE order_item_ticket
  ADD COLUMN IF NOT EXISTS served_by TEXT;

CREATE INDEX IF NOT EXISTS idx_order_item_ticket_item
  ON order_item_ticket (order_item_id);

-- ── The scanning app's calls ─────────────────────────────────────
-- The scanning app records every scan locally first and drains the queue in the
-- background, so these functions NEVER raise for a business outcome — they
-- return one row per code with a `result` of 'served' | 'already_served' |
-- 'not_found', always echoing `ticket_code` back. Two reasons:
--   1. The drain must mark each queued scan terminally without parsing error
--      strings, and 'already_served' is a NORMAL outcome here (order-slip copies
--      print the same code twice on purpose, and a re-sent queue row replays).
--   2. RAISE aborts the transaction, which would make one bad code in a batch
--      throw away every other code sent with it.
--
-- Exactly-once is still guaranteed: the ticket is locked FOR UPDATE and an
-- already-served ticket never advances the line a second time.
-- Item names live in the shared `item` catalog (0009), hence the join.

-- Dropped first: the original returned a different column set, and adding
-- p_device_id would otherwise leave an ambiguous overload behind.
DROP FUNCTION IF EXISTS serve_ticket(TEXT);
DROP FUNCTION IF EXISTS serve_ticket(TEXT, TEXT);

CREATE FUNCTION serve_ticket(p_ticket_code TEXT, p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  ticket_code      TEXT,
  result           TEXT,
  ticket_quantity  NUMERIC,
  order_item_id    BIGINT,
  sales_order_id   BIGINT,
  item_barcode     TEXT,
  item_name        TEXT,
  quantity         NUMERIC,
  served_quantity  NUMERIC,
  item_status      TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket order_item_ticket%ROWTYPE;
  v_code   TEXT := trim(p_ticket_code);
BEGIN
  SELECT * INTO v_ticket
    FROM order_item_ticket t
   WHERE t.ticket_code = v_code
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_code, 'not_found'::TEXT, NULL::NUMERIC, NULL::BIGINT,
                        NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC,
                        NULL::NUMERIC, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ticket.ticket_status = 'served' THEN
    -- Report the line's CURRENT totals so a replayed scan still renders a
    -- correct confirmation screen.
    RETURN QUERY
    SELECT v_ticket.ticket_code,
           'already_served'::TEXT,
           v_ticket.quantity,
           i.order_item_id,
           i.sales_order_id,
           i.item_barcode,
           COALESCE(m.print_desc, m.item_desc),
           i.quantity,
           i.served_quantity,
           i.item_status
      FROM sales_order_item i
      LEFT JOIN item m ON m.barcode = i.item_barcode
     WHERE i.order_item_id = v_ticket.order_item_id;
    RETURN;
  END IF;

  UPDATE order_item_ticket t
     SET ticket_status = 'served',
         served_at     = now(),
         served_by     = COALESCE(p_device_id, t.served_by)
   WHERE t.id = v_ticket.id;

  -- Advance the line by this ticket's quantity. LEAST() guards against a line
  -- whose quantity was reduced after its tickets were printed. item_status is a
  -- generated column and follows automatically — it must NOT be assigned here.
  UPDATE sales_order_item i
     SET served_quantity = LEAST(i.quantity, i.served_quantity + v_ticket.quantity),
         served_at       = CASE
                             WHEN LEAST(i.quantity, i.served_quantity + v_ticket.quantity) >= i.quantity
                               THEN now()
                             ELSE i.served_at
                           END
   WHERE i.order_item_id = v_ticket.order_item_id;

  RETURN QUERY
  SELECT v_ticket.ticket_code,
         'served'::TEXT,
         v_ticket.quantity,
         i.order_item_id,
         i.sales_order_id,
         i.item_barcode,
         COALESCE(m.print_desc, m.item_desc),
         i.quantity,
         i.served_quantity,
         i.item_status
    FROM sales_order_item i
    LEFT JOIN item m ON m.barcode = i.item_barcode
   WHERE i.order_item_id = v_ticket.order_item_id;
END $$;

GRANT EXECUTE ON FUNCTION serve_ticket(TEXT, TEXT) TO anon, authenticated;

-- Batch form for the background queue drain: one round trip per flush, one row
-- back per code, in the order given. Independent per code — a 'not_found' in the
-- middle doesn't affect the rest.
DROP FUNCTION IF EXISTS serve_tickets(TEXT[]);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[], TEXT);

CREATE FUNCTION serve_tickets(p_ticket_codes TEXT[], p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  ticket_code      TEXT,
  result           TEXT,
  ticket_quantity  NUMERIC,
  order_item_id    BIGINT,
  sales_order_id   BIGINT,
  item_barcode     TEXT,
  item_name        TEXT,
  quantity         NUMERIC,
  served_quantity  NUMERIC,
  item_status      TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  FOREACH v_code IN ARRAY p_ticket_codes LOOP
    RETURN QUERY SELECT * FROM serve_ticket(v_code, p_device_id);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION serve_tickets(TEXT[], TEXT) TO anon, authenticated;

-- ── Realtime for the ticket table ────────────────────────────────
ALTER TABLE order_item_ticket REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE order_item_ticket;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- KDS orders on the consolidator.
--
-- Kitchen orders have always lived in each POS's local sqlite (`kds_orders` /
-- `kds_order_items`), served to the KDS app over that terminal's HTTP + WebSocket
-- gateway. That ties a kitchen screen to one terminal: it only sees orders from
-- the POS it is paired with, and goes dark when that POS does.
--
-- These tables let every terminal write kitchen orders to one shared place and
-- the KDS read them over Supabase realtime — no POS needs to be reachable. The
-- POS switches to writing here with the "Sync KDS Orders" toggle in Consolidator
-- Settings; with it off nothing below is touched.
--
-- Schema mirrors the local sqlite one (see db/config.dart) with two changes,
-- matching what migration 0010 did for sales orders:
--   * `id` is a globally-unique IDENTITY, so two terminals can't collide on the
--     per-terminal autoincrement ids they used locally.
--   * `pos_client_id` records which terminal sent the order (ownership/audit
--     only — the kitchen screen shows every terminal's orders).
--
-- Status rules live in the RPCs at the bottom rather than in each client, so the
-- POS, the KDS and anything added later cannot disagree about what
-- "partial_serving" means, and two stations bumping items at once can't race.
--
-- Idempotent: CREATE ... IF NOT EXISTS / CREATE OR REPLACE / guarded publication
-- adds make re-runs a no-op.

CREATE TABLE IF NOT EXISTS kds_orders (
  id              BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  pos_client_id   TEXT REFERENCES pos_clients(client_id) ON DELETE CASCADE,
  order_number    TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  received_at     TIMESTAMPTZ DEFAULT now(),
  table_number    TEXT,
  customer_name   TEXT,
  order_sequence  INTEGER DEFAULT 1,
  overall_status  TEXT DEFAULT 'preparing',
  completed_at    TIMESTAMPTZ,
  z_read_number   INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS kds_order_items (
  id                  BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  order_id            BIGINT NOT NULL REFERENCES kds_orders(id) ON DELETE CASCADE,
  name                TEXT NOT NULL,
  quantity            INTEGER DEFAULT 1,
  modifiers           TEXT,
  customization       TEXT,
  notes               TEXT,
  barcode             TEXT,
  station             TEXT,
  estimated_prep_time INTEGER,
  category            TEXT,
  status              TEXT DEFAULT 'preparing',
  created_at          TIMESTAMPTZ DEFAULT now(),
  ready_at            TIMESTAMPTZ,
  picked_up_at        TIMESTAMPTZ,
  completed_at        TIMESTAMPTZ,
  cancelled_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_kds_order_items_order_id ON kds_order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_kds_order_items_status   ON kds_order_items (status);
CREATE INDEX IF NOT EXISTS idx_kds_orders_status        ON kds_orders (overall_status);
CREATE INDEX IF NOT EXISTS idx_kds_orders_pos_client_id ON kds_orders (pos_client_id);

-- ── Order status recalculation ───────────────────────────────────
-- The single source of truth for overall_status, ported from the POS's
-- KdsRepository._updateOverallStatus. Cancelled items are ignored; an order with
-- nothing left but cancelled items is itself cancelled.
CREATE OR REPLACE FUNCTION kds_recalc_order_status(p_order_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active        INTEGER;
  v_preparing     INTEGER;
  v_ready         INTEGER;
  v_dispatched    INTEGER;
  v_completed     INTEGER;
  v_status        TEXT;
BEGIN
  SELECT count(*) FILTER (WHERE status <> 'cancelled'),
         count(*) FILTER (WHERE status = 'preparing'),
         count(*) FILTER (WHERE status = 'ready'),
         count(*) FILTER (WHERE status = 'dispatched'),
         count(*) FILTER (WHERE status = 'completed')
    INTO v_active, v_preparing, v_ready, v_dispatched, v_completed
    FROM kds_order_items
   WHERE order_id = p_order_id;

  IF v_active = 0 THEN
    v_status := 'cancelled';
  ELSIF v_dispatched + v_completed = v_active THEN
    v_status := 'completed';
  ELSIF v_ready = v_active THEN
    v_status := 'dispatched';
  ELSIF v_ready > 0 THEN
    -- Some ready: still cooking → partial_serving, otherwise the rest is
    -- already picked up, which the POS treats as dispatched.
    v_status := CASE WHEN v_preparing > 0 THEN 'partial_serving' ELSE 'dispatched' END;
  ELSIF v_dispatched > 0 OR v_completed > 0 THEN
    v_status := 'partial_served';
  ELSE
    v_status := 'preparing';
  END IF;

  UPDATE kds_orders o
     SET overall_status = v_status,
         completed_at   = CASE WHEN v_status IN ('completed', 'dispatched')
                                 THEN now() ELSE o.completed_at END
   WHERE o.id = p_order_id;

  RETURN v_status;
END $$;

-- ── Item status ──────────────────────────────────────────────────
-- Mirrors KdsRepository.updateItemStatus, including its quirk: a KDS sending
-- 'dispatched' means "done", which is recorded as 'ready' — only the QMS pickup
-- path may mark an item dispatched.
CREATE OR REPLACE FUNCTION kds_set_item_status(p_item_id BIGINT, p_status TEXT)
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status   TEXT := CASE WHEN p_status = 'dispatched' THEN 'ready' ELSE p_status END;
  v_order_id BIGINT;
BEGIN
  UPDATE kds_order_items i
     SET status       = v_status,
         ready_at     = CASE WHEN v_status = 'ready'      THEN now() ELSE i.ready_at END,
         picked_up_at = CASE WHEN v_status = 'dispatched' THEN now() ELSE i.picked_up_at END,
         completed_at = CASE WHEN v_status = 'completed'  THEN now() ELSE i.completed_at END,
         cancelled_at = CASE WHEN v_status = 'cancelled'  THEN now() ELSE i.cancelled_at END
   WHERE i.id = p_item_id
   RETURNING i.order_id INTO v_order_id;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'kds_item_not_found: %', p_item_id USING ERRCODE = 'P0002';
  END IF;

  PERFORM kds_recalc_order_status(v_order_id);
  RETURN QUERY SELECT * FROM kds_orders WHERE id = v_order_id;
END $$;

-- ── Order status ─────────────────────────────────────────────────
-- Mirrors KdsRepository.updateOrderStatus: completing an order cascades its
-- non-cancelled items to completed.
CREATE OR REPLACE FUNCTION kds_set_order_status(p_order_id BIGINT, p_status TEXT)
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_status = 'completed' THEN
    UPDATE kds_order_items
       SET status       = 'completed',
           completed_at = now()
     WHERE order_id = p_order_id
       AND status <> 'cancelled';
  END IF;

  UPDATE kds_orders o
     SET overall_status = p_status,
         completed_at   = CASE WHEN p_status IN ('completed', 'dispatched')
                                 THEN now() ELSE o.completed_at END
   WHERE o.id = p_order_id;

  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

-- ── Pickup (QMS) ─────────────────────────────────────────────────
-- Mirrors KdsRepository.pickupOrder: everything already ready (or stamped
-- ready_at) and not yet picked up becomes dispatched.
CREATE OR REPLACE FUNCTION kds_pickup_order(p_order_id BIGINT)
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE kds_order_items
     SET status       = 'dispatched',
         picked_up_at = now()
   WHERE order_id = p_order_id
     AND picked_up_at IS NULL
     AND status <> 'cancelled'
     AND (status = 'ready' OR ready_at IS NOT NULL);

  PERFORM kds_recalc_order_status(p_order_id);
  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

-- ── Recall ───────────────────────────────────────────────────────
-- Mirrors KdsRepository.recallOrder: 'serving' pulls items back to ready,
-- anything else back to preparing (which also clears ready_at).
CREATE OR REPLACE FUNCTION kds_recall_order(p_order_id BIGINT, p_type TEXT DEFAULT 'full')
RETURNS SETOF kds_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target TEXT := CASE WHEN p_type = 'serving' THEN 'ready' ELSE 'preparing' END;
BEGIN
  UPDATE kds_orders SET completed_at = NULL WHERE id = p_order_id;

  UPDATE kds_order_items
     SET status       = v_target,
         completed_at = NULL,
         picked_up_at = NULL,
         cancelled_at = NULL,
         ready_at     = CASE WHEN v_target = 'preparing' THEN NULL ELSE ready_at END
   WHERE order_id = p_order_id
     AND status <> 'cancelled';

  PERFORM kds_recalc_order_status(p_order_id);
  RETURN QUERY SELECT * FROM kds_orders WHERE id = p_order_id;
END $$;

GRANT EXECUTE ON FUNCTION kds_recalc_order_status(BIGINT)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_set_item_status(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_set_order_status(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_pickup_order(BIGINT)          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_recall_order(BIGINT, TEXT)    TO anon, authenticated;

-- ── Realtime ─────────────────────────────────────────────────────
-- The KDS app runs on realtime alone in consolidator mode: no websocket, no
-- REST. FULL replica identity so UPDATE payloads carry the whole row and the
-- screen can apply an item status change without re-reading.
ALTER TABLE kds_orders      REPLICA IDENTITY FULL;
ALTER TABLE kds_order_items REPLICA IDENTITY FULL;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE kds_orders;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE kds_order_items;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- Scanning a ticket also closes the kitchen line.
--
-- 0021 made a ticket scan advance the SALES side (sales_order_item.served_quantity),
-- but the kitchen screen is a separate representation (kds_orders / kds_order_items,
-- 0022). So a line the runner already handed out kept sitting on the KDS as if it
-- were still waiting, and the order never finished.
--
-- Nothing linked the two, so this migration adds the link and teaches serve_ticket
-- to advance both in one transaction:
--
--   kds_order_items.order_item_id  — which sales_order_item this kitchen line came
--     from. The FALLBACK link, used for tickets minted before this migration.
--   kds_order_items.served_quantity — how much of the line has been handed over. A
--     kitchen row is one line ("3x Item A") whatever the slip mode, while
--     Per-Quantity mode mints one ticket per unit, so serving has to count rather
--     than flip: the row only becomes 'dispatched' at the full count.
--   order_item_ticket.kds_order_item_id — the EXACT kitchen line a ticket belongs
--     to. Several per-unit tickets point at the same row, which is what makes
--     Per-Quantity mode land correctly.
--
-- A scan marks the line 'dispatched' even if the kitchen never marked it ready:
-- the food physically left, and the screen should say so. The scan reports the
-- status it found first, so the scanning app can warn that this happened.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE / drop-then-create for
-- the functions whose signatures change.

ALTER TABLE kds_order_items
  ADD COLUMN IF NOT EXISTS served_quantity NUMERIC(12, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS order_item_id   BIGINT;

ALTER TABLE order_item_ticket
  ADD COLUMN IF NOT EXISTS kds_order_item_id BIGINT
    REFERENCES kds_order_items(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_kds_order_items_order_item_id
  ON kds_order_items (order_item_id);

-- ── Advance the kitchen line ─────────────────────────────────────
-- Returns the row's status BEFORE this call, or NULL when no kitchen line
-- matched — which is a normal outcome: the item may be flagged off the kitchen
-- screen (show_on_kds = 0), KDS sync may be off, or the ticket may predate 0022.
CREATE OR REPLACE FUNCTION kds_serve_units(
  p_kds_item_id   BIGINT,
  p_order_item_id BIGINT,
  p_quantity      NUMERIC
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item   kds_order_items%ROWTYPE;
  v_served NUMERIC;
BEGIN
  IF p_kds_item_id IS NOT NULL THEN
    SELECT * INTO v_item FROM kds_order_items WHERE id = p_kds_item_id FOR UPDATE;
  END IF;

  -- Fallback for tickets with no direct link: the oldest line for this order item
  -- that is neither cancelled nor already fully handed over.
  IF v_item.id IS NULL AND p_order_item_id IS NOT NULL THEN
    SELECT * INTO v_item
      FROM kds_order_items
     WHERE order_item_id = p_order_item_id
       AND status <> 'cancelled'
       AND served_quantity < quantity
     ORDER BY id
     LIMIT 1
     FOR UPDATE;
  END IF;

  IF v_item.id IS NULL THEN
    RETURN NULL;
  END IF;

  v_served := LEAST(v_item.quantity, v_item.served_quantity + COALESCE(p_quantity, 0));

  UPDATE kds_order_items i
     SET served_quantity = v_served,
         -- Fully handed over → 'dispatched' with picked_up_at, matching what
         -- kds_pickup_order does, so it lands in the KDS's Dispatched section.
         status          = CASE WHEN v_served >= i.quantity THEN 'dispatched' ELSE i.status END,
         picked_up_at    = CASE WHEN v_served >= i.quantity THEN now() ELSE i.picked_up_at END
   WHERE i.id = v_item.id;

  -- Lets the order complete on its own once every line is dispatched.
  PERFORM kds_recalc_order_status(v_item.order_id);

  RETURN v_item.status;
END $$;

-- ── The scanning app's calls ─────────────────────────────────────
-- Same contract as 0021 — never raises for a business outcome, always echoes
-- ticket_code, one row per code — plus two columns describing the kitchen side:
--   kds_matched            — was there a kitchen line to advance at all
--   kds_item_status_before — what the kitchen had it as before this scan, so the
--                            app can flag food that went out before it was ready
DROP FUNCTION IF EXISTS serve_ticket(TEXT);
DROP FUNCTION IF EXISTS serve_ticket(TEXT, TEXT);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[]);
DROP FUNCTION IF EXISTS serve_tickets(TEXT[], TEXT);

CREATE FUNCTION serve_ticket(p_ticket_code TEXT, p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  ticket_code            TEXT,
  result                 TEXT,
  ticket_quantity        NUMERIC,
  order_item_id          BIGINT,
  sales_order_id         BIGINT,
  item_barcode           TEXT,
  item_name              TEXT,
  quantity               NUMERIC,
  served_quantity        NUMERIC,
  item_status            TEXT,
  kds_matched            BOOLEAN,
  kds_item_status_before TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ticket     order_item_ticket%ROWTYPE;
  v_code       TEXT := trim(p_ticket_code);
  v_kds_before TEXT;
BEGIN
  SELECT * INTO v_ticket
    FROM order_item_ticket t
   WHERE t.ticket_code = v_code
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_code, 'not_found'::TEXT, NULL::NUMERIC, NULL::BIGINT,
                        NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC,
                        NULL::NUMERIC, NULL::TEXT, FALSE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ticket.ticket_status = 'served' THEN
    -- Report the line's CURRENT totals so a replayed scan still renders a
    -- correct confirmation screen. The kitchen is deliberately NOT touched: a
    -- re-scan must never draw the line down twice.
    RETURN QUERY
    SELECT v_ticket.ticket_code,
           'already_served'::TEXT,
           v_ticket.quantity,
           i.order_item_id,
           i.sales_order_id,
           i.item_barcode,
           COALESCE(m.print_desc, m.item_desc),
           i.quantity,
           i.served_quantity,
           i.item_status,
           FALSE,
           NULL::TEXT
      FROM sales_order_item i
      LEFT JOIN item m ON m.barcode = i.item_barcode
     WHERE i.order_item_id = v_ticket.order_item_id;
    RETURN;
  END IF;

  UPDATE order_item_ticket t
     SET ticket_status = 'served',
         served_at     = now(),
         served_by     = COALESCE(p_device_id, t.served_by)
   WHERE t.id = v_ticket.id;

  -- Advance the line by this ticket's quantity. LEAST() guards against a line
  -- whose quantity was reduced after its tickets were printed. item_status is a
  -- generated column and follows automatically — it must NOT be assigned here.
  UPDATE sales_order_item i
     SET served_quantity = LEAST(i.quantity, i.served_quantity + v_ticket.quantity),
         served_at       = CASE
                             WHEN LEAST(i.quantity, i.served_quantity + v_ticket.quantity) >= i.quantity
                               THEN now()
                             ELSE i.served_at
                           END
   WHERE i.order_item_id = v_ticket.order_item_id;

  -- ...and the kitchen line, in the same transaction.
  v_kds_before := kds_serve_units(
    v_ticket.kds_order_item_id,
    v_ticket.order_item_id,
    v_ticket.quantity
  );

  RETURN QUERY
  SELECT v_ticket.ticket_code,
         'served'::TEXT,
         v_ticket.quantity,
         i.order_item_id,
         i.sales_order_id,
         i.item_barcode,
         COALESCE(m.print_desc, m.item_desc),
         i.quantity,
         i.served_quantity,
         i.item_status,
         v_kds_before IS NOT NULL,
         v_kds_before
    FROM sales_order_item i
    LEFT JOIN item m ON m.barcode = i.item_barcode
   WHERE i.order_item_id = v_ticket.order_item_id;
END $$;

GRANT EXECUTE ON FUNCTION serve_ticket(TEXT, TEXT) TO anon, authenticated;

-- Batch form for the background queue drain: one round trip per flush, one row
-- back per code, in the order given. Independent per code — a 'not_found' in the
-- middle doesn't affect the rest.
CREATE FUNCTION serve_tickets(p_ticket_codes TEXT[], p_device_id TEXT DEFAULT NULL)
RETURNS TABLE (
  ticket_code            TEXT,
  result                 TEXT,
  ticket_quantity        NUMERIC,
  order_item_id          BIGINT,
  sales_order_id         BIGINT,
  item_barcode           TEXT,
  item_name              TEXT,
  quantity               NUMERIC,
  served_quantity        NUMERIC,
  item_status            TEXT,
  kds_matched            BOOLEAN,
  kds_item_status_before TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  FOREACH v_code IN ARRAY p_ticket_codes LOOP
    RETURN QUERY SELECT * FROM serve_ticket(v_code, p_device_id);
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION serve_tickets(TEXT[], TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION kds_serve_units(BIGINT, BIGINT, NUMERIC) TO anon, authenticated;
-- Durable print queue for web-order slips.
--
-- Web-order slips used to be printed inline by the elected print master, which
-- assumed that one terminal owns every printer in the store. It doesn't: items
-- route to 'Network Printer 1', 'Network Printer 2', 'USB Printer 1'… and a
-- terminal only has some of those configured. printOrderSlips silently skipped
-- the printers it didn't have and reported success, so the master consumed the
-- per-item print claim (printed_quantity) and the slip was lost for good — the
-- catch-up sweep never revisits a line that is already marked printed. The KDS
-- was unaffected because it ignores printer routing, which is why a kitchen
-- screen could look complete while half the paper never came out.
--
-- Now the master ENQUEUES a job per slip and any master-eligible terminal drains
-- the jobs for printers IT owns, so a 'Network Printer 2' slip is printed by
-- whichever terminal actually has that printer — not by whoever won the election.
-- A job is only marked done when a terminal really sent it, so nothing is lost:
-- a printer that is offline, or that no terminal owns yet, keeps the job pending
-- and visible instead of dropping it.
--
-- Idempotent: CREATE ... IF NOT EXISTS / CREATE OR REPLACE make re-runs a no-op.

CREATE TABLE IF NOT EXISTS print_job (
  id             BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  sales_order_id BIGINT,
  -- The slot this slip is routed to ('Network Printer 2', 'USB Printer 1'), or
  -- 'Unassigned' when the item carries no assigned_printer at all.
  printer_name   TEXT NOT NULL,
  copies         INTEGER NOT NULL DEFAULT 1,
  -- The slip is rendered at print time on whichever terminal drains it, so its
  -- paper size and station alias stay local to that terminal.
  payload        JSONB NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending',  -- pending | printing | done | failed
  attempts       INTEGER NOT NULL DEFAULT 0,
  claimed_by     TEXT,
  claimed_at     TIMESTAMPTZ,
  printed_at     TIMESTAMPTZ,
  last_error     TEXT,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_print_job_pending
  ON print_job (status, printer_name, id);

-- How long a job may sit in 'printing' before another terminal may take it over.
-- Covers a terminal that died mid-print; long enough that a slow printer on a
-- healthy terminal is never stolen from underneath it.
--   → see the interval literal in claim_print_jobs below (2 minutes).

-- ── Claim ────────────────────────────────────────────────────────
-- Hands the caller up to p_limit pending jobs it can actually print, flipping
-- them to 'printing' in the same statement.
--
-- SKIP LOCKED is what makes several terminals safe to run at once: each grabs a
-- different row instead of blocking or, worse, both printing the same slip.
CREATE OR REPLACE FUNCTION claim_print_jobs(
  p_client_id     TEXT,
  p_printer_names TEXT[],
  p_limit         INTEGER DEFAULT 10
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT j.id
      FROM print_job j
     WHERE j.printer_name = ANY (p_printer_names)
       AND (
             j.status = 'pending'
             -- Stuck: whoever claimed it never reported back.
             OR (j.status = 'printing' AND j.claimed_at < now() - INTERVAL '2 minutes')
           )
     ORDER BY j.id
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE print_job j
     SET status     = 'printing',
         claimed_by = p_client_id,
         claimed_at = now()
    FROM claimable c
   WHERE j.id = c.id
  RETURNING j.*;
END $$;

-- ── Complete ─────────────────────────────────────────────────────
-- Called only when the terminal actually sent the slip to a printer.
CREATE OR REPLACE FUNCTION complete_print_job(p_id BIGINT)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE print_job
     SET status     = 'done',
         printed_at = now(),
         last_error = NULL
   WHERE id = p_id
  RETURNING *;
END $$;

-- ── Release ──────────────────────────────────────────────────────
-- The print failed, or the terminal turned out not to have the printer after
-- all. Back to pending for someone else to take, with the reason recorded.
-- After enough tries it becomes 'failed' so a genuinely broken printer stops
-- churning and shows up in the Print Queue panel instead.
CREATE OR REPLACE FUNCTION release_print_job(
  p_id           BIGINT,
  p_error        TEXT DEFAULT NULL,
  p_max_attempts INTEGER DEFAULT 20
)
RETURNS SETOF print_job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  UPDATE print_job
     SET attempts   = attempts + 1,
         status     = CASE WHEN attempts + 1 >= p_max_attempts THEN 'failed' ELSE 'pending' END,
         claimed_by = NULL,
         claimed_at = NULL,
         last_error = p_error
   WHERE id = p_id
  RETURNING *;
END $$;

-- ── Retry ────────────────────────────────────────────────────────
-- Manual "retry failed" from the POS: puts exhausted jobs back in play.
CREATE OR REPLACE FUNCTION retry_failed_print_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE print_job
     SET status     = 'pending',
         attempts   = 0,
         claimed_by = NULL,
         claimed_at = NULL
   WHERE status = 'failed';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION claim_print_jobs(TEXT, TEXT[], INTEGER)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_print_job(BIGINT)                   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION release_print_job(BIGINT, TEXT, INTEGER)     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION retry_failed_print_jobs()                    TO anon, authenticated;
-- Item display images shared across terminals.
--
-- `item.disp_image` is and stays a *local* filesystem path — every terminal
-- renders its own file from `%APPDATA%\KwikPOS\images` (see AppPathHelper), so
-- the POS keeps working with no consolidator and no network. What was missing
-- was a way for the bytes to travel: a terminal that never picked the image has
-- no file to render.
--
-- This adds a public Storage bucket (`master-file`) that holds the item images,
-- plus `item.image_object` — the object key inside that bucket, e.g.
-- `items/<barcode>.jpg`. Saving an item uploads its image and stamps the key;
-- "Download Master File to Local" pulls every object down into the local images
-- folder and rewrites each local row's `disp_image` to point at the downloaded
-- file. Reads are therefore always local-file reads, never bucket reads.
--
-- Idempotent: ON CONFLICT DO NOTHING / ADD COLUMN IF NOT EXISTS / DROP POLICY
-- IF EXISTS before CREATE make re-runs a no-op.

-- ── Bucket ───────────────────────────────────────────────────────
-- Public: images are non-sensitive menu photos and a public bucket means the
-- POS can fetch them over plain HTTP with no signed-URL round trip.
INSERT INTO storage.buckets (id, name, public)
VALUES ('master-file', 'master-file', true)
ON CONFLICT (id) DO NOTHING;

-- ── Policies ─────────────────────────────────────────────────────
-- Terminals authenticate with the shared anon key (same trust model as the rest
-- of the consolidator tables), so anon gets full CRUD on this bucket only.
DROP POLICY IF EXISTS "master_file_read" ON storage.objects;
CREATE POLICY "master_file_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_insert" ON storage.objects;
CREATE POLICY "master_file_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_update" ON storage.objects;
CREATE POLICY "master_file_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'master-file')
  WITH CHECK (bucket_id = 'master-file');

DROP POLICY IF EXISTS "master_file_delete" ON storage.objects;
CREATE POLICY "master_file_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'master-file');

-- ── Object key on the shared item row ────────────────────────────
ALTER TABLE item ADD COLUMN IF NOT EXISTS image_object TEXT;
