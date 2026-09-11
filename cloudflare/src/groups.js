// Telegram group moderation. No runtime dependency; settings live in D1.
const TYPES = {keyword:'屏蔽词',link:'链接',forward:'转发',photo:'图片',video:'视频',document:'文件',sticker:'贴纸',voice:'语音',animation:'动图'};
const ACTIONS = {delete:'删除',mute:'删除并禁言 1 小时',ban:'删除并封禁'};
const DEFAULTS = {verify:false,flood:false,clean:false,welcome:'',rules:''};
const SEND_PERMISSIONS = ['can_send_messages','can_send_audios','can_send_documents','can_send_photos','can_send_videos','can_send_video_notes','can_send_voice_notes','can_send_polls','can_send_other_messages','can_add_web_page_previews'];
const groupId = x => /^-\d{5,20}$/.test(String(x));
const userId = x => /^[1-9]\d{4,19}$/.test(String(x));
const isGroup = c => ['group','supergroup'].includes(c?.type);
const button = (text, data) => ({text, callback_data:data});
const back = id => [[button('⬅️ 群设置',`gm:open:${id}`)]];
const parse = text => {try{return JSON.parse(text || '{}');}catch{return {};}};

async function enabled(env,id) {
  return env.DB.prepare('SELECT * FROM bot_groups WHERE chat_id=? AND enabled=1').bind(String(id)).first();
}
async function policy(env,id) {
  const row = await env.DB.prepare('SELECT config FROM group_policy WHERE chat_id=?').bind(String(id)).first();
  return {...DEFAULTS,...parse(row?.config)};
}
async function setting(env,id,key,value,h) {
  // JSON_SET avoids overwriting another administrator's unrelated concurrent change.
  await env.DB.prepare(`INSERT INTO group_policy(chat_id,config,updated_at) VALUES(?,json_set('{}',?,json(?)),?)
    ON CONFLICT(chat_id) DO UPDATE SET config=json_set(group_policy.config,?,json(?)),updated_at=excluded.updated_at`)
    .bind(String(id),`$.${key}`,JSON.stringify(value),h.nowSeconds(),`$.${key}`,JSON.stringify(value)).run();
}
async function tell(env,chat,text,h,keyboard) {
  return h.tg(env,'sendMessage',{chat_id:chat,text,parse_mode:'HTML',disable_web_page_preview:true,...(keyboard?{reply_markup:{inline_keyboard:keyboard}}:{})});
}
async function prompt(query,env,action,data,text,h) {
  await h.savePendingInput(env,query.from.id,action,{...data,chat:String(query.message.chat.id)});
  return h.editMenu(env,query.message.chat.id,query.message.message_id,text+'\n\n10 分钟内发送；群内加 @Bot用户名。',
    {inline_keyboard:[[button('取消',data.id?`gm:open:${data.id}`:'gm:list:0')]]});
}
async function nativeAdmin(env,id,uid,h) {
  const member = await h.tg(env,'getChatMember',{chat_id:id,user_id:uid});
  return ['creator','administrator'].includes(member.status);
}
async function protectedUser(env,id,uid,h) {
  const access = await h.accessFor(env,uid,{id,type:'supergroup'});
  return h.can(access,'admin') || await nativeAdmin(env,id,uid,h);
}
async function checkRights(env,id,h,restrict=false) {
  const me = await h.tg(env,'getMe',{});
  const member = await h.tg(env,'getChatMember',{chat_id:id,user_id:me.id});
  if(member.status!=='administrator' || !member.can_delete_messages || (restrict && !member.can_restrict_members)) {
    throw new Error('请先授予 Bot 群管理员的删除消息、限制成员权限。');
  }
  const chat = await h.tg(env,'getChat',{chat_id:id});
  if(restrict && chat.type!=='supergroup') throw new Error('禁言和入群验证需要超级群，请先升级群类型。');
  return chat;
}
export function matchRule(rule,message) {
  const text = String(message.text || message.caption || '').normalize('NFKC').toLocaleLowerCase().replace(/[\u200b-\u200d\ufeff]/g,'');
  if(rule.kind==='keyword') return text.includes(String(rule.pattern).normalize('NFKC').toLocaleLowerCase());
  if(rule.kind==='link') return [...(message.entities||[]),...(message.caption_entities||[])].some(e=>['url','text_link'].includes(e.type)) || /(?:https?:\/\/|www\.|t\.me\/)/i.test(text);
  if(rule.kind==='forward') return !!(message.forward_origin || message.forward_date || message.is_automatic_forward);
  return Object.hasOwn(TYPES,rule.kind) && !!message[rule.kind];
}
async function applyAction(env,id,uid,mid,action,h) {
  // Delete first; a missing Bot permission must not be reported as success.
  if(mid) await h.tg(env,'deleteMessage',{chat_id:id,message_id:mid});
  if(action==='mute') await h.tg(env,'restrictChatMember',{chat_id:id,user_id:uid,permissions:{can_send_messages:false},until_date:h.nowSeconds()+3600,use_independent_chat_permissions:true});
  if(action==='ban') await h.tg(env,'banChatMember',{chat_id:id,user_id:uid,revoke_messages:false});
}
async function release(env,id,uid,h) {
  const chat = await h.tg(env,'getChat',{chat_id:id});
  const permissions = Object.fromEntries(SEND_PERMISSIONS.map(k=>[k,chat.permissions?.[k]===true]));
  await h.tg(env,'restrictChatMember',{chat_id:id,user_id:uid,permissions, use_independent_chat_permissions:true});
}
async function logAction(env,id,actor,target,action,h) {
  await env.DB.prepare('INSERT INTO group_audit(chat_id,actor_id,target_id,action,created_at) VALUES(?,?,?,?,?)')
    .bind(String(id),String(actor||'auto'),String(target||''),action,h.nowSeconds()).run();
}
async function reportFailure(env,id,error,h) {
  // One notice per group per 5 minutes, no message bodies or tokens in the audit log.
  const key=`group-error:${id}:${Math.floor(h.nowSeconds()/300)}`;
  const r=await env.DB.prepare('INSERT OR IGNORE INTO settings(key,value,updated_at) VALUES(?,?,?)').bind(key,'1',h.nowSeconds()).run();
  if(r.meta.changes) await tell(env,id,`管群操作未完成：${h.escapeHtml(String(error.message||error).slice(0,200))}`,h).catch(()=>{});
}

