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
});
