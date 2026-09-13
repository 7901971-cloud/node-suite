import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,mkdirSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
let source=readFileSync(new URL('../src/index.js',import.meta.url),'utf8')
  .replace('import { connect } from "cloudflare:sockets";', 'const connect = (...args) => globalThis.testConnect(...args);')
  .replace("from './groups.js'", `from '${new URL('../src/groups.js',import.meta.url).href}'`);
source+='\nexport {probeTcp,updateInboundStatus,inboundAlerts,renameDeviceScript};';
const bot=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

test('TCP success, retries, recovery and changed endpoints use current result',async()=>{
  let calls=0,closed=0,writes=0;
  globalThis.testConnect=()=>{
    const current=++calls;
    return {
      opened:current===1?Promise.reject(Error('refused')):Promise.resolve({}),
      closed:Promise.resolve(),
      writable:{getWriter(){return {write(chunk){writes++;assert.deepEqual([...chunk],[0x16]);return current===2?Promise.reject(Error('write failed')):Promise.resolve();},releaseLock(){}};}},
      close(){closed++;return Promise.resolve();}
    };
  };
  assert.equal(await bot.probeTcp('8.8.8.8',38444),true);assert.equal(calls,3);assert.equal(writes,2);assert.equal(closed,3);
  const status={public4:'8.8.8.8',public6:'2606:4700:4700::1111',ss_port:38444};
  await bot.updateInboundStatus(status,{...status,inbound4:'blocked',inbound6:'blocked'},true);
  assert.equal(status.inbound4,'reachable');assert.equal(status.inbound6,'reachable');assert.deepEqual(bot.inboundAlerts(status),[]);
  const changed={...status,ss_port:40000};
  await bot.updateInboundStatus(changed,status,false);assert.equal(changed.inbound4,'pending');
});

test('IPv6-only failure is informational while confirmed IPv4 failure can alert',()=>{
  const status={public4:'8.8.8.8',public6:'2606:4700:4700::1111'};
  assert.deepEqual(bot.inboundAlerts({...status,inbound4:'reachable',inbound6:'blocked'}),[]);
  assert.deepEqual(bot.inboundAlerts({...status,inbound4:'blocked',inbound6:'reachable'}),[]);
  assert.deepEqual(bot.inboundAlerts({...status,inbound4:'blocked',inbound6:'pending'}),[]);
  assert.deepEqual(bot.inboundAlerts({...status,inbound4:'blocked',inbound6:'blocked'}),['inbound4']);
  assert.deepEqual(bot.inboundAlerts({public6:status.public6,inbound6:'blocked'}),[]);
  assert.deepEqual(bot.inboundAlerts({public4:status.public4,inbound4:'blocked'}),['inbound4']);
});

test('rename shell synchronizes router and VPS files without evaluating name',()=>{
  for(const type of ['router','vps']){
    const root=mkdtempSync(join(tmpdir(),'rename-test-'));
    try{
      const dir=join(root,'state');mkdirSync(dir);
      const node=join(root,'node.txt');
      writeFileSync(join(dir,'monitor.conf'),"DEVICE_NAME_B64='b2xk'\nDEVICE_TOKEN='keep-token'\n");
      writeFileSync(join(dir,'settings.conf'),"NODE_NAME_B64='b2xk'\nXRAY_UUID='keep-uuid'\n");
      writeFileSync(node,'vless=host:38444, password=uuid, tag=old\nvless://uuid@host:38444?security=reality#old\n');
      const name="🇨🇳 O'Reilly $() &";
      let script=bot.renameDeviceScript(name)
        .replace('/tmp/node-config.flock',join(root,'config.lock'))
        .replace('/tmp/home-suite-install.lock',join(root,'install-dir'))
        .replaceAll('/run/lock',root)
        .replace('/etc/openwrt_release',join(root,'openwrt'))
        .replaceAll('/etc/vless-reality',dir).replaceAll('/etc/home-ss',dir)
        .replaceAll('/root/vless-node-info.txt',node).replaceAll('/root/home-ss-node.txt',node)
        .replaceAll('/usr/local/sbin/vless-reality-monitor','/bin/true').replaceAll('/usr/bin/home-monitor','/bin/true');
      if(type==='router')writeFileSync(join(root,'openwrt'),'test');
      let run=spawnSync('sh',['-c',script],{encoding:'utf8'});assert.equal(run.status,0,run.stderr);
      assert.match(readFileSync(join(dir,'settings.conf'),'utf8'),/XRAY_UUID='keep-uuid'/);
      assert.match(readFileSync(join(dir,'monitor.conf'),'utf8'),/DEVICE_TOKEN='keep-token'/);
      assert.ok(readFileSync(join(dir,'settings.conf'),'utf8').includes(Buffer.from(name).toString('base64')));
      assert.ok(readFileSync(node,'utf8').includes('tag='+name));
      assert.equal(decodeURIComponent(readFileSync(node,'utf8').split('#')[1].trim()),name);
      const before=readFileSync(node,'utf8');
      // Fail after replacing the first config: trap must restore all three originals.
      script=script.replace('mv "$suite_tmp/settings.new" "$suite_dir/settings.conf"','false');
      run=spawnSync('sh',['-c',script],{encoding:'utf8'});assert.notEqual(run.status,0);
      assert.equal(readFileSync(node,'utf8'),before);
    }finally{rmSync(root,{recursive:true,force:true});}
  }
});

test('installer cleanup runs only after successful full installation',()=>{
  for(const path of ['../../router/install-router-complete.sh','../../vps/install-vless-reality-vps.sh']){
    const source=readFileSync(new URL(path,import.meta.url),'utf8');
    const cleanup=source.slice(source.lastIndexOf('# Only reached'));
    const dir=mkdtempSync(join(tmpdir(),'cleanup-test-'));
    try{
      for(const [preflight,fail,deleted] of [[0,false,true],[1,false,false],[0,true,false]]){
        const file=join(dir,'install.sh');writeFileSync(file,`set -e\nPREFLIGHT_ONLY=${preflight}\n${fail?'false':'true'}\n${cleanup}`);
        spawnSync('sh',[file]);assert.equal(existsSync(file),!deleted);
      }
    }finally{rmSync(dir,{recursive:true,force:true});}
  }
});
