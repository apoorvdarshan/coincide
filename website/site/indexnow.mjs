#!/usr/bin/env node
// Tells IndexNow search engines (Bing, Yandex, Seznam, Naver and others) about coincide.dev's pages after a deploy:
//
//   node website/site/indexnow.mjs              every URL in public/sitemap.xml
//   node website/site/indexnow.mjs /download    only these paths
//
// The key is public by design: IndexNow checks it against https://coincide.dev/<key>.txt, which is in public/.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { PUBLIC } from "./build.mjs";
import { ORIGIN } from "./layout.mjs";

const keyFile = readdirSync(PUBLIC).find((name) => /^[0-9a-f]{32}\.txt$/.test(name));
if (!keyFile) throw new Error("no IndexNow key file in website/public");
const key = keyFile.slice(0, -4);
const paths = process.argv.slice(2);
const urlList = paths.length
  ? paths.map((path) => ORIGIN + path)
  : [...readFileSync(join(PUBLIC, "sitemap.xml"), "utf8").matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);

const response = await fetch("https://api.indexnow.org/indexnow", {
  method: "POST",
  headers: { "content-type": "application/json; charset=utf-8" },
  body: JSON.stringify({ host: new URL(ORIGIN).host, key, keyLocation: `${ORIGIN}/${keyFile}`, urlList }),
});
console.log(`IndexNow: ${response.status} ${response.statusText} for ${urlList.length} URLs`);
if (!response.ok && response.status !== 202) process.exit(1);
