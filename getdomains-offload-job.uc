// Detached LuCI job. All request fields are validated before device mutation.
import { readfile, writefile, rename, rmdir, unlink } from 'fs';
import { connect } from 'ubus';
let id = ARGV[0];
if (!match(id ?? '', /^[0-9a-f]{32}$/)) exit(2);
let dir = '/tmp/getdomains-offload', folder = dir + '/jobs/' + id;
function unreserve() {
    unlink(dir + '/submission.lock/start');
    rmdir(dir + '/submission.lock');
}
function result(status, body) {
    if (!writefile(folder + '/result.new', sprintf('%J', { status, body })) ||
        !rename(folder + '/result.new', folder + '/result.json')) die('Could not save job status');
}
function invalid_request() {
    result(400, 'Invalid apply request');
    unreserve();
    exit(2);
}
let request;
try { request = json(readfile(folder + '/request.json') ?? '{}'); }
catch (e) { invalid_request(); }
if (!match(request.session ?? '', /^[0-9a-f]{32}$/) || type(request.checked) != 'bool' ||
    type(request.changes) != 'object' || !match(request.token ?? '', /^[0-9a-f]{32}$/) ||
    type(request.timeout) != 'int' || request.timeout < 90 || request.timeout > 600) invalid_request();
if (request.command != null) {
    let command = request.command, argument = request.argument;
    let valid = (command == '/sbin/ifup' || command == '/sbin/ifdown') ?
        !!match(argument ?? '', /^[a-zA-Z0-9_]{1,32}$/) :
        (command == '/etc/init.d/network' || command == '/etc/init.d/firewall' ||
         command == '/etc/init.d/sing-box') &&
        (argument == 'start' || argument == 'stop' || argument == 'restart' || argument == 'reload');
    if (!valid) invalid_request();
}
let bus = connect();
function canonical(value) {
    if (type(value) == 'object') {
        let parts = [];
        for (let key in sort(keys(value))) push(parts, sprintf('%J:%s', key, canonical(value[key])));
        return '{' + join(',', parts) + '}';
    }
    if (type(value) == 'array') return '[' + join(',', map(value, canonical)) + ']';
    return sprintf('%J', value);
}
function rpc(method, fields) {
    let args = { ubus_rpc_session: request.session, ...fields };
    bus.error(); // native LuCI clears the previous ubus status before a call
    let result = bus.call('uci', method, args);
    let code = bus.error(true);
    // Native unchecked apply reports UBUS_STATUS_NO_DATA as HTTP 204.
    // It is a successful terminal response, not a failed preparation/commit.
    if (code && !(code == 5 && method == 'apply' && !request.checked))
        die('UCI ' + method + ' failed with ubus status ' + code);
    return result;
}
let prepared = false;
try {
    // Recheck the authorized session's pending changes after the physical pause.
    if (system('/usr/libexec/getdomains-offload prepare-job') != 0) die('Preparation failed');
    prepared = true;
    if (canonical(rpc('changes', {})?.changes) != canonical(request.changes))
        die('Pending configuration changed during preparation');
    if (request.command) {
        let command = request.command, argument = request.argument;
        let code = system('GD_OFFLOAD_TRANSACTION=1 ' + command + ' ' + argument +
                          ' >' + folder + '/command.log 2>&1');
        if (command == '/sbin/ifdown' && argument == 'wan')
            system("sed -i '/^wan$/d' " + dir + '/ports');
        // ifup can be queued by netifd while its Ethernet parent is held down.
        // WAN was absent from the snapshot when explicitly stopped previously;
        // restore this newly requested child before waiting for DHCP to settle.
        if (command == '/sbin/ifup' && argument == 'wan')
            system("grep -qx wan " + dir + "/ports || printf 'wan\\n' >> " + dir + '/ports');
        if (!code) unlink(dir + '/rolled-back');
        if (system('/usr/libexec/getdomains-offload resume-job') != 0) die('Resume failed');
        result(200, { code, stdout: '', stderr: code ? 'Operation failed' : '' });
        unreserve();
        exit(code ? 1 : 0);
    }
    if (!request.checked)
        for (let package in request.changes) rpc('commit', { config: package });
    // Arm the closed-admission interval before native apply can schedule its
    // rollback. An RPC/publication error must not reopen a pending snapshot.
    if (request.checked && !writefile(dir + '/await-confirm', sprintf('%d', time() + request.timeout + 5)))
        die('Could not retain pending confirmation');
    rpc('apply', { rollback: request.checked, timeout: request.timeout });
    unlink(dir + '/rolled-back');
    if (request.checked) {
        bus.call('session', 'set', {
            ubus_rpc_session: '00000000000000000000000000000000',
            values: { rollback: { token: request.token, session: request.session,
                                 timeout: time() + request.timeout } }
        });
        if (bus.error()) die('Could not publish confirmation');
    }
    if (system('/usr/libexec/getdomains-offload resume-job') != 0) die('Resume failed');
    result(request.checked ? 200 : 204, request.checked ? { token: request.token } : null);
    if (!request.checked) unreserve();
}
catch (e) {
    if (prepared) {
        // Reconcile the actual policy, but quarantine hardware after any error.
        // A checked apply may already be running even if its reply failed.
        if (!writefile(dir + '/rolled-back', 'apply-error\n')) {
            system('/usr/libexec/getdomains-offload emergency');
            exit(1);
        }
        system('/usr/libexec/getdomains-offload recover-job');
    }
    result(503, '' + e);
    if (!readfile(dir + '/await-confirm')) unreserve();
    exit(1);
}
