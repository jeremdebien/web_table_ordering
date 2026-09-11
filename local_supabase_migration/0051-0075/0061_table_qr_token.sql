-- Dynamic table QR — short-lived ordering tokens for web table ordering.
--
-- The web app reaches a table via `/table/<table_uuid>` (0015). That uuid never
-- changes, so a photographed table QR orders forever. This adds an optional
-- store-wide DYNAMIC mode: the POS prints a slip whose QR carries a random token
-- (`<base_url>/t/<token>`) and the consolidator only accepts web-app order writes
-- that carry a live token for that table.
--
--   app_config 'table_qr'   {mode: 'static'|'dynamic', ttl_minutes, base_url}.
--                           Static (default) = today's behaviour, nothing gated.
--   table_qr_token          one row per printed QR. Live = not revoked and
--                           now() < expires_at. At most one live token per table
--                           (issuing a new one revokes the previous).
--   sales_order_2.qr_token / sales_order_item.qr_token
--                           the token the web app ordered under (audit + gate).
--
-- Enforcement (dynamic mode only) is a BEFORE trigger on the web app's writes —
-- headers whose pos_client_id is the web-ordering client (pos_clients.is_web_ordering,
-- 0018), and lines from that client that carry a web_device_id (guest lines).
-- POS / KDS writes are never gated. A token is revoked when:
--   * a new QR is printed for the table          ('reissued')
--   * the table's order is settled/cleared       ('settled' / 'cleared')
--   * the order is transferred to another table  ('transferred')
--   * the order is combined into another table   ('joined')
--   * TTL elapses (no row change; checked at use)
--
-- Trust model: the anon key ships with the web app, so this defends against
-- stale / shared / crafted QR links, not against someone scripting the RPCs.
--
-- Also seeds the web table ordering pos_clients row so it no longer has to be
-- typed by hand on every new consolidator.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT make re-runs a no-op.

-- ── Web table ordering client row ────────────────────────────────
INSERT INTO pos_clients (client_id, client_name, app_version, os_info, device_type, is_web_ordering, master_eligible)
VALUES ('4a44d303-b438-4c1e-9cfa-e6be92f60899', 'Web Table Ordering', 'web', 'web', 'web', TRUE, FALSE)
ON CONFLICT (client_id) DO UPDATE
  SET is_web_ordering = TRUE,
      master_eligible = FALSE;

-- ── Config ───────────────────────────────────────────────────────
INSERT INTO app_config (key, value)
VALUES ('table_qr', '{"mode": "static", "ttl_minutes": 120, "base_url": ""}'::JSONB)
ON CONFLICT (key) DO NOTHING;

-- ── Token table ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS table_qr_token (
  token               TEXT PRIMARY KEY,
  table_id            BIGINT NOT NULL,
  sales_order_id      BIGINT,              -- order open when issued (informational)
  issued_by_client_id TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at          TIMESTAMPTZ NOT NULL,
  revoked_at          TIMESTAMPTZ,
  revoke_reason       TEXT
);

CREATE INDEX IF NOT EXISTS idx_table_qr_token_live
  ON table_qr_token (table_id) WHERE revoked_at IS NULL;

-- No policies: anon/authenticated can't read or write tokens directly (no
-- enumeration). All access goes through the SECURITY DEFINER functions below.
ALTER TABLE table_qr_token ENABLE ROW LEVEL SECURITY;

ALTER TABLE sales_order_2    ADD COLUMN IF NOT EXISTS qr_token TEXT;
ALTER TABLE sales_order_item ADD COLUMN IF NOT EXISTS qr_token TEXT;

-- ── Helpers ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION table_qr_mode() RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT value->>'mode' FROM app_config WHERE key = 'table_qr'), 'static');
$$;

CREATE OR REPLACE FUNCTION table_qr_ttl_minutes() RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT GREATEST(1, COALESCE(
    NULLIF((SELECT value->>'ttl_minutes' FROM app_config WHERE key = 'table_qr'), '')::NUMERIC::INTEGER,
    120));
$$;

-- 22-char URL-safe token from 128 random bits (gen_random_uuid is core PG13+,
-- no pgcrypto / extensions schema dependency).
CREATE OR REPLACE FUNCTION table_qr_new_token() RETURNS TEXT
LANGUAGE sql VOLATILE AS $$
  SELECT rtrim(translate(encode(decode(replace(gen_random_uuid()::TEXT, '-', ''), 'hex'), 'base64'), '+/', '-_'), '=');
