import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const page = readFileSync('public/plotos/index.html', 'utf8')
const localCode = page.slice(page.indexOf('var LocalProvider={'), page.indexOf('/* chart engine */'))

function harness(online = false) {
  const server = { id: '50001', login: '50001', userId: 'trader', serverManaged: true, balance: 10000 }
  const DB = { accounts: [server], activeAcc: { trader: '50001' } }
  const f = new Function('DB', 'online', `
    var DEMO_MODE=false,called=0,TradingProvider={};
    ['place','close','closePartial','closeAll','modifyPosition','modifyOrder','cancelOrder'].forEach(function(k){TradingProvider[k]=function(){called++;return Promise.resolve('server')}});
    function myAcc(){return DB.accounts.find(function(a){return a.id===DB.activeAcc.trader})}
    function useLocal(){return !online}function localReady(){return true}function toast(){}
    function placeOrder(a){return{p:{accId:a.id,entry:4000}}}function save(){}
    ${localCode}
    return {DB,provider:TradingProvider,calls:function(){return called}};
  `)
  return f(DB, online) as { DB: { accounts: typeof server[]; activeAcc: { trader: string } }; provider: { place: () => Promise<{ p: { accId: string } }>; close: (p: unknown) => Promise<unknown> }; calls: () => number }
}
describe('offline trading isolation', () => {
  it('keeps account 50001 unchanged and opens disconnected fills in a separate offline account', async () => {
    const h = harness()
    const result = await h.provider.place()
    expect(result.p.accId).toBe('offline-50001')
    expect(h.DB.accounts[0]).toMatchObject({ id: '50001', balance: 10000, serverManaged: true })
    expect(h.calls()).toBe(0)
  })
  it('routes a server position to the server even while disconnected', async () => {
    const h = harness()
    await h.provider.close({ src: 'server', accId: '50001' })
    expect(h.calls()).toBe(1)
  })
  it('sends connected embedded account orders only to the server', async () => {
    const h = harness(true)
    expect(await h.provider.place()).toBe('server')
    expect(h.calls()).toBe(1)
    expect(h.DB.accounts.length).toBe(1)
  })
})