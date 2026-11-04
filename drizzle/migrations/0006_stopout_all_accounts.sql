create or replace function public.pf_engine_evaluate_account(p_account_id text)
returns text language plpgsql security definer set search_path=pg_catalog as $$
declare a public.pf_engine_accounts; eq numeric; today date:=(now() at time zone 'utc')::date; x record; reason text; px numeric;
begin
 select * into a from public.pf_engine_accounts where id=p_account_id for update;
 if not found or a.status<>'ACTIVE' then return null; end if;
 if a.day_key<>today or a.day_start_balance is null then
   update public.pf_engine_accounts set day_key=today,day_start_balance=balance where id=a.id returning * into a;
 end if;
 eq:=public.pf_engine_equity(a.id);
 update public.pf_engine_accounts set min_equity=least(coalesce(min_equity,eq),eq) where id=a.id;
 if a.program='PAPER' then
   if eq<=0 and exists(select 1 from public.pf_engine_positions where account_id=a.id and status='OPEN') then
     for x in select p.id,p.side,q.bid,q.ask from public.pf_engine_positions p join public.pf_engine_quotes q on q.symbol=p.symbol where p.account_id=a.id and p.status='OPEN' loop
       perform public.pf_engine_close_at(x.id,case when x.side='buy' then x.bid else x.ask end,'RULE');
     end loop;
     insert into public.pf_engine_ledger(account_id,user_id,event,amount,balance_after,details)
     values(a.id,a.user_id,'RULE_EVENT',0,(select balance from public.pf_engine_accounts where id=a.id),jsonb_build_object('result','STOPOUT','equity',eq));
     return 'STOPOUT';
   end if;
   return null;
 end if;
 if eq<=0 then reason:='STOPOUT';
 elsif a.daily_loss_pct is not null and eq<=a.day_start_balance*(1-a.daily_loss_pct/100) then reason:='DAILY_LOSS';
 elsif a.max_dd_pct is not null and eq<=a.initial_balance*(1-a.max_dd_pct/100) then reason:='MAX_DRAWDOWN';
 end if;
 if reason is not null then
   for x in select p.id,p.side,q.bid,q.ask from public.pf_engine_positions p join public.pf_engine_quotes q on q.symbol=p.symbol where p.account_id=a.id and p.status='OPEN' loop
     px:=case when x.side='buy' then x.bid else x.ask end;
     perform public.pf_engine_close_at(x.id,px,'RULE');
   end loop;
   update public.pf_engine_orders set status='CANCELLED',reason='Account rule breach: '||reason,updated_at=now() where account_id=a.id and status='PENDING';
   update public.pf_engine_accounts set status='LOCKED',challenge_status='FAILED',fail_reason=reason,updated_at=now() where id=a.id returning * into a;
   insert into public.pf_engine_ledger(account_id,user_id,event,amount,balance_after,details)
   values(a.id,a.user_id,'RULE_EVENT',0,a.balance,jsonb_build_object('result','FAILED','reason',reason,'equity',eq));
   return reason;
 end if;
 if a.profit_target_pct is not null and a.balance>=a.initial_balance*(1+a.profit_target_pct/100)
    and not exists(select 1 from public.pf_engine_positions where account_id=a.id and status='OPEN') then
   update public.pf_engine_orders set status='CANCELLED',reason='Phase target reached',updated_at=now() where account_id=a.id and status='PENDING';
   update public.pf_engine_accounts set status='LOCKED',challenge_status='PASSED',updated_at=now() where id=a.id returning * into a;
   insert into public.pf_engine_ledger(account_id,user_id,event,amount,balance_after,details)
   values(a.id,a.user_id,'RULE_EVENT',0,a.balance,jsonb_build_object('result','PASSED','phase',a.phase));
   return 'PASSED';
 end if;
 return null;
end $$;

create or replace function public.pf_engine_evaluate_all()
returns integer language plpgsql security definer set search_path=pg_catalog as $$
declare r record; n integer:=0;
begin
 for r in select distinct a.id from public.pf_engine_accounts a join public.pf_engine_positions p on p.account_id=a.id and p.status='OPEN' where a.status='ACTIVE'
   union select id from public.pf_engine_accounts where status='ACTIVE' and program<>'PAPER' loop
   if public.pf_engine_evaluate_account(r.id) is not null then n:=n+1; end if;
 end loop;
 return n;
end $$;