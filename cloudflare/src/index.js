import { connect } from "cloudflare:sockets";

const VERSION = "3.5.0";
const PAIR_TTL_SECONDS = 10 * 60;
const MAX_NODE_BYTES = 12 * 1024;
const PAGE_SIZE = 8;
const ALERT_NAMES = {
  service: "代理服务停止",
  tcp: "代理 TCP 未监听",
  udp: "UDP 功能异常",
  memory: "可用内存过低",
  temperature: "设备温度过高",
  storage: "存储空间不足",
  load: "系统负载过高",
  ddns: "DuckDNS 更新连续失败",
  no_public_ip: "没有可用公网地址",
  offline: "设备离线"
};
const ALLOWED_ALERTS = new Set(Object.keys(ALERT_NAMES).filter((x) => x !== "offline"));

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/health" && request.method === "GET") {
        if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_WEBHOOK_SECRET || !env.TELEGRAM_BOT_USERNAME || !ownerIds(env).length) {
          return json({ ok: false, version: VERSION, error: "control_center_not_configured" }, 503);
        }
        await encryptionKey(env);
        await Promise.all([
          env.DB.prepare("SELECT id,token_hash,enabled,status_json FROM devices LIMIT 1").first(),
          env.DB.prepare("SELECT code_hash,expires_at,used_at FROM pair_codes LIMIT 1").first(),
          env.DB.prepare("SELECT id,device_id,action,payload,status,expires_at,started_at,exit_code FROM device_commands LIMIT 1").first(),
          env.DB.prepare("SELECT id FROM node_config_drafts LIMIT 1").first(),
          env.DB.prepare("SELECT user_id,role FROM bot_users LIMIT 1").first(),
          env.DB.prepare("SELECT chat_id,access_mode,role FROM bot_groups LIMIT 1").first()
        ]);
        return json({ ok: true, service: "router-node-center", version: VERSION,
          capabilities: { router_root: true, vps_root: true, command_check: true, router_vless: true, full_status_fixed: true, bot_permissions: true, copyable_node_cards: true, node_config: true, permanent_mute: true, realtime_refresh: true, pages_address: true, group_mention_only: true } });
      }
      if (url.pathname === "/api/v1/enroll" && request.method === "POST") {
        return await enrollRouter(request, env);
      }
      if (url.pathname === "/api/v1/report" && request.method === "POST") {
        return await receiveReport(request, env);
      }
      if (url.pathname === "/api/v1/command/poll" && request.method === "POST") {
        return await pollDeviceCommand(request, env);
      }
      if (url.pathname === "/api/v1/command/check" && request.method === "POST") {
        const device = await authenticateDevice(request, env);
        if (!device) return json({ ok: false, error: "unauthorized" }, 401);
        if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_WEBHOOK_SECRET || !env.DATA_ENCRYPTION_KEY || !ownerIds(env).length) {
          return json({ ok: false, error: "control_center_not_configured" }, 503);
        }
        await env.DB.prepare("SELECT id FROM device_commands WHERE device_id=? LIMIT 1").bind(device.id).first();
        return json({ ok: true, device_id: device.id, command_api: true, server_time: nowSeconds() });
      }
      if (url.pathname === "/api/v1/command/result" && request.method === "POST") {
        return await receiveCommandResult(request, env);
      }
      if (url.pathname === "/telegram/webhook" && request.method === "POST") {
        return await telegramWebhook(request, env, ctx);
      }
      return json({ ok: false, error: "not_found" }, 404);
    } catch (_) {
      return json({ ok: false, error: "internal_error" }, 500);
    }
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runScheduled(env, Math.floor(controller.scheduledTime / 1000)));
  }
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  });
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function envInt(env, key, fallback, min, max) {
  const n = Number.parseInt(env[key] ?? "", 10);
  return Number.isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
}

function cleanText(value, max = 128) {
  return String(value ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, max);
}

