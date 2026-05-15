import { gather } from "../_lib/installs.js";

export const onRequestGet = async (context) => {
  const cache = caches.default;
  const cacheKey = new URL(context.request.url).toString();
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const { total, hasAny } = await gather();
  const body = {
    schemaVersion: 1,
    label: "installs",
    message: hasAny ? total.toLocaleString("en-US") : "n/a",
    color: hasAny ? "1D9BF0" : "lightgrey",
    cacheSeconds: 1800,
  };

  const response = new Response(JSON.stringify(body), {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "public, max-age=1800, s-maxage=1800",
      "Access-Control-Allow-Origin": "*",
    },
  });

  if (hasAny) context.waitUntil(cache.put(cacheKey, response.clone()));

  return response;
};
