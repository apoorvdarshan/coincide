// Helpers for the blog. Each post is a module in this folder with type "Article" and a `published` date; the blog
// index and the RSS feed (build.mjs) list them through blogPosts(), newest first.
import { ORIGIN, escape } from "../../layout.mjs";

/** The blog posts among the pages, newest first. */
export const blogPosts = (pages) => pages
  .filter((page) => page.path.startsWith("/blog/"))
  .sort((a, b) => new Date(b.published) - new Date(a.published) || a.path.localeCompare(b.path));

const watchURL = ({ id, short }) => short ? `https://www.youtube.com/shorts/${id}` : `https://www.youtube.com/watch?v=${id}`;

/** A video's poster (a local image) linking to the video on YouTube, so the page loads nothing from YouTube.
 *  `video` is { id, short, title, image, width, height }. */
export function video(v) {
  const href = watchURL(v);
  return `<figure class="video${v.short ? " short" : ""}">
  <a href="${href}"><img src="${v.image}" alt="Watch “${escape(v.title)}” on YouTube" width="${v.width}" height="${v.height}"><span class="play" aria-hidden="true"></span></a>
  <figcaption>${v.short ? "YouTube Short" : "Video"}: <a href="${href}">${escape(v.title)}</a></figcaption>
</figure>`;
}

/** Structured data for a video in a post. `video` also needs `description`, `uploaded` (ISO date) and `duration`
 *  (ISO 8601, like PT26S). */
export const videoSchema = (v) => ({
  "@type": "VideoObject",
  name: v.title,
  description: v.description,
  thumbnailUrl: ORIGIN + v.image,
  uploadDate: v.uploaded,
  duration: v.duration,
  embedUrl: `https://www.youtube.com/embed/${v.id}`,
  url: watchURL(v),
});

/** Where the day's media went: rows of [site, url, what was posted]. */
export const shared = (rows) => `<ul class="shared">
${rows.map(([site, href, what]) => `  <li><a href="${href}">${site}</a>${what ? `<span>${what}</span>` : ""}</li>`).join("\n")}
</ul>`;
