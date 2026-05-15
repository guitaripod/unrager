const CRATES_URL = "https://crates.io/api/v1/crates/unrager";
const GITHUB_URL =
  "https://api.github.com/repos/guitaripod/unrager/releases?per_page=100";
const UA = "unrager-site (+https://unrager.com)";
const BINARY_SUFFIXES = [".tar.gz", ".tar.xz", ".tgz", ".zip"];
const CACHE_VERSION = 2;

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

const fetchGithubReleases = async (token) => {
  const headers = {
    "User-Agent": UA,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  let url = GITHUB_URL;
  let total = 0;
  let pages = 0;
  while (url && pages < 10) {
    const r = await fetch(url, { headers });
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

export const gather = async (env = {}) => {
  const token = env.GITHUB_TOKEN || env.GH_TOKEN || null;
  const [c, g] = await Promise.allSettled([
    fetchCrates(),
    fetchGithubReleases(token),
  ]);
  const crates = c.status === "fulfilled" ? c.value : null;
  const gh = g.status === "fulfilled" ? g.value : null;
  const errors = [];
  if (c.status === "rejected")
    errors.push(`crates: ${c.reason?.message || c.reason}`);
  if (g.status === "rejected")
    errors.push(`github: ${g.reason?.message || g.reason}`);
  const total = (crates ?? 0) + (gh ?? 0);
  const hasAny = crates !== null || gh !== null;
  const bothOk = crates !== null && gh !== null;
  return { crates, gh, total, hasAny, bothOk, errors, githubAuthed: !!token };
};

export const cacheKeyFor = (request) => {
  const u = new URL(request.url);
  u.searchParams.set("__cv", String(CACHE_VERSION));
  return u.toString();
};