function numberValue(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function boolValue(value) {
  return value === "1" || value === "true" || value === true;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function bytesToB64Url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function b64UrlToBytes(value) {
  let s = String(value).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const raw = atob(s);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

function standardB64ToText(value) {
  if (!value) return "";
  const raw = atob(String(value).replace(/\s/g, ""));
  const bytes = Uint8Array.from(raw, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function encryptionKey(env) {
  const raw = b64UrlToBytes(env.DATA_ENCRYPTION_KEY || "");
  if (raw.byteLength !== 32) throw new Error("bad_encryption_key");
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function encryptText(value, env) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey(env);
  const body = new TextEncoder().encode(value);
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, body));
  const packed = new Uint8Array(iv.length + encrypted.length);
  packed.set(iv, 0);
  packed.set(encrypted, iv.length);
  return bytesToB64Url(packed);
}

async function decryptText(value, env) {
  if (!value) return "";
  const packed = b64UrlToBytes(value);
  if (packed.byteLength < 29) throw new Error("bad_ciphertext");
  const key = await encryptionKey(env);
  const clear = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: packed.slice(0, 12) },
    key,
    packed.slice(12)
  );
  return new TextDecoder().decode(clear);
}

function randomHex(bytes) {
  return [...crypto.getRandomValues(new Uint8Array(bytes))]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function randomToken(bytes = 32) {
  return bytesToB64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}

function randomPairCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const chars = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
  return `${chars.slice(0, 4)}-${chars.slice(4)}`;
}

function normalizePairCode(value) {
  return cleanText(value, 32).toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function ownerIds(env) {
  return String(env.OWNER_TELEGRAM_IDS || "")
    .split(",")
    .map((x) => x.trim())
    .filter((x) => /^\d+$/.test(x));
}

function isOwner(id, env) {
  return ownerIds(env).includes(String(id));
}

function botUsername(env) {
  return String(env.TELEGRAM_BOT_USERNAME || "").replace(/^@/, "").trim().toLowerCase();
}

function groupMessageTargetsBot(message, env) {
  if (message?.chat?.type !== "group" && message?.chat?.type !== "supergroup") return true;
  const username = botUsername(env);
  if (!username) return false;
  return String(message.text || "").toLowerCase().includes(`@${username}`);
}

function normalizedMessageText(message, env) {
  const username = botUsername(env);
  let text = String(message?.text || "").trim();
  if (!username) return text;
  text = text.replace(new RegExp(`^@${username}\\s*`, "i"), "");
  return text.replace(new RegExp(`^(/[a-z0-9_]+)@${username}(?=\\s|$)`, "i"), "$1").trim();
}

const ROLE_RANK = { viewer: 1, operator: 2, admin: 3 };

function normalRole(value) {
  const role = String(value || "").toLowerCase();
  return Object.hasOwn(ROLE_RANK, role) ? role : "";
}

function can(access, required) {
  return Number(access?.rank || 0) >= (ROLE_RANK[required] || 99);
}

async function accessFor(env, userId, chat) {
  const uid = String(userId || "");
  if (isOwner(uid, env)) return { role: "admin", rank: 3, source: "owner" };
  if (!chat?.id) return null;
  if (chat.type === "private") {
    const row = await env.DB.prepare("SELECT role FROM bot_users WHERE user_id=? AND enabled=1").bind(uid).first();
    const role = normalRole(row?.role);
    return role ? { role, rank: ROLE_RANK[role], source: "user" } : null;
  }
  if (chat.type !== "group" && chat.type !== "supergroup") return null;
  const group = await env.DB.prepare("SELECT access_mode,role FROM bot_groups WHERE chat_id=? AND enabled=1").bind(String(chat.id)).first();
  if (!group) return null;
  if (group.access_mode === "all") {
    const role = normalRole(group.role);
    const safeRole = role === "admin" ? "operator" : role;
    return safeRole ? { role: safeRole, rank: ROLE_RANK[safeRole], source: "group_all" } : null;
  }
  const member = await env.DB.prepare("SELECT role FROM bot_group_members WHERE chat_id=? AND user_id=?").bind(String(chat.id), uid).first();
  const role = normalRole(member?.role);
  return role ? { role, rank: ROLE_RANK[role], source: "group_member" } : null;
}

function roleLabel(role) {
  return ({ viewer: "只读", operator: "控制", admin: "管理员" })[role] || "未知";
}

function requireRole(access, role) {
  return can(access, role);
}

async function tg(env, method, payload) {
  const response = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data.ok) throw new Error(data.description || `telegram_${response.status}`);
  return data.result;
}

async function notifyOwners(env, text, replyMarkup) {
  let sent = 0;
  for (const chatId of ownerIds(env)) {
    try {
      await tg(env, "sendMessage", {
        chat_id: chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
        ...(replyMarkup ? { reply_markup: replyMarkup } : {})
      });
      sent += 1;
    } catch (_) {
      // Telegram 暂时不可用时保持静默，下一次异常提醒或每日汇总会重试。
    }
  }
  return sent > 0;
}

async function authenticateDevice(request, env) {
  const deviceId = cleanText(request.headers.get("x-device-id"), 64);
  const auth = request.headers.get("authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!/^[a-f0-9]{16}$/.test(deviceId) || token.length < 32) return null;
  const row = await env.DB.prepare("SELECT * FROM devices WHERE id=? AND enabled=1").bind(deviceId).first();
  if (!row) return null;
  const tokenHash = await sha256Hex(token);
  return tokenHash === row.token_hash ? row : null;
}

function parseTemperature(value) {
  if (value == null || String(value).trim() === "") return null;
  const n = Number(value);
  return Number.isFinite(n) && n > 0 && n <= 125 ? n : null;
}

function statusFromForm(form, request) {
  return {
    device_type: cleanText(form.get("device_type"), 16) === "vps" ? "vps" : "router",
    node_config: boolValue(form.get("node_config")),
    service_name: cleanText(form.get("service_name"), 32),
    protocol_name: cleanText(form.get("protocol_name"), 64),
    current_connections: numberValue(form.get("current_connections")),
    reported_at: nowSeconds(),
    router_time: numberValue(form.get("router_time")),
    uptime_sec: numberValue(form.get("uptime_sec")),
    model: cleanText(form.get("model"), 160),
    firmware: cleanText(form.get("firmware"), 160),
    mem_total_kb: numberValue(form.get("mem_total_kb")),
    mem_available_kb: numberValue(form.get("mem_available_kb")),
    mem_used_pct: numberValue(form.get("mem_used_pct")),
    load1: numberValue(form.get("load1")),
    load5: numberValue(form.get("load5")),
    load15: numberValue(form.get("load15")),
    cpu_cores: numberValue(form.get("cpu_cores"), 1),
    temperature_c: parseTemperature(form.get("temperature_c")),
    temperature_source: cleanText(form.get("temperature_source"), 96),
    udp_mode: cleanText(form.get("udp_mode"), 32),
    overlay_used_pct: numberValue(form.get("overlay_used_pct")),
    wan_if: cleanText(form.get("wan_if"), 64),
    wan_dev: cleanText(form.get("wan_dev"), 64),
    network_type: cleanText(form.get("network_type"), 160),
    local4: cleanText(form.get("local4"), 64),
    public4: cleanText(form.get("public4"), 64),
    local6: cleanText(form.get("local6"), 128),
    public6: cleanText(form.get("public6"), 128),
    ddns_domain: cleanText(form.get("ddns_domain"), 253),
    ddns_mode: cleanText(form.get("ddns_mode"), 16),
    ddns_ok: boolValue(form.get("ddns_ok")),
    ddns_failures: numberValue(form.get("ddns_failures")),
    singbox_running: boolValue(form.get("singbox_running")),
    tcp_listen: boolValue(form.get("tcp_listen")),
    udp_listen: boolValue(form.get("udp_listen")),
    ss_port: numberValue(form.get("ss_port")),
    wan_rx_bytes: numberValue(form.get("wan_rx_bytes")),
    wan_tx_bytes: numberValue(form.get("wan_tx_bytes")),
    auto_restarted: boolValue(form.get("auto_restarted")),
    client_ip: cleanText(request.headers.get("cf-connecting-ip"), 128)
  };
}

function parseAlertCodes(value) {
  const found = [];
  for (const code of String(value || "").split(",")) {
    if (ALLOWED_ALERTS.has(code) && !found.includes(code)) found.push(code);
  }
  return found.sort();
}

function safeArray(value) {
  try {
    const a = JSON.parse(value || "[]");
    return Array.isArray(a) ? a.filter((x) => typeof x === "string") : [];
  } catch (_) {
    return [];
  }
}

function safeStatus(value) {
  try {
    const x = JSON.parse(value || "{}");
    return x && typeof x === "object" && !Array.isArray(x) ? x : {};
  } catch (_) {
    return {};
  }
}

async function enrollRouter(request, env) {
  const length = Number(request.headers.get("content-length") || 0);
  if (length > 64 * 1024) return json({ ok: false, error: "payload_too_large" }, 413);
  const form = await request.formData();
  const pairCode = normalizePairCode(form.get("pair_code"));
  const name = cleanText(form.get("device_name"), 48);
  if (pairCode.length !== 8 || !name) return json({ ok: false, error: "bad_request" }, 400);

  const existing = await env.DB.prepare("SELECT id FROM devices WHERE name=? COLLATE NOCASE AND enabled=1")
    .bind(name).first();
  if (existing) return json({ ok: false, error: "device_name_exists" }, 409);

  const codeHash = await sha256Hex(pairCode);
  const now = nowSeconds();
  const pair = await env.DB.prepare(
    "SELECT code_hash FROM pair_codes WHERE code_hash=? AND used_at IS NULL AND expires_at>=?"
  ).bind(codeHash, now).first();
  if (!pair) return json({ ok: false, error: "invalid_or_expired_pair_code" }, 403);

  const deviceId = randomHex(8);
  const token = randomToken(32);
  const tokenHash = await sha256Hex(token);
  const status = statusFromForm(form, request);
  await updateInboundStatus(status, {}, true);
  const bootId = cleanText(form.get("boot_id"), 80);
  let nodeCipher = null;
  try {
    const nodeText = standardB64ToText(form.get("node_b64"));
    if (new TextEncoder().encode(nodeText).byteLength > MAX_NODE_BYTES) {
      return json({ ok: false, error: "node_too_large" }, 413);
    }
    if (nodeText) nodeCipher = await encryptText(nodeText, env);
  } catch (_) {
    return json({ ok: false, error: "bad_node_data" }, 400);
  }

  const claimed = await env.DB.prepare(
    "UPDATE pair_codes SET used_at=? WHERE code_hash=? AND used_at IS NULL AND expires_at>=?"
  ).bind(now, codeHash, now).run();
  if (numberValue(claimed?.meta?.changes) !== 1) {
    return json({ ok: false, error: "invalid_or_expired_pair_code" }, 403);
  }

  await env.DB.prepare(
    `INSERT INTO devices
      (id,name,token_hash,created_at,last_seen,online_state,active_alerts,status_json,node_cipher,node_updated_at,boot_id,client_ip)
     VALUES (?,?,?,?,?,'online','[]',?,?,?,?,?)`
  ).bind(
    deviceId, name, tokenHash, now, now, JSON.stringify(status), nodeCipher,
    nodeCipher ? now : null, bootId, status.client_ip
  ).run();
  await notifyOwners(
    env,
    `✅ <b>[节点中心] 新${status.device_type === "vps" ? "VPS" : "路由器"}已加入</b>\n设备：${escapeHtml(name)}\n状态：在线`,
    { inline_keyboard: [[{ text: "查看设备", callback_data: `rn:d:${deviceId}` }]] }
  );
  return json({ ok: true, device_id: deviceId, device_token: token, report_interval: 300 });
}

async function receiveReport(request, env) {
  const device = await authenticateDevice(request, env);
  if (!device) return json({ ok: false, error: "unauthorized" }, 401);
  const length = Number(request.headers.get("content-length") || 0);
  if (length > 64 * 1024) return json({ ok: false, error: "payload_too_large" }, 413);

  const form = await request.formData();
  const now = nowSeconds();
  const status = statusFromForm(form, request);
  const previousStatus = safeStatus(device.status_json);
  const currentAlerts = parseAlertCodes(form.get("alerts"));
  const previousAlerts = safeArray(device.active_alerts).filter((x) => x !== "offline");
  const added = currentAlerts.filter((x) => !previousAlerts.includes(x));
  const resolved = previousAlerts.filter((x) => !currentAlerts.includes(x));
  const newName = cleanText(form.get("device_name"), 48) || device.name;
  const bootId = cleanText(form.get("boot_id"), 80);
  const full = boolValue(form.get("full"));
  const refreshWasRequested = Boolean(device.refresh_requested);
  const addressChanged = status.public4 !== previousStatus.public4 || status.public6 !== previousStatus.public6 || status.ss_port !== previousStatus.ss_port;
  await updateInboundStatus(status, previousStatus, full || addressChanged);
  let nodeCipher = device.node_cipher;
  let nodeUpdatedAt = device.node_updated_at;

  if (full && form.get("node_b64")) {
    try {
      const nodeText = standardB64ToText(form.get("node_b64"));
      if (new TextEncoder().encode(nodeText).byteLength <= MAX_NODE_BYTES && nodeText) {
        nodeCipher = await encryptText(nodeText, env);
        nodeUpdatedAt = now;
      }
    } catch (_) {
      // 节点数据损坏时保留上一份有效内容，不影响心跳。
    }
  }

  try {
    await env.DB.prepare(
      `UPDATE devices SET name=?,last_seen=?,online_state='online',active_alerts=?,status_json=?,
       node_cipher=?,node_updated_at=?,boot_id=?,client_ip=?,refresh_requested=? WHERE id=?`
    ).bind(
      newName, now, JSON.stringify(currentAlerts), JSON.stringify(status), nodeCipher,
      nodeUpdatedAt, bootId, status.client_ip, full ? 0 : device.refresh_requested, device.id
    ).run();
  } catch (_) {
    return json({ ok: false, error: "device_name_exists" }, 409);
  }

  if (device.online_state === "offline") {
    await resolveAlert(env, device.id, "offline", now);
    if (!isMuted(device, now)) {
      await notifyOwners(env, `🟢 <b>[节点中心] 设备恢复在线</b>\n设备：${escapeHtml(newName)}\n离线状态已解除。`,
        deviceButton(device.id));
    }
  }

  if (device.boot_id && bootId && device.boot_id !== bootId && !isMuted(device, now)) {
    await notifyOwners(
      env,
      `🔄 <b>[节点中心] 设备已重启</b>\n设备：${escapeHtml(newName)}\n当前运行时间：${escapeHtml(formatDuration(status.uptime_sec))}`,
      deviceButton(device.id)
    );
  }

  for (const code of currentAlerts) await activateAlert(env, device.id, code, now, false);
  for (const code of resolved) await resolveAlert(env, device.id, code, now);

  if (added.length && !isMuted(device, now)) {
    const sent = await notifyOwners(env, formatAlertMessage(newName, added, status, false), deviceButton(device.id));
    if (sent) {
      for (const code of added) await markAlertNotified(env, device.id, code, now);
    }
  }
  if (resolved.length && !isMuted(device, now)) {
    await notifyOwners(env, formatAlertMessage(newName, resolved, status, true), deviceButton(device.id));
  }
  if (status.auto_restarted && !previousStatus.auto_restarted && !isMuted(device, now)) {
    await notifyOwners(
      env,
      `🛠 <b>[节点中心] 服务已自动恢复</b>\n设备：${escapeHtml(newName)}\n代理服务异常后已自动恢复。`,
      deviceButton(device.id)
    );
  }

  return json({ ok: true, refresh: refreshWasRequested && !full, server_time: now });
}

async function pollDeviceCommand(request, env) {
  const device = await authenticateDevice(request, env);
  if (!device) return json({ ok: false, error: "unauthorized" }, 401);
  const now = nowSeconds();
  await env.DB.prepare(
    "UPDATE device_commands SET status='failed',finished_at=?,exit_code=124 WHERE device_id=? AND status='running' AND started_at<?"
  ).bind(now, device.id, now - 300).run();
  await env.DB.prepare(
    "UPDATE device_commands SET status='expired' WHERE device_id=? AND status='queued' AND expires_at<?"
  ).bind(device.id, now).run();

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const command = await env.DB.prepare(
      `SELECT id,action,payload,expires_at FROM device_commands
       WHERE device_id=? AND status='queued' AND expires_at>=?
       ORDER BY created_at LIMIT 1`
    ).bind(device.id, now).first();
    if (!command) return json({ ok: true, command: null, server_time: now });
    const claimed = await env.DB.prepare(
      "UPDATE device_commands SET status='running',started_at=? WHERE id=? AND device_id=? AND status='queued'"
    ).bind(now, command.id, device.id).run();
    if (numberValue(claimed?.meta?.changes) === 1) {
      let payload = "";
      if (command.payload) {
        try { payload = await decryptText(command.payload, env); } catch (_) { payload = ""; }
      }
      return json({
        ok: true,
        command: { id: command.id, action: command.action, payload },
        server_time: now
      });
    }
  }
  return json({ ok: true, command: null, server_time: now });
}

async function receiveCommandResult(request, env) {
  const device = await authenticateDevice(request, env);
  if (!device) return json({ ok: false, error: "unauthorized" }, 401);
  const length = Number(request.headers.get("content-length") || 0);
  if (length > 128 * 1024) return json({ ok: false, error: "payload_too_large" }, 413);
  const form = await request.formData();
  const commandId = cleanText(form.get("command_id"), 40);
  const exitCode = Math.max(0, Math.min(255, numberValue(form.get("exit_code"), 1)));
  if (!/^[a-f0-9]{24}$/.test(commandId)) return json({ ok: false, error: "bad_command_id" }, 400);

  let resultText = "";
  try {
    resultText = standardB64ToText(form.get("result_b64"));
  } catch (_) {
    return json({ ok: false, error: "bad_result" }, 400);
  }
  if (new TextEncoder().encode(resultText).byteLength > 64 * 1024) {
    return json({ ok: false, error: "result_too_large" }, 413);
  }
  const command = await env.DB.prepare(
    "SELECT * FROM device_commands WHERE id=? AND device_id=? AND status IN ('running','done')"
  ).bind(commandId, device.id).first();
  if (!command) return json({ ok: false, error: "command_not_running" }, 409);
  if (command.status === "done") return json({ ok: true });

  if (command.action === 'node_config' && exitCode === 0 && form.get('node_b64')) {
    const node = standardB64ToText(form.get('node_b64'));
    if (new TextEncoder().encode(node).length > MAX_NODE_BYTES || !extractCopyableNodeEntries(node).length) return json({ok:false,error:'invalid_node'},400);
    await env.DB.prepare('UPDATE devices SET node_cipher=?,node_updated_at=?,refresh_requested=1 WHERE id=?')
      .bind(await encryptText(node,env),nowSeconds(),device.id).run();
  }

  const clippedTelegram = resultText.length > 3200 ? `${resultText.slice(0, 3200)}\n…输出已截断` : resultText;
  const deviceStatus = safeStatus(device.status_json);
  const deviceKind = deviceStatus.device_type === "vps" ? "VPS" : "路由器";
  const deviceIcon = deviceStatus.device_type === "vps" ? "🖥" : "🛜";
  const delivered = await notifyOwnersProtected(
    env,
    `<b>${deviceIcon} ${deviceKind}命令执行完成</b>\n设备：${escapeHtml(device.name)}\n` +
      `操作：<code>${escapeHtml(command.action)}</code>\n退出码：${exitCode}\n\n` +
      `<pre>${escapeHtml(clippedTelegram || "（没有输出）")}</pre>`,
    command.requested_by,
    deviceButton(device.id)
  );
  if (!delivered) return json({ ok: false, error: "telegram_delivery_failed" }, 503);
  await env.DB.prepare(
    "UPDATE device_commands SET status='done',finished_at=?,exit_code=?,result_text=NULL,payload='' WHERE id=? AND status='running'"
  ).bind(nowSeconds(), exitCode, commandId).run();
  return json({ ok: true });
}

async function notifyOwnersProtected(env, text, requester = '', keyboard = null) {
  let sent = false;
  const recipients = new Set(ownerIds(env));
  let requestedUser = String(requester || ""), requestedChat = requestedUser;
  try {
    const parsed = JSON.parse(requestedUser);
    requestedUser = String(parsed.user || "");
    requestedChat = String(parsed.chat || requestedUser);
  } catch (_) {}
  if (requestedUser && requestedChat) {
    const requestedType = requestedChat.startsWith("-") ? "group" : "private";
    if (await accessFor(env, requestedUser, { id: requestedChat, type: requestedType })) recipients.add(requestedChat);
  }
  for (const chatId of recipients) {
    try {
      await tg(env, "sendMessage", {
        chat_id: chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
        reply_markup: keyboard || { inline_keyboard: [[{ text: "🗑 删除", callback_data: "delete:this" }]] }
      });
      sent = true;
    } catch (_) {}
  }
  return sent;
}

function isMuted(device, now = nowSeconds()) {
  return numberValue(device.muted_until) === -1 || numberValue(device.muted_until) > now;
}

async function activateAlert(env, deviceId, code, now, notify) {
  await env.DB.prepare(
    `INSERT INTO alerts(device_id,code,active,first_seen,last_seen,last_notified,resolved_at)
     VALUES(?,?,1,?,?,?,NULL)
     ON CONFLICT(device_id,code) DO UPDATE SET active=1,last_seen=excluded.last_seen,
       last_notified=CASE WHEN alerts.active=0 OR ?=1 THEN excluded.last_notified ELSE alerts.last_notified END,
       first_seen=CASE WHEN alerts.active=0 THEN excluded.first_seen ELSE alerts.first_seen END,resolved_at=NULL`
  ).bind(deviceId, code, now, now, notify ? now : 0, notify ? 1 : 0).run();
}

async function resolveAlert(env, deviceId, code, now) {
  await env.DB.prepare(
    "UPDATE alerts SET active=0,last_seen=?,resolved_at=? WHERE device_id=? AND code=? AND active=1"
  ).bind(now, now, deviceId, code).run();
}

async function markAlertNotified(env, deviceId, code, now) {
  await env.DB.prepare("UPDATE alerts SET last_notified=? WHERE device_id=? AND code=?")
    .bind(now, deviceId, code).run();
}

function formatAlertMessage(name, codes, status, recovered) {
  const lines = codes.map((code) => `• ${escapeHtml(alertDescription(code, status))}`);
  return `${recovered ? "✅" : "⚠️"} <b>[节点中心] ${recovered ? "异常已恢复" : "检测到异常"}</b>\n` +
    `设备：${escapeHtml(name)}\n${lines.join("\n")}`;
}

function alertDescription(code, status) {
  const isVps = status.device_type === "vps";
  const service = status.service_name || (isVps ? "Xray" : "代理服务");
  const protocol = status.protocol_name || (isVps ? "VLESS" : "代理协议");
  if (code === "memory") return `可用内存过低：${formatMB(status.mem_available_kb)}，已使用 ${status.mem_used_pct || 0}%`;
  if (code === "temperature") return `设备温度过高：${status.temperature_c ?? "未知"}°C`;
  if (code === "storage") return `${isVps ? "根分区" : "Overlay"}已使用 ${status.overlay_used_pct || 0}%`;
  if (code === "load") return `5分钟负载 ${status.load5 || 0}，CPU ${status.cpu_cores || 1} 核`;
  if (code === "ddns") return `DuckDNS 连续失败 ${status.ddns_failures || 0} 次`;
  if (code === "service") return `${service}服务停止`;
  if (code === "tcp") return `${protocol} TCP ${status.ss_port || "未知"} 未监听`;
  if (code === "udp") return `${status.udp_mode === "vless-tunnel" || isVps ? "VLESS UDP 隧道" : `${protocol} UDP`}功能异常`;
  return ALERT_NAMES[code] || code;
}

function deviceButton(id) {
  return { inline_keyboard: [[{ text: "查看设备", callback_data: `rn:d:${id}` }]] };
}

async function telegramWebhook(request, env, ctx) {
  const provided = request.headers.get("x-telegram-bot-api-secret-token") || "";
  if (!env.TELEGRAM_WEBHOOK_SECRET || provided !== env.TELEGRAM_WEBHOOK_SECRET) {
    return json({ ok: false }, 403);
  }
  const update = await request.json();
  const actor = update.callback_query?.from || update.message?.from;
  const chat = update.callback_query?.message?.chat || update.message?.chat;
  if (update.message && !groupMessageTargetsBot(update.message, env)) return json({ ok: true });
  const access = actor ? await accessFor(env, actor.id, chat) : null;
  if (access) access.chatType = chat?.type || "";
  if (!actor || !access) {
    if (update.callback_query?.id) {
      ctx.waitUntil(tg(env, "answerCallbackQuery", {
        callback_query_id: update.callback_query.id,
        text: "没有操作权限；请让 Bot 管理员在私聊的「Bot 设置」中授权。",
        show_alert: true
      }).catch(() => {}));
    }
    return json({ ok: true });
  }

  if (update.callback_query) {
    await tg(env, "answerCallbackQuery", { callback_query_id: update.callback_query.id }).catch(() => {});
    try {
      await handleCallback(update.callback_query, env, access);
    } catch (_) {
      await tg(env, "sendMessage", {
        chat_id: chat.id,
        text: "菜单加载失败，请发 /start 重试。"
      }).catch(() => {});
      // Acknowledge Telegram to avoid endlessly replaying an action after a render failure.
    }
  } else if (update.message) {
    await handleMessage(update.message, env, access);
  }
  return json({ ok: true });
}

async function handleMessage(message, env, access) {
  const text = normalizedMessageText(message, env);
  const normalizedMessage = { ...message, text };
  if ((message.chat.type === "group" || message.chat.type === "supergroup") && text === "/id" && can(access, "admin")) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: `<b>本群 ID</b>\n<code>${message.chat.id}</code>\n\n在 Bot 私聊 → Bot 设置 → 群聊权限 中添加。`, parse_mode: "HTML" });
    return;
  }
  if (can(access, "admin") && await consumePendingInput(normalizedMessage, env)) return;
  if (text === "/pages" || text === "/page") {
    await sendPagesAddress(env, message.chat.id);
    return;
  }
  if (text === "/vps" || text === "/vps@") {
    await tg(env, "sendMessage", {
      chat_id: message.chat.id,
      text: vpsCommandHelp(),
      parse_mode: "HTML"
    });
    return;
  }
  if (text.startsWith("/vps ")) {
    await handleVpsTextCommand(message, env, access);
    return;
  }
  if (text === "/router" || text === "/router@") {
    await tg(env, "sendMessage", {
      chat_id: message.chat.id,
      text: routerCommandHelp(),
      parse_mode: "HTML"
    });
    return;
  }
  if (text.startsWith("/router ")) {
    await handleRouterTextCommand(message, env, access);
    return;
  }
  if (text.startsWith("/routers")) {
    await sendRouterHome(env, message.chat.id, access);
    return;
  }
  await tg(env, "sendMessage", {
    chat_id: message.chat.id,
    text: "<b>控制中心</b>\n",
    parse_mode: "HTML",
    reply_markup: rootKeyboard(access)
  });
}

