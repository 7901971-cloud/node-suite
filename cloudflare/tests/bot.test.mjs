import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {groupUpdate,groupCallback,groupMaintenance,matchRule} from '../src/groups.js';

// Use real SQLite for D1 SQL, with Telegram and outbound TCP mocked. Never touches live users/devices.
let source=readFileSync(new URL('../src/index.js',import.meta.url),'utf8');
source=source.replace('import { connect } from "cloudflare:sockets";', 'const connect = () => { throw new Error("TCP disabled in tests"); };');
source=source.replace("from './groups.js'",`from '${new URL('../src/groups.js',import.meta.url).href}'`);
source+='\nexport {accessFor,initializeAdmins,rootKeyboard,commandRole,consumePendingInput,savePendingInput,handleMessage,handleCallback,groupServices,enqueueDeviceCommand,pollDeviceCommand,sha256Hex,createPairCode,notifyOwnersProtected,renameDevice,renameDeviceScript,renameNodeText,validDeviceName,receiveReport,showProbe,updateInboundStatus,inboundAlerts};';
const bot=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const sql=readFileSync(new URL('../schema.sql',import.meta.url),'utf8');
const CHAT='-100123456789',OWNER='11111',ADMIN='22222',OP='33333',VIEW='44444',STRANGER='55555';
function fixture(){
  const db=new DatabaseSync(':memory:');db.exec(sql);db.exec(sql);
  const wrap=(q,args=[])=>({bind(...values){return wrap(q,values);},async first(){return db.prepare(q).get(...args)||null;},async all(){return {results:db.prepare(q).all(...args)};},async run(){const r=db.prepare(q).run(...args);return {meta:{changes:Number(r.changes)}};}});
  const env={DB:{prepare:wrap,async batch(stmts){db.exec('BEGIN');try{const r=[];for(const s of stmts)r.push(await s.run());db.exec('COMMIT');return r;}catch(e){db.exec('ROLLBACK');throw e;}}},OWNER_TELEGRAM_IDS:OWNER,TELEGRAM_BOT_USERNAME:'MyNodeBot',TELEGRAM_BOT_TOKEN:'test',TELEGRAM_WEBHOOK_SECRET:'test',DATA_ENCRYPTION_KEY:Buffer.alloc(32,1).toString('base64'),PUBLIC_GATEWAY_URL:'https://example.pages.dev'};
  const calls=[],native=new Set(),failures=new Set();
  globalThis.fetch=async(url,opt)=>{
    assert.match(String(url),/^https:\/\/api\.telegram\.org\/bottest\//);
    const method=String(url).split('/').at(-1),payload=JSON.parse(opt.body);calls.push({method,...payload});
    if(failures.has(method))return Response.json({ok:false,description:'mock missing permission'},{status:403});
    let result=true;
    if(method==='getMe') result={id:99999,username:'MyNodeBot'};
    if(method==='getChat') result={id:Number(payload.chat_id),title:'测试群',type:'supergroup',permissions:{can_send_messages:true,can_send_photos:true}};
    if(method==='getChatMember') result={status:Number(payload.user_id)===99999||native.has(String(payload.user_id))?'administrator':'member',can_delete_messages:true,can_restrict_members:true};
    if(['sendMessage','editMessageText'].includes(method))result={message_id:calls.length,chat:{id:payload.chat_id}};
    return Response.json({ok:true,result});
  };
  const user=(id,role)=>db.prepare('INSERT OR REPLACE INTO bot_users VALUES(?,?,?,?,?,1)').run(id,role,OWNER,1,1);
  const enable=(all=false)=>db.prepare("INSERT OR REPLACE INTO bot_groups VALUES(?,? ,?,'viewer',?,1,1,1)").run(CHAT,'测试群',all?'all':'members',OWNER);
  const message=(uid,text,other={})=>({message_id:12,from:{id:Number(uid),first_name:'测试'},chat:{id:Number(CHAT),type:'supergroup'},text,...other});
  const callback=(uid,data)=>({id:'cb',from:{id:Number(uid)},message:message(uid,''),data});
  const access=(uid,group=true)=>bot.accessFor(env,uid,{id:group?CHAT:uid,type:group?'supergroup':'private'});
  const policy=p=>db.prepare('INSERT OR REPLACE INTO group_policy VALUES(?,?,1)').run(CHAT,JSON.stringify(p));
  return {db,env,calls,native,failures,user,enable,message,callback,access,policy};
}
async function base(){const f=fixture();await bot.initializeAdmins(f.env);f.user(ADMIN,'admin');f.user(OP,'operator');f.user(VIEW,'viewer');f.enable();return f;}

test('unified admin/operator/viewer work privately and in enabled groups only',async()=>{
  const f=await base();for(const [id,role] of [[OWNER,'admin'],[ADMIN,'admin'],[OP,'operator'],[VIEW,'viewer']]){
    assert.equal((await f.access(id)).role,role);assert.equal((await f.access(id,false)).role,role);
  }
  assert.equal(await f.access(STRANGER),null);
  f.enable(true);assert.equal((await f.access(STRANGER)).role,'viewer');assert.equal((await f.access(ADMIN)).role,'admin');
  f.db.exec('UPDATE bot_groups SET enabled=0');assert.equal(await f.access(ADMIN),null);assert.equal(await f.access(OWNER),null);
});
test('legacy roles migrate once; group-all control closes; bootstrap admin can be removed',async()=>{
  const f=fixture();f.enable();f.db.exec("UPDATE bot_groups SET role='operator',access_mode='all'");
  f.db.prepare('INSERT INTO bot_group_members VALUES(?,?,?,?,1)').run(CHAT,ADMIN,'admin',OWNER);
  await bot.initializeAdmins(f.env);assert.equal((await f.access(ADMIN,false)).role,'admin');assert.equal(await f.access(STRANGER),null);
  f.db.prepare('DELETE FROM bot_users WHERE user_id=?').run(OWNER);await bot.initializeAdmins(f.env);assert.equal(await f.access(OWNER,false),null);
});
test('all administrators can add, demote and delete admins; last admin is protected',async()=>{
  const f=await base();
  async function input(actor,action,data,text){await bot.savePendingInput(f.env,actor,action,{...data,chat:CHAT});await bot.consumePendingInput(f.message(actor,text),f.env,await f.access(actor));}
  await input(ADMIN,'user_add',{role:'admin'},STRANGER);assert.equal((await f.access(STRANGER)).role,'admin');
  await input(ADMIN,'user_delete',{},OWNER);assert.equal(await f.access(OWNER),null);
  await input(ADMIN,'user_add',{role:'viewer'},STRANGER);assert.equal((await f.access(STRANGER)).role,'viewer');
  await input(ADMIN,'user_delete',{},ADMIN);assert.equal((await f.access(ADMIN)).role,'admin');
  await input(ADMIN,'user_add',{role:'viewer'},ADMIN);assert.equal((await f.access(ADMIN)).role,'admin');
});
test('pending inputs bind chat and recheck permission; operators cannot grant roles',async()=>{
  const f=await base();await bot.savePendingInput(f.env,ADMIN,'user_add',{role:'admin',chat:CHAT});
  assert.equal(await bot.consumePendingInput({...f.message(ADMIN,STRANGER),chat:{id:Number(ADMIN),type:'private'}},f.env,await f.access(ADMIN,false)),false);
  f.user(ADMIN,'operator');assert.equal(await bot.consumePendingInput(f.message(ADMIN,STRANGER),f.env,await f.access(ADMIN)),false);
  assert.equal(await f.access(STRANGER),null);
});
test('menus separate node/Bot; Pages appears with pairing code',async()=>{
  const f=await base();const a=await f.access(ADMIN),v=await f.access(VIEW);
  assert.equal(bot.rootKeyboard(a).inline_keyboard.flat().length,2);assert.equal(bot.rootKeyboard(v).inline_keyboard.flat().length,1);
  await bot.createPairCode(f.env,ADMIN,1,ADMIN);assert.match(f.calls.at(-1).text,/https:\/\/example.pages.dev/);assert.match(f.calls.at(-1).text,/配对码/);
});
test('operator may configure/reboot/shell; viewer cannot enqueue modifying commands',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa';f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json) VALUES(?,?,?,1,?)").run(id,'demo','hash',JSON.stringify({node_config:true}));
  for(const action of ['shell','reboot','restart_singbox','node_config']){
    const payload=action==='shell'?'uname -a':action==='node_config'?'{"field":"sni","value":"www.apple.com"}':'';
    await bot.enqueueDeviceCommand(f.env,VIEW,null,id,action,payload,VIEW,false,'',await f.access(VIEW));
    assert.equal(f.db.prepare('SELECT COUNT(*) n FROM device_commands').get().n,0);
    await bot.enqueueDeviceCommand(f.env,OP,null,id,action,payload,OP,false,'',await f.access(OP));
    assert.equal(f.db.prepare('SELECT COUNT(*) n FROM device_commands').get().n,1);f.db.exec('DELETE FROM device_commands');
  }
});
test('group /router@bot normalization passes intact shell payload',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa';f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json) VALUES(?,?,?,1,'{}')").run(id,'demo','hash');
  await bot.handleMessage(f.message(OP,`/router@MyNodeBot ${id} shell printf hello`),f.env,await f.access(OP));
  assert.equal(f.db.prepare('SELECT action FROM device_commands').get().action,'shell');
});
test('queued commands are cancelled after requester loses control permission',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa',token='x'.repeat(40),hash=await bot.sha256Hex(token);
  f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json) VALUES(?,?,?,1,'{}')").run(id,'demo',hash);
  await bot.enqueueDeviceCommand(f.env,OP,null,id,'shell','uname -a',OP,false,'',await f.access(OP));f.user(OP,'viewer');
  const request=new Request('https://test/api/v1/command/poll',{method:'POST',headers:{'x-device-id':id,authorization:`Bearer ${token}`}});
  assert.equal((await (await bot.pollDeviceCommand(request,f.env)).json()).command,null);
  assert.equal(f.db.prepare('SELECT status FROM device_commands').get().status,'cancelled');
});
test('downgraded requester does not receive privileged command output',async()=>{
  const f=await base();await bot.notifyOwnersProtected(f.env,'result',JSON.stringify({user:VIEW,chat:VIEW}),null,'operator');
  assert.ok(!f.calls.some(c=>c.method==='sendMessage'&&String(c.chat_id)===VIEW));
});
test('old group all-control buttons cannot grant rights and non-admin callbacks cannot change policy',async()=>{
  const f=await base();await bot.handleCallback(f.callback(ADMIN,'rn:perm:ga:all:operator'),f.env,await f.access(ADMIN));
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM bot_pending_inputs').get().n,0);
  await groupCallback(f.callback(OP,`gm:read:${CHAT}:1`),f.env,await f.access(OP),bot.groupServices);
  assert.equal(await f.access(STRANGER),null);
});
test('group-wide readonly toggle never overrides admin or operator',async()=>{
  const f=await base();await groupCallback(f.callback(ADMIN,`gm:read:${CHAT}:1`),f.env,await f.access(ADMIN),bot.groupServices);
  assert.equal((await f.access(STRANGER)).role,'viewer');assert.equal((await f.access(OP)).role,'operator');
  await groupCallback(f.callback(ADMIN,`gm:read:${CHAT}:0`),f.env,await f.access(ADMIN),bot.groupServices);assert.equal(await f.access(STRANGER),null);
});
test('ordinary messages do not trigger menus; false mentions do not match',async()=>{
  const f=await base();assert.equal(bot.groupServices.targetsBot(f.message(VIEW,'@MyNodeBotFake'),f.env),false);
  assert.equal(bot.groupServices.targetsBot(f.message(VIEW,'/start@MYNODEBOT'),f.env),true);
  const request=new Request('https://test/telegram/webhook',{method:'POST',headers:{'x-telegram-bot-api-secret-token':'test','content-type':'application/json'},body:JSON.stringify({message:f.message(VIEW,'普通聊天')})});
  assert.equal((await bot.default.fetch(request,f.env,{waitUntil(){}})).status,200);assert.equal(f.calls.length,0);
});
test('filter catches caption links, forwarded messages, keywords with zero width; regex is literal',()=>{
  assert.ok(matchRule({kind:'link'},{caption:'广告',caption_entities:[{type:'text_link',url:'https://example.com'}]}));
  assert.ok(matchRule({kind:'keyword',pattern:'spam'},{text:'ＳＰ\u200bＡＭ'}));
  assert.ok(!matchRule({kind:'keyword',pattern:'.*'},{text:'anything'}));
  assert.ok(matchRule({kind:'forward'},{forward_origin:{type:'user'}}));
});
test('unmentioned stranger spam is removed; admins are exempt; duplicate delivery is not punished twice',async()=>{
  const f=await base();f.db.prepare('INSERT INTO group_rules VALUES(?,?,?,?,?)').run('abc',CHAT,'keyword','spam','ban');
  const update={message:f.message(STRANGER,'spam')};await groupUpdate(update,f.env,bot.groupServices);await groupUpdate(update,f.env,bot.groupServices);
  assert.equal(f.calls.filter(c=>c.method==='banChatMember').length,1);
  await groupUpdate({message:f.message(ADMIN,'spam',{message_id:13})},f.env,bot.groupServices);assert.equal(f.calls.filter(c=>c.method==='banChatMember').length,1);
});
test('native group admins can moderate but cannot access node control',async()=>{
  const f=await base();f.native.add(STRANGER);assert.equal(await f.access(STRANGER),null);
  await groupUpdate({message:f.message(STRANGER,`/ban@MyNodeBot ${VIEW}`)},f.env,bot.groupServices);
  assert.ok(f.calls.some(c=>c.method==='banChatMember'&&String(c.user_id)===VIEW));
});
test('auto moderation errors are surfaced and do not produce a success audit',async()=>{
  const f=await base();f.failures.add('deleteMessage');f.db.prepare('INSERT INTO group_rules VALUES(?,?,?,?,?)').run('abc',CHAT,'photo','','delete');
  await groupUpdate({message:f.message(STRANGER,'',{photo:[{}]})},f.env,bot.groupServices);
  assert.ok(f.calls.some(c=>c.text?.includes('管群操作未完成')));assert.equal(f.db.prepare('SELECT COUNT(*) n FROM group_audit').get().n,0);
});
function join(f,id=STRANGER){return {chat_member:{chat:{id:Number(CHAT),type:'supergroup'},old_chat_member:{status:'left'},new_chat_member:{status:'member',user:{id:Number(id),first_name:'新人'}}}};}
test('captcha: restrict, reject other users, verify correct answer, no bot access granted',async()=>{
  const f=await base();f.policy({verify:true});await groupUpdate(join(f),f.env,bot.groupServices);
  const row=f.db.prepare('SELECT * FROM group_challenges').get();assert.ok(row);
  await groupUpdate({callback_query:f.callback(VIEW,`verify:${row.nonce}:${row.answer}`)},f.env,bot.groupServices);
  assert.equal(f.db.prepare('SELECT state FROM group_challenges').get().state,'pending');
  await groupUpdate({callback_query:f.callback(STRANGER,`verify:${row.nonce}:${row.answer}`)},f.env,bot.groupServices);
  assert.equal(f.db.prepare('SELECT state FROM group_challenges').get().state,'verified');assert.equal(await f.access(STRANGER),null);
  const last=f.calls.filter(c=>c.method==='restrictChatMember').at(-1);assert.equal(last.permissions.can_send_messages,true);assert.equal(last.permissions.can_send_videos,false);
});
test('captcha timeout removes only unverified user; cron and duplicate callbacks are idempotent',async()=>{
  const f=await base();f.policy({verify:true});await groupUpdate(join(f),f.env,bot.groupServices);
  f.db.exec('UPDATE group_challenges SET expires_at=0');await groupMaintenance(f.env,bot.groupServices);await groupMaintenance(f.env,bot.groupServices);
  assert.equal(f.calls.filter(c=>c.method==='banChatMember').length,1);assert.equal(f.db.prepare('SELECT state FROM group_challenges').get().state,'closed');
});
test('turning verification off releases pending newcomers, no ban',async()=>{
  const f=await base();f.policy({verify:true});await groupUpdate(join(f),f.env,bot.groupServices);
  await groupCallback(f.callback(ADMIN,`gm:verify:${CHAT}:0`),f.env,await f.access(ADMIN),bot.groupServices);
  assert.equal(f.db.prepare('SELECT state FROM group_challenges').get().state,'closed');assert.equal(f.calls.filter(c=>c.method==='banChatMember').length,0);
});
test('edited messages are filtered but never run administrative commands',async()=>{
  const f=await base();await groupUpdate({edited_message:f.message(ADMIN,`/ban@MyNodeBot ${STRANGER}`)},f.env,bot.groupServices);
  assert.ok(!f.calls.some(c=>c.method==='banChatMember'));
});
test('enabling moderation validates bot rights before changing config',async()=>{
  const f=await base();f.failures.add('getChatMember');await groupCallback(f.callback(ADMIN,`gm:verify:${CHAT}:1`),f.env,await f.access(ADMIN),bot.groupServices);
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM group_policy').get().n,0);
});
test('telegram webhook retry does not enqueue the same command twice',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa';f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json) VALUES(?,?,?,1,'{}')").run(id,'demo','hash');
  const update={update_id:321,message:{...f.message(OP,`/router ${id} shell uname -a`),chat:{id:Number(OP),type:'private'}}};
  const request=()=>new Request('https://test/telegram/webhook',{method:'POST',headers:{'x-telegram-bot-api-secret-token':'test','content-type':'application/json'},body:JSON.stringify(update)});
  await bot.default.fetch(request(),f.env,{waitUntil(){}});await bot.default.fetch(request(),f.env,{waitUntil(){}});
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM device_commands').get().n,1);
});
test('captcha three wrong answers expire challenge; later correct answer cannot bypass',async()=>{
  const f=await base();f.policy({verify:true});await groupUpdate(join(f),f.env,bot.groupServices);const row=f.db.prepare('SELECT * FROM group_challenges').get();
  for(let n=0;n<3;n++)await groupUpdate({callback_query:f.callback(STRANGER,`verify:${row.nonce}:0`)},f.env,bot.groupServices);
  await groupUpdate({callback_query:f.callback(STRANGER,`verify:${row.nonce}:${row.answer}`)},f.env,bot.groupServices);
  assert.equal(f.db.prepare('SELECT state FROM group_challenges').get().state,'pending');assert.equal(f.db.prepare('SELECT expires_at FROM group_challenges').get().expires_at,0);
});
test('group policy rejects forged fields and cross-group rule deletion',async()=>{
  const f=await base();f.db.prepare('INSERT INTO group_rules VALUES(?,?,?,?,?)').run('1234567890abcdef','-100999999999','keyword','spam','delete');
  await groupCallback(f.callback(ADMIN,`gm:delrule:${CHAT}:1234567890abcdef`),f.env,await f.access(ADMIN),bot.groupServices);
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM group_rules').get().n,1);
  await groupCallback(f.callback(ADMIN,`gm:read:${CHAT}:admin`),f.env,await f.access(ADMIN),bot.groupServices);assert.equal(await f.access(STRANGER),null);
});
test('disabled group is silent even for global admin commands',async()=>{
  const f=await base();f.db.exec('UPDATE bot_groups SET enabled=0');
  const handled=await groupUpdate({message:f.message(ADMIN,`/ban@MyNodeBot ${STRANGER}`)},f.env,bot.groupServices);
  assert.equal(handled,true);assert.equal(f.calls.length,0);
});
test('flood threshold mutes once it exceeds 8 messages; switch off does nothing',async()=>{
  const f=await base();f.policy({flood:true});for(let i=0;i<9;i++)await groupUpdate({message:f.message(STRANGER,'hello',{message_id:100+i})},f.env,bot.groupServices);
  assert.equal(f.calls.filter(c=>c.method==='restrictChatMember').length,1);
  f.policy({flood:false});await groupUpdate({message:f.message(STRANGER,'hello',{message_id:120})},f.env,bot.groupServices);assert.equal(f.calls.filter(c=>c.method==='restrictChatMember').length,1);
});
test('unauthorized user can retrieve only own ID in private chat',async()=>{
  const f=await base();const request=new Request('https://test/telegram/webhook',{method:'POST',headers:{'x-telegram-bot-api-secret-token':'test','content-type':'application/json'},body:JSON.stringify({message:{...f.message(STRANGER,'/id'),chat:{id:Number(STRANGER),type:'private'}}})});
  await bot.default.fetch(request,f.env,{waitUntil(){}});assert.match(f.calls.at(-1).text,new RegExp(STRANGER));assert.equal(await f.access(STRANGER,false),null);
});

