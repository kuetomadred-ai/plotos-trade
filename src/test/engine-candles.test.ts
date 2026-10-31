import { describe, expect, it } from 'vitest'
import { parseRiskBars } from '../lib/engine-candles'

describe('historical protection data', () => {
  const now = Date.parse('2026-10-31T10:00:00Z')
  const bar = { openTime: '2026-10-31T09:58:00Z', high: 4010, low: 3990, isOpen: false }
  it('does not invent bid/ask basis for unlabelled provider candles', () => {
    expect(parseRiskBars({ bars: [bar] }, now).basis).toBe('UNKNOWN')
    expect(parseRiskBars({ priceBasis: 'ASK', bars: [bar] }, now).basis).toBe('ASK')
  })
  it('excludes forming candles and incomplete minutes', () => {
    expect(parseRiskBars({ bars: [{ ...bar, isOpen: true }, { ...bar, openTime: '2026-10-31T09:59:30Z' }] }, now).bars).toEqual([])
  })
  it('keeps concrete valid high/low levels in chronological order', () => {
    expect(parseRiskBars({ bars: [{ ...bar, openTime: '2026-10-31T09:59:00Z' }, bar] }, now).bars.map(b => [b.openTime, b.high, b.low])).toEqual([['2026-10-31T09:58:00.000Z', 4010, 3990], ['2026-10-31T09:59:00.000Z', 4010, 3990]])
  })
})