export async function groupPanel(env,chat,mid,id,h) {
  const g=await enabled(env,id);
  if(!g) return h.editMenu(env,chat,mid,'该群未启用。',{inline_keyboard:[[button('群列表','gm:list:0')]]});
  const p=await policy(env,id);
  const on=v=>v?'开':'关';
  return h.editMenu(env,chat,mid,`<b>👥 ${h.escapeHtml(g.title||id)}</b>\n<code>${id}</code>\n开启「全员可用 Bot」后，普通成员获得只读使用权；关闭后仅已授权用户可用。管理员始终可用。`,{inline_keyboard:[
    [button(`🤖 全员可用 Bot：${on(g.access_mode==='all' && g.role==='viewer')}`,`gm:read:${id}:${g.access_mode==='all'?'0':'1'}`)],
    [button('🛡 风控规则',`gm:rules:${id}:0`),button('🚫 添加屏蔽词',`gm:choose:${id}:keyword`)],
    [button(`✅ 入群验证：${on(p.verify)}`,`gm:verify:${id}:${p.verify?'0':'1'}`),button(`⚡ 防刷屏：${on(p.flood)}`,`gm:flood:${id}:${p.flood?'0':'1'}`)],
    [button(`🧹 清理进退群通知：${on(p.clean)}`,`gm:clean:${id}:${p.clean?'0':'1'}`)],
    [button('👋 编辑欢迎语',`gm:welcome:${id}`),button('📜 编辑群规',`gm:ruletext:${id}`)],
    [button('🛠 管群命令',`gm:help:${id}`),button('🔐 权限检查',`gm:check:${id}`)],
    [button('📋 处理记录',`gm:audit:${id}`),button('⛔ 停用机器人',`gm:remove:${id}`)],
    [button('⬅️ 群列表','gm:list:0')]
  ]});
}

