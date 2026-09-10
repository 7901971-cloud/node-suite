const ALLOWED_ROUTES = new Set([
  "GET /health",
  "POST /api/v1/enroll",
  "POST /api/v1/report",
  "POST /api/v1/command/poll",
  "POST /api/v1/command/result",
  "POST /api/v1/command/check",
]);

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  const route = `${request.method.toUpperCase()} ${url.pathname}`;

  if (!ALLOWED_ROUTES.has(route)) {
    return jsonResponse({ ok: false, error: "not_found" }, 404);
  }

  if (!env.ROUTER_WORKER || typeof env.ROUTER_WORKER.fetch !== "function") {
    return jsonResponse({ ok: false, error: "service_binding_unavailable" }, 503);
  }

  const response = await env.ROUTER_WORKER.fetch(request);
  const headers = new Headers(response.headers);
  headers.set("cache-control", "no-store");
  headers.set("x-router-gateway", "cloudflare-pages");

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
