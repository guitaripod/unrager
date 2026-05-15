const CRATES_URL = "https://crates.io/api/v1/crates/unrager";
const GITHUB_URL =
  "https://api.github.com/repos/guitaripod/unrager/releases?per_page=100";
const UA = "unrager-site (+https://unrager.com)";
const BINARY_SUFFIXES = [".tar.gz", ".tar.xz", ".tgz", ".zip"];

const isBinaryAsset = (name) => {
  const lower = (name || "").toLowerCase();
  return BINARY_SUFFIXES.some((s) => lower.endsWith(s));
};

const nextLink = (header) => {
  if (!header) return null;
  const m = header.match(/<([^>]+)>;\s*rel="next"/);
  return m ? m[1] : null;
};

const fetchCrates = async () => {
  const r = await fetch(CRATES_URL, {
    headers: { "User-Agent": UA, Accept: "application/json" },
  });
  if (!r.ok) throw new Error(`crates.io ${r.status}`);
  const j = await r.json();
  const total = j?.crate?.downloads;
  if (typeof total !== "number") throw new Error("crates.io shape");
  return total;
};

const fetchGithubReleases = async () => {
  let url = GITHUB_URL;
  let total = 0;
  let pages = 0;
  while (url && pages < 10) {
    const r = await fetch(url, {
      headers: {
        "User-Agent": UA,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });
    if (!r.ok) throw new Error(`github ${r.status}`);
    const releases = await r.json();
    for (const rel of releases) {
      for (const a of rel.assets || []) {
        if (isBinaryAsset(a.name)) total += a.download_count || 0;
      }
    }
    url = nextLink(r.headers.get("link"));
    pages += 1;
  }
  return total;
};

export const onRequestGet = async (context) => {
  const cache = caches.default;
  const cacheKey = new URL(context.request.url).toString();
  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  const [cratesResult, ghResult] = await Promise.allSettled([
    fetchCrates(),
    fetchGithubReleases(),
  ]);
  const crates =
    cratesResult.status === "fulfilled" ? cratesResult.value : null;
  const gh = ghResult.status === "fulfilled" ? ghResult.value : null;
  const errors = [];
  if (cratesResult.status === "rejected")
    errors.push(`crates: ${cratesResult.reason?.message || cratesResult.reason}`);
  if (ghResult.status === "rejected")
    errors.push(`github: ${ghResult.reason?.message || ghResult.reason}`);

  const hasAny = crates !== null || gh !== null;
  const total = (crates ?? 0) + (gh ?? 0);

  const body = {
    schemaVersion: 1,
    label: "installs",
    message: hasAny ? total.toLocaleString("en-US") : "n/a",
    color: hasAny ? "1D9BF0" : "lightgrey",
    cacheSeconds: 1800,
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
      "Cache-Control": "public, max-age=1800, s-maxage=1800",
      "Access-Control-Allow-Origin": "*",
    },
  });

  if (hasAny) context.waitUntil(cache.put(cacheKey, response.clone()));

  return response;
};