export async function groupCallback(query,env,access,h) {
  const chat=query.message.chat.id,mid=query.message.message_id;
  if(!h.can(access,'admin')) return tell(env,chat,'需要 Bot 管理员权限。',h);
  const [,op,id,arg]=String(query.data||'').split(':');
  try {
    if(op==='add') return prompt(query,env,'group_enable',{},'请输入群数字 ID（负数）；全员可用 Bot 默认关闭。',h);
    if(op==='list') {
      const page=Math.max(0,Math.min(10000,Number(id)||0));
      const rows=(await env.DB.prepare('SELECT chat_id,title FROM bot_groups WHERE enabled=1 ORDER BY chat_id LIMIT 9 OFFSET ?').bind(page*8).all()).results||[];
      const keys=rows.slice(0,8).map(r=>[button(r.title||r.chat_id,`gm:open:${r.chat_id}`)]);
      const nav=[]; if(page)nav.push(button('上一页',`gm:list:${page-1}`)); if(rows.length>8)nav.push(button('下一页',`gm:list:${page+1}`)); if(nav.length)keys.push(nav);
      keys.push([button('➕ 启用群聊','gm:add'),button('⬅️ Bot 管理','rn:settings')]);
      return h.editMenu(env,chat,mid,'<b>👥 已启用群聊</b>',{inline_keyboard:keys});
    }
    if(!groupId(id) || !await enabled(env,id)) return tell(env,chat,'该群未启用，请刷新群列表。',h);
    if(op==='open') return groupPanel(env,chat,mid,id,h);
    if(op==='read' && ['0','1'].includes(arg)) {
      await env.DB.prepare("UPDATE bot_groups SET access_mode=?,role='viewer',updated_at=? WHERE chat_id=? AND enabled=1")
        .bind(arg==='1'?'all':'members',h.nowSeconds(),id).run();
    } else if(['verify','flood','clean'].includes(op) && ['0','1'].includes(arg)) {
      if(arg==='1') await checkRights(env,id,h,op!=='clean');
      await setting(env,id,op,arg==='1',h);
      if(op==='verify' && arg==='0') await settleChallenges(env,h,id,true);
    } else if(op==='welcome' || op==='ruletext') {
      return prompt(query,env,'group_text',{id,key:op==='welcome'?'welcome':'rules'},'输入文本（最多 800 字），发送 - 清空。欢迎语可用 {name}。',h);
    } else if(op==='rules') {
      const page=Math.max(0,Math.min(10000,Number(arg)||0));
      const rules=(await env.DB.prepare('SELECT * FROM group_rules WHERE chat_id=? ORDER BY id LIMIT 9 OFFSET ?').bind(id,page*8).all()).results||[];
      const text=rules.slice(0,8).map(r=>`${h.escapeHtml(TYPES[r.kind]||r.kind)} ${h.escapeHtml(r.pattern)} · ${ACTIONS[r.action]}`).join('\n');
      const keys=rules.slice(0,8).map(r=>[button(`删除规则：${(r.pattern||TYPES[r.kind]).slice(0,28)}`,`gm:delrule:${id}:${r.id}`)]);
      const nav=[];if(page)nav.push(button('上一页',`gm:rules:${id}:${page-1}`));if(rules.length>8)nav.push(button('下一页',`gm:rules:${id}:${page+1}`));if(nav.length)keys.push(nav);
      keys.push([button('➕ 添加规则',`gm:types:${id}`)],...back(id));
      return h.editMenu(env,chat,mid,'<b>🛡 风控规则</b>\n'+(text||'暂无规则'),{inline_keyboard:keys});
    } else if(op==='types') {
      const entries=Object.entries(TYPES),keys=[];
      for(let i=0;i<entries.length;i+=2)keys.push(entries.slice(i,i+2).map(([k,v])=>button(v,`gm:choose:${id}:${k}`)));
      return h.editMenu(env,chat,mid,'选择过滤内容',{inline_keyboard:[...keys,...back(id)]});
    } else if(op==='choose' && TYPES[arg]) {
      return h.editMenu(env,chat,mid,`<b>${TYPES[arg]}</b> · 选择处理方式`,{inline_keyboard:[
        ...Object.entries(ACTIONS).map(([a,label])=>[button(label,`gm:new:${id}:${arg}_${a}`)]),...back(id)]});
    } else if(op==='new') {
      const [kind,action]=String(arg).split('_');
      if(!TYPES[kind] || !ACTIONS[action]) return;
      await checkRights(env,id,h,action!=='delete');
      if(kind==='keyword') return prompt(query,env,'group_keyword',{id,action},`输入屏蔽词，每行一条；最多 30 条，每条 80 字。\n处理：${ACTIONS[action]}（字面匹配，不执行正则）。`,h);
      await addRule(env,id,kind,'',action,h);
    } else if(op==='delrule' && /^[a-f0-9]{16}$/.test(arg||'')) {
      await env.DB.prepare('DELETE FROM group_rules WHERE chat_id=? AND id=?').bind(id,arg).run();
    } else if(op==='remove') {
      return h.editMenu(env,chat,mid,'停用本群机器人？群内查询、控制和自动管群都会停止。',{inline_keyboard:[[button('确认停用',`gm:removeok:${id}`)],...back(id)]});
    } else if(op==='removeok') {
      await settleChallenges(env,h,id,true);
      const remaining=await env.DB.prepare("SELECT COUNT(*) c FROM group_challenges WHERE chat_id=? AND state IN ('pending','verifying','expiring')").bind(id).first();
      if(remaining.c) throw new Error('仍有入群限制未解除，请检查 Bot 权限后重试。');
      await env.DB.prepare('UPDATE bot_groups SET enabled=0 WHERE chat_id=?').bind(id).run();
      await logAction(env,id,query.from.id,'','停用',h);
      return groupCallback({...query,data:'gm:list:0'},env,access,h);
    } else if(op==='help') return h.editMenu(env,chat,mid,groupHelp(env),{inline_keyboard:back(id)});
    else if(op==='check') {
      const detail=await checkRights(env,id,h,true);
      return h.editMenu(env,chat,mid,`✅ 删除消息、限制成员权限正常\n群类型：${h.escapeHtml(detail.type)}\n置顶还需 Telegram 的置顶消息权限。`,{inline_keyboard:back(id)});
    } else if(op==='audit') {
      const rows=(await env.DB.prepare('SELECT actor_id,target_id,action,created_at FROM group_audit WHERE chat_id=? ORDER BY id DESC LIMIT 12').bind(id).all()).results||[];
      return h.editMenu(env,chat,mid,'<b>📋 最近处理</b>\n'+(rows.map(r=>`${new Date(r.created_at*1000).toISOString().slice(5,16)} UTC · ${h.escapeHtml(r.action)} · ${h.escapeHtml(r.target_id)}`).join('\n')||'暂无'),{inline_keyboard:back(id)});
    } else return;
    await logAction(env,id,query.from.id,'',`设置:${op}`,h);
    return groupPanel(env,chat,mid,id,h);
  } catch(error) {return tell(env,chat,h.escapeHtml(String(error.message||error).slice(0,250)),h,groupId(id)?back(id):undefined);}
}

