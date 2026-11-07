CREATE OR REPLACE FUNCTION public.pf_engine_bot_step()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE b record; q record; v_open int; v_float numeric; v_res jsonb; p record; n int := 0; v_px numeric;
  v_dir text; v_closed int; v_new text; v_t time; v_dow int; v_us boolean;
BEGIN
  v_t := (now() AT TIME ZONE 'UTC')::time;
  v_dow := extract(isodow from (now() AT TIME ZONE 'UTC'));
  v_us := v_dow BETWEEN 1 AND 5 AND v_t BETWEEN '14:30' AND '16:30';
  FOR b IN SELECT * FROM pf_engine_bots WHERE active FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      IF b.symbol = 'US30' AND NOT v_us THEN
        FOR p IN SELECT id FROM pf_engine_positions WHERE account_id=b.account_id AND symbol='US30' AND status='OPEN' LOOP
          PERFORM pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
        END LOOP;
        IF b.last_entry IS NOT NULL OR b.last_action IS DISTINCT FROM 'OUTSIDE US SESSION (PAUSED)' THEN
          UPDATE pf_engine_bots SET last_entry=NULL, last_action='OUTSIDE US SESSION (PAUSED)', updated_at=now() WHERE id=b.id;
        END IF;
        CONTINUE;
      END IF;
      SELECT bid, ask INTO q FROM pf_engine_quotes WHERE symbol = b.symbol;
      IF q IS NULL THEN CONTINUE; END IF;
      SELECT count(*) INTO v_open FROM pf_engine_positions WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN';

      IF b.mode = 'whipsaw' THEN
        v_px := (q.bid + q.ask) / 2;
        IF v_open = 0 THEN
          PERFORM pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'buy', 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE pf_engine_bots SET last_entry=v_px, cycle=cycle+1, last_action=format('WHIPSAW START: BUY %s @ %s', b.lots, round(v_px,2)), updated_at=now() WHERE id=b.id;
          n := n + 1; CONTINUE;
        END IF;
        IF b.last_entry IS NULL THEN
          UPDATE pf_engine_bots SET last_entry=v_px, updated_at=now() WHERE id=b.id; CONTINUE;
        END IF;
        SELECT id, side INTO p FROM pf_engine_positions WHERE account_id=b.account_id AND symbol=b.symbol AND status='OPEN' ORDER BY opened_at DESC LIMIT 1;
        IF (p.side='buy' AND v_px <= b.last_entry - b.step) OR (p.side='sell' AND v_px >= b.last_entry + b.step) THEN
          FOR p IN SELECT id, side FROM pf_engine_positions WHERE account_id=b.account_id AND symbol=b.symbol AND status='OPEN' LOOP
            v_new := CASE WHEN p.side='buy' THEN 'sell' ELSE 'buy' END;
            PERFORM pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
          END LOOP;
          PERFORM pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_new, 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE pf_engine_bots SET last_entry=v_px, last_action=format('WHIPSAW FLIP -> %s %s @ %s', upper(v_new), b.lots, round(v_px,2)), updated_at=now() WHERE id=b.id;
          n := n + 1;
        END IF;
        CONTINUE;
      END IF;

      IF b.mode = 'hedge_trap' THEN
        v_px := (q.bid + q.ask) / 2;
        IF v_open = 0 THEN
          PERFORM pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'buy', 'MARKET', b.lots, NULL, NULL, NULL);
          PERFORM pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, 'sell', 'MARKET', b.lots, NULL, NULL, NULL);
          UPDATE pf_engine_bots SET last_entry = v_px, cycle = cycle + 1,
            last_action = format('HEDGE PAIR @ %s', round(v_px, 2)), updated_at = now() WHERE id = b.id;
          n := n + 1; CONTINUE;
        END IF;
        IF b.last_entry IS NULL THEN
          UPDATE pf_engine_bots SET last_entry = v_px, updated_at = now() WHERE id = b.id; CONTINUE;
        END IF;
        v_dir := CASE WHEN v_px >= b.last_entry + b.step THEN 'up'
                      WHEN v_px <= b.last_entry - b.step THEN 'down' ELSE NULL END;
        IF v_dir IS NULL THEN CONTINUE; END IF;
        v_closed := 0;
        FOR p IN SELECT id FROM pf_engine_positions
                 WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN'
                   AND ((v_dir = 'up' AND side = 'buy' AND q.bid > entry_price)
                     OR (v_dir = 'down' AND side = 'sell' AND q.ask < entry_price)) LOOP
          PERFORM pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
          v_closed := v_closed + 1;
        END LOOP;
        v_new := CASE WHEN v_dir = 'up' THEN 'sell' ELSE 'buy' END;
        IF v_open - v_closed < b.max_positions THEN
          v_res := pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, v_new, 'MARKET', b.lots, NULL, NULL, NULL);
        END IF;
        UPDATE pf_engine_bots SET last_entry = v_px,
          last_action = format('%s $%s: closed %s winners, %s %s @ %s', upper(v_dir), b.step, v_closed, upper(v_new), b.lots, round(v_px, 2)),
          updated_at = now() WHERE id = b.id;
        n := n + 1; CONTINUE;
      END IF;

      SELECT pf_engine_equity(b.account_id) - a.balance INTO v_float FROM pf_engine_accounts a WHERE a.id = b.account_id;
      IF v_open > 0 AND v_float >= b.target THEN
        FOR p IN SELECT id FROM pf_engine_positions WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN' LOOP
          PERFORM pf_engine_close_position(b.user_id, p.id, gen_random_uuid());
        END LOOP;
        UPDATE pf_engine_bots SET last_entry = NULL, cycle = cycle + 1, cycles_won = cycles_won + 1,
          total_profit = total_profit + v_float, last_action = format('TARGET +%s closed %s', round(v_float,2), v_open), updated_at = now() WHERE id = b.id;
        n := n + 1; CONTINUE;
      END IF;
      IF v_open = 0 THEN b.last_entry := NULL; END IF;
      v_px := CASE WHEN b.side = 'buy' THEN q.ask ELSE q.bid END;
      IF v_open < b.max_positions AND (b.last_entry IS NULL OR
         (b.side = 'buy' AND q.bid <= b.last_entry - b.step) OR (b.side = 'sell' AND q.ask >= b.last_entry + b.step)) THEN
        v_res := pf_engine_place_order(b.user_id, b.account_id, gen_random_uuid(), b.symbol, b.side, 'MARKET', b.lots, NULL, NULL, NULL);
        UPDATE pf_engine_bots SET last_entry = COALESCE((v_res->>'fill_price')::numeric, v_px),
          last_action = format('%s %s @ %s', upper(b.side), b.lots, COALESCE(v_res->>'fill_price', v_px::text)), updated_at = now() WHERE id = b.id;
        n := n + 1;
      ELSIF v_open = 0 THEN
        UPDATE pf_engine_bots SET last_entry = NULL, updated_at = now() WHERE id = b.id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE pf_engine_bots SET last_action = 'ERROR: ' || SQLERRM, updated_at = now() WHERE id = b.id;
    END;
  END LOOP;
  RETURN n;
END $function$;