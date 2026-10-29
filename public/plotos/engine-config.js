// Set this to the deployed backend origin (for example: https://api.example.com).
// Empty means fail-closed: trading is disabled; the client never falls back to local execution.
window.PLUTUS_ENGINE_API_URL = window.PLUTUS_NATIVE ? "" : window.location.origin;
// Optional HTTPS origin serving /api/public/payments/* for native builds. Web builds use same-origin.
// Leave blank until your own application server is deployed; payments then fail closed in native builds.
window.PLUTUS_PAYMENTS_API_URL = "";
// Public (publishable) cloud config so the web terminal keeps trades and sessions on the server.
window.PLUTUS_SUPABASE_URL = window.PLUTUS_SUPABASE_URL || "https://c--dfcd02c1-396d-4f73-8066-f696bf93052a-prod.lovable.cloud";
window.PLUTUS_SUPABASE_PUBLISHABLE_KEY = window.PLUTUS_SUPABASE_PUBLISHABLE_KEY || "sb_publishable_6LFr7m9ecDgx_g8-LhCkxg_Juv53e6C";