function rootKeyboard(access) {
  const rows = [[{ text: "🛜 节点中心", callback_data: "rn:home" }, { text: "🌐 Pages 地址", callback_data: "rn:pages" }]];
  if (can(access, "admin")) rows.push([{ text: "⚙️ Bot 设置", callback_data: "rn:settings" }]);
  return { inline_keyboard: rows };
}

function publicPagesUrl(env) {
  const value = String(env.PUBLIC_GATEWAY_URL || "").trim().replace(/\/$/, "");
  return /^https:\/\/[A-Za-z0-9.-]+(?::\d+)?$/.test(value) ? value : "";
}

async function sendPagesAddress(env, chatId) {
  const url = publicPagesUrl(env);
  return tg(env, "sendMessage", {
    chat_id: chatId,
    text: url
      ? `<b>🌐 Pages 监控入口</b>\n\n<code>${escapeHtml(url)}</code>`
      : "尚未登记 Pages 地址，请重新运行 Cloudflare/Pages 部署脚本。",
    parse_mode: "HTML",
    disable_web_page_preview: true
  });
}

async function showPagesAddress(env, chatId, messageId, access) {
  const url = publicPagesUrl(env);
  return editMenu(env, chatId, messageId,
    url ? `<b>🌐 Pages 监控入口</b>\n\n<code>${escapeHtml(url)}</code>` : "尚未登记 Pages 地址，请重新运行 Cloudflare/Pages 部署脚本。",
    { inline_keyboard: [[{ text: "🏠 主菜单", callback_data: "root" }]] }
  );
}

function routerHomeKeyboard(access) {
  const rows = [
    [{ text: "📋 状态汇总", callback_data: "rn:summary" }, { text: "🚨 异常设备", callback_data: "rn:bad:0" }],
    [{ text: "📡 所有设备", callback_data: "rn:list:0" }]
  ];
  if (can(access, "admin")) rows[1].push({ text: "➕ 添加设备", callback_data: "rn:add" });
  rows.push([{ text: "🏠 主菜单", callback_data: "root" }]);
  return { inline_keyboard: rows };
}

async function handleCallback(query, env, access) {
  const data = String(query.data || "");
  const chatId = query.message.chat.id;
  const messageId = query.message.message_id;
  if (data === "root") return editMenu(env, chatId, messageId, "<b>控制中心</b>\n", rootKeyboard(access));
  if (data === "rn:pages") return showPagesAddress(env, chatId, messageId, access);
  if (data === "delete:this") return tg(env, "deleteMessage", { chat_id: chatId, message_id: messageId }).catch(() => {});
  if (!data.startsWith("rn:")) return;

  if (data === "rn:settings") return showBotSettings(env, chatId, messageId, access);
  if (data.startsWith("rn:perm:")) return handlePermissionCallback(query, env, access);
  if (data === "rn:home") return editRouterHome(env, chatId, messageId, access);
  if (data === "rn:add") return can(access, "admin") ? createPairCode(env, chatId, messageId, query.from.id) : denyMenu(env, chatId, messageId, access);
  if (data === "rn:summary") return showSummary(env, chatId, messageId, access);

  const parts = data.split(":");
  const action = parts[1];
  if (action === "list" || action === "bad") {
    return showDeviceList(env, chatId, messageId, action === "bad", numberValue(parts[2]), access);
  }
  const id = parts[2];
  if (!/^[a-f0-9]{16}$/.test(id || "")) return;
  if (["cfg", "cfgi", "cfgr", "cfgok"].includes(action)) return nodeEditCallback(query, env, access);
  if (action === "d") return showDevice(env, chatId, messageId, id, access);
  if (action === "status") return showFullStatus(env, chatId, messageId, id, access);
  if (action === "node") return showNode(env, chatId, id);
  if (action === "ssh") return showSsh(env, chatId, id);
  if (action === "probe") return showProbe(env, chatId, messageId, id, access);
  if (action === "ctl") return can(access, "operator") ? showDeviceControl(env, chatId, messageId, id, access) : denyMenu(env, chatId, messageId, access);
  if (action === "cmd") {
    const command = cleanText(parts[3], 32);
    const d = await getDevice(env, id);
    if (!d) return editRouterHome(env, chatId, messageId, access);
    const isVps = safeStatus(d.status_json).device_type === "vps";
    if (command === "reboot_ask") return can(access, "admin") ? confirmDeviceReboot(env, chatId, messageId, id, access) : denyMenu(env, chatId, messageId, access);
    const allowed = isVps
      ? ["status", "restart_xray", "update_xray", "reboot"]
      : ["status", "restart_singbox", "ddns_refresh", "reboot"];
    if (allowed.includes(command)) {
      return enqueueDeviceCommand(env, chatId, messageId, id, command, "", query.from.id, true, "", access);
    }
  }
  if (action === "refresh") return requestRefresh(env, chatId, messageId, id, access, query.from.id);
  if (action === "mute") return can(access, "operator") ? showMuteMenu(env, chatId, messageId, id, access) : denyMenu(env, chatId, messageId, access);
  if (action === "muteset") return can(access, "operator") ? setMute(env, chatId, messageId, id, Number(parts[3]), access) : denyMenu(env, chatId, messageId, access);
  if (action === "remove") return can(access, "admin") ? confirmRemove(env, chatId, messageId, id, access) : denyMenu(env, chatId, messageId, access);
  if (action === "removeok") return can(access, "admin") ? removeDevice(env, chatId, messageId, id, access) : denyMenu(env, chatId, messageId, access);
}

