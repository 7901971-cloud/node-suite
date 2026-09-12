import { readFileSync, writeFileSync } from 'node:fs';

const file = new URL('./src/index.js', import.meta.url);
let source = readFileSync(file, 'utf8');
const marker = '// NODE_SUITE_TG_NODE_V37';
if (source.includes(marker)) process.exit(0);

function once(needle, replacement, label) {
  const count = source.split(needle).length - 1;
  if (count !== 1) throw new Error(`${label}: expected 1 anchor, found ${count}`);
  source = source.replace(needle, replacement);
}
const lines = (...v) => v.join('\n');

once('const VERSION = "3.6.0";', lines('const VERSION = "3.7.0";', marker), 'version');
once(
  '  const entries = extractCopyableNodeEntries(nodeText);',
  lines(
    '  const entries = extractCopyableNodeEntries(nodeText)',
    '    .filter((entry) => /^vless=/i.test(entry.value))',
    '    .slice(0, 1)',
    '    .map((entry) => ({ ...entry, label: "Quantumult X 整行导入", value: withSniCheckUrl(entry.value) }));'
  ), 'node list');
once('function extractCopyableNodeEntries(nodeText) {', lines(
  'function withSniCheckUrl(value) {',
  '  const text = String(value || "").trim();',
  '  const match = text.match(/(?:^|,\\s*)obfs-host=([^,\\s]+)/i);',
  '  if (!/^vless=/i.test(text) || !match) return text;',
  '  const host = match[1].trim();',
  '  if (!/^([a-z\\d]([a-z\\d-]*[a-z\\d])?\\.)+[a-z]{2,63}$/i.test(host)) return text;',
  '  const field = `server_check_url=http://${host}/generate_204`;',
  '  if (/(?:^|,\\s*)server_check_url=/i.test(text)) return text.replace(/,\\s*server_check_url=[^,]+/i, `, ${field}`);',
  '  if (/,\\s*tag=/i.test(text)) return text.replace(/,\\s*tag=/i, `, ${field}, tag=`);',
  '  return `${text}, ${field}`;',
  '}', '', 'function extractCopyableNodeEntries(nodeText) {'
), 'check url helper');

once("const NODE_FIELDS = { sni: 'SNI', target: 'REALITY 目标', port: '节点端口', uuid: 'UUID', keys: 'REALITY 密钥', shortid: 'Short ID' };",
     "const NODE_FIELDS = { sni: '修改 SNI', target: 'REALITY 目标', port: '节点端口', uuid: 'UUID', keys: 'REALITY 密钥', shortid: 'Short ID' };", 'field title');
once("      [{text:'更换 SNI',callback_data:`rn:cfgi:${id}:sni`},{text:'更换目标',callback_data:`rn:cfgi:${id}:target`}],",
     "      [{text:'修改 SNI',callback_data:`rn:cfgi:${id}:sni`}],", 'SNI menu');
once("    const hint = field === 'sni' ? '请输入域名（目标同步为该域名:443）。' : field === 'target' ? '请输入域名:端口（保留 SNI）。' : field === 'port' ? '请输入端口 1–65535。' : '请输入新值，或发送 random 随机生成。';",
     "    const hint = field === 'sni' ? '请输入域名。' : field === 'target' ? '请输入域名:端口（保留 SNI）。' : field === 'port' ? '请输入端口 1–65535。' : '请输入新值，或发送 random 随机生成。';", 'SNI prompt');

const probeRe = /async function probeTcp\(host, port\) \{[\s\S]*?\n\}\n\nfunction isPublicIPv4/;
if (!probeRe.test(source)) throw new Error('probe function anchor missing');
source = source.replace(probeRe, lines(
  'async function probeTcp(host, port, attempts = 3) {',
  '  if (!host || port < 1 || port > 65535) return false;',
  '  for (let attempt = 0; attempt < attempts; attempt += 1) {',
  '    let socket;',
  '    try {',
  '      socket = connect({ hostname: host, port }, { secureTransport: "off" });',
  '      await Promise.race([socket.opened, new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 2500))]);',
  '      return true;',
  '    } catch (_) {',
  '      // One Cloudflare egress failure is not proof that every Internet client is blocked.',
  '    } finally { try { socket?.close(); } catch (_) {} }',
  '    if (attempt + 1 < attempts) await new Promise((resolve) => setTimeout(resolve, 150));',
  '  }',
  '  return false;',
  '}', '', 'function isPublicIPv4'
));

