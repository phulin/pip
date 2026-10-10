import { env } from 'cloudflare:workers';
import { describe, it, expect, vi } from 'vitest';
import { pushActivity, liveState } from '../src/push';

// Exercise real signing + payload construction, substituting only Apple's transport.
describe('Family Live Activity delivery', () => {
  it('uses Swift Date encoding and keeps both side totals', () => {
    const state = liveState({ side: 'right', paused: false, endedAt: null, segmentStartedAt: 200000, leftSeconds: 60, rightSeconds: 10 }, 230000);
    expect(state).toEqual({ side: 'Right', paused: false, elapsed: 100, timerStart: 130 - 978307200, leftSeconds: 60, rightSeconds: 40 });
  });
  it('starts once per family device, updates, ends, and excludes removed members', async () => {
    const family = crypto.randomUUID(), baby = crypto.randomUUID(), activityId = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO families VALUES (?, ?, ?)').bind(family, 'Family', Date.now()).run();
    await env.DB.prepare('INSERT INTO babies VALUES (?, ?, ?, ?)').bind(baby, family, 'Milo', '2026-01-01').run();
    const activity = { id: activityId, babyId: baby, kind: 'breast', side: 'left', paused: false, leftSeconds: 0, rightSeconds: 0, startedAt: Date.now(), segmentStartedAt: Date.now(), endedAt: null, deleted: false };
    await env.DB.prepare('INSERT INTO activities VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 0, ?)').bind(activityId, family, baby, 'owner', 'breast', activity.startedAt, null, JSON.stringify(activity), crypto.randomUUID(), Date.now()).run();
    const devices: string[] = [], users: string[] = [];
    for (let i = 0; i < 2; i++) {
      const user = crypto.randomUUID(), device = crypto.randomUUID(); users.push(user); devices.push(device);
      await env.DB.batch([
        env.DB.prepare('INSERT INTO users VALUES (?, ?, ?, ?, ?)').bind(user, user + '@example.com', 'test', 'Caregiver', Date.now()),
        env.DB.prepare("INSERT INTO members VALUES (?, ?, 'member')").bind(user, family),
        env.DB.prepare('INSERT INTO sessions VALUES (?, ?, ?)').bind(user, user, Date.now() + 60000),
        env.DB.prepare('INSERT INTO live_devices VALUES (?, ?, ?, ?, ?, ?)').bind(device, user, user, `start${i}`, 'sandbox', Date.now())
      ]);
    }
    const key = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const der = await crypto.subtle.exportKey('pkcs8', key.privateKey);
    const pem = '-----BEGIN PRIVATE KEY-----\n' + btoa(String.fromCharCode(...new Uint8Array(der))) + '\n-----END PRIVATE KEY-----';
    const configured = { ...env, APNS_KEY_ID: 'TEST', APNS_TEAM_ID: 'TEAM', APNS_PRIVATE_KEY: pem };
    const calls: any[] = [];
    const mocked = vi.spyOn(globalThis, 'fetch').mockImplementation(async (url, options) => {
      calls.push({ url: String(url), headers: options!.headers, ...JSON.parse(options!.body as string) });
      return new Response(null, { status: 200 });
    });
    try {
      await pushActivity(configured, family, activityId, 1000);
      expect(calls).toHaveLength(2);
      expect(calls.every(c => c.aps.event === 'start' && c.aps.attributes.activityId === activityId)).toBe(true);
      expect(calls[0].headers['apns-topic']).toBe('app.pip.baby.push-type.liveactivity');
      expect(calls[0].headers.authorization).toMatch(/^bearer [^.]+\.[^.]+\.[^.]+$/);
      await pushActivity(configured, family, activityId, 1001);
      expect(calls).toHaveLength(2); // No duplicate starts before token callback.
      for (let i = 0; i < 2; i++) await env.DB.prepare('INSERT INTO live_tokens VALUES (?, ?, ?)').bind(devices[i], activityId, `update${i}`).run();
      await pushActivity(configured, family, activityId, 1002);
      expect(calls.slice(2).every(c => c.aps.event === 'update')).toBe(true);
      await env.DB.prepare('DELETE FROM members WHERE user_id = ?').bind(users[1]).run();
      await env.DB.prepare('UPDATE activities SET payload = ? WHERE id = ?').bind(JSON.stringify({ ...activity, endedAt: Date.now(), paused: true }), activityId).run();
      await pushActivity(configured, family, activityId, 1003);
      expect(calls).toHaveLength(5); expect(calls[4].aps.event).toBe('end'); expect(calls[4].aps['dismissal-date']).toBe(1003);
      mocked.mockResolvedValueOnce(new Response(JSON.stringify({ reason: 'InternalServerError' }), { status: 500 }));
      await expect(pushActivity(configured, family, activityId, 1004)).rejects.toThrow('retry');
      mocked.mockResolvedValueOnce(new Response(JSON.stringify({ reason: 'Unregistered' }), { status: 410 }));
      await pushActivity(configured, family, activityId, 1005);
      expect(await env.DB.prepare('SELECT 1 FROM live_tokens WHERE device_id = ?').bind(devices[0]).first()).toBeNull();
    } finally { mocked.mockRestore(); }
  });
});
