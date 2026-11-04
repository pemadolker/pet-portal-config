// E5 (zero-downtime release) and E7 (worker loss): steady traffic across the core
// path while something changes underneath. Pass for E5: 0 failed requests during the
// rollout. Pass for E7: success rate above 99 % while a worker is drained.
//   k6 run -e DURATION=6m experiments/k6/e5-steady-load.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { BASE, PARAMS, auth, login } from './lib.js';

export const options = {
  scenarios: {
    browse: { executor: 'constant-arrival-rate', rate: Number(__ENV.RATE || 30), timeUnit: '1s', duration: __ENV.DURATION || '6m', preAllocatedVUs: 30, maxVUs: 120 },
  },
  thresholds: {
    http_req_failed: [__ENV.MAX_FAILED_RATE ? `rate<=${__ENV.MAX_FAILED_RATE}` : 'rate==0'],
    http_req_duration: ['p(95)<500'],
  },
};

export function setup() {
  return { token: login(__ENV.ADMIN_EMAIL, __ENV.ADMIN_PASSWORD).token };
}

const paths = ['/search?limit=12', '/shelters', '/search?species=dog', '/reports/summary', '/notifications'];
export default function (data) {
  const p = paths[Math.floor(Math.random() * paths.length)];
  const res = http.get(`${BASE}${p}`, p.startsWith('/reports') || p.startsWith('/notif') ? auth(data.token) : PARAMS);
  check(res, { '2xx': (r) => r.status >= 200 && r.status < 300 });
}
