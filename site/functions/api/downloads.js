import { gather, cacheKeyFor } from "../_lib/installs.js";

export const onRequestGet = async (context) => {
  const cache = caches.default;
  const cacheKey = cacheKeyFor(context.request);
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const { crates, gh, total, bothOk, errors } = await gather(context.env);
  const body = {
    total,
    sources: {
      crates_io: { count: crates, url: "https://crates.io/crates/unrager" },
      github_releases: {
        count: gh,
        url: "https://github.com/guitaripod/unrager/releases",
        note: "binary tarballs only; SHA256SUMS excluded",
      },
    },
    updated_at: new Date().toISOString(),
  };
  if (errors.length) body.errors = errors;

  const response = new Response(JSON.stringify(body), {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": bothOk
        ? "public, max-age=1800, s-maxage=1800"
        : "public, max-age=60, s-maxage=60",
      "Access-Control-Allow-Origin": "*",
    },
  });

  if (bothOk) context.waitUntil(cache.put(cacheKey, response.clone()));

  return response;
};
