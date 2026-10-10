import { Hono } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { bodyLimit } from 'hono/body-limit';
import { z } from 'zod';
import { hash, hashPassword, token, verifyPassword } from './security';
import { FamilyRoom } from './realtime';
import { pushEnabled } from './push';
export { FamilyRoom };
export interface Env { FAMILY_ROOMS: DurableObjectNamespace<FamilyRoom>; APNS_KEY_ID?: string; APNS_TEAM_ID?: string; APNS_PRIVATE_KEY?: string; DB: D1Database; AUTH_LIMITER: RateLimit; EMAIL?: SendEmail; EMAIL_FROM?: string }
type User = { id: string; email: string; name: string };
const app = new Hono<{ Bindings: Env; Variables: { user: User; familyId: string; role: string } }>();
const now = () => Date.now();
const fail = (status: 400 | 401 | 403 | 404 | 409 | 429, message: string): never => { throw new HTTPException(status, { message }); };
const id = z.string().uuid();
const name = z.string().trim().min(1).max(80);
const credentials = z.object({ email: z.email().max(254).transform(s => s.toLowerCase().trim()), password: z.string().min(10).max(128) });
app.use('*', bodyLimit({ maxSize: 32 * 1024, onError: c => c.json({ error: 'Request too large' }, 413) }));
app.use('*', async (c, next) => { await next(); c.header('Cache-Control', 'no-store'); c.header('X-Content-Type-Options', 'nosniff'); });
app.onError((e, c) => {
  if (e instanceof z.ZodError) return c.json({ error: 'Please check the submitted fields.', details: e.issues.map(i => ({ field: i.path.join('.'), message: i.message })) }, 400);
  if (e instanceof HTTPException) return c.json({ error: e.message }, e.status);
  if (e instanceof SyntaxError) return c.json({ error: 'Invalid JSON' }, 400);
  console.error('Request failed', e.name); // Never log credentials or baby records.
  return c.json({ error: 'Something went wrong. Please try again.' }, 500);
});
app.get('/health', c => c.json({ status: 'ok', service: 'pip' }));
app.use('/auth/*', async (c, next) => {
  const key = hash(c.req.header('CF-Connecting-IP') || 'local');
  if (!(await c.env.AUTH_LIMITER.limit({ key })).success) fail(429, 'Too many attempts. Please wait a minute.');
  await next();
});
async function session(db: D1Database, user: User) {
  const value = token();
  await db.prepare('INSERT INTO sessions VALUES (?, ?, ?)').bind(hash(value), user.id, now() + 30 * 86400000).run();
  return { token: value, user };
}
app.post('/auth/register', async c => {
  const data = credentials.extend({ name }).parse(await c.req.json());
  const user = { id: crypto.randomUUID(), email: data.email, name: data.name };
  const password = await hashPassword(data.password);
  const result = await c.env.DB.prepare('INSERT INTO users VALUES (?, ?, ?, ?, ?) ON CONFLICT(email) DO NOTHING').bind(user.id, user.email, password, user.name, now()).run();
  if (!result.meta.changes) fail(409, 'Unable to create this account. Try signing in instead.');
  return c.json(await session(c.env.DB, user), 201);
});
app.post('/auth/login', async c => {
  const data = credentials.parse(await c.req.json());
  if (!(await c.env.AUTH_LIMITER.limit({ key: 'login:' + hash(data.email) })).success) fail(429, 'Too many attempts. Please wait a minute.');
  const user = await c.env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(data.email).first<User & { password_hash: string }>();
  const valid = await verifyPassword(data.password, user?.password_hash || '');
  if (!user || !valid) return fail(401, 'Email or password is incorrect.');
  return c.json(await session(c.env.DB, { id: user.id, email: user.email, name: user.name }));
});
app.post('/auth/forgot-password', async c => {
  const { email } = z.object({ email: credentials.shape.email }).parse(await c.req.json());
  if (!c.env.EMAIL || !c.env.EMAIL_FROM) throw new HTTPException(503, { message: 'Email delivery is not configured yet.' });
  const user = await c.env.DB.prepare('SELECT id FROM users WHERE email = ?').bind(email).first<{id: string}>();
  if (user) {
    const code = token().toUpperCase();
    await c.env.DB.prepare('INSERT INTO password_resets VALUES (?, ?, ?)').bind(hash(code), user.id, now() + 1800000).run();
    try { await c.env.EMAIL.send({ from: c.env.EMAIL_FROM, to: email, subject: 'Reset your Pip password', text: `Enter this code in Pip to reset your password: ${code}\n\nOpen Pip: pipbaby://reset?code=${code}\n\nExpires in 30 minutes. Ignore this email if you did not request it.` }); }
    catch { await c.env.DB.prepare('DELETE FROM password_resets WHERE token_hash = ?').bind(hash(code)).run(); }
  }
  return c.json({ ok: true });
});
app.post('/auth/reset-password', async c => {
  const { code, password } = z.object({ code: z.string().trim().length(64), password: credentials.shape.password }).parse(await c.req.json());
  const encoded = await hashPassword(password);
  // Atomic single-use claim. Failed downstream operations cannot replay the reset.
  const reset = await c.env.DB.prepare('DELETE FROM password_resets WHERE token_hash = ? AND expires_at > ? RETURNING user_id').bind(hash(code.toUpperCase()), now()).first<{user_id: string}>();
  if (!reset) return fail(400, 'This reset code is invalid or expired.');
  await c.env.DB.batch([
    c.env.DB.prepare('UPDATE users SET password_hash = ? WHERE id = ?').bind(encoded, reset.user_id),
    c.env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(reset.user_id),
    c.env.DB.prepare('DELETE FROM password_resets WHERE user_id = ?').bind(reset.user_id)
  ]);
  return c.json({ ok: true });
});
app.use('/v1/*', async (c, next) => {
  const value = c.req.header('Authorization')?.replace(/^Bearer /, '');
  if (!value) return fail(401, 'Please sign in.');
  const user = await c.env.DB.prepare('SELECT u.id, u.email, u.name FROM users u JOIN sessions s ON s.user_id = u.id WHERE s.token_hash = ? AND s.expires_at > ?').bind(hash(value), now()).first<User>();
  if (!user) return fail(401, 'Your session expired. Please sign in again.');
  c.set('user', user);
  await next();
});
app.get('/v1/me', async c => {
  const family = await c.env.DB.prepare('SELECT f.id, f.name, m.role FROM families f JOIN members m ON m.family_id = f.id WHERE m.user_id = ?').bind(c.get('user').id).first();
  return c.json({ user: c.get('user'), family });
});
app.post('/v1/logout', async c => {
  await c.env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(hash(c.req.header('Authorization')!.replace(/^Bearer /, ''))).run();
  return c.json({ ok: true });
});
app.post('/v1/password', async c => {
  const data = z.object({ currentPassword: z.string().max(128), password: credentials.shape.password }).parse(await c.req.json());
  const row = await c.env.DB.prepare('SELECT password_hash FROM users WHERE id = ?').bind(c.get('user').id).first<{ password_hash: string }>();
  if (!row || !(await verifyPassword(data.currentPassword, row.password_hash))) fail(401, 'Current password is incorrect.');
  const password = await hashPassword(data.password);
  await c.env.DB.batch([
    c.env.DB.prepare('UPDATE users SET password_hash = ? WHERE id = ?').bind(password, c.get('user').id),
    c.env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(c.get('user').id)
  ]);
  return c.json(await session(c.env.DB, c.get('user')));
});
app.post('/v1/families', async c => {
  const data = z.object({ name, babyName: name, birthday: z.iso.date() }).parse(await c.req.json());
  const exists = await c.env.DB.prepare('SELECT 1 FROM members WHERE user_id = ?').bind(c.get('user').id).first();
  if (exists) fail(409, 'You already belong to a family.');
  const familyId = crypto.randomUUID();
  try {
    await c.env.DB.batch([
      c.env.DB.prepare('INSERT INTO families VALUES (?, ?, ?)').bind(familyId, data.name, now()),
      c.env.DB.prepare("INSERT INTO members VALUES (?, ?, 'owner')").bind(c.get('user').id, familyId),
      c.env.DB.prepare('INSERT INTO babies VALUES (?, ?, ?, ?)').bind(crypto.randomUUID(), familyId, data.babyName, data.birthday)
    ]);
  } catch { return fail(409, 'A family was already created. Please refresh.'); }
  return c.json({ id: familyId, name: data.name, role: 'owner' }, 201);
});
app.post('/v1/join', async c => {
  const { code } = z.object({ code: z.string().trim().min(10).max(100) }).parse(await c.req.json());
  if (!(await c.env.AUTH_LIMITER.limit({ key: 'join:' + c.get('user').id })).success) fail(429, 'Please wait before trying another code.');
  const [result] = await c.env.DB.batch([
    c.env.DB.prepare("INSERT INTO members (user_id, family_id, role) SELECT ?, family_id, 'member' FROM invites WHERE code_hash = ? AND expires_at > ? AND email = ? ON CONFLICT(user_id) DO NOTHING").bind(c.get('user').id, hash(code.toUpperCase()), now(), c.get('user').email),
    c.env.DB.prepare('DELETE FROM invites WHERE code_hash = ? AND email = ?').bind(hash(code.toUpperCase()), c.get('user').email)
  ]);
  if (!result.meta.changes) fail(409, 'This invite is expired or invalid, or you already belong to a family.');
  return c.json({ ok: true });
});
app.use('/v1/family/*', async (c, next) => {
  const member = await c.env.DB.prepare('SELECT family_id, role FROM members WHERE user_id = ?').bind(c.get('user').id).first<{ family_id: string; role: string }>();
  if (!member) return fail(403, 'Create or join a family first.');
  c.set('familyId', member.family_id); c.set('role', member.role); await next();
});
async function changed(env: Env, family: string, activityId?: string) {
  await env.FAMILY_ROOMS.get(env.FAMILY_ROOMS.idFromName(family)).publish(activityId, family);
}
app.get('/v1/family/live', async c => {
  const headers = new Headers(c.req.raw.headers);
  headers.set('X-Session', hash(c.req.header('Authorization')!.replace(/^Bearer /, '')));
  headers.set('X-Family', c.get('familyId'));
  return c.env.FAMILY_ROOMS.get(c.env.FAMILY_ROOMS.idFromName(c.get('familyId'))).fetch(new Request(c.req.raw, { headers }));
});
const pushToken = z.string().regex(/^[a-f0-9]{32,512}$/);
app.put('/v1/family/devices/:id', async c => {
  const deviceId = id.parse(c.req.param('id'));
  const data = z.object({ token: pushToken, environment: z.enum(['sandbox', 'production']), activeIds: z.array(id).max(20).default([]) }).parse(await c.req.json());
  const existing = await c.env.DB.prepare('SELECT user_id, token FROM live_devices WHERE id = ?').bind(deviceId).first<{user_id: string; token: string}>();
  if (existing && existing.user_id !== c.get('user').id) fail(403, 'Device belongs to another account.');
  await c.env.DB.prepare('INSERT INTO live_devices VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET session_hash = excluded.session_hash, token = excluded.token, environment = excluded.environment, updated_at = excluded.updated_at').bind(deviceId, c.get('user').id, hash(c.req.header('Authorization')!.replace(/^Bearer /, '')), data.token, data.environment, now()).run();
  for (const activityId of data.activeIds) {
    await c.env.DB.prepare('INSERT OR IGNORE INTO live_starts SELECT ?, id FROM activities WHERE id = ? AND family_id = ?').bind(deviceId, activityId, c.get('familyId')).run();
  }
  const running = await c.env.DB.prepare("SELECT id FROM activities WHERE family_id = ? AND kind = 'breast' AND ended_at IS NULL AND deleted = 0").bind(c.get('familyId')).all<{id: string}>();
  for (const a of running.results) c.executionCtx.waitUntil(changed(c.env, c.get('familyId'), a.id));
  return c.json({ ok: true, pushEnabled: pushEnabled(c.env) });
});
app.put('/v1/family/devices/:id/activities/:activityId', async c => {
  const deviceId = id.parse(c.req.param('id')), activityId = id.parse(c.req.param('activityId'));
  const data = z.object({ token: pushToken }).parse(await c.req.json());
  const allowed = await c.env.DB.prepare('SELECT 1 FROM live_devices d JOIN activities a ON a.family_id = ? WHERE d.id = ? AND d.user_id = ? AND a.id = ?').bind(c.get('familyId'), deviceId, c.get('user').id, activityId).first();
  if (!allowed) fail(404, 'Device or activity not found.');
  await c.env.DB.prepare('INSERT INTO live_tokens VALUES (?, ?, ?) ON CONFLICT(device_id, activity_id) DO UPDATE SET token = excluded.token').bind(deviceId, activityId, data.token).run();
  c.executionCtx.waitUntil(changed(c.env, c.get('familyId'), activityId));
  return c.json({ ok: true });
});
app.get('/v1/family/members', async c => {
  const data = await c.env.DB.prepare('SELECT u.id, u.name, m.role FROM users u JOIN members m ON m.user_id = u.id WHERE m.family_id = ? ORDER BY m.role DESC, u.name').bind(c.get('familyId')).all();
  return c.json({ members: data.results });
});
app.post('/v1/family/invites', async c => {
  if (c.get('role') !== 'owner') fail(403, 'Only the family owner can invite members.');
  const { email } = z.object({ email: credentials.shape.email }).parse(await c.req.json());
  if (!(await c.env.AUTH_LIMITER.limit({ key: 'invite:' + c.get('user').id })).success) fail(429, 'Please wait before sending more invitations.');
  if (!c.env.EMAIL || !c.env.EMAIL_FROM) throw new HTTPException(503, { message: 'Email delivery is not configured yet.' });
  const code = token().slice(0, 32).toUpperCase();
  const expiresAt = now() + 7 * 86400000;
  await c.env.DB.prepare('INSERT INTO invites VALUES (?, ?, ?, ?)').bind(hash(code), c.get('familyId'), expiresAt, email).run();
  try {
    await c.env.EMAIL.send({ from: c.env.EMAIL_FROM, to: email, subject: 'You’re invited to your family on Pip', text: `${c.get('user').name} invited you to share baby care on Pip. Sign in with ${email}, then use this invitation code: ${code}\n\nOpen Pip: pipbaby://join?code=${code}\n\nThis invitation expires in 7 days. If you were not expecting it, you can ignore this email.` });
  } catch {
    await c.env.DB.prepare('DELETE FROM invites WHERE code_hash = ?').bind(hash(code)).run();
    throw new HTTPException(502, { message: 'The invitation could not be delivered. Please try again.' });
  }
  return c.json({ ok: true });
});
app.delete('/v1/family/members/:id', async c => {
  const target = c.req.param('id');
  if (target !== c.get('user').id && c.get('role') !== 'owner') fail(403, 'Only the owner can remove members.');
  const result = await c.env.DB.prepare("DELETE FROM members WHERE user_id = ? AND family_id = ? AND role != 'owner'").bind(target, c.get('familyId')).run();
  if (!result.meta.changes) fail(409, 'The family owner cannot be removed.');
  c.executionCtx.waitUntil(changed(c.env, c.get('familyId')));
  return c.json({ ok: true });
});
app.get('/v1/family/babies', async c => c.json({ babies: (await c.env.DB.prepare('SELECT id, name, birthday FROM babies WHERE family_id = ? ORDER BY rowid').bind(c.get('familyId')).all()).results }));
app.post('/v1/family/babies', async c => {
  const data = z.object({ name, birthday: z.iso.date() }).parse(await c.req.json());
  const babyId = crypto.randomUUID();
  await c.env.DB.prepare('INSERT INTO babies VALUES (?, ?, ?, ?)').bind(babyId, c.get('familyId'), data.name, data.birthday).run();
  return c.json({ id: babyId, ...data }, 201);
});
const activitySchema = z.object({
  id, babyId: id, kind: z.enum(['breast','bottle','pump']), startedAt: z.number().min(0), endedAt: z.number().nullable().default(null),
  side: z.enum(['left','right']), leftSeconds: z.number().min(0).max(604800), rightSeconds: z.number().min(0).max(604800),
  segmentStartedAt: z.number().nullable().default(null), paused: z.boolean(), volumeML: z.number().min(0).max(5000),
  milk: z.enum(['breastMilk','formula']), notes: z.string().max(2000), deleted: z.boolean(),
  revision: z.number().int().min(0), mutationId: id, controlAt: z.number().nonnegative().nullable().optional()
}).superRefine((a, ctx) => {
  if (a.startedAt > now() + 300000 || (a.endedAt !== null && (a.endedAt < a.startedAt || a.endedAt > now() + 300000))) ctx.addIssue({ code: 'custom', message: 'Invalid activity times' });
  if (a.segmentStartedAt !== null && (a.segmentStartedAt < a.startedAt || a.segmentStartedAt > now() + 300000)) ctx.addIssue({ code: 'custom', message: 'Invalid timer segment' });
  if ((a.paused || a.endedAt !== null) && a.segmentStartedAt !== null) ctx.addIssue({ code: 'custom', message: 'Stopped timers cannot have an active segment' });
  if (!a.paused && a.endedAt === null && a.segmentStartedAt === null) ctx.addIssue({ code: 'custom', message: 'Running activities need a timer segment' });
});
type ActivityRow = { payload: string; revision: number; mutation_id: string; created_by: string };
const decode = (r: ActivityRow) => ({ ...JSON.parse(r.payload), revision: r.revision, mutationId: r.mutation_id, createdBy: r.created_by });
app.get('/v1/family/activities', async c => {
  const cursor = c.req.query('cursor');
  const rows = await c.env.DB.prepare('SELECT rowid AS cursor, payload, revision, mutation_id, created_by FROM activities WHERE family_id = ? AND rowid > ? ORDER BY rowid LIMIT 501').bind(c.get('familyId'), cursor ? z.coerce.number().int().min(0).parse(cursor) : 0).all<ActivityRow & { cursor: number }>();
  const page = rows.results.slice(0, 500);
  return c.json({ activities: page.map(decode), nextCursor: rows.results.length > 500 ? page.at(-1)!.cursor : null });
});
app.put('/v1/family/activities/:id', async c => {
  const input = await c.req.json();
  const original = activitySchema.parse(input);
  for (let attempt = 0; attempt < 12; attempt++) {
  let a = { ...original };
  if (a.id !== c.req.param('id')) fail(400, 'Activity ID mismatch');
  const db = c.env.DB;
  if (!(await db.prepare('SELECT 1 FROM babies WHERE id = ? AND family_id = ?').bind(a.babyId, c.get('familyId')).first())) fail(404, 'Baby not found');
  const existing = await db.prepare('SELECT payload, revision, mutation_id, created_by FROM activities WHERE id = ? AND family_id = ?').bind(a.id, c.get('familyId')).first<ActivityRow>();
  if (existing?.mutation_id === a.mutationId) return c.json(decode(existing));
  if (existing && existing.revision !== a.revision) {
    const current = decode(existing);
    const base = input.base ? activitySchema.parse(input.base) : null;
    if (!base || base.id !== a.id) return c.json({ error: 'Another caregiver updated this activity.', current }, 409);
    // Merge independent edits, keeping timer state as one indivisible group.
    const groups = [['startedAt', 'endedAt', 'side', 'leftSeconds', 'rightSeconds', 'segmentStartedAt', 'paused', 'deleted', 'controlAt'], ['notes'], ['volumeML'], ['milk']];
    const merged = { ...current, mutationId: a.mutationId };
    for (const fields of groups) {
      const localChanged = fields.some(k => (a as any)[k] !== (base as any)[k]);
      const remoteChanged = fields.some(k => current[k] !== (base as any)[k]);
      if (localChanged && remoteChanged && fields.some(k => (a as any)[k] !== current[k])) return c.json({ error: 'Both caregivers changed the same detail.', current }, 409);
      if (localChanged) for (const k of fields) merged[k] = (a as any)[k];
    }
    a = activitySchema.parse(merged);
  }
  if (!existing && a.revision !== 0) fail(409, 'Activity no longer exists.');
  let changes = 0;
  try {
    const result = existing
      ? await db.prepare('UPDATE activities SET ended_at = ?, started_at = ?, payload = ?, revision = revision + 1, mutation_id = ?, deleted = ?, updated_at = ? WHERE id = ? AND family_id = ? AND revision = ? AND baby_id = ? AND kind = ?').bind(a.endedAt, a.startedAt, JSON.stringify(a), a.mutationId, Number(a.deleted), now(), a.id, c.get('familyId'), a.revision, a.babyId, a.kind).run()
      : await db.prepare('INSERT INTO activities VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)').bind(a.id, c.get('familyId'), a.babyId, c.get('user').id, a.kind, a.startedAt, a.endedAt, JSON.stringify(a), a.mutationId, Number(a.deleted), now()).run();
    changes = result.meta.changes;
  } catch (e) {
    if (String(e).includes('UNIQUE constraint')) {
      const running = await db.prepare('SELECT payload, revision, mutation_id, created_by FROM activities WHERE baby_id = ? AND kind = ? AND ended_at IS NULL AND deleted = 0 AND family_id = ?').bind(a.babyId, a.kind, c.get('familyId')).first<ActivityRow>();
      return c.json({ error: 'An activity is already running.', current: running ? decode(running) : undefined }, 409);
    }
    throw e;
  }
  if (!changes) continue;
  c.executionCtx.waitUntil(changed(c.env, c.get('familyId'), a.id));
  return c.json({ ...a, revision: a.revision + 1, createdBy: existing?.created_by || c.get('user').id });
  }
  return fail(409, 'Activity is busy. Please retry.');
});
// Target-state commands are durable and idempotent across retries and caregivers.
app.post('/v1/family/activities/:id/commands', async c => {
  const activityId = id.parse(c.req.param('id'));
  const command = z.object({ id, side: z.enum(['left', 'right']).optional(), paused: z.boolean().optional(), finish: z.boolean().optional(), volumeML: z.number().min(0).max(5000).optional(), occurredAt: z.number().nonnegative() }).parse(await c.req.json());
  for (let attempt = 0; attempt < 12; attempt++) {
    const row = await c.env.DB.prepare('SELECT payload, revision, mutation_id, created_by FROM activities WHERE id = ? AND family_id = ?').bind(activityId, c.get('familyId')).first<ActivityRow>();
    if (!row) return fail(404, 'Activity not found.');
    const a = decode(row);
    const receipt = await c.env.DB.prepare('SELECT activity_id FROM activity_commands WHERE id = ?').bind(command.id).first<{activity_id: string}>();
    if (receipt) {
      if (receipt.activity_id !== activityId) fail(409, 'Command belongs to another activity.');
      return c.json(a);
    }
    // Finished/deleted activities never reopen because an offline control arrives late.
    if (a.endedAt == null && !a.deleted) {
      const time = Math.max(a.segmentStartedAt ?? a.startedAt, Math.min(now(), command.occurredAt));
      const timerChanged = command.finish || (command.side !== undefined && command.side !== a.side) || (command.paused !== undefined && command.paused !== a.paused);
      if (timerChanged && command.occurredAt >= (a.controlAt ?? a.startedAt)) {
        a.controlAt = time;
        if (!a.paused && a.segmentStartedAt != null) a[a.side === 'left' ? 'leftSeconds' : 'rightSeconds'] += Math.max(0, (time - a.segmentStartedAt) / 1000);
        if (command.side !== undefined && a.kind === 'breast') a.side = command.side;
        if (command.paused !== undefined) a.paused = command.paused;
        if (command.finish) { a.endedAt = time; a.paused = true; }
        a.segmentStartedAt = a.paused ? null : time;
      }
      if (command.volumeML !== undefined) a.volumeML = command.volumeML;
    }
    a.mutationId = command.id;
    const [update] = await c.env.DB.batch([
      c.env.DB.prepare('UPDATE activities SET ended_at = ?, payload = ?, revision = revision + 1, mutation_id = ?, updated_at = ? WHERE id = ? AND family_id = ? AND revision = ? AND NOT EXISTS (SELECT 1 FROM activity_commands WHERE id = ?)').bind(a.endedAt, JSON.stringify(a), command.id, now(), activityId, c.get('familyId'), row.revision, command.id),
      c.env.DB.prepare('INSERT OR IGNORE INTO activity_commands SELECT ?, id, ? FROM activities WHERE id = ? AND mutation_id = ?').bind(command.id, now(), activityId, command.id)
    ]);
    if (update.meta.changes) {
      c.executionCtx.waitUntil(changed(c.env, c.get('familyId'), activityId));
      return c.json({ ...a, revision: row.revision + 1 });
    }
  }
  return fail(409, 'Activity is busy. Please retry.');
});
app.delete('/v1/account', async c => {
  const { password } = z.object({ password: z.string().max(128) }).parse(await c.req.json());
  const row = await c.env.DB.prepare('SELECT password_hash FROM users WHERE id = ?').bind(c.get('user').id).first<{ password_hash: string }>();
  if (!row || !(await verifyPassword(password, row.password_hash))) fail(401, 'Password is incorrect.');
  const member = await c.env.DB.prepare('SELECT family_id, role FROM members WHERE user_id = ?').bind(c.get('user').id).first<{family_id: string; role: string}>();
  const statements = [];
  if (member?.role === 'owner') statements.push(c.env.DB.prepare('DELETE FROM families WHERE id = ?').bind(member.family_id));
  statements.push(c.env.DB.prepare('DELETE FROM users WHERE id = ?').bind(c.get('user').id));
  await c.env.DB.batch(statements);
  return c.json({ ok: true });
});
export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledEvent, env: Env) {
    await env.DB.batch([env.DB.prepare('DELETE FROM sessions WHERE expires_at < ?').bind(now()), env.DB.prepare('DELETE FROM invites WHERE expires_at < ?').bind(now()), env.DB.prepare('DELETE FROM password_resets WHERE expires_at < ?').bind(now())]);
  }
};
