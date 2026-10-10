import { DurableObject } from 'cloudflare:workers';
import type { Env } from './index';
import { pushActivity } from './push';

// This binding is private. Public access passes session + family authorization first.
export class FamilyRoom extends DurableObject<Env> {
  async fetch(request: Request) {
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('Upgrade required', { status: 426 });
    const pair = new WebSocketPair();
    pair[1].serializeAttachment({ session: request.headers.get('X-Session'), family: request.headers.get('X-Family') });
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].send('sync'); // Close the subscribe/snapshot race.
    return new Response(null, { status: 101, webSocket: pair[0] });
  }
  async publish(activityId?: string, family?: string) {
    if (activityId && family) {
      await this.ctx.storage.put(`pending:${activityId}`, { family, nonce: crypto.randomUUID() });
      await this.ctx.storage.setAlarm(Date.now() + 100);
    }
    for (const socket of this.ctx.getWebSockets()) {
      const { session, family } = socket.deserializeAttachment();
      const allowed = await this.env.DB.prepare('SELECT 1 FROM sessions s JOIN members m ON m.user_id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ? AND m.family_id = ?').bind(session, Date.now(), family).first();
      try { if (allowed) socket.send('sync'); else socket.close(1008, 'Session ended'); } catch { /* disconnected */ }
    }
  }
  async alarm() {
    const pending = await this.ctx.storage.list<{family: string; nonce: string}>({ prefix: 'pending:' });
    for (const [key, value] of pending) {
      try {
        const activityId = key.slice(8);
        const previous = await this.ctx.storage.get<number>(`timestamp:${activityId}`) || 0;
        const timestamp = Math.max(Math.floor(Date.now() / 1000), previous + 1);
        await this.ctx.storage.put(`timestamp:${activityId}`, timestamp);
        await pushActivity(this.env, value.family, activityId, timestamp);
        // Never drop an update that arrived while Apple was processing this push.
        await this.ctx.storage.transaction(async tx => {
          const current = await tx.get<{nonce: string}>(key);
          if (current?.nonce === value.nonce) await tx.delete(key);
        });
      } catch { await this.ctx.storage.setAlarm(Date.now() + 30000); }
    }
    if ((await this.ctx.storage.list({ prefix: 'pending:', limit: 1 })).size && !await this.ctx.storage.getAlarm()) await this.ctx.storage.setAlarm(Date.now() + 1000);
  }
  webSocketMessage(socket: WebSocket) { socket.send('pong'); }
  webSocketClose(socket: WebSocket) { socket.close(); }
}