async function addRule(env,id,kind,pattern,action,h) {
  const n=await env.DB.prepare('SELECT COUNT(*) c FROM group_rules WHERE chat_id=?').bind(id).first();
  if(n.c>=100) throw new Error('每群最多 100 条规则，请先删除旧规则。');
  await env.DB.prepare(`INSERT INTO group_rules(id,chat_id,kind,pattern,action) VALUES(?,?,?,?,?)
    ON CONFLICT(chat_id,kind,pattern) DO UPDATE SET action=excluded.action`)
    .bind(h.randomHex(8),id,kind,pattern,action).run();
}
export async function groupInput(message,env,action,data,h) {
  const chat=message.chat.id,input=String(message.text||'').trim();
  try {
    if(action==='group_enable') {
      if(!groupId(input)) throw new Error('请输入负数群 ID。');
      const g=await h.tg(env,'getChat',{chat_id:input});
      if(!isGroup(g)) throw new Error('只支持群和超级群。');
      const me=await h.tg(env,'getMe',{});
      const member=await h.tg(env,'getChatMember',{chat_id:input,user_id:me.id});
      if(!['member','administrator'].includes(member.status)) throw new Error('请先将 Bot 加入目标群。');
      await env.DB.prepare(`INSERT INTO bot_groups(chat_id,title,access_mode,role,added_by,created_at,updated_at,enabled)
        VALUES(?,?,'members','viewer',?,?,?,1) ON CONFLICT(chat_id) DO UPDATE SET title=excluded.title,enabled=1,updated_at=excluded.updated_at`)
        .bind(input,String(g.title||'').slice(0,80),String(message.from.id),h.nowSeconds(),h.nowSeconds()).run();
      return await groupPanel(env,chat,null,input,h),true;
    }
    if(!await enabled(env,data.id)) throw new Error('该群已停用。');
    if(action==='group_text' && ['welcome','rules'].includes(data.key)) {
      if(input.length>800) throw new Error('文本最多 800 字。');
      await setting(env,data.id,data.key,input==='-'?'':input,h);
    } else if(action==='group_keyword' && ACTIONS[data.action]) {
      const words=[...new Set(input.split('\n').map(s=>s.trim().normalize('NFKC')).filter(Boolean))];
      if(!words.length || words.length>30 || words.some(w=>w.length>80)) throw new Error('每次 1–30 条，每条最多 80 字。');
      await checkRights(env,data.id,h,data.action!=='delete');
      for(const word of words) await addRule(env,data.id,'keyword',word,data.action,h);
    } else throw new Error('操作已过期，请重新打开群设置。');
    await logAction(env,data.id,message.from.id,'',action,h);
    await groupPanel(env,chat,null,data.id,h);
  } catch(error) {await tell(env,chat,h.escapeHtml(String(error.message||error).slice(0,250)),h);}
  return true;
}

