-- 0085_print_job_customization.sql
--
-- Server-built order slips (print_job payloads from kds_ingest_sales_order_item
-- and kds_enqueue_reprint_slip) never carried the line's product customization,
-- so POS/KDS print-job drains could not print the chosen options.
--
-- Rather than re-copying the large ingest/reprint functions, a BEFORE trigger on
-- print_job fills `customization` (the sales_order_item.customization TEXT JSON,
-- {groupName: [{barcode, quantity, productName}]}) into every payload line that
-- has an orderItemId and no customization yet. Covers inserts and the perOrder
-- merge-window UPDATE that appends lines.
--
-- Idempotent. Applied MANUALLY against Supabase (see consolidator-migrations-manual).

CREATE OR REPLACE FUNCTION print_job_fill_customization()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_orders JSONB;
  v_out    JSONB := '[]'::jsonb;
  v_line   JSONB;
  v_cust   TEXT;
BEGIN
  v_orders := NEW.payload->'orders';
  IF v_orders IS NULL OR jsonb_typeof(v_orders) <> 'array' THEN
    RETURN NEW;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(v_orders) LOOP
    IF NOT (v_line ? 'customization') AND (v_line->>'orderItemId') IS NOT NULL THEN
      SELECT s.customization INTO v_cust
        FROM sales_order_item s
       WHERE s.order_item_id::text = v_line->>'orderItemId';
      IF v_cust IS NOT NULL AND btrim(v_cust) NOT IN ('', '{}', 'null') THEN
        v_line := v_line || jsonb_build_object('customization', v_cust);
      END IF;
    END IF;
    v_out := v_out || jsonb_build_array(v_line);
  END LOOP;

  NEW.payload := jsonb_set(NEW.payload, '{orders}', v_out);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block a slip over customization enrichment.
  RAISE WARNING 'print_job_fill_customization failed: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_print_job_fill_customization ON print_job;
CREATE TRIGGER trg_print_job_fill_customization
  BEFORE INSERT OR UPDATE OF payload ON print_job
  FOR EACH ROW EXECUTE FUNCTION print_job_fill_customization();
