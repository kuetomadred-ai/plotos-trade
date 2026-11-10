import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "PLUTUS — منصة تداول للموبايل" },
      {
        name: "description",
        content: "منصة PLUTUS للتداول بأسعار حية ورسوم شموع وصفقات بتصميم MT5 للموبايل.",
      },
      { property: "og:title", content: "PLUTUS — منصة تداول" },
      { property: "og:description", content: "أسعار حية ورسوم بيانية وإدارة صفقات بتصميم MT5." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: App,
});

function App() {
  const search = typeof window !== "undefined" ? window.location.search : "";
  const iframeSrc = `/plotos/index.html${search || "?demo=1"}`;

  return (
    <iframe
      src={iframeSrc}
      title="PLUTUS"
      className="fixed inset-0 h-[100dvh] w-full border-0 bg-background"
      allow="clipboard-write; fullscreen"
    />
  );
}