function groupHelp(env) {
  const bot=String(env.TELEGRAM_BOT_USERNAME||'Bot用户名').replace(/^@/,'');
  return `<b>管群命令</b>\n回复目标消息使用：\n`+
    ['del','ban','unban','kick','mute 60','unmute','pin','unpin'].map(c=>`<code>/${c.split(' ')[0]}@${bot}${c.includes(' ')?' 60':''}</code>`).join('\n')+
    `\n\n也可 /ban@${bot} 用户ID、/unban@${bot} 用户ID、/mute@${bot} 用户ID 分钟。\n`+
    `<code>/rules@${bot}</code> 群规\n<code>/id@${bot}</code> 当前群与用户 ID\n\nBot 管理员和 Telegram 群管理员可执行管群命令；不会封禁管理员。风控规则仍会检查管理员消息，但管理员/匿名管理员命中限制类规则时只删除消息，不执行禁言或封禁。`;
}
async function moderationCommand(message,env,p,h) {
  if(!h.targetsBot(message,env) || message.sender_chat || message.from?.is_bot) return false;
  const text=h.normalize(message,env), [cmd,...args]=text.split(/\s+/);
  const id=String(message.chat.id);
  if(cmd==='/rules') {await tell(env,id,h.escapeHtml(p.rules||'本群尚未设置群规。'),h);return true;}
  if(cmd==='/id') {await tell(env,id,`群：<code>${id}</code>\n你：<code>${message.from.id}</code>`+(message.reply_to_message?.from?`\n目标：<code>${message.reply_to_message.from.id}</code>`:''),h);return true;}
  const action=cmd.replace(/^\//,'');
  if(!['del','ban','unban','kick','mute','unmute','pin','unpin','grouphelp'].includes(action)) return false;
  if(!await protectedUser(env,id,message.from.id,h)) return true;
  if(action==='grouphelp') {await tell(env,id,groupHelp(env),h);return true;}
  const reply=message.reply_to_message;
  if(['del','pin','unpin'].includes(action)) {
    if(!reply?.message_id) throw new Error('请回复目标消息后执行。');
    await h.tg(env,{del:'deleteMessage',pin:'pinChatMessage',unpin:'unpinChatMessage'}[action],{chat_id:id,message_id:reply.message_id, ...(action==='pin'?{disable_notification:true}:{})});
  } else {
    if(reply?.sender_chat) throw new Error('匿名管理员或频道消息不能作为用户目标。');
    const target=String(reply?.from?.id || args[0] || '');
    if(!userId(target)) throw new Error('请回复目标用户消息，或输入数字用户 ID。');
    if(await protectedUser(env,id,target,h)) throw new Error('不能对管理员执行限制操作。');
    if(action==='mute') {
      const raw=args[reply?0:1]||'60',minutes=Number(raw);
      if(!/^\d+$/.test(raw) || minutes<1 || minutes>43200) throw new Error('禁言分钟数须为 1–43200。');
      await h.tg(env,'restrictChatMember',{chat_id:id,user_id:target,permissions:{can_send_messages:false},until_date:h.nowSeconds()+minutes*60,use_independent_chat_permissions:true});
    } else if(action==='unmute') {
      const pending=await env.DB.prepare("SELECT nonce FROM group_challenges WHERE chat_id=? AND user_id=? AND state IN ('pending','verifying','expiring')").bind(id,target).first();
      if(pending) throw new Error('此用户仍在入群验证中，请完成验证或关闭本群验证后重试。');
      await release(env,id,target,h);
    } else if(action==='unban') await h.tg(env,'unbanChatMember',{chat_id:id,user_id:target,only_if_banned:true});
    else {
      await h.tg(env,'banChatMember',{chat_id:id,user_id:target,revoke_messages:false});
      if(action==='kick') await h.tg(env,'unbanChatMember',{chat_id:id,user_id:target,only_if_banned:true});
    }
    await logAction(env,id,message.from.id,target,action,h);
  }
  await tell(env,id,'✅ 已完成',h);
  return true;
}

async function beginChallenge(env,chat,user,p,h) {
  if(user.is_bot || await protectedUser(env,chat.id,user.id,h)) return;
  if(!p.verify) {if(p.welcome)await tell(env,chat.id,h.escapeHtml(p.welcome.replaceAll('{name}',user.first_name||'新成员')),h);return;}
  if(chat.type!=='supergroup') throw new Error('入群验证需要超级群。');
  const bytes=crypto.getRandomValues(new Uint8Array(3)),a=1+bytes[0]%9,b=1+bytes[1]%9;
  const answer=a+b,nonce=h.randomHex(8),now=h.nowSeconds();
  const result=await env.DB.prepare(`INSERT OR IGNORE INTO group_challenges
    (nonce,chat_id,user_id,answer,expires_at,state,updated_at) VALUES(?,?,?,?,?,'pending',?)`)
    .bind(nonce,String(chat.id),String(user.id),String(answer),now+300,now).run();
  if(!result.meta.changes) return;
  try {
    // Expiring restriction is a failsafe if Telegram or cron is unavailable.
    await h.tg(env,'restrictChatMember',{chat_id:chat.id,user_id:user.id,permissions:{can_send_messages:false},until_date:now+600,use_independent_chat_permissions:true});
    const choices=[answer,answer+1,answer+2];
    for(let i=choices.length-1;i>0;i--){const j=crypto.getRandomValues(new Uint32Array(1))[0]%(i+1);[choices[i],choices[j]]=[choices[j],choices[i]];}
    const msg=await tell(env,chat.id,`<a href="tg://user?id=${user.id}">${h.escapeHtml(user.first_name||'新成员')}</a>，请在 5 分钟内选择 ${a} + ${b} 的答案。`,h,
      [choices.map(n=>button(String(n),`verify:${nonce}:${n}`))]);
    await env.DB.prepare('UPDATE group_challenges SET message_id=? WHERE nonce=?').bind(msg.message_id,nonce).run();
  } catch(error) {
    await release(env,chat.id,user.id,h).then(async()=>env.DB.prepare('DELETE FROM group_challenges WHERE nonce=?').bind(nonce).run()).catch(()=>{});
    throw error;
  }
}
async function verifyCallback(query,env,h) {
  const [,nonce,answer]=String(query.data).split(':');
  const row=await env.DB.prepare('SELECT * FROM group_challenges WHERE nonce=?').bind(nonce||'').first();
  const respond=text=>h.tg(env,'answerCallbackQuery',{callback_query_id:query.id,text,show_alert:true}).catch(()=>{});
  if(!row || row.state!=='pending' || row.expires_at<h.nowSeconds()) return respond('验证已失效。');
  if(String(query.from.id)!==row.user_id || String(query.message?.chat?.id)!==row.chat_id) return respond('仅限本人验证。');
  if(!await enabled(env,row.chat_id) || !(await policy(env,row.chat_id)).verify) return respond('本群验证已关闭。');
  if(row.answer!==answer) {
    await env.DB.prepare("UPDATE group_challenges SET attempts=attempts+1,expires_at=CASE WHEN attempts>=2 THEN 0 ELSE expires_at END WHERE nonce=? AND state='pending'").bind(nonce).run();
    return respond('答案错误，最多 3 次机会。');
  }
  const claimed=await env.DB.prepare("UPDATE group_challenges SET state='verifying',updated_at=? WHERE nonce=? AND state='pending' AND attempts<3 AND expires_at>=?").bind(h.nowSeconds(),nonce,h.nowSeconds()).run();
  if(!claimed.meta.changes) return respond('验证已被处理。');
  try {
    await release(env,row.chat_id,row.user_id,h);
    await env.DB.prepare("UPDATE group_challenges SET state='verified',updated_at=? WHERE nonce=?").bind(h.nowSeconds(),nonce).run();
    await respond('验证通过');
    if(row.message_id)await h.tg(env,'deleteMessage',{chat_id:row.chat_id,message_id:row.message_id}).catch(()=>{});
    const p=await policy(env,row.chat_id);
    if(p.welcome)await tell(env,row.chat_id,h.escapeHtml(p.welcome.replaceAll('{name}',query.from.first_name||'新成员')),h);
    await logAction(env,row.chat_id,row.user_id,row.user_id,'验证通过',h);
  } catch(error) {
    await env.DB.prepare("UPDATE group_challenges SET state='pending' WHERE nonce=? AND state='verifying'").bind(nonce).run();
    await respond('解除限制失败，请联系群管理员。');
  }
}

async function settleChallenges(env,h,id=null,cancel=false) {
  const now=h.nowSeconds();
  const rows=(await env.DB.prepare(`SELECT * FROM group_challenges WHERE state IN ('pending','verifying','expiring')
    AND (? IS NULL OR chat_id=?) AND (?=1 OR expires_at<? OR (state<>'pending' AND updated_at<?)) LIMIT 5`)
    .bind(id,id,cancel?1:0,now,now-120).all()).results||[];
  for(const row of rows) {
    try {
      const g=await enabled(env,row.chat_id), p=await policy(env,row.chat_id);
      const exempt=await protectedUser(env,row.chat_id,row.user_id,h);
      const unlock=cancel || !g || !p.verify || exempt || row.state==='verifying';
      const r=await env.DB.prepare('UPDATE group_challenges SET state=?,updated_at=? WHERE nonce=? AND state=? AND updated_at=?')
        .bind(unlock?'verifying':'expiring',now,row.nonce,row.state,row.updated_at).run();
      if(!r.meta.changes)continue;
      if(unlock)await release(env,row.chat_id,row.user_id,h);
      else {
        const member=await h.tg(env,'getChatMember',{chat_id:row.chat_id,user_id:row.user_id});
        if(!['left','kicked'].includes(member.status)) await h.tg(env,'banChatMember',{chat_id:row.chat_id,user_id:row.user_id,revoke_messages:false});
        await h.tg(env,'unbanChatMember',{chat_id:row.chat_id,user_id:row.user_id,only_if_banned:true});
      }
      await env.DB.prepare("UPDATE group_challenges SET state='closed',updated_at=? WHERE nonce=?").bind(now,row.nonce).run();
      if(row.message_id)await h.tg(env,'deleteMessage',{chat_id:row.chat_id,message_id:row.message_id}).catch(()=>{});
      await logAction(env,row.chat_id,'auto',row.user_id,unlock?'解除验证限制':'验证超时移出',h);
    } catch(error) {await reportFailure(env,row.chat_id,error,h);}
  }
}
export async function groupMaintenance(env,h) {
  await settleChallenges(env,h);
  const now=h.nowSeconds();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM group_audit WHERE created_at<?').bind(now-7*86400),
    env.DB.prepare('DELETE FROM group_rate WHERE window<?').bind(now-120),
    env.DB.prepare("DELETE FROM group_challenges WHERE state IN ('verified','closed') AND updated_at<?").bind(now-86400),
    env.DB.prepare("DELETE FROM settings WHERE key LIKE 'group-error:%' AND updated_at<?").bind(now-600),
    env.DB.prepare('DELETE FROM group_events WHERE created_at<?').bind(now-86400)
  ]);
}

