// Minimal smoke tests run by CI before any image is built/pushed.
// Keeping these fast and dependency-light on purpose: CI should fail fast.

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

process.env.PORT = '8091';
process.env.APP_VERSION = 'test-version';
process.env.ENVIRONMENT = 'test';
process.env.FAILURE_RATE = '0';

const app = require('../src/index.js');

let server;

test.before(() => {
  server = app.listen(8091);
});

test.after(() => {
  server.close();
});

function get(path) {
  return new Promise((resolve, reject) => {
    http.get(`http://localhost:8091${path}`, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    }).on('error', reject);
  });
}

test('healthz returns 200', async () => {
  const res = await get('/healthz');
  assert.strictEqual(res.status, 200);
});

test('readyz returns 200', async () => {
  const res = await get('/readyz');
  assert.strictEqual(res.status, 200);
});

test('version endpoint reports configured version', async () => {
  const res = await get('/version');
  const body = JSON.parse(res.body);
  assert.strictEqual(body.version, 'test-version');
  assert.strictEqual(body.environment, 'test');
});

test('metrics endpoint exposes http_requests_total', async () => {
  const res = await get('/metrics');
  assert.match(res.body, /http_requests_total/);
});