async function denyMenu(env, chatId, messageId, access) {
  return editMenu(env, chatId, messageId,
    `<b>权限不足</b>\n\n你当前权限：${roleLabel(access?.role)}。需要更高权限请联系 Bot 管理员。`,
    rootKeyboard(access));
}

function settingsKeyboard() {
  return {
    inline_keyboard: [
      [{ text: "👤 用户权限", callback_data: "rn:perm:users" }, { text: "👥 群聊权限", callback_data: "rn:perm:groups" }],
      [{ text: "📖 权限说明", callback_data: "rn:perm:help" }, { text: "🔄 刷新", callback_data: "rn:settings" }],
      [{ text: "🏠 主菜单", callback_data: "root" }]
    ]
  };
}

async function showBotSettings(env, chatId, messageId, access) {
  if (!can(access, "admin")) {
    return denyMenu(env, chatId, messageId, access);
  }
  const [users, groups] = await Promise.all([
    env.DB.prepare("SELECT COUNT(*) c FROM bot_users WHERE enabled=1").first(),
    env.DB.prepare("SELECT COUNT(*) c FROM bot_groups WHERE enabled=1").first()
  ]);
  const text = `<b>⚙️ Bot 设置 · 权限管理</b>\n\n` +
    `额外用户：${numberValue(users?.c)}\n已授权群聊：${numberValue(groups?.c)}\n\n` +
    `内置 Owner 始终保留最高管理员权限，不能在这里删除。\n` +
    `群内需要先将 Bot 加入群；Owner 在群内发送 <code>/id</code> 可取得群 ID。`;
  return editMenu(env, chatId, messageId, text, settingsKeyboard());
}

function permissionHelpKeyboard() {
  return { inline_keyboard: [[{ text: "⬅️ 返回 Bot 设置", callback_data: "rn:settings" }]] };
}

function permissionHelpText() {
  return `<b>📖 权限说明</b>\n\n` +
    `<b>只读</b>：查看设备、完整状态、节点、SSH、外部探测、请求刷新。\n` +
    `<b>控制</b>：包含只读；可执行状态查询、重启 Xray/代理、刷新 DDNS、告警静音。\n` +
    `<b>管理员</b>：最高权限；可执行全部命令、root Shell、重启整机、直接修改节点底层配置及管理 Bot 权限。\n\n` +
    `群聊可设为“群内全部成员”或“仅指定成员”。群全员仅允许只读或控制；管理员只能授予单独用户或群内指定成员。群内只有 @Bot 的消息才会回复。`;
}

function userPermissionKeyboard() {
  return {
    inline_keyboard: [
      [{ text: "➕ 添加只读用户", callback_data: "rn:perm:ua:viewer" }, { text: "➕ 添加控制用户", callback_data: "rn:perm:ua:operator" }],
      [{ text: "➕ 添加管理员", callback_data: "rn:perm:ua:admin" }, { text: "➖ 删除用户", callback_data: "rn:perm:ud" }],
      [{ text: "📋 用户列表", callback_data: "rn:perm:ul" }],
      [{ text: "⬅️ 返回 Bot 设置", callback_data: "rn:settings" }]
    ]
  };
}

function groupPermissionKeyboard() {
  return {
    inline_keyboard: [
      [{ text: "➕ 群全员只读", callback_data: "rn:perm:ga:all:viewer" }, { text: "➕ 群全员控制", callback_data: "rn:perm:ga:all:operator" }],
      [{ text: "➕ 建立指定成员群", callback_data: "rn:perm:ga:members:viewer" }],
      [{ text: "➕ 指定成员只读", callback_data: "rn:perm:ma:viewer" }, { text: "➕ 指定成员控制", callback_data: "rn:perm:ma:operator" }],
      [{ text: "➕ 指定成员管理员", callback_data: "rn:perm:ma:admin" }, { text: "➖ 删除指定成员", callback_data: "rn:perm:md" }],
      [{ text: "➖ 删除群权限", callback_data: "rn:perm:gd" }, { text: "📋 群权限列表", callback_data: "rn:perm:gl" }],
      [{ text: "⬅️ 返回 Bot 设置", callback_data: "rn:settings" }]
    ]
  };
}

async function savePendingInput(env, actorId, action, data = {}) {
  const now = nowSeconds();
  await env.DB.prepare(
    `INSERT INTO bot_pending_inputs(actor_id,action,data_json,expires_at) VALUES(?,?,?,?)
     ON CONFLICT(actor_id) DO UPDATE SET action=excluded.action,data_json=excluded.data_json,expires_at=excluded.expires_at`
  ).bind(String(actorId), action, JSON.stringify(data), now + 600).run();
}

async function promptPermissionInput(env, query, action, data, text, keyboard) {
  await savePendingInput(env, query.from.id, action, data);
  return editMenu(env, query.message.chat.id, query.message.message_id,
    `${text}\n\n<b>10 分钟内直接发送即可；不会公开显示敏感节点信息。</b>`, keyboard);
}

async function handlePermissionCallback(query, env, access) {
  const chatId = query.message.chat.id;
  const messageId = query.message.message_id;
  if (!can(access, "admin")) return denyMenu(env, chatId, messageId, access);
  const parts = String(query.data || "").split(":");
  const op = parts[2] || "";
  if (op === "help") return editMenu(env, chatId, messageId, permissionHelpText(), permissionHelpKeyboard());
  if (op === "users") return editMenu(env, chatId, messageId, "<b>👤 用户权限</b>\n\n添加后，对方需在 Bot 私聊发送 /start。", userPermissionKeyboard());
  if (op === "groups") return editMenu(env, chatId, messageId, "<b>👥 群聊权限</b>\n\n先把 Bot 加进目标群；Owner 在群内发送 <code>/id</code> 取得群 ID。重复添加同一群可直接修改模式或角色。", groupPermissionKeyboard());
  if (op === "ua" && normalRole(parts[3])) return promptPermissionInput(env, query, "user_add", { role: parts[3] }, `请输入要添加为「${roleLabel(parts[3])}」的 Telegram 用户数字 ID：`, userPermissionKeyboard());
  if (op === "ud") return promptPermissionInput(env, query, "user_delete", {}, "请输入要删除的 Telegram 用户数字 ID：", userPermissionKeyboard());
  if (op === "ga" && (parts[3] === "all" || parts[3] === "members") && normalRole(parts[4]) && !(parts[3] === "all" && parts[4] === "admin")) {
    const kind = parts[3] === "all" ? "群内全部成员" : "仅指定成员";
    return promptPermissionInput(env, query, "group_add", { mode: parts[3], role: parts[4] }, `请输入群 ID；将设置为「${kind} · ${roleLabel(parts[4])}」。`, groupPermissionKeyboard());
  }
  if (op === "gd") return promptPermissionInput(env, query, "group_delete", {}, "请输入要删除授权的群 ID：", groupPermissionKeyboard());
  if (op === "ma" && normalRole(parts[3])) return promptPermissionInput(env, query, "member_add", { role: parts[3] }, `请输入「群ID 用户ID」；该成员将获得「${roleLabel(parts[3])}」。`, groupPermissionKeyboard());
  if (op === "md") return promptPermissionInput(env, query, "member_delete", {}, "请输入「群ID 用户ID」以移除指定成员：", groupPermissionKeyboard());
  if (op === "ul") return showPermissionUsers(env, chatId, messageId);
  if (op === "gl") return showPermissionGroups(env, chatId, messageId);
  return showBotSettings(env, chatId, messageId, access);
}

async function consumePendingInput(message, env) {
  const actorId = String(message.from.id);
  const pending = await env.DB.prepare("SELECT action,data_json,expires_at FROM bot_pending_inputs WHERE actor_id=?").bind(actorId).first();
  if (!pending) return false;
  await env.DB.prepare("DELETE FROM bot_pending_inputs WHERE actor_id=?").bind(actorId).run();
  if (numberValue(pending.expires_at) < nowSeconds()) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: "输入已过期，请在 Bot 设置中重新点选操作。" });
    return true;
  }
  const input = String(message.text || "").trim();
  if (input.startsWith("/")) return false;
  let data = {};
  try { data = JSON.parse(pending.data_json || "{}"); } catch (_) {}
  if (pending.action === "node_input") {
    await previewNodeEdit(env, actorId, message.chat.id, null, data.id, data.field, input);
    return true;
  }
  const idOk = (v, group = false) => group ? /^-?\d{5,20}$/.test(v) : /^\d{5,20}$/.test(v);
  let result = "";
  if (pending.action === "user_add" && idOk(input) && normalRole(data.role)) {
    const now = nowSeconds();
    await env.DB.prepare(`INSERT INTO bot_users(user_id,role,added_by,created_at,updated_at,enabled) VALUES(?,?,?,?,?,1)
      ON CONFLICT(user_id) DO UPDATE SET role=excluded.role,added_by=excluded.added_by,updated_at=excluded.updated_at,enabled=1`).bind(input, data.role, actorId, now, now).run();
    result = `✅ 已授权用户 <code>${input}</code>：${roleLabel(data.role)}`;
  } else if (pending.action === "user_delete" && idOk(input)) {
    await env.DB.prepare("DELETE FROM bot_users WHERE user_id=?").bind(input).run();
    result = `✅ 已删除用户 <code>${input}</code> 的额外权限（Owner 不受影响）。`;
  } else if (pending.action === "group_add" && idOk(input, true) && (data.mode === "all" || data.mode === "members") && normalRole(data.role) && !(data.mode === "all" && data.role === "admin")) {
    const now = nowSeconds();
    await env.DB.prepare(`INSERT INTO bot_groups(chat_id,title,access_mode,role,added_by,created_at,updated_at,enabled) VALUES(?,?,?,?,?,?,?,1)
      ON CONFLICT(chat_id) DO UPDATE SET access_mode=excluded.access_mode,role=excluded.role,added_by=excluded.added_by,updated_at=excluded.updated_at,enabled=1`).bind(input, "", data.mode, data.role, actorId, now, now).run();
    result = `✅ 已设置群 <code>${input}</code>：${data.mode === "all" ? "全员" : "仅指定成员"} · ${roleLabel(data.role)}`;
  } else if ((pending.action === "member_add" || pending.action === "member_delete") && input.split(/\s+/).length === 2) {
    const [groupId, userId] = input.split(/\s+/);
    if (!idOk(groupId, true) || !idOk(userId)) result = "❌ 格式不正确，应为：群ID 用户ID";
    else if (pending.action === "member_add" && normalRole(data.role)) {
      const group = await env.DB.prepare("SELECT chat_id FROM bot_groups WHERE chat_id=? AND enabled=1").bind(groupId).first();
      if (!group) result = "❌ 群尚未授权，请先添加群权限。";
      else {
        await env.DB.prepare(`INSERT INTO bot_group_members(chat_id,user_id,role,added_by,created_at) VALUES(?,?,?,?,?)
          ON CONFLICT(chat_id,user_id) DO UPDATE SET role=excluded.role,added_by=excluded.added_by,created_at=excluded.created_at`).bind(groupId, userId, data.role, actorId, nowSeconds()).run();
        result = `✅ 已设置群成员 <code>${userId}</code>：${roleLabel(data.role)}`;
      }
    } else {
      await env.DB.prepare("DELETE FROM bot_group_members WHERE chat_id=? AND user_id=?").bind(groupId, userId).run();
      result = `✅ 已移除群成员 <code>${userId}</code> 的权限。`;
    }
  } else if (pending.action === "group_delete" && idOk(input, true)) {
    await env.DB.prepare("DELETE FROM bot_group_members WHERE chat_id=?").bind(input).run();
    await env.DB.prepare("DELETE FROM bot_groups WHERE chat_id=?").bind(input).run();
    result = `✅ 已删除群 <code>${input}</code> 的权限及成员列表。`;
  } else result = "❌ 输入格式不正确；请重新从 Bot 设置点选对应操作。";
  await tg(env, "sendMessage", { chat_id: message.chat.id, text: result, parse_mode: "HTML", reply_markup: settingsKeyboard() });
  return true;
}

