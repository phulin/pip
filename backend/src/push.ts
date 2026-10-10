import type { Env } from './index';

export const pushEnabled = (env: Env) => Boolean(env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_PRIVATE_KEY);
const b64 = (data: string | Uint8Array) => btoa(typeof data === 'string' ? data : String.fromCharCode(...data)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
let cached: { key: string; jwt: string; until: number } | undefined;
async function authorization(env: Env) {
  if (cached && cached.key === env.APNS_KEY_ID && cached.until > Date.now()) return cached.jwt;
  const pem = env.APNS_PRIVATE_KEY!.replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const unsigned = b64(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID })) + '.' + b64(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned));
  const jwt = unsigned + '.' + b64(new Uint8Array(signature));
  cached = { key: env.APNS_KEY_ID!, jwt, until: Date.now() + 45 * 60000 };
  return jwt;
}
export function liveState(a: any, time: number) {
  const extra = a.endedAt == null && !a.paused && a.segmentStartedAt != null ? Math.max(0, (time - a.segmentStartedAt) / 1000) : 0;
  const left = a.leftSeconds + (a.side === 'left' ? extra : 0), right = a.rightSeconds + (a.side === 'right' ? extra : 0);
  return { side: a.side === 'left' ? 'Left' : 'Right', paused: a.paused, elapsed: left + right,
    // Swift's default Date Codable uses seconds since 2001-01-01.
    timerStart: time / 1000 - left - right - 978307200, leftSeconds: left, rightSeconds: right };
}
export async function pushActivity(env: Env, family: string, activityId: string, timestamp: number) {
  if (!pushEnabled(env)) return;
  const row = await env.DB.prepare('SELECT a.payload, b.name FROM activities a JOIN babies b ON b.id = a.baby_id WHERE a.id = ? AND a.family_id = ? AND a.kind = ?').bind(activityId, family, 'breast').first<{payload: string; name: string}>();
  if (!row) return;
  const a = JSON.parse(row.payload), ended = a.endedAt != null || a.deleted;
  const devices = await env.DB.prepare('SELECT d.id, d.token, d.environment, t.token AS update_token FROM live_devices d JOIN sessions s ON s.token_hash = d.session_hash JOIN members m ON m.user_id = d.user_id LEFT JOIN live_tokens t ON t.device_id = d.id AND t.activity_id = ? WHERE m.family_id = ? AND s.expires_at > ?').bind(activityId, family, Date.now()).all<{id: string; token: string; environment: string; update_token: string | null}>();
  let failed = false;
  for (const device of devices.results) {
    const start = !device.update_token;
    if (start && ended) continue;
    if (start && await env.DB.prepare('SELECT 1 FROM live_starts WHERE device_id = ? AND activity_id = ?').bind(device.id, activityId).first()) continue;
    const aps: Record<string, unknown> = { timestamp, event: ended ? 'end' : start ? 'start' : 'update', 'content-state': liveState(a, Date.now()) };
    if (start) Object.assign(aps, { 'attributes-type': 'FeedAttributes', attributes: { activityId, babyName: row.name }, alert: { title: `${row.name}’s feed`, body: 'Feeding started' }, 'input-push-token': 1 });
    if (ended) aps['dismissal-date'] = timestamp;
    else aps['stale-date'] = timestamp + 8 * 3600;
    try {
      const response = await fetch(`https://${device.environment === 'sandbox' ? 'api.sandbox' : 'api'}.push.apple.com/3/device/${device.update_token || device.token}`, {
        method: 'POST', signal: AbortSignal.timeout(8000), headers: { authorization: `bearer ${await authorization(env)}`, 'apns-topic': 'app.pip.baby.push-type.liveactivity', 'apns-push-type': 'liveactivity', 'apns-priority': '10', 'apns-expiration': String(Math.floor(Date.now() / 1000) + 300), 'apns-collapse-id': activityId }, body: JSON.stringify({ aps })
      });
      if (response.ok) {
        if (start) await env.DB.prepare('INSERT OR IGNORE INTO live_starts VALUES (?, ?)').bind(device.id, activityId).run();
      } else {
        const error = await response.json() as { reason?: string };
        if (response.status === 410 || error.reason === 'BadDeviceToken' || error.reason === 'Unregistered') {
          if (start) await env.DB.prepare('DELETE FROM live_devices WHERE id = ?').bind(device.id).run();
          else await env.DB.prepare('DELETE FROM live_tokens WHERE device_id = ? AND activity_id = ?').bind(device.id, activityId).run();
        } else { console.error('APNs rejected delivery', response.status, error.reason); failed = true; }
      }
    } catch { failed = true; }
  }
  if (failed) throw new Error('APNs delivery will retry');
}
