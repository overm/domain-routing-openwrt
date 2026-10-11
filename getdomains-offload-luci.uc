// Separate controller; the stock UCI controller and its confirm token remain.
import { readfile, writefile, mkdir, rmdir, unlink, stat } from 'fs';
const native = require('luci.controller.admin.uci');
const directory = '/tmp/getdomains-offload';
function unreserve() {
    unlink(directory + '/submission.lock/start');
    rmdir(directory + '/submission.lock');
}
function reserve() {
    if (!mkdir(directory + '/submission.lock', 0700)) return false;
    if (!writefile(directory + '/submission.lock/start', split(readfile('/proc/uptime'), '.')[0])) {
        unreserve(); return false;
    }
    return true;
}

function critical(changes) {
    for (let package in changes) {
        if (package == 'network' || package == 'firewall' || package == 'sing-box' ||
            package == 'pbr' || package == 'mwan3' || package == 'sqm' || package == 'qos')
            return true;
        if (package != 'dhcp') continue;
        for (let change in changes[package]) {
            let section = change[1];
            if (section == 'wdns') return true;
            let row = ubus.call('uci', 'get', {
                ubus_rpc_session: ctx.authsession, config: 'dhcp', section
            })?.values;
            // Pending deletion hides the row in this session. Classify it from
            // committed UCI so removing a manual DNS/IP Sets row stays routine.
            if (!row) row = ubus.call('uci', 'get', { config: 'dhcp', section })?.values;
            let kind = row?.['.type'];
            if (change[0] == 'add') kind = change[2];
            if (kind == 'ipset' || kind == 'domain' || kind == 'hostrecord' || kind == 'cname') continue;
            if (kind == 'dnsmasq' && (change[2] == 'address' || change[2] == 'server' ||
                change[2] == 'cname' || change[2] == 'hostrecord')) continue;
            // Unknown rows, DHCP allocation and confdir remain conservative.
            return true;
        }
    }
    return false;
}
function error(code, message) {
    http.status(code, message); http.prepare_content('text/plain'); http.write(message);
}
function command_valid(command, argument) {
    if (command == '/sbin/ifup' || command == '/sbin/ifdown')
        return type(argument) == 'string' && !!match(argument, /^[a-zA-Z0-9_]{1,32}$/);
    return (command == '/etc/init.d/network' || command == '/etc/init.d/firewall' ||
            command == '/etc/init.d/sing-box') &&
           (argument == 'start' || argument == 'stop' || argument == 'restart' || argument == 'reload');
}
function access(scope, object, method) {
    return !!ubus.call('session', 'access', {
        ubus_rpc_session: ctx.authsession, scope, object, function: method
    })?.access;
}
function command_allowed(command, argument) {
    // Retain the native RPC permissions; UCI write alone does not grant exec.
    if (command == '/sbin/ifup' || command == '/sbin/ifdown')
        return access('ubus', 'file', 'exec') &&
               (access('file', command, 'exec') || access('file', command + ' ' + argument, 'exec'));
    let info = stat(command);
    return access('ubus', 'rc', 'init') && info?.uid == 0 && info?.gid == 0 &&
           (info.mode & 0100) && !(info.mode & 0002);
}
function apply(checked) {
    let mode = trim(readfile('/etc/getdomains/offload-mode') ?? 'disable');
    if (mode == 'strict' && stat(directory + '/boot-settling'))
        return error(503, 'Offload is initializing; retry shortly');
    // Even an empty/native DNS apply must not cancel or interleave with an
    // outstanding checked apply and its rollback snapshot.
    if (mode == 'strict' && stat(directory + '/submission.lock'))
        return error(409, 'Another apply is pending');
    let changes = ubus.call('uci', 'changes', { ubus_rpc_session: ctx.authsession })?.changes;
    if (changes?.firewall) {
        let rows = ubus.call('uci', 'get', { ubus_rpc_session: ctx.authsession, config: 'firewall' })?.values;
        for (let section in rows)
            if (rows[section]?.['.type'] == 'defaults' &&
                (rows[section].flow_offloading == '1' || rows[section].flow_offloading_hw == '1'))
                return error(409, 'Flow offloading is managed by getdomains; select its mode through reinstallation');
    }
    let important = critical(changes);
    if (mode == 'strict' && important && readfile('/etc/getdomains/offload-reboot-required'))
        return error(409, 'Reboot to finish offload reinstallation first');
    // An unsupported/kill-switch strict configuration has no hardware owner.
    // Preserve native checked-apply cleanup in this verified software fallback;
    // there is no keeper there to expire an asynchronous confirmation lock.
    if (mode == 'strict' && important && !stat(directory + '/owner.sock')) {
        if (system('/usr/libexec/getdomains-offload software-ok') != 0)
            return error(503, 'Hardware state cannot be verified');
        return call(native[checked ? 'action_apply_rollback' : 'action_apply_unchecked'],
                    native, { ubus, ctx, http, config, dispatcher });
    }
    if (mode != 'strict' || !important) {
        if (mode == 'medium' && important) system('/usr/libexec/getdomains-offload pending');
        return call(native[checked ? 'action_apply_rollback' : 'action_apply_unchecked'],
                    native, { ubus, ctx, http, config, dispatcher });
    }
    for (let package in changes)
        if (!ubus.call('session', 'access', {
            ubus_rpc_session: ctx.authsession, scope: 'uci', object: package, function: 'write'
        })?.access) return error(403, 'Permission denied');
    // Only one policy operation may be outstanding, including checked apply.
    if (!reserve()) return error(409, 'Another apply is pending');
    let id = dispatcher.randomid(16);
    let folder = directory + '/jobs/' + id;
    if (!mkdir(folder, 0700) || !writefile(folder + '/request.json', sprintf('%J', {
        session: ctx.authsession, checked, changes,
        timeout: min(max(+(config?.apply?.rollback ?? 90), 90), 600),
        token: dispatcher.randomid(16)
    }))) { unreserve(); return error(503, 'Could not queue apply'); }
    if (system('/usr/bin/setsid /usr/libexec/getdomains-offload job ' + id +
               ' </dev/null >' + folder + '/worker.log 2>&1 &') != 0)
        { unreserve(); return error(503, 'Could not start apply'); }
    http.status(202, 'Accepted'); http.prepare_content('application/json');
    http.write_json({ getdomains_job: id });
}
return {
    action_command: function() {
        let command = http.formvalue('command'), argument = http.formvalue('argument');
        if (!command_valid(command, argument)) return error(400, 'Unsupported operation');
        if (!command_allowed(command, argument)) return error(403, 'Permission denied');
        // Native interface/service execution is authorized by file.exec or
        // rc.init above. It does not require permission to edit that service's
        // UCI package (sing-box need not have a LuCI configuration application).
        let mode = trim(readfile('/etc/getdomains/offload-mode') ?? 'disable');
        if (mode == 'strict' && stat(directory + '/boot-settling'))
            return error(503, 'Offload is initializing; retry shortly');
        if (mode == 'strict' && readfile('/etc/getdomains/offload-reboot-required'))
            return error(409, 'Reboot to finish offload reinstallation first');
        if (mode == 'strict' && !stat(directory + '/owner.sock')) {
            if (system('/usr/libexec/getdomains-offload software-ok') != 0)
                return error(503, 'Hardware state cannot be verified');
            http.prepare_content('application/json'); http.write_json({ native: true }); return;
        }
        if (mode != 'strict') {
            if (mode == 'medium') system('/usr/libexec/getdomains-offload pending');
            http.prepare_content('application/json'); http.write_json({ native: true }); return;
        }
        if (!reserve()) return error(409, 'Another apply is pending');
        let id = dispatcher.randomid(16), folder = directory + '/jobs/' + id;
        if (!mkdir(folder, 0700) || !writefile(folder + '/request.json', sprintf('%J', {
            session: ctx.authsession, checked: false, timeout: 90, token: dispatcher.randomid(16),
            command, argument, changes: ubus.call('uci', 'changes', { ubus_rpc_session: ctx.authsession })?.changes
        }))) { unreserve(); return error(503, 'Could not queue operation'); }
        if (system('/usr/bin/setsid /usr/libexec/getdomains-offload job ' + id +
               ' </dev/null >' + folder + '/worker.log 2>&1 &') != 0) {
            unreserve(); return error(503, 'Could not start operation');
        }
        http.status(202, 'Accepted'); http.prepare_content('application/json');
        http.write_json({ getdomains_job: id });
    },
    action_apply_rollback: function() { return apply(true); },
    action_apply_unchecked: function() { return apply(false); },
    action_confirm: function() {
        let before = ubus.call('session', 'get', {
            ubus_rpc_session: '00000000000000000000000000000000', keys: [ 'rollback' ]
        })?.values?.rollback;
        let valid = before?.token == http.formvalue('token') && before?.timeout >= time();
        let result = call(native.action_confirm, native, { ubus, ctx, http, config, dispatcher });
        // A failed native confirmation must never reopen admission.
        let rollback = ubus.call('session', 'get', {
            ubus_rpc_session: '00000000000000000000000000000000', keys: [ 'rollback' ]
        })?.values?.rollback;
        if (valid && !rollback?.token && readfile(directory + '/await-confirm'))
            system('/usr/libexec/getdomains-offload confirmed');
        return result;
    },
    action_job: function() {
        let id = http.formvalue('job');
        if (type(id) != 'string' || !match(id, /^[0-9a-f]{32}$/)) return error(400, 'Invalid job');
        let folder = directory + '/jobs/' + id;
        let request = json(readfile(folder + '/request.json') ?? '{}');
        if (request.session != ctx.authsession) return error(403, 'Permission denied');
        http.prepare_content('application/json');
        http.write_json(json(readfile(folder + '/result.json') ?? '{"pending":true}'));
    },
    action_status: function() {
        http.prepare_content('application/json');
        http.write_json({ mode: trim(readfile('/etc/getdomains/offload-mode') ?? 'disable'),
            state: trim(readfile(directory + '/state') ?? 'STOPPED'),
            reboot_required: !!readfile('/etc/getdomains/offload-reboot-required') });
    }
};