async function showPermissionUsers(env, chatId, messageId) {
  const rows = (await env.DB.prepare("SELECT user_id,role,updated_at FROM bot_users WHERE enabled=1 ORDER BY updated_at DESC LIMIT 40").all()).results || [];
  const lines = rows.length ? rows.map((r) => `• <code>${escapeHtml(r.user_id)}</code> · ${roleLabel(r.role)}`) : ["（暂无额外用户）"];
  return editMenu(env, chatId, messageId, `<b>📋 用户权限</b>\n\n${lines.join("\n")}`, userPermissionKeyboard());
}

async function showPermissionGroups(env, chatId, messageId) {
  const rows = (await env.DB.prepare(`SELECT g.chat_id,g.access_mode,g.role,COUNT(m.user_id) members
    FROM bot_groups g LEFT JOIN bot_group_members m ON m.chat_id=g.chat_id WHERE g.enabled=1
    GROUP BY g.chat_id,g.access_mode,g.role ORDER BY g.updated_at DESC LIMIT 40`).all()).results || [];
  const lines = rows.length ? rows.map((r) => {
    const effectiveRole = r.access_mode === "all" && r.role === "admin" ? "operator" : r.role;
    return `• <code>${escapeHtml(r.chat_id)}</code> · ${r.access_mode === "all" ? "全员" : `指定成员 ${numberValue(r.members)} 人`} · ${roleLabel(effectiveRole)}`;
  }) : ["（暂无已授权群）"];
  return editMenu(env, chatId, messageId, `<b>📋 群聊权限</b>\n\n${lines.join("\n")}`, groupPermissionKeyboard());
}

async function editMenu(env, chatId, messageId, text, replyMarkup) {
  try {
    return await tg(env, "editMessageText", {
      chat_id: chatId,
      message_id: messageId,
      text,
      parse_mode: "HTML",
      disable_web_page_preview: true,
      reply_markup: replyMarkup
    });
  } catch (error) {
    if (String(error?.message || error).toLowerCase().includes("message is not modified")) return true;
    return tg(env, "sendMessage", {
      chat_id: chatId,
      text,
      parse_mode: "HTML",
      disable_web_page_preview: true,
      reply_markup: replyMarkup
    });
  }
}

async function sendRouterHome(env, chatId, access) {
  const counts = await deviceCounts(env);
  return tg(env, "sendMessage", {
    chat_id: chatId,
    text: routerHomeText(counts),
    parse_mode: "HTML",
    reply_markup: routerHomeKeyboard(access)
  });
}

async function editRouterHome(env, chatId, messageId, access) {
  const counts = await deviceCounts(env);
  return editMenu(env, chatId, messageId, routerHomeText(counts), routerHomeKeyboard(access));
}

async function deviceCounts(env) {
  const cutoff = nowSeconds() - envInt(env, "OFFLINE_MINUTES", 15, 5, 1440) * 60;
  const row = await env.DB.prepare(
    `SELECT COUNT(*) total,
      SUM(CASE WHEN last_seen>=? AND active_alerts='[]' THEN 1 ELSE 0 END) normal,
      SUM(CASE WHEN last_seen>=? AND active_alerts<>'[]' THEN 1 ELSE 0 END) abnormal,
      SUM(CASE WHEN last_seen IS NULL OR last_seen<? THEN 1 ELSE 0 END) offline
     FROM devices WHERE enabled=1`
  ).bind(cutoff, cutoff, cutoff).first();
  return {
    total: numberValue(row?.total), normal: numberValue(row?.normal),
    abnormal: numberValue(row?.abnormal), offline: numberValue(row?.offline)
  };
}

function routerHomeText(c) {
  return `<b>🛜 节点中心</b>\n\n路由器与 VPS 总数：${c.total}\n🟢 正常：${c.normal}\n🟡 异常：${c.abnormal}\n🔴 离线：${c.offline}`;
}

function vpsCommandHelp(deviceId = "设备ID") {
  return `<b>🖥 VPS 管理命令</b>\n\n` +
    `<code>/vps ${deviceId} status</code>\n` +
    `<code>/vps ${deviceId} restart-xray</code>\n` +
    `<code>/vps ${deviceId} update-xray</code>\n` +
    `<code>/vps ${deviceId} reboot</code>\n` +
    `<code>/vps ${deviceId} shell 命令</code>\n\n` +
    `Shell 以 root 执行，最长 120 秒。仅限 Bot 管理员私聊。`;
}

async function handleVpsTextCommand(message, env, access) {
  const match = String(message.text || "").trim().match(/^\/vps\s+([a-f0-9]{16})\s+([a-z-]+)(?:\s+([\s\S]*))?$/i);
  if (!match) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: vpsCommandHelp(), parse_mode: "HTML" });
    return;
  }
  const deviceId = match[1].toLowerCase();
  const requested = match[2].toLowerCase();
  const payload = String(match[3] || "").trim();
  const actionMap = {
    status: "status",
    "restart-xray": "restart_xray",
    "update-xray": "update_xray",
    reboot: "reboot",
    shell: "shell"
  };
  const action = actionMap[requested];
  if (!action || (action === "shell" && !payload)) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: vpsCommandHelp(deviceId), parse_mode: "HTML" });
    return;
  }
  await enqueueDeviceCommand(env, message.chat.id, null, deviceId, action, payload, message.from.id, false, "vps", access);
}

function routerCommandHelp(deviceId = "设备ID") {
  return `<b>🛜 路由器管理命令</b>\n\n` +
    `<code>/router ${deviceId} status</code>\n` +
    `<code>/router ${deviceId} restart-singbox</code>\n` +
    `<code>/router ${deviceId} ddns</code>\n` +
    `<code>/router ${deviceId} reboot</code>\n` +
    `<code>/router ${deviceId} shell 命令</code>\n\n` +
    `Shell 以 root 执行，最长 120 秒。仅限 Bot 管理员私聊。`;
}

async function handleRouterTextCommand(message, env, access) {
  const match = String(message.text || "").trim().match(/^\/router\s+([a-f0-9]{16})\s+([a-z-]+)(?:\s+([\s\S]*))?$/i);
  if (!match) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: routerCommandHelp(), parse_mode: "HTML" });
    return;
  }
  const deviceId = match[1].toLowerCase();
  const requested = match[2].toLowerCase();
  const payload = String(match[3] || "").trim();
  const actionMap = {
    status: "status",
    "restart-singbox": "restart_singbox",
    ddns: "ddns_refresh",
    reboot: "reboot",
    shell: "shell"
  };
  const action = actionMap[requested];
  if (!action || (action === "shell" && !payload)) {
    await tg(env, "sendMessage", { chat_id: message.chat.id, text: routerCommandHelp(deviceId), parse_mode: "HTML" });
    return;
  }
  await enqueueDeviceCommand(env, message.chat.id, null, deviceId, action, payload, message.from.id, false, "router", access);
}

async function createPairCode(env, chatId, messageId, ownerId) {
  const code = randomPairCode();
  const normalized = normalizePairCode(code);
  const hash = await sha256Hex(normalized);
  const now = nowSeconds();
  await env.DB.prepare(
    "INSERT INTO pair_codes(code_hash,created_by,created_at,expires_at,used_at) VALUES(?,?,?,?,NULL)"
  ).bind(hash, String(ownerId), now, now + PAIR_TTL_SECONDS).run();
  const text = `<b>➕ 添加设备</b>\n\n一次性配对码：\n<code>${code}</code>\n\n有效期10分钟，只能使用一次。` +
    `\n在路由器或 VPS 安装脚本中填写监控入口和此配对码。`;
  return editMenu(env, chatId, messageId, text, {
    inline_keyboard: [
      [{ text: "重新生成", callback_data: "rn:add" }],
      [{ text: "⬅️ 返回节点中心", callback_data: "rn:home" }]
    ]
  });
}

async function showDeviceList(env, chatId, messageId, abnormalOnly, page, access) {
  const safePage = Math.max(0, Math.floor(page));
  const cutoff = nowSeconds() - envInt(env, "OFFLINE_MINUTES", 15, 5, 1440) * 60;
  const where = abnormalOnly
    ? "enabled=1 AND (last_seen IS NULL OR last_seen<? OR active_alerts<>'[]')"
    : "enabled=1";
  const countStmt = abnormalOnly
    ? env.DB.prepare(`SELECT COUNT(*) c FROM devices WHERE ${where}`).bind(cutoff)
    : env.DB.prepare(`SELECT COUNT(*) c FROM devices WHERE ${where}`);
  const total = numberValue((await countStmt.first())?.c);
  const maxPage = Math.max(0, Math.ceil(total / PAGE_SIZE) - 1);
  const currentPage = Math.min(safePage, maxPage);
  const listStmt = abnormalOnly
    ? env.DB.prepare(`SELECT * FROM devices WHERE ${where} ORDER BY name LIMIT ? OFFSET ?`).bind(cutoff, PAGE_SIZE, currentPage * PAGE_SIZE)
    : env.DB.prepare(`SELECT * FROM devices WHERE ${where} ORDER BY name LIMIT ? OFFSET ?`).bind(PAGE_SIZE, currentPage * PAGE_SIZE);
  const rows = (await listStmt.all()).results || [];
  const keyboard = rows.map((d) => [{
    text: `${deviceIcon(d, cutoff)} ${d.name} · ${relativeTime(d.last_seen)}`,
    callback_data: `rn:d:${d.id}`
  }]);
  const nav = [];
  if (currentPage > 0) nav.push({ text: "◀️", callback_data: `rn:${abnormalOnly ? "bad" : "list"}:${currentPage - 1}` });
  if (currentPage < maxPage) nav.push({ text: "▶️", callback_data: `rn:${abnormalOnly ? "bad" : "list"}:${currentPage + 1}` });
  if (nav.length) keyboard.push(nav);
  keyboard.push([{ text: "⬅️ 返回节点中心", callback_data: "rn:home" }]);
  const title = abnormalOnly ? "🚨 异常设备" : "📡 所有设备";
  const text = `<b>${title}</b>${!rows.length ? "\n暂无设备" : ""}${maxPage ? `\n${currentPage + 1}/${maxPage + 1}` : ""}`;
  return editMenu(env, chatId, messageId, text, { inline_keyboard: keyboard });
}

function deviceIcon(device, cutoff = nowSeconds() - 900) {
  if (!device.last_seen || numberValue(device.last_seen) < cutoff || device.online_state === "offline") return "🔴";
  if (safeArray(device.active_alerts).length) return "🟡";
  return "🟢";
}

async function getDevice(env, id) {
  return env.DB.prepare("SELECT * FROM devices WHERE id=? AND enabled=1").bind(id).first();
}

