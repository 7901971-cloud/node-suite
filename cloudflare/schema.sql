CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL COLLATE NOCASE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_seen INTEGER,
  online_state TEXT NOT NULL DEFAULT 'unknown',
  active_alerts TEXT NOT NULL DEFAULT '[]',
  status_json TEXT NOT NULL DEFAULT '{}',
  node_cipher TEXT,
  node_updated_at INTEGER,
  boot_id TEXT,
  client_ip TEXT,
  refresh_requested INTEGER NOT NULL DEFAULT 0,
  muted_until INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_devices_last_seen
  ON devices(enabled, last_seen);

CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_active_name
  ON devices(name COLLATE NOCASE) WHERE enabled=1;

CREATE TABLE IF NOT EXISTS pair_codes (
  code_hash TEXT PRIMARY KEY,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pair_codes_expiry
  ON pair_codes(expires_at);

CREATE TABLE IF NOT EXISTS alerts (
  device_id TEXT NOT NULL,
  code TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  last_notified INTEGER NOT NULL DEFAULT 0,
  resolved_at INTEGER,
  PRIMARY KEY(device_id, code),
  FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_alerts_active
  ON alerts(active, last_notified);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS device_commands (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  action TEXT NOT NULL,
  payload TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'queued',
  requested_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  started_at INTEGER,
  finished_at INTEGER,
  exit_code INTEGER,
  result_text TEXT,
  FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_device_commands_poll
  ON device_commands(device_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_device_commands_expiry
  ON device_commands(expires_at);

-- Bot 权限由此处长期维护。OWNER_TELEGRAM_IDS 始终是不可删除的最高管理员，
-- 其余用户/群均通过 Bot 设置菜单管理，无须再次修改 Worker 源码或 Secret。
CREATE TABLE IF NOT EXISTS bot_users (
  user_id TEXT PRIMARY KEY,
  role TEXT NOT NULL CHECK(role IN ('viewer','operator','admin')),
  added_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS bot_groups (
  chat_id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  access_mode TEXT NOT NULL CHECK(access_mode IN ('all','members')),
  role TEXT NOT NULL CHECK(role IN ('viewer','operator','admin')),
  added_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS bot_group_members (
  chat_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('viewer','operator','admin')),
  added_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(chat_id, user_id),
  FOREIGN KEY(chat_id) REFERENCES bot_groups(chat_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_bot_group_members_user
  ON bot_group_members(user_id, chat_id);

-- 管理菜单中“请输入 ID”这一类短暂交互状态，十分钟后自然过期。
CREATE TABLE IF NOT EXISTS bot_pending_inputs (
  actor_id TEXT PRIMARY KEY,
  action TEXT NOT NULL,
  data_json TEXT NOT NULL DEFAULT '{}',
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS node_config_drafts (
  id TEXT PRIMARY KEY,
  actor_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  payload TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS node_config_drafts_expiry ON node_config_drafts(expires_at);

CREATE INDEX IF NOT EXISTS idx_bot_pending_inputs_expiry
  ON bot_pending_inputs(expires_at);
