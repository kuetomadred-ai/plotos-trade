create or replace function public.pf_engine_demo_refill()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.program='PAPER' and new.balance<=0 and not exists(select 1 from public.pf_engine_positions where account_id=new.id and status='OPEN') then
   update public.pf_engine_orders set status='CANCELLED',reason='Demo refill',updated_at=now() where account_id=new.id and status='PENDING';
   new.balance:=1000; new.initial_balance:=1000; new.day_start_balance:=1000; new.min_equity:=1000; new.status:='ACTIVE';
   insert into public.pf_engine_ledger(account_id,user_id,event,amount,balance_after,details)
   values(new.id,new.user_id,'RULE_EVENT',1000,1000,jsonb_build_object('result','DEMO_REFILL'));
 end if;
 return new;
end $$;
drop trigger if exists pf_engine_demo_refill on public.pf_engine_accounts;
create trigger pf_engine_demo_refill before update on public.pf_engine_accounts for each row execute function public.pf_engine_demo_refill();
update public.pf_engine_accounts set updated_at=now() where program='PAPER' and balance<=0;