test('rename is restricted, unique and survives old device reports',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa',token='x'.repeat(40);
  f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json) VALUES(?,?,?,1,'{}')").run(id,'旧名',await bot.sha256Hex(token));
  await bot.renameDevice(f.env,f.message(VIEW,'新名'),id,'新名',await f.access(VIEW));
  assert.equal(f.db.prepare('SELECT name FROM devices').get().name,'旧名');
  await bot.handleCallback(f.callback(OP,`rn:rename:${id}`),f.env,await f.access(OP));
  await bot.consumePendingInput(f.message(OP,'🇨🇳重庆2'),f.env,await f.access(OP));
  assert.equal(f.db.prepare('SELECT name FROM devices').get().name,'🇨🇳重庆2');
  assert.equal(f.db.prepare('SELECT action FROM device_commands').get().action,'shell');
  const form=new FormData();form.set('device_name','旧名');
  const response=await bot.receiveReport(new Request('https://test/api/v1/report',{method:'POST',headers:{'x-device-id':id,authorization:`Bearer ${token}`},body:form}),f.env);
  assert.equal(response.status,200);
  assert.equal(f.db.prepare('SELECT name FROM devices').get().name,'🇨🇳重庆2');
  f.db.exec('DELETE FROM device_commands');
  f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at) VALUES('bbbbbbbbbbbbbbbb','占用','another',1)").run();
  await bot.renameDevice(f.env,f.message(OP,'占用'),id,'占用',await f.access(OP));
  assert.equal(f.db.prepare('SELECT name FROM devices WHERE id=?').get(id).name,'🇨🇳重庆2');
  assert.equal(f.db.prepare('SELECT COUNT(*) n FROM device_commands').get().n,0);
});

