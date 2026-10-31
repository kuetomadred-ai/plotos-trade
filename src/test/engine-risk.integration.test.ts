// @vitest-environment node
import postgres from 'postgres'
import { describe, expect, it } from 'vitest'

const connection = process.env['SUPABASE_DB_URL']
const rollback = new Error('rollback risk fixture')
describe.skipIf(!connection)('database SL/TP settlement (rolled-back fixtures)', () => {
  async function fixture(run: (sql: postgres.TransactionSql) => Promise<void>, side = 'buy') {
    if (!connection) throw new Error('Test database missing')
    const db = postgres(connection, { max: 1 })
    try {
      await db.begin(async sql => {
        await sql`insert into public.pf_engine_instruments(symbol,tick_size,tick_value,contract_size) values('RISKTEST',1,1,1)`
        await sql`insert into public.pf_engine_accounts(id,user_id,initial_balance,balance,leverage) values('risk-test','00000000-0000-4000-8000-000000000001',10000,10000,100)`
        await sql`insert into public.pf_engine_positions(id,user_id,account_id,symbol,side,lots,entry_price,stop_loss,take_profit,opened_at) values('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000001','risk-test','RISKTEST',${side},1,4000,${side === 'buy' ? 3990 : 4010},${side === 'buy' ? 4010 : 3990},now()-interval '10 minutes')`
        await run(sql)
        throw rollback
      })
    } catch (e) { if (e !== rollback) throw e } finally { await db.end() }
  }
  async function reconcile(sql: postgres.TransactionSql, high: number, low: number, basis = 'ASK', offset = '5 minutes') {
    return sql`select public.pf_engine_reconcile_candles('RISKTEST',jsonb_build_array(jsonb_build_object('openTime',date_trunc('minute',now()-${offset}::interval),'high',${high}::numeric,'low',${low}::numeric,'isOpen',false)),${basis}) as result`
  }
  it('closes buy at the exact TP 4010 once, credits 10, and records settlement time honestly', async () => {
    await fixture(async sql => {
      await reconcile(sql, 4010, 3995)
      await reconcile(sql, 4010, 3995)
      const [p] = await sql`select status,exit_price,realized_pnl,close_reason from public.pf_engine_positions where account_id='risk-test'`
      expect(p).toMatchObject({ status: 'CLOSED', exit_price: '4010.000000000000', realized_pnl: '10.00', close_reason: 'TP' })
      const [a] = await sql`select balance from public.pf_engine_accounts where id='risk-test'`
      expect(a?.balance).toBe('10010.00')
      const [l] = await sql`select count(*)::int as count from public.pf_engine_ledger where account_id='risk-test'`
      expect(l?.count).toBe(1)
    })
  })
  it('closes sell at exact SL 4010 rather than overshoot 4015', async () => {
    await fixture(async sql => {
      await reconcile(sql, 4015, 3995, 'BID')
      const [p] = await sql`select exit_price,realized_pnl,close_reason from public.pf_engine_positions where account_id='risk-test'`
      expect(p).toMatchObject({ exit_price: '4010.000000000000', realized_pnl: '-10.00', close_reason: 'SL' })
    }, 'sell')
  })
  it('does not fill unknown candle basis and records the gap', async () => {
    await fixture(async sql => {
      await reconcile(sql, 4015, 3995, 'UNKNOWN')
      const [p] = await sql`select status,risk_issue->>'kind' as issue from public.pf_engine_positions where account_id='risk-test'`
      expect(p).toMatchObject({ status: 'OPEN', issue: 'UNKNOWN_CANDLE_BASIS' })
    })
  })
  it('does not guess which level was hit first when both SL and TP touched', async () => {
    await fixture(async sql => {
      await reconcile(sql, 4015, 3985)
      const [p] = await sql`select status,risk_issue->>'kind' as issue from public.pf_engine_positions where account_id='risk-test'`
      expect(p).toMatchObject({ status: 'OPEN', issue: 'AMBIGUOUS_SL_TP' })
    })
  })
  it('ignores candles before entry or before the latest protection change', async () => {
    await fixture(async sql => {
      await reconcile(sql, 4015, 3995, 'ASK', '11 minutes')
      await sql`update public.pf_engine_positions set take_profit=4011 where account_id='risk-test'`
      await reconcile(sql, 4015, 3995)
      const [p] = await sql`select status from public.pf_engine_positions where account_id='risk-test'`
      expect(p?.status).toBe('OPEN')
    })
  })
  it('executes live buy SL immediately even during the first minute at exactly 3990', async () => {
    await fixture(async sql => {
      await sql`update public.pf_engine_positions set opened_at=now() where account_id='risk-test'`
      await sql`select public.pf_engine_process_tick('RISKTEST',3989,3990,now())`
      const [p] = await sql`select status,exit_price,close_reason from public.pf_engine_positions where account_id='risk-test'`
      expect(p).toMatchObject({ status: 'CLOSED', exit_price: '3990.000000000000', close_reason: 'SL' })
    })
  })
})