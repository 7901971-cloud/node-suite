import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

test('runtime patch exposes one Quantumult X node with SNI-based check URL', () => {
  assert.match(source, /const VERSION = "3\.8\.0";/);
  assert.match(source, /function withSniCheckUrl\(value\)/);
  assert.match(source, /server_check_url=http:\/\/\$\{host\}\/generate_204/);
  assert.match(source, /\.filter\(\(entry\) => \/\^vless=\/i\.test\(entry\.value\)\)/);
  assert.match(source, /\.slice\(0, 1\)/);
});

test('node config menu keeps SNI as the single REALITY target editor', () => {
  assert.match(source, /text:'修改 SNI'/);
  assert.doesNotMatch(source, /text:'更换目标'/);
  assert.match(source, /field === 'sni' \? '请输入域名。'/);
});