test('node names preserve connection parameters and reject malformed names',()=>{
  const name="🇨🇳 O'Reilly $() &";
  assert.ok(bot.validDeviceName(name));
  for(const bad of ['', 'x,y','x\ny','a'.repeat(49)])assert.equal(bot.validDeviceName(bad),false);
  assert.equal(bot.renameNodeText('vless=host:38444, password=uuid, tag=old\nvless://uuid@host:38444?security=reality#old',name),`vless=host:38444, password=uuid, tag=${name}\nvless://uuid@host:38444?security=reality#${encodeURIComponent(name)}`);
});

test('failed probe replaces previous success and appears in abnormal device state',async()=>{
  const f=await base(),id='aaaaaaaaaaaaaaaa';
  const status={public4:'8.8.8.8',ss_port:38444,tcp_listen:true,inbound4:'reachable'};
  f.db.prepare("INSERT INTO devices(id,name,token_hash,created_at,status_json,last_seen) VALUES(?,?,?,1,?,?)").run(id,'probe','hash',JSON.stringify(status),Math.floor(Date.now()/1000));
  await bot.showProbe(f.env,OP,1,id,await f.access(OP));
  const device=f.db.prepare('SELECT * FROM devices').get();
  assert.equal(JSON.parse(device.status_json).inbound4,'blocked');
  assert.deepEqual(JSON.parse(device.active_alerts),['inbound4']);
  assert.equal(f.db.prepare("SELECT active FROM alerts WHERE code='inbound4'").get().active,1);
});
