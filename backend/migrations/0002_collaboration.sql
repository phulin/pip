CREATE UNIQUE INDEX one_active_kind ON activities(baby_id, kind) WHERE ended_at IS NULL AND deleted = 0;
CREATE TABLE activity_commands (id TEXT PRIMARY KEY, activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE, created_at INTEGER NOT NULL);
CREATE TABLE live_devices (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE, token TEXT NOT NULL, environment TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE live_tokens (device_id TEXT NOT NULL REFERENCES live_devices(id) ON DELETE CASCADE, activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE, token TEXT NOT NULL, PRIMARY KEY(device_id, activity_id));
CREATE TABLE live_starts (device_id TEXT NOT NULL REFERENCES live_devices(id) ON DELETE CASCADE, activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE, PRIMARY KEY(device_id, activity_id));
