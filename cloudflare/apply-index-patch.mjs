import { readFileSync, writeFileSync } from 'node:fs';

const file = new URL('./src/index.js', import.meta.url);
let source = readFileSync(file, 'utf8');
const marker = '// NODE_SUITE_TG_NODE_V37';

if (source.includes(marker)) {
  console.log('Cloudflare runtime patch 3.7 already applied.');
  process.exit(0);
}

function replaceOnce(needle, replacement, label) {
  const count = source.split(needle).length - 1;
  if (count !== 1) throw new Error(`${label}: expected exactly one anchor, found ${count}`);
  source = source.replace(needle, replacement);
}

replaceOnce(
  'const VERSION = "3.6.0";',
  `const VERSION = "3.7.0";\n${marker}`,
  'version'
);

replaceOnce(
  '  const entries = extractCopyableNodeEntries(nodeText);',
  `  const entries = extractCopyableNodeEntries(nodeText)\n    .filter((entry) => /^vless=/i.test(entry.value))\n    .slice(0, 1)\n    .map((entry) => ({ ...entry, label: "Quantumult X 整行导入", value: withSniCheckUrl(entry.value) }));`,
  'current node list'
);

replaceOnce(
  'function extractCopyableNodeEntries(nodeText) {',
  `function withSniCheckUrl(value) {\n  const text = String(value || "").trim();\n  if (!/^vless=/i.test(text)) return text;\n  const match = text.match(/(?:^|,\\s*)obfs-host=([^,\\s]+)/i);\n  if (!match) return text;\n  const host = match[1].trim();\n  if (!/^([a-z\\d]([a-z\\d-]*[a-z\\d])?\\.)+[a-z]{2,63}$/i.test(host)) return text;\n  const field = \\`server_check_url=http://\\${host}/generate_204\\`;\n  if (/(?:^|,\\s*)server_check_url=/i.test(text)) {\n    return text.replace(/,\\s*server_check_url=[^,]+/i, \\`, \\${field}\\`);\n  }\n  if (/,\\s*tag=/i.test(text)) return text.replace(/,\\s*tag=/i, \\`, \\${field}, tag=\\`);\n  return \\`\\${text}, \\${field}\\`;\n}\n\nfunction extractCopyableNodeEntries(nodeText) {`,
  'server_check_url helper'
);

replaceOnce(
  "const NODE_FIELDS = { sni: 'SNI', target: 'REALITY 目标', port: '节点端口', uuid: 'UUID', keys: 'REALITY 密钥', shortid: 'Short ID' };",
  "const NODE_FIELDS = { sni: '修改 SNI', target: 'REALITY 目标', port: '节点端口', uuid: 'UUID', keys: 'REALITY 密钥', shortid: 'Short ID' };",
  'node field title'
);

replaceOnce(
  "      [{text:'更换 SNI',callback_data:`rn:cfgi:${id}:sni`},{text:'更换目标',callback_data:`rn:cfgi:${id}:target`}],",
  "      [{text:'修改 SNI',callback_data:`rn:cfgi:${id}:sni`}],",
  'node config menu'
);

replaceOnce(
  "    const hint = field === 'sni' ? '请输入域名（目标同步为该域名:443）。' : field === 'target' ? '请输入域名:端口（保留 SNI）。' : field === 'port' ? '请输入端口 1–65535。' : '请输入新值，或发送 random 随机生成。';",
  "    const hint = field === 'sni' ? '请输入域名。' : field === 'target' ? '请输入域名:端口（保留 SNI）。' : field === 'port' ? '请输入端口 1–65535。' : '请输入新值，或发送 random 随机生成。';",
  'SNI prompt'
);

