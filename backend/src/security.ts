import { scrypt, randomBytes, timingSafeEqual, createHash } from 'node:crypto';
const derive = (password: string, salt: string) => new Promise<Buffer>((resolve, reject) => {
  scrypt(password, salt, 32, { N: 16384, r: 8, p: 5, maxmem: 64 * 1024 * 1024 }, (error, key) => error ? reject(error) : resolve(key));
});
export const token = () => randomBytes(32).toString('hex');
export const hash = (value: string) => createHash('sha256').update(value).digest('hex');
export async function hashPassword(password: string) {
  const salt = randomBytes(16).toString('hex');
  return `scrypt-v1:${salt}:${(await derive(password, salt)).toString('hex')}`;
}
export async function verifyPassword(password: string, encoded: string) {
  const [, salt, expected] = encoded.split(':');
  const actual = await derive(password, salt || '00000000000000000000000000000000');
  const target = Buffer.from(expected || '00'.repeat(32), 'hex');
  return target.length === actual.length && timingSafeEqual(actual, target);
}
