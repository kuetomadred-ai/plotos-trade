import { readFileSync } from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'

const root = process.cwd()
const migration = readFileSync(path.join(root, 'drizzle/migrations/0012_range_box_bot.sql'), 'utf8')
const server = readFileSync(path.join(root, 'src/lib/terminal-engine.server.ts'), 'utf8')
const html = readFileSync(path.join(root, 'public/plotos/index.html'), 'utf8')

describe('range-box bot contract', () => {
  it('adds the persistent range and dynamic-lot fields', () => {
    expect(migration).toContain('range_high numeric NOT NULL DEFAULT 0')
    expect(migration).toContain('range_low numeric NOT NULL DEFAULT 0')
    expect(migration).toContain("exhausted_zones text[] NOT NULL DEFAULT '{}'::text[]")
    expect(migration).toContain('dynamic_lot_enabled boolean NOT NULL DEFAULT true')
    expect(migration).toContain('lot_per_thousand numeric NOT NULL DEFAULT 1.0')
  })

  it('does not place inside the range or an exhausted one-dollar bucket', () => {
    expect(migration).toContain("WHEN v_px > b.range_high THEN 'buy'")
    expect(migration).toContain("WHEN v_px < b.range_low THEN 'sell'")
    expect(migration).toContain("v_bucket = ANY(COALESCE(b.exhausted_zones, '{}'::text[]))")
    expect(migration).toContain('floor((a.balance / 1000.0) * COALESCE(b.lot_per_thousand, 1.0))')
  })

  it('binds range updates to the authenticated user and owned account', () => {
    expect(migration).toContain('b.user_id = p_user_id')
    expect(migration).toContain('a.user_id = p_user_id')
    expect(server).toContain("if (path === 'v1/bot/range')")
    expect(server).toContain('p_user_id: userId')
    expect(server).toContain("z.string().uuid()")
  })

  it('exposes chart controls and both price lines without enabling a bot', () => {
    expect(html).toContain('rangeBoxPanel')
    expect(html).toContain('SAVE RANGE TO BOT')
    expect(html).toContain("title:'RANGE HIGH'")
    expect(html).toContain("title:'RANGE LOW'")
    expect(migration).not.toContain("UPDATE public.pf_engine_bots SET mode='range_box'")
  })
})