replaceOnce(
  `async function probeTcp(host, port) {\n  if (!host || port < 1 || port > 65535) return false;\n  let socket;\n  try {\n    socket = connect({ hostname: host, port }, { secureTransport: "off" });\n    await Promise.race([\n      socket.opened,\n      new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 3500))\n    ]);\n    return true;\n  } catch (_) {\n    return false;\n  } finally {\n    try { socket?.close(); } catch (_) {}\n  }\n}`,
  `async function probeTcp(host, port, attempts = 3) {\n  if (!host || port < 1 || port > 65535) return false;\n  for (let attempt = 0; attempt < attempts; attempt += 1) {\n    let socket;\n    try {\n      socket = connect({ hostname: host, port }, { secureTransport: "off" });\n      await Promise.race([\n        socket.opened,\n        new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 2500))\n      ]);\n      return true;\n    } catch (_) {\n      // A single Cloudflare egress path can fail even when the node is reachable elsewhere.\n    } finally {\n      try { socket?.close(); } catch (_) {}\n    }\n    if (attempt + 1 < attempts) await new Promise((resolve) => setTimeout(resolve, 150));\n  }\n  return false;\n}`,
  'TCP probe retries'
);

replaceOnce(
  `function inboundStateText(value) {\n  return value === "reachable" ? "✅ 公网可连接" : value === "blocked" ? "❌ TCP 入站未通过" : value === "none" ? "无公网地址" : "等待外部检测";\n}\n\nfunction detectedNetworkType(status) {\n  const has4 = isPublicIPv4(status.public4);\n  const has6 = isPublicIPv6(status.public6);\n  const ok4 = status.inbound4 === "reachable";\n  const ok6 = status.inbound6 === "reachable";\n  const state4 = has4 ? (ok4 ? "公网入站已验证" : status.inbound4 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "上级 NAT 或未确认";\n  const state6 = has6 ? (ok6 ? "公网入站已验证" : status.inbound6 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "无公网地址";\n  if (has4 && has6) return \\`双栈：IPv4（\\${state4}）；IPv6（\\${state6}）\\`;\n  if (has6) return \\`IPv6（\\${state6}）；IPv4 为上级 NAT 或未确认\\`;\n  if (has4) return \\`IPv4（\\${state4}）；IPv6 无公网地址\\`;\n  return "上级 NAT / 暂无可发布地址";\n}\n\nasync function updateInboundStatus(status, previous = {}, force = false) {\n  const port = numberValue(status.ss_port);\n  status.inbound4 = isPublicIPv4(status.public4) ? (previous.inbound4 || "pending") : "none";\n  status.inbound6 = isPublicIPv6(status.public6) ? (previous.inbound6 || "pending") : "none";\n  if (force && port > 0 && port <= 65535) {\n    const checks = [];\n    if (isPublicIPv4(status.public4)) checks.push(probeTcp(status.public4, port).then((ok) => { status.inbound4 = ok ? "reachable" : "blocked"; }));\n    if (isPublicIPv6(status.public6)) checks.push(probeTcp(status.public6, port).then((ok) => { status.inbound6 = ok ? "reachable" : "blocked"; }));\n    await Promise.all(checks);\n  }\n  status.network_type = detectedNetworkType(status);\n  return status;\n}`,
  `function inboundStateText(value) {\n  return value === "reachable" ? "✅ 公网可连接" : value === "blocked" ? "❌ 本机 TCP 未监听" : value === "unverified" ? "⚠️ 外部探测未确认" : value === "none" ? "无公网地址" : "等待外部检测";\n}\n\nfunction failedProbeState(previous, localListening) {\n  if (previous === "reachable") return "reachable";\n  return localListening ? "unverified" : "blocked";\n}\n\nfunction detectedNetworkType(status) {\n  const has4 = isPublicIPv4(status.public4);\n  const has6 = isPublicIPv6(status.public6);\n  const state = (family, hasAddress) => {\n    if (!hasAddress) return family === 4 ? "上级 NAT 或未确认" : "无公网地址";\n    const value = family === 4 ? status.inbound4 : status.inbound6;\n    if (value === "reachable") return "公网入站已验证";\n    if (value === "blocked") return "本机 TCP 未监听";\n    if (value === "unverified") return "公网地址/本机监听正常，外部探测未确认";\n    return "等待外部检测";\n  };\n  const state4 = state(4, has4);\n  const state6 = state(6, has6);\n  if (has4 && has6) return \\`双栈：IPv4（\\${state4}）；IPv6（\\${state6}）\\`;\n  if (has6) return \\`IPv6（\\${state6}）；IPv4 为上级 NAT 或未确认\\`;\n  if (has4) return \\`IPv4（\\${state4}）；IPv6 无公网地址\\`;\n  return "上级 NAT / 暂无可发布地址";\n}\n\nasync function updateInboundStatus(status, previous = {}, force = false) {\n  const port = numberValue(status.ss_port);\n  const previousPort = numberValue(previous.ss_port);\n  const same4 = isPublicIPv4(status.public4) && status.public4 === previous.public4 && port === previousPort;\n  const same6 = isPublicIPv6(status.public6) && status.public6 === previous.public6 && port === previousPort;\n  const previous4 = same4 ? previous.inbound4 : "";\n  const previous6 = same6 ? previous.inbound6 : "";\n  status.inbound4 = isPublicIPv4(status.public4) ? (previous4 || "pending") : "none";\n  status.inbound6 = isPublicIPv6(status.public6) ? (previous6 || "pending") : "none";\n  if (force && port > 0 && port <= 65535) {\n    const checks = [];\n    if (isPublicIPv4(status.public4)) checks.push(probeTcp(status.public4, port).then((ok) => { status.inbound4 = ok ? "reachable" : failedProbeState(previous4, status.tcp_listen); }));\n    if (isPublicIPv6(status.public6)) checks.push(probeTcp(status.public6, port).then((ok) => { status.inbound6 = ok ? "reachable" : failedProbeState(previous6, status.tcp_listen); }));\n    await Promise.all(checks);\n  }\n  status.network_type = detectedNetworkType(status);\n  return status;\n}`,
  'inbound state semantics'
);

