export type RiskBar = { openTime: string; high: number; low: number; isOpen: boolean }
export function parseRiskBars(payload: unknown, now = Date.now()): { bars: RiskBar[]; basis: 'BID' | 'ASK' | 'UNKNOWN' } {
  if (!payload || typeof payload !== 'object') return { bars: [], basis: 'UNKNOWN' }
  const data = payload as Record<string, unknown>
  // Never infer bid/ask from unlabelled OHLC or reconstruct historic spreads from today's quote.
  const label = String(data['priceBasis'] ?? '').toUpperCase()
  const basis = label === 'BID' || label === 'ASK' ? label : 'UNKNOWN'
  const bars = (Array.isArray(data['bars']) ? data['bars'] : []).flatMap(raw => {
    if (!raw || typeof raw !== 'object') return []
    const r = raw as Record<string, unknown>
    const t = Date.parse(String(r['openTime'] ?? '')), high = Number(r['high']), low = Number(r['low'])
    if (!Number.isFinite(t) || !Number.isFinite(high) || !Number.isFinite(low) || low <= 0 || high < low || t + 60000 > now || r['isOpen'] !== false) return []
    return [{ openTime: new Date(t).toISOString(), high, low, isOpen: false }]
  }).sort((a, b) => a.openTime.localeCompare(b.openTime)).slice(-1000)
  return { bars, basis }
}