import { supabaseAdmin } from '@/integrations/supabase/client.server'
import { parseQuotes } from './terminal-contract'
import { parseRiskBars } from './engine-candles'

export async function reconcileEngineProtection(symbols?: string[]) {
  const { data, error } = await supabaseAdmin.from('pf_engine_positions').select('symbol,opened_at,protection_changed_at,risk_checked_at').eq('status', 'OPEN').or('stop_loss.not.is.null,take_profit.not.is.null')
  if (error) throw new Error('Protection state unavailable')
  const starts = new Map<string, number>()
  for (const row of data ?? []) {
    if (symbols && !symbols.includes(row.symbol)) continue
    const start = Math.max(Date.parse(row.opened_at), Date.parse(row.protection_changed_at ?? row.opened_at), Date.parse(row.risk_checked_at ?? row.opened_at))
    starts.set(row.symbol, Math.min(starts.get(row.symbol) ?? start, start))
  }
  const results = await Promise.all([...starts].map(async ([symbol, start]) => {
    try {
      const limit = Math.min(1000, Math.max(3, Math.ceil((Date.now() - start) / 60000) + 1))
      const response = await fetch(`https://biquote.io/api/${encodeURIComponent(symbol)}/ohlc?interval=1m&limit=${limit}`, { signal: AbortSignal.timeout(3500) })
      if (!response.ok) throw new Error('Candles unavailable')
      const { bars, basis } = parseRiskBars(await response.json())
      if (!bars.length) return { closed: 0, unresolved: 0, failed: 0 }
      const { data: result, error: rpcError } = await supabaseAdmin.rpc('pf_engine_reconcile_candles', { p_symbol: symbol, p_bars: bars, p_basis: basis })
      if (rpcError) throw new Error('Reconciliation failed')
      const summary = result as { closed?: number; unresolved?: number } | null
      return { closed: summary?.closed ?? 0, unresolved: summary?.unresolved ?? 0, failed: 0 }
    } catch { return { closed: 0, unresolved: 0, failed: 1 } }
  }))
  return results.reduce((sum, r) => ({ closed: sum.closed + r.closed, unresolved: sum.unresolved + r.unresolved, failed: sum.failed + r.failed }), { closed: 0, unresolved: 0, failed: 0 })
}

export async function refreshEngineQuotes(withCandles = false) {
  const reconciliation = withCandles ? await reconcileEngineProtection() : undefined
  const { data: instruments, error } = await supabaseAdmin.from('pf_engine_instruments').select('symbol').eq('enabled', true)
  if (error) throw new Error('Instrument catalogue unavailable')
  const symbols = instruments?.map(row => row.symbol) ?? []
  if (!symbols.length) return { processed: 0 }
  const query = new URLSearchParams()
  for (const symbol of symbols) query.append('symbols', symbol)
  const response = await fetch(`https://biquote.io/api/latest?${query}`, { signal: AbortSignal.timeout(8000) })
  if (!response.ok) throw new Error('Market prices unavailable')
  const payload: unknown = await response.json()
  let processed = 0, failed = 0
  // Sequential ticks preserve account/quote transaction ordering and connection limits.
  for (const quote of parseQuotes(payload, symbols)) {
    const { error: tickError } = await supabaseAdmin.rpc('pf_engine_process_tick', { p_symbol: quote.symbol, p_bid: quote.bid, p_ask: quote.ask, p_quote_at: quote.quoteAt })
    if (tickError) { failed++; continue }
    processed++
  }
  const { error: riskError } = await supabaseAdmin.rpc('pf_engine_evaluate_all')
  if (riskError) throw new Error('Risk evaluation failed')
  return { processed, failed, reconciliation }
}