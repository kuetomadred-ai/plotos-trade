// Martingale test bot for a demo account. Run: bun run scripts/martingale-bot.ts [minutes]
// Fixed 1-lot entries, no doubling. When profit reaches +$100 it closes everything
// and starts a brand new cycle from scratch.
import { createClient } from "@supabase/supabase-js";

const ACCOUNT = "9982430";
const USER = "4b2eb61d-0eb9-46a3-a09c-9684e88bc54c";
const SYMBOL = "XAUUSD";
const STEP = 1; // dollars against us before adding another 1-lot trade
const MINUTES = Number(process.argv[2] ?? 4);
const LOT = 1; // fixed lot size — never doubled
const TARGET = 100; // take profit and restart the cycle at +$100

const sb = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });

let lastEntry: number | null = null;
let startEquity = 0;
let cycle = 1;
const end = Date.now() + MINUTES * 60_000;

async function quote() {
  const { data } = await sb.from("pf_engine_quotes").select("bid,ask").eq("symbol", SYMBOL).single();
  return data as { bid: number; ask: number };
}

async function equity() {
  const { data } = await sb.rpc("pf_engine_equity", { p_account_id: ACCOUNT });
  return Number(data);
}

async function openPositions() {
  const { data } = await sb.from("pf_engine_positions")
    .select("id").eq("account_id", ACCOUNT).eq("status", "OPEN");
  return (data ?? []) as { id: string }[];
}

async function buy() {
  const { data, error } = await sb.rpc("pf_engine_place_order", {
    p_user_id: USER, p_account_id: ACCOUNT, p_request_id: crypto.randomUUID(),
    p_symbol: SYMBOL, p_side: "buy", p_order_type: "MARKET", p_lots: LOT,
  });
  if (error) { console.log("rejected:", error.message); return; }
  lastEntry = Number((data as any).fill_price);
  console.log(`  BUY ${LOT.toFixed(2)} @ ${lastEntry}`);
}

// Close every open position, then begin a fresh cycle.
async function takeProfitAndRestart() {
  const positions = await openPositions();
  for (const p of positions) {
    await sb.rpc("pf_engine_close_position", {
      p_user_id: USER, p_position_id: p.id, p_request_id: crypto.randomUUID(),
    });
  }
  const { data: acc } = await sb.from("pf_engine_accounts").select("balance").eq("id", ACCOUNT).single();
  console.log(`  >>> TARGET HIT: +${TARGET}$ — closed ${positions.length} position(s), balance ${acc?.balance}. Restarting cycle.`);
  lastEntry = null;
  startEquity = await equity();
  cycle++;
}

async function newCycle() {
  lastEntry = null;
  startEquity = await equity();
  console.log(`--- cycle ${cycle} starts (equity ${startEquity.toFixed(2)}) ---`);
}

await newCycle();

while (Date.now() < end) {
  const q = await quote();
  const { data: acc } = await sb.from("pf_engine_accounts").select("balance").eq("id", ACCOUNT).single();
  const eq = await equity();
  const profit = eq - startEquity;
  console.log(new Date().toISOString().slice(11, 19), "bid", q.bid, "balance", acc?.balance, "equity", eq.toFixed(2), "profit", profit.toFixed(2));

  if (profit >= TARGET) {
    await takeProfitAndRestart();
    await new Promise((r) => setTimeout(r, 1500));
    continue;
  }

  if (lastEntry === null || q.bid <= lastEntry - STEP) await buy();
  await new Promise((r) => setTimeout(r, 3000));
}
