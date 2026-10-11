"""Run ucode boundary tests with mocked actions and private fixture files only."""
import json
import shlex
from pathlib import Path
from offload_lifecycle_support import arguments, Device, save

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = '/tmp/getdomains-offload-ucode-unit'


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'cases': []}

    def ucode(source, name):
        path = DIRECTORY + '/' + name + '.uc'
        device.upload(source, path)
        return device.run('ucode ' + shlex.quote(path), False)

    try:
        device.run('test ! -e ' + DIRECTORY + '; mkdir -m 0700 ' + DIRECTORY)
        shell = (ROOT / 'getdomains-offload.sh').read_text()
        policy = shell.split('gd_safe_policy() {', 1)[1].split('gd_fingerprint() {', 1)[0]
        validator = policy.split("ucode -e '", 1)[1].split("' || return 1", 1)[0]
        chains = json.loads(device.run('nft -j list chains')[1])
        for label, extra, expected in [
            ('native-hooks', None, 0),
            ('foreign-late-drop-hook', {'chain': {'family': 'inet', 'table': 'fw4', 'name': 'foreign', 'hook': 'forward', 'prio': 20, 'type': 'filter'}}, 1),
            ('changed-native-priority', {'chain': {'family': 'inet', 'table': 'fw4', 'name': 'forward', 'hook': 'forward', 'prio': 20, 'type': 'filter'}}, 1),
            ('foreign-family', {'chain': {'family': 'ip', 'table': 'fw4', 'name': 'forward', 'hook': 'forward', 'prio': 0, 'type': 'filter'}}, 1),
            ('changed-native-type', {'chain': {'family': 'inet', 'table': 'fw4', 'name': 'forward', 'hook': 'forward', 'prio': 0, 'type': 'nat'}}, 1),
        ]:
            payload = {'nftables': chains['nftables'] + ([extra] if extra else [])}
            device.upload(json.dumps(payload), DIRECTORY+'/chains.json')
            device.upload(validator, DIRECTORY+'/hooks.uc')
            code, output = device.run('ucode '+DIRECTORY+'/hooks.uc <'+DIRECTORY+'/chains.json', False)
            assert code == expected, (label, output)
        report['cases'].append({'case': 'native-hook-allowlist-and-foreign-hook-rejection', 'passed': True})
        software = shell.split('gd_software_ok() {', 1)[1].split('gd_kill_switch() {', 1)[0]
        software_validator = software.split("ucode -e '", 1)[1].split("' || return 1", 1)[0]
        for label, rows, expected in [('empty-software-path', [], 0),
                                      ('foreign-cache', [{'flowtable': {'name': 'foreign'}}], 1)]:
            device.upload(json.dumps({'nftables': rows}), DIRECTORY + '/flowtables.json')
            device.upload(software_validator, DIRECTORY + '/flowtables.uc')
            code, output = device.run('ucode ' + DIRECTORY + '/flowtables.uc <' + DIRECTORY + '/flowtables.json', False)
            assert code == expected, (label, output)
        report['cases'].append({'case': 'software-fallback-refuses-running-foreign-cache', 'passed': True})
        fingerprint = shell.split('gd_fingerprint() {', 1)[1].split('gd_render() {', 1)[0]
        canonical = fingerprint.split("nft -j list chains | ucode -e '", 1)[1].split("'\n", 1)[0]
        outputs = []
        for label, payload in [('original', chains), ('recreated', json.loads(json.dumps(chains)))]:
            if label == 'recreated':
                payload['nftables'].reverse()
                for row in payload['nftables']:
                    if row.get('chain'):
                        row['chain']['handle'] = row['chain'].get('handle', 0) + 1000
            device.upload(json.dumps(payload), DIRECTORY + '/canonical.json')
            device.upload(canonical, DIRECTORY + '/canonical.uc')
            code, output = device.run('ucode ' + DIRECTORY + '/canonical.uc <' + DIRECTORY + '/canonical.json', False)
            assert code == 0, output
            outputs.append(output)
        assert outputs[0] == outputs[1], 'Object IDs/order must not look like a policy change'
        report['cases'].append({'case': 'policy-fingerprint-ignores-recreated-object-ids-and-order', 'passed': True})
        source = (ROOT / 'getdomains-offload-luci.uc').read_text()
        source = source.split("const native = require('luci.controller.admin.uci');", 1)[1]
        source = source.replace('return {\n    action_command:',
                                'return { test_critical: critical, test_allowed: command_allowed,\n    action_command:')
        mock = r'''
let entries = {}, grants = {}, form = {}, response = {}, commands = [];
let mode = 'strict', pending = false, owner = true, system_error = 0;
let ctx = { authsession: 'a' }; let config = {}; let dispatcher = {};
let native = {};
function readfile(path) { return path == '/etc/getdomains/offload-mode' ? mode : null; }
function writefile() { return true; }
function mkdir() { return true; }
function rmdir() { return true; }
function unlink() { return true; }
function stat(path) {
    if (path == '/tmp/getdomains-offload/submission.lock') return pending;
    if (path == '/tmp/getdomains-offload/owner.sock') return owner;
    if (path == '/tmp/getdomains-offload/boot-settling') return false;
    return { uid: 0, gid: 0, mode: 0755 };
}
let ubus = { call: function(object, method, args) {
    if (object == 'session') return { access: !!grants[args.scope + ':' + args.object + ':' + args.function] };
    if (method == 'get') return { values: args.ubus_rpc_session ? entries.pending : entries.committed };
    return { changes: entries.changes };
} };
let http = { formvalue: function(key) { return form[key]; },
    status: function(code) { response.code = code; },
    prepare_content: function() {}, write: function(body) { response.body = body; },
    write_json: function(body) { response.body = body; } };
function system(command) { push(commands, command); return system_error; }
let controller = (function() {
'''
        cases = r'''
})();
function assert(value, label) { if (!value) die(label); }
assert(controller.test_critical({ network: [['set', 'lan', 'ipaddr', 'test']] }), 'network must be critical');
assert(controller.test_critical({ dhcp: [['set', 'wdns', 'dhcp_option', 'test']] }), 'WDNS must be critical');
for (let kind in ['ipset', 'domain', 'hostrecord', 'cname']) {
    entries = { pending: null, committed: { '.type': kind } };
    assert(!controller.test_critical({ dhcp: [['remove', 'manual']] }), 'deleted manual row ' + kind);
    assert(!controller.test_critical({ dhcp: [['add', 'manual', kind]] }), 'new manual row ' + kind);
}
entries = { pending: { '.type': 'dnsmasq' } };
assert(!controller.test_critical({ dhcp: [['list-add', 'main', 'server', '/example/test']] }), 'manual server');
assert(controller.test_critical({ dhcp: [['set', 'main', 'confdir', '/test']] }), 'confdir');
entries = {};
assert(controller.test_critical({ dhcp: [['remove', 'unknown']] }), 'unknown deleted row');
grants = { 'uci:network:write': true };
form = { command: '/sbin/ifup', argument: 'wan' };
controller.action_command();
assert(response.code == 403 && !length(commands), 'UCI permission must not grant exec');
grants['ubus:file:exec'] = true; grants['file:/sbin/ifup wan:exec'] = true;
assert(controller.test_allowed('/sbin/ifup', 'wan'), 'native command-line grant');
assert(!controller.test_allowed('/sbin/ifdown', 'wan'), 'different command must remain denied');
grants['ubus:rc:init'] = true;
assert(controller.test_allowed('/etc/init.d/network', 'reload'), 'native rc permission');
pending = true; response = {}; controller.action_apply_unchecked();
assert(response.code == 409 && !length(commands), 'empty apply must respect checked lock');
pending = false; mode = 'medium'; response = {};
grants = { 'ubus:rc:init': true };
form = { command: '/etc/init.d/sing-box', argument: 'restart' };
controller.action_command();
assert(response.body?.native && length(commands) == 1,
       'native service exec must not require an unrelated UCI write grant');
mode = 'strict'; owner = false; commands = []; response = {};
controller.action_command();
assert(response.body?.native && commands[0] == '/usr/libexec/getdomains-offload software-ok',
       'ownerless verified software command must stay native');
entries = { changes: { network: [['set', 'lan', 'proto', 'static']] } };
native.action_apply_unchecked = function() { response.body = 'native-software-apply'; };
response = {}; controller.action_apply_unchecked();
assert(response.body == 'native-software-apply', 'ownerless apply must not leave a checked lock');
system_error = 1; response = {}; controller.action_apply_unchecked();
assert(response.code == 503, 'an unverifiable ownerless state must not bypass the barrier');
printf('%J\n', { passed: true });
'''
        code, output = ucode(mock + source + cases, 'controller')
        assert code == 0, output
        report['cases'].append({'case': 'classification-native-acl-and-global-apply-lock', 'passed': True})

        job = (ROOT / 'getdomains-offload-job.uc').read_text()
        job = '\n'.join(line for line in job.splitlines() if not line.startswith('import '))
        job = job.replace('system(', 'mock_system(').replace('exit(', 'finish(')
        for label, request, changed, error, expected, prepared in [
            ('malformed-request', {}, False, 0, 400, False),
            ('command-injection', {'command': '/bin/sh', 'argument': 'reboot'}, False, 0, 400, False),
            ('ifdown-wan-excludes-port-restoration', {'command': '/sbin/ifdown', 'argument': 'wan'}, False, 0, 200, True),
            ('ifup-wan-restores-previously-down-port', {'command': '/sbin/ifup', 'argument': 'wan'}, False, 0, 200, True),
            ('snapshot-race', None, True, 0, 503, True),
            ('commit-failure', None, False, 6, 503, True),
            ('unchecked-native-no-data', None, False, 5, 204, True),
            ('checked-confirmation-publication', {'checked': True}, False, 0, 200, True),
            ('checked-apply-rpc-failure', {'checked': True}, False, 6, 503, True),
            ('confirmation-publication-failure', {'checked': True}, False, 9, 503, True),
        ]:
            valid = {'session': 'a'*32, 'checked': False, 'changes': {'network': [['set', 'lan', 'proto', 'static']]},
                     'token': 'b'*32, 'timeout': 90}
            if request == {}: valid = {}
            elif request: valid.update(request)
            header = "let ARGV = ['" + 'c'*32 + "'];\nlet request_input = " + json.dumps(valid) + ';\n'
            header += 'let changed = ' + str(changed).lower() + '; let rpc_error = ' + str(error) + ';\n'
            header += r'''
let store = {}, calls = [], methods = [], last_error = 0;
function readfile(path) { return index(path, '/request.json') >= 0 ? sprintf('%J', request_input) : store[path]; }
function writefile(path, data) { store[path] = data; return true; }
function rename(a, b) { store[b] = store[a]; return true; }
function rmdir() { return true; }
function unlink() { return true; }
function mock_system(command) { push(calls, command); return 0; }
function connect() { return {
    error: function(numeric) { let code = last_error; last_error = 0; return numeric ? code : code ? 'error' : null; },
    call: function(object, method, args) {
        push(methods, method); last_error = 0;
        if (method == 'changes') return { changes: changed ? {} : request_input.changes };
        if (method == 'commit' && rpc_error == 6) last_error = 6;
        if (method == 'apply' && rpc_error != 9) last_error = rpc_error;
        if (object == 'session' && method == 'set' && rpc_error == 9) last_error = 9;
        return {};
    }
}; }
function finish(code) {
    printf('%J\n', { code, calls, methods, store }); exit(0);
}
'''
            code, output = ucode(header + job + '\nfinish(0);\n', label)
            assert code == 0, output
            actual = json.loads(output)
            result = next(json.loads(value) for key, value in actual['store'].items() if key.endswith('/result.json'))
            assert result['status'] == expected, (label, actual)
            assert bool(actual['calls']) == prepared, (label, actual)
            if changed: assert 'commit' not in actual['methods'], actual
            if expected == 503:
                assert any(k.endswith('/rolled-back') for k in actual['store']), actual
                assert any('recover-job' in c for c in actual['calls']), actual
                if valid.get('checked'):
                    assert any(k.endswith('/await-confirm') for k in actual['store']), actual
            if valid.get('command') and expected == 200:
                assert result['body']['code'] == 0 and 'commit' not in actual['methods'], actual
                if valid['command'] == '/sbin/ifup':
                    assert any("printf 'wan\\n'" in call and '/ports' in call for call in actual['calls']), actual
                else:
                    assert any("sed -i '/^wan$/d'" in call for call in actual['calls']), actual
            elif expected == 200:
                assert result['body']['token'] == 'b'*32 and any(k.endswith('/await-confirm') for k in actual['store'])
            report['cases'].append({'case': label, 'passed': True})

        setup = (ROOT / 'getdomains-offload-setup.uc').read_text()
        fixture = DIRECTORY + '/setup'
        setup = setup.replace('/www/luci-static/resources', fixture).replace('/etc/getdomains', fixture)
        device.run('mkdir -p ' + fixture + '/view/network ' + fixture + '/view/system')
        device.upload(setup, DIRECTORY + '/setup.uc')
        originals = {
            fixture+'/ui.js': "'use strict';request.request(L.url('admin/uci', 'apply'));",
            fixture+'/view/network/interfaces.js': "'use strict';fs.exec('/sbin/ifup',[sid]);fs.exec('/sbin/ifdown',[sid]);",
            fixture+'/view/system/startup.js': "'use strict';this.callRcInit(name,action);",
        }
        for path, contents in originals.items(): device.upload(contents, path)
        device.run('ucode '+DIRECTORY+'/setup.uc check; ucode '+DIRECTORY+'/setup.uc install')
        patched = {path: device.run('cat '+path)[1] for path in originals}
        device.run('ucode '+DIRECTORY+'/setup.uc install; ucode '+DIRECTORY+'/setup.uc check')
        assert all(device.run('cat '+path)[1] == value for path, value in patched.items())
        device.run('ucode '+DIRECTORY+'/setup.uc remove')
        assert all(device.run('cat '+path)[1] == value for path, value in originals.items())
        device.run('ucode '+DIRECTORY+'/setup.uc install')
        device.upload(patched[fixture+'/ui.js']+'// unrelated user edit\n', fixture+'/ui.js')
        device.run('ucode '+DIRECTORY+'/setup.uc remove')
        assert device.run('cat '+fixture+'/ui.js')[1] == originals[fixture+'/ui.js']+'// unrelated user edit\n'
        for path, contents in originals.items(): device.upload(contents, path)
        device.upload("'use strict'; unknown_revision();", fixture+'/view/system/startup.js')
        assert device.run('ucode '+DIRECTORY+'/setup.uc install', False)[0] != 0
        assert device.run('cat '+fixture+'/ui.js')[1] == originals[fixture+'/ui.js']
        report['cases'].append({'case': 'all-view-preflight-idempotence-and-foreign-edit-preservation', 'passed': True})
        report['status'] = 'passed'
    finally:
        # Fixed private fixture path, never a configuration or library directory.
        device.run('rm -rf ' + DIRECTORY, False)
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
