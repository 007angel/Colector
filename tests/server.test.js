const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const test = require('node:test');

const { createApp } = require('../server');

const fixturePath = path.join(__dirname, 'fixtures', 'metrics.json');
const metrics = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

function createFakePool() {
    const calls = [];

    return {
        calls,
        async query(sql, params = []) {
            calls.push({ sql, params });

            if (sql.includes('INSERT INTO server_metrics')) {
                return { rows: [{ id: 77 }] };
            }

            if (sql.includes('SELECT DISTINCT ON')) {
                return {
                    rows: [
                        {
                            hostname: 'linux-test-01',
                            ip_private: '10.0.0.15',
                            cpu_usage_percent: 42.5,
                            mem_usage_percent: 50,
                            disk_usage_percent: 50,
                            saturation_percent: 31.25,
                            uptime_days: 12,
                            timestamp: '2026-06-15T22:00:00.000Z'
                        }
                    ]
                };
            }

            return { rows: [] };
        }
    };
}

async function withServer(app, fn) {
    const server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));

    try {
        const { port } = server.address();
        await fn(`http://127.0.0.1:${port}`);
    } finally {
        await new Promise((resolve, reject) => {
            server.close((err) => (err ? reject(err) : resolve()));
        });
    }
}

test('rejects metrics without a valid API key', async () => {
    process.env.API_KEY = 'valid-key';
    const pool = createFakePool();
    const app = createApp(pool);

    await withServer(app, async (baseUrl) => {
        const response = await fetch(`${baseUrl}/api/metrics`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', authorization: 'Bearer wrong-key' },
            body: JSON.stringify(metrics)
        });

        assert.equal(response.status, 401);
        assert.equal(pool.calls.length, 0);
    });
});

test('stores metrics, heavy files, open ports, and top processes with bearer API key', async () => {
    process.env.API_KEY = 'valid-key';
    const pool = createFakePool();
    const app = createApp(pool);

    await withServer(app, async (baseUrl) => {
        const response = await fetch(`${baseUrl}/api/metrics`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', authorization: 'Bearer valid-key' },
            body: JSON.stringify(metrics)
        });

        const body = await response.json();
        assert.equal(response.status, 200);
        assert.deepEqual(body, { success: true, id: 77 });
    });

    assert.equal(pool.calls.length, 4);
    assert.match(pool.calls[0].sql, /INSERT INTO server_metrics/);
    assert.equal(pool.calls[0].params[0], 'linux-test-01');
    assert.equal(pool.calls[0].params[6], 42.5);
    assert.equal(pool.calls[0].params[10], 8192);
    assert.equal(pool.calls[0].params[14], 102400);
    assert.equal(pool.calls[0].params[23], JSON.stringify(metrics));

    assert.match(pool.calls[1].sql, /INSERT INTO heavy_files/);
    assert.deepEqual(pool.calls[1].params, [77, '/var/log/big.log', '150M']);

    assert.match(pool.calls[2].sql, /INSERT INTO open_ports/);
    assert.deepEqual(pool.calls[2].params, [77, 22, 'tcp']);

    assert.match(pool.calls[3].sql, /INSERT INTO top_processes/);
    assert.deepEqual(pool.calls[3].params, [77, 1234, 'root', 7.5, 3.2, 'node']);
});

test('returns dashboard metrics only with bearer API key', async () => {
    process.env.API_KEY = 'valid-key';
    const pool = createFakePool();
    const app = createApp(pool);

    await withServer(app, async (baseUrl) => {
        const unauthorized = await fetch(`${baseUrl}/api/dashboard`);
        assert.equal(unauthorized.status, 401);

        const response = await fetch(`${baseUrl}/api/dashboard`, {
            headers: { authorization: 'Bearer valid-key' }
        });
        const body = await response.json();

        assert.equal(response.status, 200);
        assert.equal(body[0].hostname, 'linux-test-01');
        assert.equal(body[0].cpu_usage_percent, 42.5);
    });
});
