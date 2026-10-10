import { env } from 'cloudflare:workers';
import { SELF } from 'cloudflare:test';
import { describe, it, expect } from 'vitest';
import { hash } from '../src/security';
let ip = 1;
async function request(path: string, method = 'GET', body?: unknown, token?: string) {
  const response = await SELF.fetch('https://pip.test' + path, { method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': `192.0.2.${ip++}`, ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: response.status, data: await response.json() as any };
}
async function account() {
  const email = `${crypto.randomUUID()}@example.com`;
  const response = await request('/auth/register', 'POST', { name: 'Caregiver', email, password: 'a-long-test-password' });
  expect(response.status).toBe(201);
  return { ...response.data, email };
}
async function family() {
  const a = await account();
  expect((await request('/v1/families', 'POST', { name: 'Our family', babyName: 'Milo', birthday: '2026-01-01' }, a.token)).status).toBe(201);
  const me = await request('/v1/me', 'GET', undefined, a.token);
  const babies = await request('/v1/family/babies', 'GET', undefined, a.token);
  return { ...a, familyId: me.data.family.id, babyId: babies.data.babies[0].id };
}
function activity(babyId: string) {
  const startedAt = Date.now() - 60000;
  return { id: crypto.randomUUID(), babyId, kind: 'breast', startedAt, endedAt: null, side: 'left', leftSeconds: 0, rightSeconds: 0, segmentStartedAt: startedAt, paused: false, volumeML: 0, milk: 'breastMilk', notes: '', deleted: false, revision: 0, mutationId: crypto.randomUUID() };
}
describe('Pip API', () => {
  it('stores salted password hashes and revokes sessions on logout', async () => {
    const a = await account();
    const row = await env.DB.prepare('SELECT password_hash FROM users WHERE id = ?').bind(a.user.id).first();
    expect(row.password_hash).toMatch(/^scrypt-v1:/);
    const login = await request('/auth/login', 'POST', { email: a.email.toUpperCase(), password: 'a-long-test-password' });
    expect(login.status).toBe(200);
    expect((await request('/auth/login', 'POST', { email: a.email, password: 'wrong-password' })).status).toBe(401);
    await request('/v1/logout', 'POST', undefined, login.data.token);
    expect((await request('/v1/me', 'GET', undefined, login.data.token)).status).toBe(401);
  });
  it('requires auth and isolates families', async () => {
    expect((await request('/v1/me')).status).toBe(401);
    const a = await family(); const b = await family();
    const log = activity(a.babyId);
    expect((await request(`/v1/family/activities/${log.id}`, 'PUT', log, b.token)).status).toBe(404);
    expect((await request('/v1/family/activities', 'GET', undefined, b.token)).data.activities).toEqual([]);
  });
  it('uses idempotent writes, optimistic concurrency, and one active feed per baby', async () => {
    const a = await family(); const log = activity(a.babyId); const path = `/v1/family/activities/${log.id}`;
    const first = await request(path, 'PUT', log, a.token); expect(first.status).toBe(200); expect(first.data.revision).toBe(1);
    expect((await request(path, 'PUT', log, a.token)).data.revision).toBe(1);
    const stale = await request(path, 'PUT', { ...log, mutationId: crypto.randomUUID() }, a.token);
    expect(stale.status).toBe(409); expect(stale.data.current.revision).toBe(1);
    const second = activity(a.babyId);
    expect((await request(`/v1/family/activities/${second.id}`, 'PUT', second, a.token)).status).toBe(409);
    const finish = { ...first.data, endedAt: Date.now(), segmentStartedAt: null, paused: true, mutationId: crypto.randomUUID() };
    expect((await request(path, 'PUT', finish, a.token)).data.revision).toBe(2);
    expect((await request(`/v1/family/activities/${second.id}`, 'PUT', second, a.token)).status).toBe(200);
  });
  it('accepts only invitations addressed to the signed-in email and respects expiry', async () => {
    const owner = await family(); const invited = await account(); const stranger = await account();
    const code = 'A'.repeat(32);
    await env.DB.prepare('INSERT INTO invites VALUES (?, ?, ?, ?)').bind(hash(code), owner.familyId, Date.now() + 100000, invited.email).run();
    expect((await request('/v1/join', 'POST', { code }, stranger.token)).status).toBe(409);
    expect((await request('/v1/join', 'POST', { code }, invited.token)).status).toBe(200);
    const me = await request('/v1/me', 'GET', undefined, invited.token); expect(me.data.family.id).toBe(owner.familyId);
    expect((await request('/v1/family/invites', 'POST', { email: stranger.email }, invited.token)).status).toBe(403);
    expect((await request(`/v1/family/members/${invited.user.id}`, 'DELETE', undefined, owner.token)).status).toBe(200);
    await env.DB.prepare('UPDATE invites SET expires_at = 0').run();
    expect((await request('/v1/join', 'POST', { code }, invited.token)).status).toBe(409);
    expect((await request('/v1/family/activities', 'GET', undefined, invited.token)).status).toBe(403);
  });
  it('rejects invalid timers and persists bottle and pumping logs', async () => {
    const a = await family(); const log = activity(a.babyId);
    expect((await request(`/v1/family/activities/${log.id}`, 'PUT', { ...log, paused: true }, a.token)).status).toBe(400);
    for (const kind of ['bottle', 'pump']) {
      const row = { ...activity(a.babyId), kind, endedAt: Date.now(), segmentStartedAt: null, paused: true, volumeML: 90 };
      expect((await request(`/v1/family/activities/${row.id}`, 'PUT', row, a.token)).status).toBe(200);
    }
    expect((await request('/v1/family/activities', 'GET', undefined, a.token)).data.activities).toHaveLength(2);
  });
  it('saves running pump and bottle timers before they finish', async () => {
    const a = await family();
    for (const kind of ['pump', 'bottle']) {
      const row = { ...activity(a.babyId), kind };
      const path = `/v1/family/activities/${row.id}`;
      const saved = await request(path, 'PUT', row, a.token);
      expect(saved.status).toBe(200);
      expect(saved.data.endedAt).toBeNull();
      expect((await request(path, 'PUT', { ...saved.data, segmentStartedAt: null, mutationId: crypto.randomUUID() }, a.token)).status).toBe(400);
      const paused = await request(path, 'PUT', { ...saved.data, paused: true, segmentStartedAt: null, leftSeconds: 60, volumeML: 80, mutationId: crypto.randomUUID() }, a.token);
      expect(paused.status).toBe(200);
      const finished = await request(path, 'PUT', { ...paused.data, endedAt: Date.now(), mutationId: crypto.randomUUID() }, a.token);
      expect(finished.status).toBe(200);
      expect(finished.data.volumeML).toBe(80);
      expect(finished.data.leftSeconds).toBe(60);
    }
  });
  it('accepts Swift Codable omission of optional timestamps', async () => {
    const a = await family();
    const running = activity(a.babyId);
    const { endedAt, ...swiftRunning } = running;
    const first = await request(`/v1/family/activities/${running.id}`, 'PUT', swiftRunning, a.token);
    expect(first.status).toBe(200);
    expect(first.data.endedAt).toBeNull();
    const { segmentStartedAt, ...swiftPaused } = { ...first.data, paused: true, mutationId: crypto.randomUUID() };
    const paused = await request(`/v1/family/activities/${running.id}`, 'PUT', swiftPaused, a.token);
    expect(paused.status).toBe(200);
    expect(paused.data.segmentStartedAt).toBeNull();
  });
  it('consumes reset codes once and invalidates existing sessions', async () => {
    const a = await account(); const code = 'B'.repeat(64);
    await env.DB.prepare('INSERT INTO password_resets VALUES (?, ?, ?)').bind(hash(code), a.user.id, Date.now() + 100000).run();
    expect((await request('/auth/reset-password', 'POST', { code, password: 'my-new-password' })).status).toBe(200);
    expect((await request('/auth/reset-password', 'POST', { code, password: 'another-password' })).status).toBe(400);
    expect((await request('/v1/me', 'GET', undefined, a.token)).status).toBe(401);
    expect((await request('/auth/login', 'POST', { email: a.email, password: 'my-new-password' })).status).toBe(200);
  });
  it('deletes an owner account and family records', async () => {
    const a = await family();
    expect((await request('/v1/account', 'DELETE', { password: 'wrong' }, a.token)).status).toBe(401);
    expect((await request('/v1/account', 'DELETE', { password: 'a-long-test-password' }, a.token)).status).toBe(200);
    expect(await env.DB.prepare('SELECT 1 FROM families WHERE id = ?').bind(a.familyId).first()).toBeNull();
    expect((await request('/v1/me', 'GET', undefined, a.token)).status).toBe(401);
  });
  it('coordinates two caregivers without double toggles and deduplicates old command retries', async () => {
    const owner = await family(), partner = await account();
    await env.DB.prepare("INSERT INTO members VALUES (?, ?, 'member')").bind(partner.user.id, owner.familyId).run();
    const log = activity(owner.babyId), path = `/v1/family/activities/${log.id}`;
    await request(path, 'PUT', log, owner.token);
    const command = (values: any) => ({ id: crypto.randomUUID(), occurredAt: Date.now(), ...values });
    const switchRight = command({ side: 'right' });
    const switched = await Promise.all([request(path + '/commands', 'POST', switchRight, owner.token), request(path + '/commands', 'POST', command({ side: 'right' }), partner.token)]);
    expect(switched.map(r => r.status)).toEqual([200, 200]);
    expect(switched.every(r => r.data.side === 'right')).toBe(true);
    const pauses = await Promise.all([request(path + '/commands', 'POST', command({ paused: true }), owner.token), request(path + '/commands', 'POST', command({ paused: true }), partner.token)]);
    expect(pauses.every(r => r.status === 200 && r.data.paused)).toBe(true);
    const left = await request(path + '/commands', 'POST', command({ side: 'left' }), partner.token);
    const replay = await request(path + '/commands', 'POST', switchRight, owner.token);
    expect(replay.data.side).toBe('left');
    expect(replay.data.revision).toBe(left.data.revision);
    expect(replay.data.leftSeconds + replay.data.rightSeconds).toBeGreaterThanOrEqual(60);
    await request(path + '/commands', 'POST', command({ finish: true }), owner.token);
    const late = await request(path + '/commands', 'POST', command({ paused: false, side: 'right' }), partner.token);
    expect(late.data.endedAt).not.toBeNull(); expect(late.data.paused).toBe(true);
    const stranger = await family();
    expect((await request(path + '/commands', 'POST', command({ paused: false }), stranger.token)).status).toBe(404);
  });
  it('merges independent edits and preserves a real same-field conflict', async () => {
    const a = await family(), log = activity(a.babyId), path = `/v1/family/activities/${log.id}`;
    const base = (await request(path, 'PUT', log, a.token)).data;
    const responses = await Promise.all([
      request(path, 'PUT', { ...base, base, notes: 'Hungry', mutationId: crypto.randomUUID() }, a.token),
      request(path, 'PUT', { ...base, base, volumeML: 30, mutationId: crypto.randomUUID() }, a.token)
    ]);
    expect(responses.map(r => r.status)).toEqual([200, 200]);
    const current = (await request('/v1/family/activities', 'GET', undefined, a.token)).data.activities[0];
    expect(current.notes).toBe('Hungry'); expect(current.volumeML).toBe(30);
    const conflict = await request(path, 'PUT', { ...base, base, notes: 'Different note', mutationId: crypto.randomUUID() }, a.token);
    expect(conflict.status).toBe(409); expect(conflict.data.current.notes).toBe('Hungry');
    // A stale notes edit must not rewind a timer switched by another caregiver.
    await request(path + '/commands', 'POST', { id: crypto.randomUUID(), occurredAt: Date.now(), side: 'right' }, a.token);
    const note = await request(path, 'PUT', { ...current, base: current, notes: 'Settled', mutationId: crypto.randomUUID() }, a.token);
    expect(note.status).toBe(200); expect(note.data.side).toBe('right'); expect(note.data.notes).toBe('Settled');
  });
  it('returns the existing shared pump or bottle when both caregivers start', async () => {
    const a = await family();
    for (const kind of ['pump', 'bottle']) {
      const first = { ...activity(a.babyId), kind }, second = { ...activity(a.babyId), kind };
      const responses = await Promise.all([first, second].map(log => request(`/v1/family/activities/${log.id}`, 'PUT', log, a.token)));
      expect(responses.map(r => r.status).sort()).toEqual([200, 409]);
      expect(responses.find(r => r.status === 409)!.data.current.id).toBe(responses.find(r => r.status === 200)!.data.id);
    }
  });
  it('delivers live invalidations to both family sockets and closes a removed member', async () => {
    const a = await family(), partner = await account();
    await env.DB.prepare("INSERT INTO members VALUES (?, ?, 'member')").bind(partner.user.id, a.familyId).run();
    const connect = async (token: string) => {
      const response = await SELF.fetch('https://pip.test/v1/family/live', { headers: { Authorization: `Bearer ${token}`, Upgrade: 'websocket' } });
      expect(response.status).toBe(101);
      const socket = response.webSocket!; socket.accept();
      await new Promise<void>(resolve => socket.addEventListener('message', () => resolve(), { once: true }));
      return socket;
    };
    const first = await connect(a.token), second = await connect(partner.token);
    const next = (ws: WebSocket) => new Promise(resolve => ws.addEventListener('message', resolve, { once: true }));
    const updates = Promise.all([next(first), next(second)]);
    const log = activity(a.babyId);
    await request(`/v1/family/activities/${log.id}`, 'PUT', log, partner.token);
    await updates;
    const closed = new Promise(resolve => second.addEventListener('close', resolve, { once: true }));
    await request(`/v1/family/members/${partner.user.id}`, 'DELETE', undefined, a.token);
    await closed; first.close();
  });
  it('scopes push registrations to a signed-in device and revokes them on logout', async () => {
    const a = await family(), other = await family(), device = crypto.randomUUID();
    const registration = { token: 'a'.repeat(64), environment: 'sandbox' };
    expect((await request(`/v1/family/devices/${device}`, 'PUT', registration, a.token)).status).toBe(200);
    expect((await request(`/v1/family/devices/${device}`, 'PUT', registration, other.token)).status).toBe(403);
    const log = activity(a.babyId); await request(`/v1/family/activities/${log.id}`, 'PUT', { ...log, liveDeviceId: device }, a.token);
    expect(await env.DB.prepare('SELECT 1 FROM live_starts WHERE device_id = ? AND activity_id = ?').bind(device, log.id).first()).not.toBeNull();
    expect((await request(`/v1/family/devices/${device}/activities/${log.id}`, 'PUT', { token: 'b'.repeat(64) }, other.token)).status).toBe(404);
    expect((await request(`/v1/family/devices/${device}/activities/${log.id}`, 'PUT', { token: 'b'.repeat(64) }, a.token)).status).toBe(200);
    await request('/v1/logout', 'POST', undefined, a.token);
    expect(await env.DB.prepare('SELECT 1 FROM live_devices WHERE id = ?').bind(device).first()).toBeNull();
    expect(await env.DB.prepare('SELECT 1 FROM live_tokens WHERE device_id = ?').bind(device).first()).toBeNull();
  });

  it('merges out-of-order switch and pause commands but ignores older edits to the same control', async () => {
    const a = await family(), log = activity(a.babyId), path = `/v1/family/activities/${log.id}`;
    await request(path, 'PUT', log, a.token);
    const now = Date.now();
    const control = (fields: any, time: number) => request(path + '/commands', 'POST', { id: crypto.randomUUID(), occurredAt: time, ...fields }, a.token);
    await control({ side: 'right' }, now - 1000);
    const paused = await control({ paused: true }, now - 3000);
    expect(paused.data.side).toBe('right'); expect(paused.data.paused).toBe(true);
    const stale = await control({ side: 'left', paused: false }, now - 4000);
    expect(stale.data.side).toBe('right'); expect(stale.data.paused).toBe(true);
    const resumed = await control({ paused: false }, now);
    expect(resumed.data.paused).toBe(false); expect(resumed.data.side).toBe('right');
  });

});
