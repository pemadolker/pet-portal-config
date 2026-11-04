// E2 - One winner out of many contenders.
// 2,000 adopters try to adopt 10 pets within 60 seconds. Pass: exactly 10 applications
// accepted (one per pet); every other attempt answered 409 PET_TAKEN; nothing else.
//
//   k6 run -e ADMIN_EMAIL=... -e ADMIN_PASSWORD=... experiments/k6/e2-one-winner.js
// Run experiments/loadtest-mode.sh on first (raises the gateway's per-IP limits through etcd).
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { BASE, auth, must, shelterWithPets, adopters } from './lib.js';

const USERS = Number(__ENV.USERS || 2000);
const PETS = Number(__ENV.PETS || 10);
const accepted = new Counter('adoption_accepted');
const taken = new Counter('adoption_taken');
const other = new Counter('adoption_other');

export const options = {
  setupTimeout: '30m',
  scenarios: {
    rush: { executor: 'shared-iterations', vus: Number(__ENV.VUS || 200), iterations: USERS, maxDuration: '60s' },
  },
  thresholds: {
    adoption_accepted: [`count==${PETS}`],
    adoption_taken: [`count==${USERS - PETS}`],
    adoption_other: ['count==0'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  const run = `e2-${Date.now().toString(36)}`;
  const s = shelterWithPets(run, PETS);
  console.log(`setup: shelter with ${PETS} pets; creating ${USERS} adopters (takes a few minutes: scrypt is deliberately slow)`);
  return { ...s, tokens: adopters(run, USERS) };
}

export default function (data) {
  const k = exec.scenario.iterationInTest;
  const res = http.post(`${BASE}/adoptions`, JSON.stringify({
    petId: data.petIds[k % PETS], homeType: 'house', hasYard: true, message: 'Contention test: I would like to adopt this pet please.',
  }), auth(data.tokens[k]));
  if (res.status === 201) accepted.add(1);
  else if (res.status === 409 && res.json('code') === 'PET_TAKEN') taken.add(1);
  else other.add(1);
  check(res, { 'accepted or PET_TAKEN': (r) => r.status === 201 || r.status === 409 });
}

export function teardown(data) {
  const apps = must(http.get(`${BASE}/adoptions/shelter`, auth(data.staffToken)), 200, 'shelter applications');
  const perPet = {};
  for (const a of apps) perPet[a.petId] = (perPet[a.petId] || 0) + 1;
  const max = Math.max(0, ...Object.values(perPet));
  console.log(`stored applications: ${apps.length}, pets with an application: ${Object.keys(perPet).length}, most applications on one pet: ${max}`);
  if (apps.length !== PETS || max !== 1) throw new Error('E2 FAIL: the database does not hold exactly one application per pet');
  console.log('E2 PASS (database check). Confirm in SQL: see experiments/README.md');
}