async function showDevice(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return editRouterHome(env, chatId, messageId, access);
  const s = safeStatus(d.status_json);
  const alerts = safeArray(d.active_alerts);
  const isVps = s.device_type === "vps";
  const protocol = s.protocol_name || (isVps ? "VLESS Reality" : "Shadowsocks");
  const cutoff = nowSeconds() - envInt(env, "OFFLINE_MINUTES", 15, 5, 1440) * 60;
  const text = `<b>${deviceIcon(d, cutoff)} ${escapeHtml(d.name)}</b>\n\n` +
    `状态：${deviceStateText(d, cutoff)}\n` +
    `最后上报：${escapeHtml(formatDate(d.last_seen, env))}（${relativeTime(d.last_seen)}）\n` +
    `网络：${escapeHtml(s.network_type || "未知")}\n` +
    `节点：${escapeHtml(protocol)} ${s.ss_port || "未知"} · TCP ${s.tcp_listen ? "✅" : "❌"} / ${(s.udp_mode === "vless-tunnel" || isVps) ? "UDP隧道支持" : "UDP监听"} ${s.udp_listen ? "✅" : "❌"}\n` +
    `${isVps ? `当前连接：${s.current_connections || 0}\n` : ""}` +
    `内存：${s.mem_used_pct ?? "?"}% · 温度：${s.temperature_c == null ? "未发现可读传感器" : `${s.temperature_c}°C`}\n` +
    `异常：${alerts.length ? alerts.map((x) => escapeHtml(ALERT_NAMES[x] || x)).join("、") : "无"}`;
  const muted = isMuted(d);
  const keyboard = [
    [{ text: "📊 完整状态", callback_data: `rn:status:${id}` }, { text: "🌐 外部探测", callback_data: `rn:probe:${id}` }],
    [{ text: "🔗 当前节点", callback_data: `rn:node:${id}` }, { text: "🖥 SSH 地址", callback_data: `rn:ssh:${id}` }],
    [{ text: "⚡ 实时刷新", callback_data: `rn:refresh:${id}` }, { text: "🛠 远程控制", callback_data: `rn:ctl:${id}` }],
    ...(can(access, "operator") ? [[
      ...(can(access, "admin") ? [{ text: "⚙️ 节点配置", callback_data: `rn:cfg:${id}` }] : []),
      { text: muted ? "🔔 解除静音" : "🔕 告警静音", callback_data: `rn:mute:${id}` }
    ]] : []),
    ...(can(access, "admin") ? [[{ text: "🗑 移除设备", callback_data: `rn:remove:${id}` }]] : []),
    [{ text: "⬅️ 设备列表", callback_data: "rn:list:0" }, { text: "🏠 主菜单", callback_data: "root" }]
  ];
  return editMenu(env, chatId, messageId, text, { inline_keyboard: keyboard });
}

function deviceStateText(d, cutoff) {
  if (!d.last_seen || numberValue(d.last_seen) < cutoff || d.online_state === "offline") return "🔴 离线";
  if (safeArray(d.active_alerts).length) return "🟡 在线但有异常";
  return "🟢 在线正常";
}

async function showFullStatus(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return editRouterHome(env, chatId, messageId, access);
  const s = safeStatus(d.status_json);
  const isVps = s.device_type === "vps";
  const temp = s.temperature_c == null ? "未发现可读传感器" : `${s.temperature_c}°C`;
  const text = `<b>📊 ${escapeHtml(d.name)} · 完整状态</b>\n\n` +
    `<b>系统</b>\n型号：${escapeHtml(s.model || "未知")}\n固件：${escapeHtml(s.firmware || "未知")}\n` +
    `运行时间：${escapeHtml(formatDuration(s.uptime_sec))}\n负载：${s.load1 || 0} / ${s.load5 || 0} / ${s.load15 || 0}（${s.cpu_cores || 1}核）\n` +
    `内存：${formatMB(s.mem_available_kb)} 可用 / ${formatMB(s.mem_total_kb)} 总计，已用 ${s.mem_used_pct || 0}%\n` +
    `温度：${temp}${s.temperature_source ? `（${escapeHtml(s.temperature_source)}）` : ""}\n${isVps ? "根分区" : "Overlay"}：已用 ${s.overlay_used_pct || 0}%\n\n` +
    `<b>网络</b>\n类型：${escapeHtml(s.network_type || "未知")}\n接口：${escapeHtml(s.wan_if || "无")} / ${escapeHtml(s.wan_dev || "无")}\n` +
    `公网IPv4：<code>${escapeHtml(s.public4 || "无")}</code> · ${inboundStateText(s.inbound4)}\n` +
    `公网IPv6：<code>${escapeHtml(s.public6 || "无")}</code> · ${inboundStateText(s.inbound6)}\n` +
    `${isVps ? "" : `DDNS：<code>${escapeHtml(s.ddns_domain || "无")}</code>（${escapeHtml(s.ddns_mode || "无")}）\n`}` +
    `WAN收发：${formatBytes(s.wan_rx_bytes)} / ${formatBytes(s.wan_tx_bytes)}\n\n` +
    `<b>服务</b>\n${escapeHtml(s.service_name || (isVps ? "Xray" : "sing-box"))}：${s.singbox_running ? "✅" : "❌"}\n` +
    `协议：${escapeHtml(s.protocol_name || (isVps ? "VLESS Reality Vision" : "Shadowsocks 2022"))}\n` +
    `端口：${s.ss_port || "未知"}\nTCP监听：${s.tcp_listen ? "✅" : "❌"}\n${(s.udp_mode === "vless-tunnel" || isVps) ? "UDP隧道支持（非实测）" : "UDP监听"}：${s.udp_listen ? "✅" : "❌"}` +
    `${isVps ? `\n当前连接：${s.current_connections || 0}` : ""}`;
  return editMenu(env, chatId, messageId, text, {
    inline_keyboard: [
      [{ text: "🔗 当前节点", callback_data: `rn:node:${id}` }, { text: "🖥 SSH地址", callback_data: `rn:ssh:${id}` }],
      [{ text: isVps ? "🛠 VPS远程控制" : "🛠 路由器远程控制", callback_data: `rn:ctl:${id}` }],
      [{ text: "⚡ 实时刷新", callback_data: `rn:refresh:${id}` }],
      [{ text: "⬅️ 返回设备", callback_data: `rn:d:${id}` }]
    ]
  });
}

async function showNode(env, chatId, id) {
  const d = await getDevice(env, id);
  if (!d) return;
  const editing = await env.DB.prepare("SELECT id FROM device_commands WHERE device_id=? AND action='node_config' AND status IN ('queued','running') AND expires_at>=? LIMIT 1").bind(id,nowSeconds()).first();
  if (editing) return tg(env,'sendMessage',{chat_id:chatId,text:'节点正在更新，请稍后获取。'});
  if (!d.node_cipher) {
    await tg(env, "sendMessage", { chat_id: chatId, text: "尚未收到节点信息，请先点击实时刷新。" });
    return;
  }
  let nodeText;
  try {
    nodeText = await decryptText(d.node_cipher, env);
  } catch (_) {
    nodeText = "节点信息解密失败，请重新部署相同的数据加密密钥或让设备重新配对。";
  }
  const entries = extractCopyableNodeEntries(nodeText);
  if (!entries.length) {
    await tg(env, "sendMessage", {
      chat_id: chatId,
      text: `<b>🔗 ${escapeHtml(d.name)} · 当前节点</b>\n\n当前设备尚未上传可识别的配置行；请点击「实时刷新」。`,
      parse_mode: "HTML"
    });
    return;
  }
  for (const entry of entries) {
    await tg(env, "sendMessage", {
      chat_id: chatId,
      text: `<b>${escapeHtml(d.name)} · ${escapeHtml(entry.label)}</b>\n<code>${escapeHtml(entry.value)}</code>`,
      parse_mode: "HTML",
      disable_web_page_preview: true,
      reply_markup: { inline_keyboard: [[{ text: "🗑 删除", callback_data: "delete:this" }]] }
    });
  }
}

function extractCopyableNodeEntries(nodeText) {
  const rows = String(nodeText || "").split(/\r?\n/).map((x) => x.trim());
  const entries = [];
  const seen = new Set();
  for (const row of rows) {
    if (!/^(vless=|vless:\/\/|ss=|ss:\/\/|trojan=|trojan:\/\/)/i.test(row)) continue;
    const value = row.slice(0, 3900);
    if (seen.has(value)) continue;
    seen.add(value);
    entries.push({ label: /^vless=/i.test(value) ? "Quantumult X 整行导入" : /^vless:\/\//i.test(value) ? "标准 VLESS 链接" : "节点配置", value });
  }
  return entries;
}

async function showSsh(env, chatId, id) {
  const d = await getDevice(env, id);
  if (!d) return;
  const s = safeStatus(d.status_json);
  const host = s.ddns_domain || s.public6 || s.public4;
  const lines = [];
  if (host) lines.push(["自动选择", `ssh root@${host}`]);
  if (s.public6 && host) lines.push(["IPv6", `ssh -6 root@${host}`]);
  if (s.public4 && host) lines.push(["IPv4", `ssh -4 root@${host}`]);
  if (!lines.length) lines.push(["提示", "当前没有可用的公网地址或DDNS域名"]);
  await tg(env, "sendMessage", {
    chat_id: chatId,
    text: `<b>🖥 ${escapeHtml(d.name)} · SSH 地址</b>\n\n${lines.map(([label, command]) => `${escapeHtml(label)}：\n<code>${escapeHtml(command)}</code>`).join("\n\n")}`,
    parse_mode: "HTML",
    reply_markup: { inline_keyboard: [[{ text: "🗑 删除", callback_data: "delete:this" }]] }
  });
}

async function showProbe(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return;
  const s = safeStatus(d.status_json);
  const isVps = s.device_type === "vps";
  const port = numberValue(s.ss_port);
  const targets = [];
  if (isPublicIPv4(s.public4)) targets.push(["IPv4", s.public4]);
  if (isPublicIPv6(s.public6)) targets.push(["IPv6", s.public6]);
  const results = await Promise.all(targets.map(async ([label, host]) => [label, await probeTcp(host, port)]));
  s.inbound4 = isPublicIPv4(s.public4) ? (results.find(([label]) => label === "IPv4")?.[1] ? "reachable" : "blocked") : "none";
  s.inbound6 = isPublicIPv6(s.public6) ? (results.find(([label]) => label === "IPv6")?.[1] ? "reachable" : "blocked") : "none";
  s.network_type = detectedNetworkType(s);
  await env.DB.prepare("UPDATE devices SET status_json=? WHERE id=? AND enabled=1").bind(JSON.stringify(s), id).run();
  const lines = results.length
    ? results.map(([label, ok]) => `${label} TCP ${port}：${ok ? "✅ 可连接" : "❌ 无法连接"}`)
    : ["没有可用于外部探测的公网地址。"];
  lines.push(isVps
    ? "VLESS 的 UDP 通过 XUDP 封装在 TCP 内，不需要服务器单独监听 UDP 端口。"
    : "UDP只能确认路由器本地监听，Cloudflare不执行UDP外部探测。");
  return editMenu(env, chatId, messageId, `<b>🌐 ${escapeHtml(d.name)} · 外部探测</b>\n\n${lines.join("\n")}`, {
    inline_keyboard: [
      [{ text: "重新探测", callback_data: `rn:probe:${id}` }],
      [{ text: "⬅️ 返回设备", callback_data: `rn:d:${id}` }]
    ]
  });
}

async function probeTcp(host, port) {
  if (!host || port < 1 || port > 65535) return false;
  let socket;
  try {
    socket = connect({ hostname: host, port }, { secureTransport: "off" });
    await Promise.race([
      socket.opened,
      new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 3500))
    ]);
    return true;
  } catch (_) {
    return false;
  } finally {
    try { socket?.close(); } catch (_) {}
  }
}

function isPublicIPv4(value) {
  const p = String(value || "").split(".").map(Number);
  if (p.length !== 4 || p.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) return false;
  if (p[0] === 10 || p[0] === 127 || p[0] === 0 || p[0] >= 224) return false;
  if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return false;
  if (p[0] === 169 && p[1] === 254) return false;
  if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return false;
  if (p[0] === 192 && p[1] === 168) return false;
  return true;
}

function isPublicIPv6(value) {
  const s = String(value || "").toLowerCase();
  return s.includes(":") && s !== "::" && s !== "::1" && !s.startsWith("fe8") && !s.startsWith("fe9") &&
    !s.startsWith("fea") && !s.startsWith("feb") && !s.startsWith("fc") && !s.startsWith("fd");
}

function inboundStateText(value) {
  return value === "reachable" ? "✅ 公网可连接" : value === "blocked" ? "❌ TCP 入站未通过" : value === "none" ? "无公网地址" : "等待外部检测";
}