replaceOnce(
  `  s.inbound4 = isPublicIPv4(s.public4) ? (results.find(([label]) => label === "IPv4")?.[1] ? "reachable" : "blocked") : "none";\n  s.inbound6 = isPublicIPv6(s.public6) ? (results.find(([label]) => label === "IPv6")?.[1] ? "reachable" : "blocked") : "none";`,
  `  s.inbound4 = isPublicIPv4(s.public4) ? (results.find(([label]) => label === "IPv4")?.[1] ? "reachable" : failedProbeState(s.inbound4, s.tcp_listen)) : "none";\n  s.inbound6 = isPublicIPv6(s.public6) ? (results.find(([label]) => label === "IPv6")?.[1] ? "reachable" : failedProbeState(s.inbound6, s.tcp_listen)) : "none";`,
  'manual probe state'
);

replaceOnce(
  '    ? results.map(([label, ok]) => `${label} TCP ${port}：${ok ? "✅ 可连接" : "❌ 无法连接"}`)',
  '    ? results.map(([label, ok]) => ok ? `${label} TCP ${port}：✅ 可连接` : s.tcp_listen ? `${label} TCP ${port}：⚠️ Cloudflare 当前探测点未连通（不代表公网不可用）` : `${label} TCP ${port}：❌ 本机 TCP 未监听`)',
  'manual probe text'
);

replaceOnce(
  '    : ["没有可用于外部探测的公网地址。"];',
  '    : ["没有可用于外部探测的公网地址。"];\n  lines.push("说明：外部 TCP 探测只代表 Cloudflare 当前出口到该地址的可达性；失败不能证明其它公网客户端也不可达。");',
  'manual probe explanation'
);

writeFileSync(file, source, 'utf8');
console.log('Applied Cloudflare runtime patch 3.7: single QX node, SNI check URL, simplified SNI menu, resilient inbound probe.');
