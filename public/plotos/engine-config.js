// Set this to the deployed backend origin (for example: https://api.example.com).
// Empty means fail-closed: trading is disabled; the client never falls back to local execution.
window.PLUTUS_ENGINE_API_URL = window.PLUTUS_NATIVE ? "https://plotos-trade.lovable.app/api/public/engine" : window.location.origin;
// Optional HTTPS origin serving /api/public/payments/* for native builds. Web builds use same-origin.
// Leave blank until your own application server is deployed; payments then fail closed in native builds.
window.PLUTUS_PAYMENTS_API_URL = "";
// Public (publishable) cloud config so the web terminal keeps trades and sessions on the server.
window.PLUTUS_SUPABASE_URL = window.PLUTUS_SUPABASE_URL || "https://jujjjvuspzfgrmeljljh.supabase.co";
window.PLUTUS_SUPABASE_PUBLISHABLE_KEY = window.PLUTUS_SUPABASE_PUBLISHABLE_KEY || "sb_publishable_X9YRYOHzL1v0OVXF_KRjiw_EHj7kTdV";
