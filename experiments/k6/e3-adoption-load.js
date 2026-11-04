// E3 - Adoption autoscaling.
// Baseline: run with PROFILE=baseline against ONE adoption pod (KEDA paused, see README)
// to find its capacity. Then the real run: ramp up, hold 5 minutes, stop.
// Pass: adoption pods rise from 2 under load, never exceed 6, and return to 2 after
// the scale-down window. Watch: kubectl -n pet-portal-prod get hpa keda-hpa-adoption -w
import http from 'k6/http';
import { check } from 'k6';
import { BASE, PARAMS, shelterWithPets } from './lib.js';

const PEAK = Number(__ENV.PEAK_RPS || 250);
const profiles = {
  baseline: { executor: 'ramping-arrival-rate', startRate: 10, timeUnit: '1s', preAllocatedVUs: 100, maxVUs: 400,
    stages: [{ target: 400, duration: '4m' }] },
  rush: { executor: 'ramping-arrival-rate', startRate: 5, timeUnit: '1s', preAllocatedVUs: 100, maxVUs: 400,
    stages: [{ target: PEAK, duration: '1m' }, { target: PEAK, duration: '5m' }, { target: 0, duration: '30s' }] },
};

export const options = {
  setupTimeout: '5m',
  scenarios: { load: profiles[__ENV.PROFILE || 'rush'] },
  thresholds: __ENV.PROFILE === 'baseline' ? {} : {
    http_req_failed: ['rate<0.01'],             // availability above 99 %
    'http_req_duration{kind:availability}': ['p(95)<500'],
  },
};

export function setup() {
  return shelterWithPets(`e3-${Date.now().toString(36)}`, 20);
}

// Mostly the adoption service: everyone on a pet page polls its live availability.
export default function (data) {
  const pet = data.petIds[Math.floor(Math.random() * data.petIds.length)];
  const res = http.get(`${BASE}/adoptions/availability/${pet}`, { ...PARAMS, tags: { kind: 'availability' } });
  check(res, { 'availability 200': (r) => r.status === 200 });
}
