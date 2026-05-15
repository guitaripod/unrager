import { gather, cacheKeyFor } from "../_lib/installs.js";

export const onRequestGet = async (context) => {
  const cache = caches.default;
  const cacheKey = cacheKeyFor(context.request);
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const { total, hasAny, bothOk } = await gather(context.env);
  const body = {
    schemaVersion: 1,
    label: "installs",
    message: hasAny ? total.toLocaleString("en-US") : "n/a",
    color: hasAny ? "1D9BF0" : "lightgrey",
    cacheSeconds: bothOk ? 1800 : 60,
  };

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