once(
  '  return value === "reachable" ? "✅ 公网可连接" : value === "blocked" ? "❌ TCP 入站未通过" : value === "none" ? "无公网地址" : "等待外部检测";',
  '  return value === "reachable" ? "✅ 公网可连接" : value === "blocked" ? "❌ 本机 TCP 未监听" : value === "unverified" ? "⚠️ 外部探测未确认" : value === "none" ? "无公网地址" : "等待外部检测";',
  'inbound label');
once('}\n\nfunction detectedNetworkType(status) {', lines(
  '}', '',
  'function failedProbeState(previous, localListening) {',
  '  if (previous === "reachable") return "reachable";',
  '  return localListening ? "unverified" : "blocked";',
  '}', '',
  'function detectedNetworkType(status) {'
), 'failed probe helper');
once('  const state4 = has4 ? (ok4 ? "公网入站已验证" : status.inbound4 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "上级 NAT 或未确认";',
     '  const state4 = has4 ? (ok4 ? "公网入站已验证" : status.inbound4 === "blocked" ? "本机 TCP 未监听" : status.inbound4 === "unverified" ? "公网地址/本机监听正常，外部探测未确认" : "等待外部检测") : "上级 NAT 或未确认";', 'IPv4 state');
once('  const state6 = has6 ? (ok6 ? "公网入站已验证" : status.inbound6 === "blocked" ? "TCP 入站未通过" : "等待外部检测") : "无公网地址";',
     '  const state6 = has6 ? (ok6 ? "公网入站已验证" : status.inbound6 === "blocked" ? "本机 TCP 未监听" : status.inbound6 === "unverified" ? "公网地址/本机监听正常，外部探测未确认" : "等待外部检测") : "无公网地址";', 'IPv6 state');

once('  const port = numberValue(status.ss_port);\n  status.inbound4 = isPublicIPv4(status.public4) ? (previous.inbound4 || "pending") : "none";\n  status.inbound6 = isPublicIPv6(status.public6) ? (previous.inbound6 || "pending") : "none";', lines(
  '  const port = numberValue(status.ss_port);',
  '  const previousPort = numberValue(previous.ss_port);',
  '  const previous4 = status.public4 === previous.public4 && port === previousPort ? previous.inbound4 : "";',
  '  const previous6 = status.public6 === previous.public6 && port === previousPort ? previous.inbound6 : "";',
  '  status.inbound4 = isPublicIPv4(status.public4) ? (previous4 || "pending") : "none";',
  '  status.inbound6 = isPublicIPv6(status.public6) ? (previous6 || "pending") : "none";'
), 'status initialization');
once('status.inbound4 = ok ? "reachable" : "blocked";', 'status.inbound4 = ok ? "reachable" : failedProbeState(previous4, status.tcp_listen);', 'IPv4 probe result');
once('status.inbound6 = ok ? "reachable" : "blocked";', 'status.inbound6 = ok ? "reachable" : failedProbeState(previous6, status.tcp_listen);', 'IPv6 probe result');

once('s.inbound4 = isPublicIPv4(s.public4) ? (results.find(([label]) => label === "IPv4")?.[1] ? "reachable" : "blocked") : "none";',
     's.inbound4 = isPublicIPv4(s.public4) ? (results.find(([label]) => label === "IPv4")?.[1] ? "reachable" : failedProbeState(s.inbound4, s.tcp_listen)) : "none";', 'manual IPv4 result');
once('s.inbound6 = isPublicIPv6(s.public6) ? (results.find(([label]) => label === "IPv6")?.[1] ? "reachable" : "blocked") : "none";',
     's.inbound6 = isPublicIPv6(s.public6) ? (results.find(([label]) => label === "IPv6")?.[1] ? "reachable" : failedProbeState(s.inbound6, s.tcp_listen)) : "none";', 'manual IPv6 result');
once('    ? results.map(([label, ok]) => `${label} TCP ${port}：${ok ? "✅ 可连接" : "❌ 无法连接"}`)',
     '    ? results.map(([label, ok]) => ok ? `${label} TCP ${port}：✅ 可连接` : s.tcp_listen ? `${label} TCP ${port}：⚠️ Cloudflare 当前探测点未连通（不代表公网不可用）` : `${label} TCP ${port}：❌ 本机 TCP 未监听`)', 'manual probe text');
once('    : ["没有可用于外部探测的公网地址。"];', lines(
  '    : ["没有可用于外部探测的公网地址。"];',
  '  lines.push("说明：外部 TCP 探测只代表 Cloudflare 当前出口到该地址的可达性；失败不能证明其它公网客户端也不可达。");'
), 'manual probe explanation');

writeFileSync(file, source, 'utf8');
console.log('Applied Cloudflare runtime patch 3.7.');
