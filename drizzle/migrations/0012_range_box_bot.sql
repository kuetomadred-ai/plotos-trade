ALTER TABLE public.pf_engine_bots
  ADD COLUMN IF NOT EXISTS range_high numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS range_low numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS exhausted_zones text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS dynamic_lot_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS lot_per_thousand numeric NOT NULL DEFAULT 1.0;

CREATE OR REPLACE FUNCTION public.pf_engine_update_bot_range(
  p_user_id uuid,
  p_bot_id uuid,
  p_high numeric,
  p_low numeric
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_updated integer;
BEGIN
  IF p_high IS NULL OR p_low IS NULL OR p_high <= p_low OR p_low < 0 THEN
    RAISE EXCEPTION 'range_high must be greater than range_low and both must be non-negative';
  END IF;

  UPDATE public.pf_engine_bots b
     SET range_high = p_high,
         range_low = p_low,
         exhausted_zones = '{}'::text[],
         last_entry = NULL,
         last_action = format('RANGE UPDATED: %s - %s', round(p_low, 5), round(p_high, 5)),
         updated_at = now()
   WHERE b.id = p_bot_id
     AND b.user_id = p_user_id
     AND EXISTS (
       SELECT 1
         FROM public.pf_engine_accounts a
        WHERE a.id = b.account_id
          AND a.user_id = p_user_id
     );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'Bot not found';
  END IF;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.pf_engine_update_bot_range(uuid, uuid, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pf_engine_update_bot_range(uuid, uuid, numeric, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.pf_engine_bot_step()
 RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  b record;
  q record;
  a record;
  v_open integer;
  v_float numeric;
  v_res jsonb;
  p record;
  n integer := 0;
  v_px numeric;
  v_lots numeric;
  v_bucket text;
  v_range_side text;
  v_dir text;
  v_closed integer;
  v_new text;
  v_t time;
  v_dow integer;
  v_us boolean;
  v_side text;
BEGIN
  v_t := (now() AT TIME ZONE 'UTC')::time;
  v_dow := extract(isodow from (now() AT TIME ZONE 'UTC'));
  v_us := v_dow BETWEEN 1 AND 5 AND v_t BETWEEN '14:30' AND '16:30';

  FOR b IN SELECT * FROM public.pf_engine_bots WHERE active FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      IF b.symbol = 'US30' AND NOT v_us THEN
        FOR p IN SELECT id FROM public.pf_engine_positions
          WHERE account_id = b.account_id AND symbol = 'US30' AND status = 'OPEN'
        LOOP
          PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
        END LOOP;
        IF b.last_entry IS NOT NULL OR b.last_action IS DISTINCT FROM 'OUTSIDE US SESSION (PAUSED)' THEN
          UPDATE public.pf_engine_bots
             SET last_entry = NULL, last_action = 'OUTSIDE US SESSION (PAUSED)', updated_at = now()
           WHERE id = b.id;
        END IF;
        CONTINUE;
      END IF;

      SELECT bid, ask INTO q FROM public.pf_engine_quotes WHERE symbol = b.symbol;
      IF q IS NULL THEN CONTINUE; END IF;
      SELECT count(*) INTO v_open FROM public.pf_engine_positions
       WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN';

      IF b.mode = 'range_box' THEN
        IF b.range_high <= b.range_low OR b.range_high <= 0 THEN
          UPDATE public.pf_engine_bots
             SET last_action = 'RANGE NOT CONFIGURED', updated_at = now()
           WHERE id = b.id;
          CONTINUE;
        END IF;

        SELECT * INTO a FROM public.pf_engine_accounts WHERE id = b.account_id AND user_id = b.user_id;
        IF a IS NULL THEN CONTINUE; END IF;

        v_px := (q.bid + q.ask) / 2;
        IF v_open > 0 THEN
          SELECT public.pf_engine_equity(b.account_id) - a.balance INTO v_float;
          IF v_float >= b.target THEN
            FOR p IN SELECT id FROM public.pf_engine_positions
              WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN'
            LOOP
              PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
            END LOOP;
            UPDATE public.pf_engine_bots
               SET last_entry = NULL,
                   cycle = cycle + 1,
                   cycles_won = cycles_won + 1,
                   total_profit = total_profit + v_float,
                   last_action = format('RANGE TARGET +%s closed %s', round(v_float, 2), v_open),
                   updated_at = now()
             WHERE id = b.id;
            n := n + 1;
            CONTINUE;
          END IF;
        END IF;

        v_range_side := CASE
          WHEN v_px > b.range_high THEN 'buy'
          WHEN v_px < b.range_low THEN 'sell'
          ELSE NULL
        END;
        IF v_range_side IS NULL THEN
          UPDATE public.pf_engine_bots
             SET last_action = format('RANGE HOLD @ %s', round(v_px, 5)), updated_at = now()
           WHERE id = b.id;
          CONTINUE;
        END IF;

        v_bucket := floor(v_px)::text;
        IF v_bucket = ANY(COALESCE(b.exhausted_zones, '{}'::text[])) THEN
          UPDATE public.pf_engine_bots
             SET last_action = format('ZONE EXHAUSTED %s @ %s', v_bucket, round(v_px, 5)), updated_at = now()
           WHERE id = b.id;
          CONTINUE;
        END IF;

        IF v_open < b.max_positions THEN
          v_lots := CASE
            WHEN COALESCE(b.dynamic_lot_enabled, true)
              THEN GREATEST(1.0, floor((a.balance / 1000.0) * COALESCE(b.lot_per_thousand, 1.0)))
            ELSE b.lots
          END;
          v_res := public.pf_engine_place_order(
            b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_range_side,
            'MARKET', v_lots, NULL, NULL, NULL
          );
          UPDATE public.pf_engine_bots
             SET last_entry = COALESCE((v_res->>'fill_price')::numeric, v_px),
                 exhausted_zones = CASE
                   WHEN v_bucket = ANY(COALESCE(exhausted_zones, '{}'::text[])) THEN exhausted_zones
                   ELSE array_append(COALESCE(exhausted_zones, '{}'::text[]), v_bucket)
                 END,
                 last_action = format('RANGE BREAK %s %s @ %s', upper(v_range_side), v_lots, round(v_px, 5)),
                 updated_at = now()
           WHERE id = b.id;
          n := n + 1;
        END IF;
        CONTINUE;
      END IF;

      IF b.mode = 'whipsaw' THEN
        v_px := (q.bid + q.ask) / 2;
        IF v_open = 0 THEN
          PERFORM public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'buy', 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE public.pf_engine_bots SET last_entry=v_px, cycle=cycle+1, last_action=format('WHIPSAW START: BUY %s @ %s', b.lots, round(v_px,2)), updated_at=now() WHERE id=b.id;
          n := n + 1; CONTINUE;
        END IF;
        IF b.last_entry IS NULL THEN
          UPDATE public.pf_engine_bots SET last_entry=v_px, updated_at=now() WHERE id=b.id; CONTINUE;
        END IF;
        SELECT side INTO v_side FROM public.pf_engine_positions WHERE account_id=b.account_id AND symbol=b.symbol AND status='OPEN' ORDER BY opened_at DESC LIMIT 1;
        IF (v_side='buy' AND v_px >= b.last_entry + b.step) OR (v_side='sell' AND v_px <= b.last_entry - b.step) THEN
          FOR p IN SELECT id FROM public.pf_engine_positions WHERE account_id=b.account_id AND symbol=b.symbol AND status='OPEN' LOOP
            PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
          END LOOP;
          PERFORM public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_side, 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE public.pf_engine_bots SET last_entry=v_px, cycles_won=cycles_won+1, last_action=format('TP HIT -> RE-ENTER %s %s @ %s', upper(v_side), b.lots, round(v_px,2)), updated_at=now() WHERE id=b.id;
          n := n + 1;
        ELSIF (v_side='buy' AND v_px <= b.last_entry - b.step) OR (v_side='sell' AND v_px >= b.last_entry + b.step) THEN
          v_new := CASE WHEN v_side='buy' THEN 'sell' ELSE 'buy' END;
          FOR p IN SELECT id FROM public.pf_engine_positions WHERE account_id=b.account_id AND symbol=b.symbol AND status='OPEN' LOOP
            PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
          END LOOP;
          PERFORM public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_new, 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE public.pf_engine_bots SET last_entry=v_px, last_action=format('SL HIT -> FLIP %s %s @ %s', upper(v_new), b.lots, round(v_px,2)), updated_at=now() WHERE id=b.id;
          n := n + 1;
        END IF;
        CONTINUE;
      END IF;

      IF b.mode = 'hedge_trap' THEN
        v_px := (q.bid + q.ask) / 2;
        IF v_open = 0 THEN
          PERFORM public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'buy', 'MARKET', b.lots, NULL, NULL, NULL);
          PERFORM public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'sell', 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE public.pf_engine_bots SET last_entry = v_px, cycle = cycle + 1, last_action = format('HEDGE PAIR @ %s', round(v_px, 2)), updated_at = now() WHERE id = b.id;
          n := n + 1; CONTINUE;
        END IF;
        IF b.last_entry IS NULL THEN
          UPDATE public.pf_engine_bots SET last_entry = v_px, updated_at = now() WHERE id = b.id; CONTINUE;
        END IF;
        v_dir := CASE WHEN v_px >= b.last_entry + b.step THEN 'up' WHEN v_px <= b.last_entry - b.step THEN 'down' ELSE NULL END;
        IF v_dir IS NULL THEN CONTINUE; END IF;
        v_closed := 0;
        FOR p IN SELECT id FROM public.pf_engine_positions WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN'
          AND ((v_dir = 'up' AND side = 'buy' AND q.bid > entry_price) OR (v_dir = 'down' AND side = 'sell' AND q.ask < entry_price)) LOOP
          PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid()); v_closed := v_closed + 1;
        END LOOP;
        v_new := CASE WHEN v_dir = 'up' THEN 'sell' ELSE 'buy' END;
        IF v_open - v_closed < b.max_positions THEN
          v_res := public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_new, 'MARKET', b.lots, NULL, NULL, NULL);
        END IF;
        UPDATE public.pf_engine_bots SET last_entry = v_px, last_action = format('%s $%s: closed %s winners, %s %s @ %s', upper(v_dir), b.step, v_closed, upper(v_new), b.lots, round(v_px, 2)), updated_at = now() WHERE id = b.id;
        n := n + 1; CONTINUE;
      END IF;

      SELECT public.pf_engine_equity(b.account_id) - a.balance INTO v_float FROM public.pf_engine_accounts a WHERE a.id = b.account_id;
      IF v_open > 0 AND v_float >= b.target THEN
        FOR p IN SELECT id FROM public.pf_engine_positions WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN' LOOP
          PERFORM public.pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
        END LOOP;
        UPDATE public.pf_engine_bots SET last_entry = NULL, cycle = cycle + 1, cycles_won = cycles_won + 1, total_profit = total_profit + v_float, last_action = format('TARGET +%s closed %s', round(v_float,2), v_open), updated_at = now() WHERE id = b.id;
        n := n + 1; CONTINUE;
      END IF;
      IF v_open = 0 THEN b.last_entry := NULL; END IF;
      v_px := CASE WHEN b.side = 'buy' THEN q.ask ELSE q.bid END;
      IF v_open < b.max_positions AND (b.last_entry IS NULL OR (b.side = 'buy' AND q.bid <= b.last_entry - b.step) OR (b.side = 'sell' AND q.ask >= b.last_entry + b.step)) THEN
        v_res := public.pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, b.side, 'MARKET', b.lots, NULL, NULL, NULL);
        UPDATE public.pf_engine_bots SET last_entry = COALESCE((v_res->>'fill_price')::numeric, v_px), last_action = format('%s %s @ %s', upper(b.side), b.lots, COALESCE(v_res->>'fill_price', v_px::text)), updated_at = now() WHERE id = b.id;
        n := n + 1;
      ELSIF v_open = 0 THEN
        UPDATE public.pf_engine_bots SET last_entry = NULL, updated_at = now() WHERE id = b.id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.pf_engine_bots SET last_action = 'ERROR: ' || SQLERRM, updated_at = now() WHERE id = b.id;
    END;
  END LOOP;
  RETURN n;
END;
$function$;

REVOKE ALL ON FUNCTION public.pf_engine_bot_step() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pf_engine_bot_step() TO service_role;