$$;

CREATE OR REPLACE FUNCTION revoke_table_qr(p_table_id BIGINT, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE table_qr_token
     SET revoked_at = now(), revoke_reason = p_reason
   WHERE table_id = p_table_id
     AND revoked_at IS NULL;
END $$;

CREATE OR REPLACE FUNCTION _table_qr_json(t table_qr_token) RETURNS JSONB
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'token', t.token,
    'table_id', t.table_id,
    'sales_order_id', t.sales_order_id,
    'created_at', t.created_at,
    'expires_at', t.expires_at);
$$;

-- ── POS: issue / reprint ─────────────────────────────────────────
-- Revokes the table's live token(s) and issues a fresh one.
CREATE OR REPLACE FUNCTION issue_table_qr(p_table_id BIGINT, p_sales_order_id BIGINT, p_client_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  PERFORM revoke_table_qr(p_table_id, 'reissued');

  INSERT INTO table_qr_token (token, table_id, sales_order_id, issued_by_client_id, expires_at)
  VALUES (table_qr_new_token(), p_table_id, p_sales_order_id, p_client_id,
          now() + make_interval(mins => table_qr_ttl_minutes()))
  RETURNING * INTO t;

  RETURN _table_qr_json(t);
END $$;

-- The table's live token, or NULL (Reprint).
CREATE OR REPLACE FUNCTION current_table_qr(p_table_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  SELECT * INTO t FROM table_qr_token
   WHERE table_id = p_table_id AND revoked_at IS NULL AND expires_at > now()
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN _table_qr_json(t);
END $$;

-- Web waiter tool: reuse the table's live token so a waiter ordering for a
-- guest never revokes the guest's printed QR; issue one only when none is live.
CREATE OR REPLACE FUNCTION staff_table_qr(p_table_id BIGINT, p_client_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v JSONB;
  v_so BIGINT;
BEGIN
  v := current_table_qr(p_table_id);
  IF v IS NOT NULL THEN RETURN v; END IF;

  SELECT sales_order_id INTO v_so FROM sales_order_2
   WHERE table_id = p_table_id AND payment_status IN (0, 1)
   ORDER BY created_at DESC LIMIT 1;
  RETURN issue_table_qr(p_table_id, v_so, p_client_id);
END $$;

-- ── Web: resolve a scanned token ─────────────────────────────────
-- {status: 'ok'|'expired'|'invalid', table_id, table_uuid, table_desc, expires_at}
CREATE OR REPLACE FUNCTION resolve_table_qr(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t  table_qr_token;
  tb tables;
BEGIN
  SELECT * INTO t FROM table_qr_token WHERE token = p_token;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  SELECT * INTO tb FROM tables WHERE table_id = t.table_id;

  RETURN jsonb_build_object(
    'status', CASE WHEN t.revoked_at IS NULL AND t.expires_at > now() THEN 'ok' ELSE 'expired' END,
    'table_id', t.table_id,
    'table_uuid', tb.table_uuid,
    'table_desc', tb.table_desc,
    'expires_at', t.expires_at,
    'revoke_reason', t.revoke_reason);
END $$;

-- ── Enforcement ──────────────────────────────────────────────────
-- Raises TABLE_QR_EXPIRED / TABLE_QR_INVALID (SQLSTATE P0001, message = code)
-- unless p_token is a live token for p_table_id.
CREATE OR REPLACE FUNCTION _table_qr_assert(p_token TEXT, p_table_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t table_qr_token;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RAISE EXCEPTION 'TABLE_QR_INVALID' USING HINT = 'Scan the QR code provided by staff.';
  END IF;
  SELECT * INTO t FROM table_qr_token WHERE token = p_token;
  IF NOT FOUND OR t.table_id IS DISTINCT FROM p_table_id THEN
    RAISE EXCEPTION 'TABLE_QR_INVALID' USING HINT = 'Scan the QR code provided by staff.';
  END IF;
  IF t.revoked_at IS NOT NULL OR t.expires_at <= now() THEN
    RAISE EXCEPTION 'TABLE_QR_EXPIRED' USING HINT = 'This QR has expired. Ask staff for a new one.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION _is_web_ordering_client(p_client_id TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT is_web_ordering FROM pos_clients WHERE client_id = p_client_id), FALSE);
$$;

CREATE OR REPLACE FUNCTION table_qr_guard_sales_order()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF table_qr_mode() = 'dynamic' AND _is_web_ordering_client(NEW.pos_client_id) THEN
    PERFORM _table_qr_assert(NEW.qr_token, NEW.table_id);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_guard_sales_order ON sales_order_2;
CREATE TRIGGER trg_table_qr_guard_sales_order
  BEFORE INSERT ON sales_order_2
  FOR EACH ROW EXECUTE FUNCTION table_qr_guard_sales_order();

-- Lines: guest lines only — web client AND web_device_id set. Only the web app
-- stamps web_device_id; the POS and server functions never copy it, so lines
-- moved INTO a web-created order (transfer_sales_order_items stamps the target
-- header's client id) are not mistaken for guest writes. Gated on INSERT and on
-- UPDATEs that ADD quantity (the web app's merge-into-existing-line path);
-- reductions / POS-side edits (void, printed_quantity, split) never are.
CREATE OR REPLACE FUNCTION table_qr_guard_sales_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_table_id BIGINT;
BEGIN
  IF NEW.web_device_id IS NULL
     OR table_qr_mode() <> 'dynamic'
     OR NOT _is_web_ordering_client(NEW.pos_client_id) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.quantity <= OLD.quantity THEN
    RETURN NEW;
  END IF;

  SELECT table_id INTO v_table_id FROM sales_order_2 WHERE sales_order_id = NEW.sales_order_id LIMIT 1;
  PERFORM _table_qr_assert(NEW.qr_token, v_table_id);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_guard_sales_order_item ON sales_order_item;
CREATE TRIGGER trg_table_qr_guard_sales_order_item
  BEFORE INSERT OR UPDATE OF quantity ON sales_order_item
  FOR EACH ROW EXECUTE FUNCTION table_qr_guard_sales_order_item();

-- ── Revocation on order lifecycle ────────────────────────────────
-- Always runs (even in static mode) so switching to dynamic never finds stale
-- live tokens from a previous session.
CREATE OR REPLACE FUNCTION table_qr_on_sales_order_change()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM revoke_table_qr(OLD.table_id, 'cleared');
    RETURN NULL;
  END IF;

  IF OLD.table_id IS DISTINCT FROM NEW.table_id AND OLD.table_id IS NOT NULL THEN
    PERFORM revoke_table_qr(OLD.table_id, 'transferred');
  END IF;

  IF COALESCE(OLD.payment_status, 0) IN (0, 1) AND COALESCE(NEW.payment_status, 0) NOT IN (0, 1) THEN
    PERFORM revoke_table_qr(NEW.table_id, 'settled');
  END IF;

  IF (OLD.parent_sales_order_id IS NULL AND NEW.parent_sales_order_id IS NOT NULL
        AND NEW.parent_sales_order_id <> NEW.sales_order_id)
     OR (COALESCE(OLD.is_combine, FALSE) = FALSE AND COALESCE(NEW.is_combine, FALSE) = TRUE
        AND NEW.parent_sales_order_id IS NOT NULL AND NEW.parent_sales_order_id <> NEW.sales_order_id) THEN
    PERFORM revoke_table_qr(NEW.table_id, 'joined');
  END IF;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Never block a POS settle / transfer on token bookkeeping.
  RAISE WARNING 'table_qr_on_sales_order_change failed for sales_order_id=%: %',
    COALESCE(NEW.sales_order_id, OLD.sales_order_id), SQLERRM;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_table_qr_on_sales_order_change ON sales_order_2;
CREATE TRIGGER trg_table_qr_on_sales_order_change
  AFTER UPDATE OF table_id, payment_status, parent_sales_order_id, is_combine OR DELETE ON sales_order_2
  FOR EACH ROW EXECUTE FUNCTION table_qr_on_sales_order_change();

-- ── Grants ───────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION issue_table_qr(BIGINT, BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION current_table_qr(BIGINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION staff_table_qr(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION resolve_table_qr(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION revoke_table_qr(BIGINT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION table_qr_mode() TO anon, authenticated;