function detectedNetworkType(status) {
  const has4 = isPublicIPv4(status.public4);
  const has6 = isPublicIPv6(status.public6);
  const ok4 = status.inbound4 === "reachable";
  const ok6 = status.inbound6 === "reachable";
  const state4 = has4 ? (ok4 ? "公网入站已验证" : status.inbound4 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "上级 NAT 或未确认";
  const state6 = has6 ? (ok6 ? "公网入站已验证" : status.inbound6 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "无公网地址";
  if (has4 && has6) return `双栈：IPv4（${state4}）；IPv6（${state6}）`;
  if (has6) return `IPv6（${state6}）；IPv4 为上级 NAT 或未确认`;
  if (has4) return `IPv4（${state4}）；IPv6 无公网地址`;
  return "上级 NAT / 暂无可发布地址";
}

async function updateInboundStatus(status, previous = {}, force = false) {
  const port = numberValue(status.ss_port);
  status.inbound4 = isPublicIPv4(status.public4) ? (previous.inbound4 || "pending") : "none";
  status.inbound6 = isPublicIPv6(status.public6) ? (previous.inbound6 || "pending") : "none";
  if (force && port > 0 && port <= 65535) {
    const checks = [];
    if (isPublicIPv4(status.public4)) checks.push(probeTcp(status.public4, port).then((ok) => { status.inbound4 = ok ? "reachable" : "blocked"; }));
    if (isPublicIPv6(status.public6)) checks.push(probeTcp(status.public6, port).then((ok) => { status.inbound6 = ok ? "reachable" : "blocked"; }));
    await Promise.all(checks);
  }
  status.network_type = detectedNetworkType(status);
  return status;
}

async function requestRefresh(env, chatId, messageId, id, access, actorId) {
  await env.DB.prepare("UPDATE devices SET refresh_requested=1 WHERE id=? AND enabled=1").bind(id).run();
  return enqueueDeviceCommand(env, chatId, messageId, id, "refresh", "", actorId, true, "", access);
}

async function showDeviceControl(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return editRouterHome(env, chatId, messageId, access);
  const s = safeStatus(d.status_json);
  const isVps = s.device_type === "vps";
  const kind = isVps ? "VPS" : "路由器";
  const shellExample = isVps
    ? `/vps ${d.id} shell uname -a`
    : `/router ${d.id} shell logread | tail -50`;
  const text = `<b>🛠 ${escapeHtml(d.name)} · ${kind}远程控制</b>\n\n` +
    `设备 ID：<code>${d.id}</code>\n` +
    `命令由设备主动通过认证通道领取，通常10秒内开始；无需开放额外管理端口。\n\n` +
    `${can(access, "admin") ? `任意 root Shell：\n<code>${escapeHtml(shellExample)}</code>\n\n` : ""}` +
    `当前权限：${roleLabel(access.role)}。${can(access, "admin") ? "管理员可使用 root Shell 与整机重启。" : "整机重启与 root Shell 仅限管理员。"}`;
  const keyboard = isVps
    ? [
        [{ text: "📊 立即查询", callback_data: `rn:cmd:${id}:status` }],
        [{ text: "🔄 重启 Xray", callback_data: `rn:cmd:${id}:restart_xray` }],
        [{ text: "⬆️ 更新 Xray", callback_data: `rn:cmd:${id}:update_xray` }],
        ...(can(access, "admin") ? [[{ text: "⏻ 重启 VPS", callback_data: `rn:cmd:${id}:reboot_ask` }]] : []),
        [{ text: "⬅️ 返回设备", callback_data: `rn:d:${id}` }]
      ]
    : [
        [{ text: "📊 立即查询", callback_data: `rn:cmd:${id}:status` }],
        [{ text: s.service_name === "Xray" ? "🔄 重启家宽 Xray" : "🔄 重启 sing-box", callback_data: `rn:cmd:${id}:restart_singbox` }],
        [{ text: "🌐 立即刷新 DDNS", callback_data: `rn:cmd:${id}:ddns_refresh` }],
        ...(can(access, "admin") ? [[{ text: "⏻ 重启路由器", callback_data: `rn:cmd:${id}:reboot_ask` }]] : []),
        [{ text: "⬅️ 返回设备", callback_data: `rn:d:${id}` }]
      ];
  return editMenu(env, chatId, messageId, text, { inline_keyboard: keyboard });
}

async function confirmDeviceReboot(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return;
  const isVps = safeStatus(d.status_json).device_type === "vps";
  const kind = isVps ? "VPS" : "路由器";
  return editMenu(env, chatId, messageId,
    `<b>⚠️ 确认重启整台${kind}？</b>\n\n设备：${escapeHtml(d.name)}\n节点和远程连接会暂时断开。`,
    { inline_keyboard: [
      [{ text: "确认重启", callback_data: `rn:cmd:${id}:reboot` }],
      [{ text: "取消", callback_data: `rn:ctl:${id}` }]
    ] }
  );
}

async function enqueueDeviceCommand(env, chatId, messageId, id, action, payload, ownerId, edit, requiredType = "", access = null) {
  const d = await getDevice(env, id);
  if (!d) {
    const text = "设备不存在。";
    if (edit && messageId) return editMenu(env, chatId, messageId, text, routerHomeKeyboard(access));
    return tg(env, "sendMessage", { chat_id: chatId, text });
  }
  const s = safeStatus(d.status_json);
  const type = s.device_type === "vps" ? "vps" : "router";
  if (requiredType && type !== requiredType) {
    const text = requiredType === "vps" ? "该设备不是 VPS。" : "该设备不是路由器。";
    return tg(env, "sendMessage", { chat_id: chatId, text });
  }
  const allowed = type === "vps"
    ? new Set(["status", "refresh", "restart_xray", "update_xray", "reboot", "shell", "node_config"])
    : new Set(["status", "refresh", "restart_singbox", "ddns_refresh", "reboot", "shell", "node_config"]);
  if (!allowed.has(action)) return;
  const requiredRole = (["shell", "reboot", "node_config"].includes(action)) ? "admin" : ["status", "refresh"].includes(action) ? "viewer" : "operator";
  if (!can(access, requiredRole)) {
    const text = `权限不足：${action === "shell" || action === "reboot" ? "root Shell 与整机重启需要管理员权限。" : "此操作需要控制权限。"}`;
    if (edit && messageId) return editMenu(env, chatId, messageId, text, { inline_keyboard: [[{ text: "返回设备", callback_data: `rn:d:${id}` }]] });
    return tg(env, "sendMessage", { chat_id: chatId, text });
  }
  const safePayload = ["shell", "node_config"].includes(action) ? String(payload || "").trim().slice(0, 4096) : "";
  if (action === "shell" && !safePayload) return;
  if (action === "node_config") {
    let change;
    try { change=JSON.parse(safePayload); } catch (_) { return; }
    if (!s.node_config || !validNodeValue(change.field,change.value)) return;
  }

  const pending = await env.DB.prepare(
    "SELECT COUNT(*) c FROM device_commands WHERE device_id=? AND status IN ('queued','running') AND expires_at>=?"
  ).bind(id, nowSeconds()).first();
  if (numberValue(pending?.c) >= 3) {
    const text = `该${type === "vps" ? "VPS" : "路由器"}已有 3 条命令等待执行，请稍后再试。`;
    if (edit && messageId) return editMenu(env, chatId, messageId, text, { inline_keyboard: [[{ text: "返回控制", callback_data: `rn:ctl:${id}` }]] });
    return tg(env, "sendMessage", { chat_id: chatId, text });
  }

  const commandId = randomHex(12);
  const now = nowSeconds();
  const storedPayload = safePayload ? await encryptText(safePayload, env) : "";
  await env.DB.prepare(
    `INSERT INTO device_commands
      (id,device_id,action,payload,status,requested_by,created_at,expires_at)
     VALUES(?,?,?,?,'queued',?,?,?)`
  ).bind(commandId, id, action, storedPayload, JSON.stringify({ user: String(ownerId), chat: String(chatId) }), now, now + 300).run();
  const labels = {
    status: "立即查询", refresh: "实时刷新", restart_xray: "重启 Xray", update_xray: "更新 Xray",
    restart_singbox: s.service_name === "Xray" ? "重启家宽 Xray" : "重启 sing-box", ddns_refresh: "刷新 DDNS",
    reboot: type === "vps" ? "重启 VPS" : "重启路由器", shell: "执行 root Shell", node_config: "修改节点配置"
  };
  const text = `<b>✅ 已排队</b>\n\n设备：${escapeHtml(d.name)}\n` +
    `操作：${escapeHtml(labels[action] || action)}\n命令 ID：<code>${commandId}</code>\n` +
    `结果将单独发送。`;
  if (edit && messageId) {
    return editMenu(env, chatId, messageId, text, { inline_keyboard: [[{ text: "返回控制", callback_data: `rn:ctl:${id}` }]] });
  }
  return tg(env, "sendMessage", { chat_id: chatId, text, parse_mode: "HTML" });
}

async function showMuteMenu(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return;
  const active = isMuted(d);
  return editMenu(env, chatId, messageId,
    `<b>🔕 ${escapeHtml(d.name)} · 告警静音</b>\n\n${numberValue(d.muted_until) === -1 ? "永久静音" : active ? `当前静音至：${escapeHtml(formatDate(d.muted_until, env))}` : "当前未静音。"}`,
    { inline_keyboard: [
      [{ text: "1小时", callback_data: `rn:muteset:${id}:1` }, { text: "6小时", callback_data: `rn:muteset:${id}:6` }],
      [{ text: "24小时", callback_data: `rn:muteset:${id}:24` }, { text: "永久静音", callback_data: `rn:muteset:${id}:-1` }],
      [{ text: "解除静音", callback_data: `rn:muteset:${id}:0` }],
      [{ text: "⬅️ 返回设备", callback_data: `rn:d:${id}` }]
    ] }
  );
}

async function setMute(env, chatId, messageId, id, hours, access) {
  if (![-1,0,1,6,24].includes(hours)) return;
  const until = hours === -1 ? -1 : hours ? nowSeconds() + hours * 3600 : 0;
  await env.DB.prepare("UPDATE devices SET muted_until=? WHERE id=? AND enabled=1").bind(until, id).run();
  return showMuteMenu(env, chatId, messageId, id, access);
}

async function confirmRemove(env, chatId, messageId, id, access) {
  const d = await getDevice(env, id);
  if (!d) return;
  return editMenu(env, chatId, messageId,
    `<b>⚠️ 确认移除设备？</b>\n\n设备：${escapeHtml(d.name)}\n移除后设备配置不会改变，但将停止向此Bot上报。重新加入需要生成新配对码。`,
    { inline_keyboard: [
      [{ text: "确认移除", callback_data: `rn:removeok:${id}` }],
      [{ text: "取消", callback_data: `rn:d:${id}` }]
    ] }
  );
}

async function removeDevice(env, chatId, messageId, id, access) {
  await env.DB.prepare("UPDATE devices SET enabled=0,token_hash=? WHERE id=?")
    .bind(`disabled-${randomHex(16)}`, id).run();
  return editRouterHome(env, chatId, messageId, access);
}

async function showSummary(env, chatId, messageId, access) {
  const rows = (await env.DB.prepare("SELECT * FROM devices WHERE enabled=1 ORDER BY name LIMIT 60").all()).results || [];
  const cutoff = nowSeconds() - envInt(env, "OFFLINE_MINUTES", 15, 5, 1440) * 60;
  const lines = rows.map((d) => {
    const s = safeStatus(d.status_json);
    return `${deviceIcon(d, cutoff)} <b>${escapeHtml(d.name)}</b> · 内存${s.mem_used_pct ?? "?"}% · ${s.temperature_c == null ? "无温度" : `${s.temperature_c}°C`} · ${relativeTime(d.last_seen)}\n` +
      `  IPv4 <code>${escapeHtml(s.public4 || "无")}</code> · IPv6 <code>${escapeHtml(s.public6 || "无")}</code>`;
  });
  const counts = await deviceCounts(env);
  const header = `<b>📋 节点中心当前汇总</b>\n${escapeHtml(formatDate(nowSeconds(), env))}\n\n` +
    `总数 ${counts.total} · 正常 ${counts.normal} · 异常 ${counts.abnormal} · 离线 ${counts.offline}\n\n` +
    (lines.length ? "" : "暂无设备");
  const text = appendLinesWithinTelegramLimit(header, lines);
  return editMenu(env, chatId, messageId, text, {
    inline_keyboard: [[{ text: "🔄 刷新汇总", callback_data: "rn:summary" }], [{ text: "⬅️ 返回节点中心", callback_data: "rn:home" }]]
  });
}

async function runScheduled(env, scheduledAt) {
  const now = scheduledAt || nowSeconds();
  const offlineSeconds = envInt(env, "OFFLINE_MINUTES", 15, 5, 1440) * 60;
  const cutoff = now - offlineSeconds;
  const offlineRows = (await env.DB.prepare(
    "SELECT * FROM devices WHERE enabled=1 AND online_state<>'offline' AND (last_seen IS NULL OR last_seen<?) LIMIT 100"
  ).bind(cutoff).all()).results || [];

  for (const d of offlineRows) {
    await env.DB.prepare("UPDATE devices SET online_state='offline' WHERE id=?").bind(d.id).run();
    await activateAlert(env, d.id, "offline", now, false);
    if (!isMuted(d, now)) {
      const sent = await notifyOwners(
        env,
        `🔴 <b>[节点中心] 设备离线</b>\n设备：${escapeHtml(d.name)}\n超过 ${Math.floor(offlineSeconds / 60)} 分钟没有收到心跳。`,
        deviceButton(d.id)
      );
      if (sent) await markAlertNotified(env, d.id, "offline", now);
    }
  }

  const remindBefore = now - envInt(env, "ALERT_REMIND_HOURS", 6, 1, 168) * 3600;
  const reminders = (await env.DB.prepare(
    `SELECT a.device_id,a.code,a.last_notified,d.name,d.muted_until,d.status_json
     FROM alerts a JOIN devices d ON d.id=a.device_id
     WHERE a.active=1 AND d.enabled=1 AND a.last_notified<? AND d.muted_until<>-1 AND d.muted_until<=? LIMIT 50`
  ).bind(remindBefore, now).all()).results || [];
  for (const r of reminders) {
    const sent = await notifyOwners(env,
      `⏰ <b>[节点中心] 异常仍在持续</b>\n设备：${escapeHtml(r.name)}\n• ${escapeHtml(alertDescription(r.code, safeStatus(r.status_json)))}`,
      deviceButton(r.device_id));
    if (sent) await markAlertNotified(env, r.device_id, r.code, now);
  }

  const local = localDateParts(now, env.REPORT_TIMEZONE || "Asia/Shanghai");
  const targetHour = envInt(env, "DAILY_REPORT_HOUR", 9, 0, 23);
  if (local.hour === targetHour && local.minute < 5) {
    const key = `daily:${local.date}`;
    const sent = await env.DB.prepare("SELECT value FROM settings WHERE key='last_daily_report'").first();
    if (sent?.value !== key) {
      const rows = (await env.DB.prepare("SELECT * FROM devices WHERE enabled=1 ORDER BY name LIMIT 60").all()).results || [];
      const counts = await deviceCounts(env);
      const lines = rows.map((d) => {
        const s = safeStatus(d.status_json);
        return `${deviceIcon(d, cutoff)} <b>${escapeHtml(d.name)}</b> · 内存${s.mem_used_pct ?? "?"}% · ${s.temperature_c == null ? "无温度" : `${s.temperature_c}°C`} · ${relativeTime(d.last_seen)}\n` +
          `  IPv4 <code>${escapeHtml(s.public4 || "无")}</code> · IPv6 <code>${escapeHtml(s.public6 || "无")}</code>`;
      });
      const header = `<b>📅 [节点中心] 每日状态汇总</b>\n${escapeHtml(local.date)}\n\n` +
        `设备 ${counts.total} · 正常 ${counts.normal} · 异常 ${counts.abnormal} · 离线 ${counts.offline}\n\n` +
        (lines.length ? "" : "暂无设备");
      const text = appendLinesWithinTelegramLimit(header, lines);
      const sent = await notifyOwners(env, text, routerHomeKeyboard());
      if (sent) {
        await env.DB.prepare(
          `INSERT INTO settings(key,value,updated_at) VALUES('last_daily_report',?,?)
           ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`
        ).bind(key, now).run();
      }
    }
  }

  const retention = envInt(env, "ALERT_RETENTION_DAYS", 30, 1, 365) * 86400;
  await env.DB.prepare("DELETE FROM pair_codes WHERE expires_at<?").bind(now - 86400).run();
  await env.DB.prepare("DELETE FROM alerts WHERE active=0 AND resolved_at<?").bind(now - retention).run();
  await env.DB.prepare("DELETE FROM device_commands WHERE expires_at<?").bind(now - 7 * 86400).run();
}

function localDateParts(epoch, timeZone) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", hourCycle: "h23"
    }).formatToParts(new Date(epoch * 1000));
    const o = Object.fromEntries(parts.map((p) => [p.type, p.value]));
    return { date: `${o.year}-${o.month}-${o.day}`, hour: Number(o.hour), minute: Number(o.minute) };
  } catch (_) {
    const d = new Date(epoch * 1000);
    return { date: d.toISOString().slice(0, 10), hour: d.getUTCHours(), minute: d.getUTCMinutes() };
  }
}

