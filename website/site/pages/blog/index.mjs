// The blog hub: every post in this folder, newest first, built from the posts themselves.
import { escape, formatDate } from "../../layout.mjs";
import { blogPosts } from "./_blog.mjs";

export default {
  path: "/blog",
  title: "Coincide blog: feature videos, launch notes and deep dives",
  description: "News from Coincide, the native Mac app for coding agents: a short video on one feature at a time, launch notes, and how it works inside.",
  name: "Blog",
  summary: "Feature videos, launch notes and deep dives.",
  type: "CollectionPage",
  eyebrow: "Blog",
  h1: "The Coincide blog",
  lede: `A short video on one feature at a time, launch notes, and how Coincide works inside. Follow along with the <a href="/blog/feed.xml">RSS feed</a>.`,
  updated: "2026-11-02",
  related: ["/features", "/changelog", "/download"],
  body: (s) => `
<ul class="cards posts">
${blogPosts(s.pages).map((post) => `  <li><a class="card" href="${post.path}"><b>${post.h1}</b><span>${post.summary}</span><small><time datetime="${post.published}">${formatDate(post.published)}</time>${post.media ? ` · ${escape(post.media)}` : ""}</small></a></li>`).join("\n")}
</ul>`,
};
