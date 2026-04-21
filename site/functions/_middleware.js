const INSTALL_UPSTREAM =
  "https://raw.githubusercontent.com/guitaripod/unrager/master/install.sh";

export const onRequest = async ({ request, next }) => {
  const url = new URL(request.url);

  if (url.hostname === "www.unrager.com") {
    url.hostname = "unrager.com";
    return Response.redirect(url.toString(), 301);
  }

  if (url.pathname === "/install.sh" || url.pathname === "/install") {
    const upstream = await fetch(INSTALL_UPSTREAM, { cf: { cacheTtl: 300 } });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": "text/x-shellscript; charset=utf-8",
        "Cache-Control": "public, max-age=300",
        "X-Source": INSTALL_UPSTREAM,
      },
    });
  }

  return next();
};
