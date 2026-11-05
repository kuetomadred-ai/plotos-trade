CREATE TABLE public.pf_engine_bots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  account_id text NOT NULL REFERENCES public.pf_engine_accounts(id),
  symbol text NOT NULL DEFAULT 'XAUUSD',
  side text NOT NULL DEFAULT 'buy',
  lots numeric NOT NULL DEFAULT 1,
  step numeric NOT NULL DEFAULT 1,
  target numeric NOT NULL DEFAULT 100,
  max_positions integer NOT NULL DEFAULT 5,
  active boolean NOT NULL DEFAULT true,
  last_entry numeric,
  cycle integer NOT NULL DEFAULT 1,
  cycles_won integer NOT NULL DEFAULT 0,
  total_profit numeric NOT NULL DEFAULT 0,
  last_action text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.pf_engine_bots TO authenticated;
GRANT ALL ON public.pf_engine_bots TO service_role;
ALTER TABLE public.pf_engine_bots ENABLE ROW LEVEL SECURITY;
CREATE POLICY pf_engine_bot_owner_read ON public.pf_engine_bots FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.pf_engine_bot_step() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b record; q record; v_open int; v_float numeric; v_res jsonb; p record; n int := 0; v_px numeric;
BEGIN
  FOR b IN SELECT * FROM pf_engine_bots WHERE active FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      SELECT bid, ask INTO q FROM pf_engine_quotes WHERE symbol = b.symbol;
      IF q IS NULL THEN CONTINUE; END IF;
      SELECT count(*) INTO v_open FROM pf_engine_positions WHERE account_id = b.account_id AND symbol = b.symbol AND status = 'OPEN';
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
END $$;
REVOKE ALL ON FUNCTION public.pf_engine_bot_step() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pf_engine_bot_step() TO service_role;