export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "deploylight.akim.workers.dev") {
      url.protocol = "https:";
      url.hostname = "deploylight.andrewkim.me";
      url.port = "";
      return Response.redirect(url.toString(), 308);
    }
    return env.ASSETS.fetch(request);
  },
};
