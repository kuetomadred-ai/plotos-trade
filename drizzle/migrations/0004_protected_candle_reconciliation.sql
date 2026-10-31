ALTER TABLE public.pf_engine_positions ADD COLUMN IF NOT EXISTS protection_changed_at timestamptz, ADD COLUMN IF NOT EXISTS risk_checked_at timestamptz, ADD COLUMN IF NOT EXISTS risk_issue jsonb;
CREATE OR REPLACE FUNCTION public.pf_engine_protection_changed() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$ BEGIN IF NEW.stop_loss IS DISTINCT FROM OLD.stop_loss OR NEW.take_profit IS DISTINCT FROM OLD.take_profit THEN NEW.protection_changed_at:=clock_timestamp(); NEW.risk_checked_at:=NULL; NEW.risk_issue:=NULL; END IF; RETURN NEW; END $$;
CREATE TRIGGER pf_engine_protection_changed BEFORE UPDATE OF stop_loss,take_profit ON public.pf_engine_positions FOR EACH ROW EXECUTE FUNCTION public.pf_engine_protection_changed();
CREATE OR REPLACE FUNCTION public.pf_engine_reconcile_candles(p_symbol text,p_bars jsonb,p_basis text DEFAULT 'UNKNOWN') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p public.pf_engine_positions; i public.pf_engine_instruments; a public.pf_engine_accounts; b jsonb; bt timestamptz; hi numeric; lo numeric; px numeric; pnl numeric; reason text; sl_hit boolean; tp_hit boolean; n integer:=0; unresolved integer:=0;
BEGIN
 IF p_basis NOT IN ('BID','ASK','UNKNOWN') OR jsonb_typeof(p_bars)<>'array' OR jsonb_array_length(p_bars)>1000 THEN RAISE EXCEPTION 'Invalid candle batch'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('pf-risk:'||p_symbol,0));
 SELECT * INTO i FROM public.pf_engine_instruments WHERE symbol=p_symbol AND enabled; IF NOT FOUND THEN RETURN jsonb_build_object('closed',0,'unresolved',0); END IF;
 FOR p IN SELECT * FROM public.pf_engine_positions WHERE symbol=p_symbol AND status='OPEN' AND (stop_loss IS NOT NULL OR take_profit IS NOT NULL) ORDER BY account_id,id FOR UPDATE LOOP
  FOR b IN SELECT value FROM jsonb_array_elements(p_bars) ORDER BY (value->>'openTime')::timestamptz LOOP
   bt:=(b->>'openTime')::timestamptz; hi:=(b->>'high')::numeric; lo:=(b->>'low')::numeric;
   IF hi IS NULL OR lo IS NULL OR lo<=0 OR hi<lo OR bt IS NULL THEN RAISE EXCEPTION 'Invalid candle'; END IF;
   IF coalesce((b->>'isOpen')::boolean,true) OR bt+interval '1 minute'>now() OR bt<greatest(p.opened_at,coalesce(p.protection_changed_at,p.opened_at)) OR (p.risk_checked_at IS NOT NULL AND bt<p.risk_checked_at) THEN CONTINUE; END IF;
   sl_hit:=p.stop_loss IS NOT NULL AND CASE WHEN p.side='buy' THEN lo<=p.stop_loss ELSE hi>=p.stop_loss END;
   tp_hit:=p.take_profit IS NOT NULL AND CASE WHEN p.side='buy' THEN hi>=p.take_profit ELSE lo<=p.take_profit END;
   IF p_basis='UNKNOWN' OR (p.side='buy' AND p_basis<>'ASK') OR (p.side='sell' AND p_basis<>'BID') OR (sl_hit AND tp_hit) THEN
    IF sl_hit OR tp_hit THEN UPDATE public.pf_engine_positions SET risk_issue=jsonb_build_object('kind',CASE WHEN p_basis='UNKNOWN' THEN 'UNKNOWN_CANDLE_BASIS' WHEN sl_hit AND tp_hit THEN 'AMBIGUOUS_SL_TP' ELSE 'INCOMPATIBLE_CANDLE_BASIS' END,'bar_open_at',bt,'detected_at',now(),'high',hi,'low',lo) WHERE id=p.id; unresolved:=unresolved+1; EXIT; END IF;
    CONTINUE;
   END IF;
   UPDATE public.pf_engine_positions SET risk_checked_at=bt+interval '1 minute',risk_issue=NULL WHERE id=p.id;
   IF NOT sl_hit AND NOT tp_hit THEN CONTINUE; END IF;
   reason:=CASE WHEN sl_hit THEN 'SL' ELSE 'TP' END; px:=CASE WHEN sl_hit THEN p.stop_loss ELSE p.take_profit END;
   pnl:=round(((px-p.entry_price)/i.tick_size*i.tick_value*p.lots*CASE WHEN p.side='buy' THEN 1 ELSE -1 END)::numeric,2);
   SELECT * INTO a FROM public.pf_engine_accounts WHERE id=p.account_id FOR UPDATE;
   UPDATE public.pf_engine_positions SET status='CLOSED',closed_at=now(),exit_price=px,realized_pnl=pnl,close_reason=reason WHERE id=p.id;
   UPDATE public.pf_engine_accounts SET balance=balance+pnl,updated_at=now() WHERE id=a.id RETURNING * INTO a;
   INSERT INTO public.pf_engine_trades_history(position_id,user_id,account_id,symbol,side,lots,entry_price,exit_price,realized_pnl,close_reason,opened_at,closed_at) VALUES(p.id,p.user_id,p.account_id,p.symbol,p.side,p.lots,p.entry_price,px,pnl,reason,p.opened_at,now());
   INSERT INTO public.pf_engine_ledger(account_id,user_id,position_id,event,amount,balance_after,details) VALUES(p.account_id,p.user_id,p.id,'POSITION_CLOSED',pnl,a.balance,jsonb_build_object('price',px,'reason',reason,'source','VERIFIED_CANDLE_RECONCILIATION','bar_open_at',bt,'time_precision','MINUTE_RANGE','settled_at',now(),'spread_bonus',0,'spread_unavailable',true,'price_basis',p_basis));
   n:=n+1; EXIT;
  END LOOP;
 END LOOP;
 RETURN jsonb_build_object('closed',n,'unresolved',unresolved);
END $$;
REVOKE ALL ON FUNCTION public.pf_engine_protection_changed() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.pf_engine_reconcile_candles(text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.pf_engine_reconcile_candles(text,jsonb,text) TO service_role;