function formatDate(epoch, env) {
  if (!epoch) return "从未";
  try {
    return new Intl.DateTimeFormat("zh-CN", {
      timeZone: env.REPORT_TIMEZONE || "Asia/Shanghai",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
      hourCycle: "h23"
    }).format(new Date(numberValue(epoch) * 1000));
  } catch (_) {
    return new Date(numberValue(epoch) * 1000).toISOString().replace("T", " ").slice(0, 16);
  }
}

function relativeTime(epoch) {
  if (!epoch) return "从未上报";
  const d = Math.max(0, nowSeconds() - numberValue(epoch));
  if (d < 60) return `${d}秒前`;
  if (d < 3600) return `${Math.floor(d / 60)}分钟前`;
  if (d < 86400) return `${Math.floor(d / 3600)}小时前`;
  return `${Math.floor(d / 86400)}天前`;
}

function formatDuration(seconds) {
  const n = Math.max(0, numberValue(seconds));
  const days = Math.floor(n / 86400);
  const hours = Math.floor((n % 86400) / 3600);
  const minutes = Math.floor((n % 3600) / 60);
  return `${days}天 ${hours}小时 ${minutes}分钟`;
}

function formatMB(kb) {
  return `${(numberValue(kb) / 1024).toFixed(1)} MB`;
}

function formatBytes(value) {
  let n = Math.max(0, numberValue(value));
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;
}

function appendLinesWithinTelegramLimit(header, lines, limit = 3900) {
  let text = header;
  let used = 0;
  for (const line of lines) {
    if (text.length + line.length + 1 > limit) break;
    text += `${line}\n`;
    used += 1;
  }
  if (used < lines.length) text += `\n…另有 ${lines.length - used} 台设备，请在设备列表中查看。`;
  return text.trimEnd();
}

const NODE_FIELDS = { sni: 'SNI', target: 'REALITY 目标', port: '节点端口', uuid: 'UUID', keys: 'REALITY 密钥', shortid: 'Short ID' };
function validNodeValue(field, value) {
  if (typeof value !== 'string' || value.length > 300 || /[\r\n\x00-\x1f]/.test(value)) return false;
  if (['keys', 'uuid', 'shortid'].includes(field) && value === 'random') return true;
  if (field === 'sni') return value.length <= 253 && /^([a-z\d]([a-z\d-]*[a-z\d])?\.)+[a-z]{2,63}$/i.test(value);
  if (field === 'target') return /^[a-z\d.-]+:[1-9]\d{0,4}$/i.test(value) && Number(value.split(':')[1]) <= 65535;
  if (field === 'port') return /^[1-9]\d{0,4}$/.test(value) && Number(value) <= 65535;
  if (field === 'uuid') return /^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i.test(value);
  if (field === 'shortid') return /^([a-f\d]{2}){1,8}$/i.test(value);
  return false;
}
async function nodeEditCallback(query, env, access) {
  const chatId = query.message.chat.id, mid = query.message.message_id;
  if (!can(access, 'admin')) {
    return editMenu(env, chatId, mid, '只有管理员可以修改节点配置。', rootKeyboard(access));
  }
  const [, action, id, field] = query.data.split(':');
  const d = await getDevice(env, id);
  if (!d) return;
  if (!safeStatus(d.status_json).node_config) {
    return editMenu(env, chatId, mid, '此设备不支持在线修改节点配置，请重新运行 1.1 安装器补齐组件。旧 SS 节点需先安装 VLESS。', deviceButton(id));
  }
  if (action === 'cfg') {
    await env.DB.prepare('DELETE FROM node_config_drafts WHERE actor_id=?').bind(String(query.from.id)).run();
    await env.DB.prepare("DELETE FROM bot_pending_inputs WHERE actor_id=? AND action LIKE 'node_%'").bind(String(query.from.id)).run();
    return editMenu(env, chatId, mid, `<b>⚙️ ${escapeHtml(d.name)} · 节点配置</b>`, { inline_keyboard: [
      [{text:'更换 SNI',callback_data:`rn:cfgi:${id}:sni`},{text:'更换目标',callback_data:`rn:cfgi:${id}:target`}],
      [{text:'更换端口',callback_data:`rn:cfgi:${id}:port`},{text:'更换 UUID',callback_data:`rn:cfgi:${id}:uuid`}],
      [{text:'生成新密钥',callback_data:`rn:cfgr:${id}:keys`},{text:'更换 Short ID',callback_data:`rn:cfgi:${id}:shortid`}],
      [{text:'⬅️ 返回设备',callback_data:`rn:d:${id}`}]
    ] });
  }
  if (action === 'cfgok') {
    // Atomically consume a short-lived draft. Replayed/old buttons cannot submit twice.
    const draft = await env.DB.prepare("DELETE FROM node_config_drafts WHERE id=? AND actor_id=? AND device_id=? AND expires_at>=? RETURNING payload")
      .bind(field, String(query.from.id), id, nowSeconds()).first();
    if (!draft) return editMenu(env,chatId,mid,'确认已失效，请重新选择。',deviceButton(id));
    const payload = await decryptText(draft.payload, env);
    return enqueueDeviceCommand(env,chatId,mid,id,'node_config',payload,query.from.id,true,'',access);
  }
  if (!NODE_FIELDS[field]) return;
  if (action === 'cfgr' && field === 'keys') return previewNodeEdit(env,query.from.id,chatId,mid,id,field,'random');
  if (action === 'cfgi') {
    await savePendingInput(env, query.from.id, 'node_input', {id,field});
    const hint = field === 'sni' ? '请输入域名（目标同步为该域名:443）。' : field === 'target' ? '请输入域名:端口（保留 SNI）。' : field === 'port' ? '请输入端口 1–65535。' : '请输入新值，或发送 random 随机生成。';
    return editMenu(env,chatId,mid,`<b>${NODE_FIELDS[field]}</b>\n${hint}`,{inline_keyboard:[[{text:'取消',callback_data:`rn:cfg:${id}`}]]});
  }
}
async function previewNodeEdit(env, actorId, chatId, mid, id, field, value) {
  if (!validNodeValue(field,value)) return tg(env,'sendMessage',{chat_id:chatId,text:'格式错误，请重新选择配置项。'});
  const nonce=randomHex(8);
  await env.DB.prepare('DELETE FROM node_config_drafts WHERE actor_id=? OR expires_at<?').bind(String(actorId),nowSeconds()).run();
  await env.DB.prepare('INSERT INTO node_config_drafts(id,actor_id,device_id,payload,expires_at) VALUES(?,?,?,?,?)')
    .bind(nonce,String(actorId),id,await encryptText(JSON.stringify({field,value}),env),nowSeconds()+600).run();
  const text=`<b>确认修改 ${NODE_FIELDS[field]}？</b>\n<code>${escapeHtml(value==='random'?'设备本地随机生成':value)}</code>\n\n服务会短暂重启；客户端需重新导入节点。`+
    (field==='port'?'\n请同步调整主路由转发或云安全组。':'');
  const keyboard={inline_keyboard:[[{text:'确认修改',callback_data:`rn:cfgok:${id}:${nonce}`}],[{text:'取消',callback_data:`rn:cfg:${id}`}]]};
  if(mid) return editMenu(env,chatId,mid,text,keyboard);
  return tg(env,'sendMessage',{chat_id:chatId,text,parse_mode:'HTML',reply_markup:keyboard});
}
