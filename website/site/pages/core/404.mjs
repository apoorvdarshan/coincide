// Served with a 404 status for any address that has no page (wrangler.jsonc: not_found_handling "404-page").
export default {
  path: "/404",
  title: "Page not found · Coincide",
  description: "There's no page at this address on coincide.dev. Try the features, the agents, the docs or the download page.",
  name: "Page not found",
  noindex: true,
  eyebrow: "404",
  h1: "This page isn’t here.",
  lede: "The address may be mistyped, or the page may have moved. These are the places most people are looking for:",
  body: (s) => `${s.cards(["/download", "/features", "/agents", "/docs", "/faq", "/changelog"])}
<p>Or go back to the <a href="/">home page</a>. If a link on this site brought you here, please <a href="https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml">report it on GitHub</a>.</p>`,
};
