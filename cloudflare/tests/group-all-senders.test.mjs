import test from 'node:test';
import assert from 'node:assert/strict';
import {groupUpdate} from '../src/groups.js';

const CHAT='-100123456789';

function fixture(){
  const calls=[];
  const audits=[];
  const claims=new Set();
  const rule={id:'rule1',chat_id:CHAT,kind:'keyword',pattern:'spam',action:'ban'};
  const statement=(sql,args=[])=>({
    bind(...values){return statement(sql,values);},
    async first(){
      if(sql.includes('SELECT * FROM bot_groups')) return {chat_id:CHAT,title:'测试群',enabled:1};
      if(sql.includes('SELECT config FROM group_policy')) return {config:'{}'};
      if(sql.includes('INSERT OR IGNORE INTO group_events')) {
        const key=String(args[0]);
        if(claims.has(key)) return {meta:{changes:0}};
        claims.add(key);return {meta:{changes:1}};
      }
      throw new Error(`unexpected first: ${sql}`);
    },
    async all(){
      if(sql.includes('SELECT * FROM group_rules')) return {results:[rule]};
      throw new Error(`unexpected all: ${sql}`);
    },
    async run(){
      if(sql.includes('INSERT OR IGNORE INTO group_events')) {
        const key=String(args[0]);
        if(claims.has(key)) return {meta:{changes:0}};
        claims.add(key);return {meta:{changes:1}};
      }
      if(sql.includes('INSERT INTO group_audit')) {audits.push({target:String(args[2]),action:String(args[3])});return {meta:{changes:1}};}
      if(sql.includes('INSERT OR IGNORE INTO settings')) return {meta:{changes:1}};
      throw new Error(`unexpected run: ${sql}`);
    }
  });
  const env={DB:{prepare:statement}};
  const h={
    nowSeconds:()=>1700000000,
    escapeHtml:x=>String(x),
    targetsBot:()=>false,
    normalize:m=>String(m.text||''),
    can:(access,role)=>role==='admin' && Number(access?.rank||0)>=3,
    accessFor:async(_env,uid)=>String(uid)==='22222'?{role:'admin',rank:3}:null,
    tg:async(_env,method,payload)=>{
      calls.push({method,...payload});
      if(method==='getChatMember') return {status:'member'};
      if(method==='sendMessage') return {message_id:999};
      return true;
    }
  };
  const msg=(id,text,extra={})=>({message_id:id,chat:{id:Number(CHAT),type:'supergroup'},text,...extra});
  return {env,h,calls,audits,msg};
}

test('configured rules still delete matching Telegram admin messages without banning the admin',async()=>{
  const f=fixture();
  const handled=await groupUpdate({message:f.msg(10,'spam',{from:{id:22222,first_name:'管理员'}})},f.env,f.h);
  assert.equal(handled,true);
  assert.equal(f.calls.filter(x=>x.method==='deleteMessage').length,1);
  assert.equal(f.calls.filter(x=>x.method==='banChatMember').length,0);
  assert.equal(f.audits.at(-1).action,'keyword:ban->delete');
});

test('anonymous administrators are filtered even though Telegram exposes sender_chat instead of real user',async()=>{
  const f=fixture();
  const handled=await groupUpdate({message:f.msg(11,'spam',{
    from:{id:1087968824,is_bot:true,first_name:'GroupAnonymousBot'},
    sender_chat:{id:Number(CHAT),title:'测试群',type:'supergroup'}
  })},f.env,f.h);
  assert.equal(handled,true);
  assert.equal(f.calls.filter(x=>x.method==='deleteMessage').length,1);
  assert.equal(f.calls.filter(x=>x.method==='banChatMember').length,0);
  assert.match(f.audits.at(-1).target,/^sender_chat:/);
});

test('ordinary members still receive the configured punitive action',async()=>{
  const f=fixture();
  await groupUpdate({message:f.msg(12,'spam',{from:{id:55555,first_name:'普通成员'}})},f.env,f.h);
  assert.equal(f.calls.filter(x=>x.method==='deleteMessage').length,1);
  assert.equal(f.calls.filter(x=>x.method==='banChatMember').length,1);
  assert.equal(f.audits.at(-1).action,'keyword:ban');
});

test('unmatched anonymous messages are consumed silently and cannot reach Bot controls',async()=>{
  const f=fixture();
  f.env.DB.prepare=(sql,args=[])=>({
    bind(...values){return f.env.DB.prepare(sql,values);},
    async first(){if(sql.includes('SELECT * FROM bot_groups'))return {chat_id:CHAT,enabled:1};if(sql.includes('SELECT config FROM group_policy'))return {config:'{}'};throw new Error(sql);},
    async all(){if(sql.includes('SELECT * FROM group_rules'))return {results:[]};throw new Error(sql);},
    async run(){throw new Error(sql);}
  });
  const handled=await groupUpdate({message:f.msg(13,'hello',{
    from:{id:1087968824,is_bot:true},sender_chat:{id:Number(CHAT),title:'测试群',type:'supergroup'}
  })},f.env,f.h);
  assert.equal(handled,true);
  assert.equal(f.calls.length,0);
});
