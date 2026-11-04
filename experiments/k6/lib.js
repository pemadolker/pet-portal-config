// Shared helpers for the k6 experiments.
import http from 'k6/http';
import { check, fail } from 'k6';

export const BASE = __ENV.BASE_URL || 'https://portal.local/api';
export const PARAMS = { headers: { 'Content-Type': 'application/json' }, timeout: '15s' };
export const auth = (token) => ({ ...PARAMS, headers: { ...PARAMS.headers, Authorization: `Bearer ${token}` } });

export function must(res, status, what) {
  if (res.status !== status) fail(`${what}: expected ${status}, got ${res.status} ${res.body && res.body.slice(0, 200)}`);
  return res.json();
}

export function login(email, password) {
  return must(http.post(`${BASE}/login`, JSON.stringify({ email, password }), PARAMS), 200, `login ${email}`);
}

// Creates an approved shelter with `pets` pets; returns { staffToken, shelterId, petIds }.
export function shelterWithPets(run, pets) {
  const admin = login(__ENV.ADMIN_EMAIL, __ENV.ADMIN_PASSWORD).token;
  const email = `${run}-staff@load.test`;
  must(http.post(`${BASE}/signup`, JSON.stringify({ name: 'Load Staff', email, password: 'load-test-pass', role: 'staff', shelterName: `Load shelter ${run}`, district: 'Thimphu' }), PARAMS), 201, 'staff signup');
  const staff = login(email, 'load-test-pass');
  must(http.patch(`${BASE}/shelters/${staff.user.shelterId}/approval`, JSON.stringify({ status: 'approved' }), auth(admin)), 200, 'approve shelter');
  const petIds = [];
  for (let i = 0; i < pets; i++) {
    const p = must(http.post(`${BASE}/pets`, JSON.stringify({ name: `Race ${i}`, species: 'dog', sex: i % 2 ? 'male' : 'female', ageMonths: 12 + i, description: 'A pet created for a load experiment.' }), auth(staff.token)), 201, 'create pet');
    petIds.push(p.id);
  }
  return { staffToken: staff.token, shelterId: staff.user.shelterId, petIds };
}

// Signs up and logs in `n` adopters in parallel batches; returns their tokens.
export function adopters(run, n, batch = 25) {
  const tokens = [];
  for (let start = 0; start < n; start += batch) {
    const idx = [...Array(Math.min(batch, n - start)).keys()].map((k) => start + k);
    const signups = http.batch(idx.map((k) => ['POST', `${BASE}/signup`, JSON.stringify({ name: `Adopter ${k}`, email: `${run}-u${k}@load.test`, password: 'load-test-pass' }), PARAMS]));
    signups.forEach((r, j) => check(r, { 'adopter created': (x) => x.status === 201 }) || fail(`signup ${idx[j]}: ${r.status} ${r.body}`));
    const logins = http.batch(idx.map((k) => ['POST', `${BASE}/login`, JSON.stringify({ email: `${run}-u${k}@load.test`, password: 'load-test-pass' }), PARAMS]));
    logins.forEach((r, j) => { if (r.status !== 200) fail(`login ${idx[j]}: ${r.status}`); tokens.push(r.json().token); });
  }
  return tokens;
}
