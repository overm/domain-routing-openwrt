// LuCI transport tests without a browser, native services or device mutation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../getdomains-offload.js'), 'utf8');
let passed = 0;
const response = (status, value) => ({ status, json: () => value, responseText: '' });
const job = 'a'.repeat(32);
function fixture(items) {
    let calls = [], now = 0;
    let request = { request: (url, options) => {
        calls.push({url, options});
        let item = items.shift();
        if (item instanceof Error) return Promise.reject(item);
        if (!item) return Promise.reject(new Error('Unexpected request'));
        return Promise.resolve(item);
    }};
    let obj = new Function('request', 'baseclass', 'L', 'window', 'Date', source)(
        request, {extend: x => x}, {url: (...args) => '/' + args.join('/'),
            env: {sessionid: 'session', token: 'csrf'}},
        {setTimeout: f => { now += 1500; f(); }}, {now: () => now});
    return {obj, calls, expire: () => {now = 180001;}};
}
async function main() {
    for (let status of [200, 204, 400, 403, 409, 503]) {
        let r = response(status, {}), f = fixture([r]);
        assert.equal(await f.obj.applyRequest('/apply', {}), r);
        assert.equal(f.calls.length, 1); passed++;
    }
    let f = fixture([response(202, {getdomains_job: '../../bad'})]);
    await assert.rejects(f.obj.applyRequest('/apply', {}), /Invalid apply job/); passed++;
    f = fixture([response(202, {getdomains_job: job}), new Error('LAN down'),
        response(504, {}), response(200, {pending: true}),
        response(200, {status: 200, body: {token: 'confirm-token'}})]);
    let r = await f.obj.applyRequest('/apply', {});
    assert.equal(r.status, 200); assert.equal(r.json().token, 'confirm-token');
    assert.equal(f.calls.length, 5);
    assert.deepEqual(f.calls[1].options.query, {job, sid: 'session'}); passed++;
    f = fixture([response(202, {getdomains_job: job}), response(200, {status: 503, body: 'Preparation failed'})]);
    r = await f.obj.applyRequest('/apply', {});
    assert.equal(r.status, 503); assert.equal(r.responseText, 'Preparation failed'); passed++;
    f = fixture([response(202, {getdomains_job: job}), response(200, {pending: true})]);
    let promise = f.obj.applyRequest('/apply', {}); f.expire();
    await assert.rejects(promise, /timed out/); passed++;
    f = fixture([response(200, {native: true})]);
    r = await f.obj.execRequest('/sbin/ifup', ['wan'], (cmd, args) => ({cmd, args}));
    assert.deepEqual(r, {cmd: '/sbin/ifup', args: ['wan']}); passed++;
    f = fixture([response(202, {getdomains_job: job}), response(200, {status: 200, body: {code: 0}})]);
    r = await f.obj.execRequest('/sbin/ifup', ['wan'], () => {throw new Error('Must not repeat operation');});
    assert.equal(r.code, 0); passed++;
    f = fixture([response(409, 'busy')]);
    await assert.rejects(f.obj.execRequest('/sbin/ifup', ['wan'], () => {}), /Operation failed/); passed++;
    f = fixture([]);
    assert.equal(await f.obj.rcRequest('dnsmasq', 'restart', () => 17), 17);
    assert.equal(f.calls.length, 0); passed++;
    f = fixture([response(200, {native: true})]);
    assert.equal(await f.obj.rcRequest('network', 'restart', () => Promise.resolve(0)), 0); passed++;
    // All installed resource files must parse in LuCI's function wrapper.
    new Function(fs.readFileSync(path.join(__dirname, '../getdomains-offload-status.js'), 'utf8'));
    passed++;
    console.log(JSON.stringify({passed}));
}
main().catch(e => { console.error(e); process.exit(1); });
