export const onRequest = async ({ request, next }) => {
  const url = new URL(request.url);
  if (url.hostname === "www.unrager.com") {
    url.hostname = "unrager.com";
    return Response.redirect(url.toString(), 301);
  }
  return next();
};
