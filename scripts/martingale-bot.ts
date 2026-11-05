// Martingale test bot for a demo account. Run: bun run scripts/martingale-bot.ts [minutes]
import { createClient } from "@supabase/supabase-js";

const ACCOUNT = "9982430";
const USER = "4b2eb61d-0eb9-46a3-a09c-9684e88bc54c";
const SYMBOL = "XAUUSD";
const STEP = 1; // dollars against us before adding another 1-lot trade
const MINUTES = Number(process.argv[2] ?? 4);
const LOT = 1; // fixed lot size — never doubled

const sb = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
let lastEntry: number | null = null;
const end = Date.now() + MINUTES * 60_000;

async function quote() {
  const { data } = await sb.from("pf_engine_quotes").select("bid,ask").eq("symbol", SYMBOL).single();
  return data as { bid: number; ask: number };
}
async function buy() {
  const { data, error } = await sb.rpc("pf_engine_place_order", {
    p_user_id: USER, p_account_id: ACCOUNT, p_request_id: crypto.randomUUID(),
    p_symbol: SYMBOL, p_side: "buy", p_order_type: "MARKET", p_lots: LOT,
  });
  if (error) { console.log("rejected:", error.message); return; }
  lastEntry = Number((data as any).fill_price);
  console.log(`BUY ${LOT.toFixed(2)} @ ${lastEntry}`);
}

while (Date.now() < end) {
  const q = await quote();
  const { data: acc } = await sb.from("pf_engine_accounts").select("balance").eq("id", ACCOUNT).single();
  const { data: eq } = await sb.rpc("pf_engine_equity", { p_account_id: ACCOUNT });
  console.log(new Date().toISOString().slice(11, 19), "bid", q.bid, "balance", acc?.balance, "equity", eq);
  if (lastEntry === null || q.bid <= lastEntry - STEP) await buy();
  await new Promise((r) => setTimeout(r, 3000));
}