export async function groupUpdate(update,env,h) {
  if(update.callback_query?.data?.startsWith('verify:')) {await verifyCallback(update.callback_query,env,h);return true;}
  const member=update.chat_member;
  const message=update.message||update.edited_message;
  const chat=member?.chat||message?.chat;
  if(!isGroup(chat))return false;
  const id=String(chat.id);
  // /id is the only discovery command allowed before enabling a group.
  if(message && h.targetsBot(message,env) && h.normalize(message,env)==='/id' && !message.sender_chat) {
    const access=await h.accessFor(env,message.from?.id,{id:message.from?.id,type:'private'});
    if(h.can(access,'admin')) {await tell(env,id,`群：<code>${id}</code>\n你：<code>${message.from.id}</code>`,h);return true;}
  }
  if(!await enabled(env,id))return true;
  const p=await policy(env,id);
  try {
    if(member) {
      const present=m=>['member','administrator','creator'].includes(m?.status)||(m?.status==='restricted' && m.is_member);
      if(!present(member.old_chat_member) && present(member.new_chat_member)) await beginChallenge(env,chat,member.new_chat_member.user,p,h);
      if(present(member.old_chat_member) && !present(member.new_chat_member)) await env.DB.prepare('DELETE FROM group_challenges WHERE chat_id=? AND user_id=?').bind(id,String(member.new_chat_member.user.id)).run();
      return true;
    }
    if(message.new_chat_members || message.left_chat_member) {
      // Join validation uses chat_member only to avoid duplicate challenge races.
      if(p.clean)await h.tg(env,'deleteMessage',{chat_id:id,message_id:message.message_id});
      return true;
    }

    // Telegram anonymous administrators arrive as sender_chat (usually with a bot-like from field).
    // They still pass through risk rules; only user-specific punishment is downgraded to deletion.
    const anonymous=!!message.sender_chat;
    const uid=anonymous?'':String(message.from?.id||'');
    if(!anonymous && (!message.from || message.from.is_bot)) return true;
    if(!update.edited_message && !anonymous && await moderationCommand(message,env,p,h)) return true;

    const rules=(await env.DB.prepare('SELECT * FROM group_rules WHERE chat_id=?').bind(id).all()).results||[];
    let matched=rules.filter(r=>matchRule(r,message)).sort((a,b)=>({delete:1,mute:2,ban:3}[b.action]-{delete:1,mute:2,ban:3}[a.action]))[0];
    if(p.flood && !update.edited_message && uid) {
      const window=Math.floor(h.nowSeconds()/10)*10;
      const rate=await env.DB.prepare(`INSERT INTO group_rate(chat_id,user_id,window,count) VALUES(?,?,?,1)
        ON CONFLICT(chat_id,user_id,window) DO UPDATE SET count=count+1 RETURNING count`).bind(id,uid,window).first();
      if(rate.count>8 && matched?.action!=='ban') matched={action:'mute',kind:'flood'};
    }
    if(matched) {
      const protectedSender=uid ? await protectedUser(env,id,uid,h) : true;
      const action=(anonymous||protectedSender)?'delete':matched.action;
      const target=uid || `sender_chat:${message.sender_chat?.id||'anonymous'}`;
      const key=`${id}:${message.message_id}:${update.edited_message?message.edit_date||update.update_id:'new'}`;
      const claimed=await env.DB.prepare('INSERT OR IGNORE INTO group_events(id,created_at) VALUES(?,?)').bind(key,h.nowSeconds()).run();
      if(claimed.meta.changes) {
        await applyAction(env,id,uid,message.message_id,action,h);
        const auditAction=action===matched.action?`${matched.kind}:${action}`:`${matched.kind}:${matched.action}->delete`;
        await logAction(env,id,'auto',target,auditAction,h);
      }
      return true;
    }
    // Anonymous senders can be filtered but cannot safely use Bot controls because Telegram hides the real actor.
    if(anonymous) return true;
    // Edited text is filtered, never executed as an administrative command.
    return !!update.edited_message;
  } catch(error) {await reportFailure(env,id,error,h);return true;}
}
