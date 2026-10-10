// Research-only LuCI extension. Native controller source is left intact.
const native = require('luci.controller.admin.uci');

function apply_prepared(method) {
    let pending = ubus.call('uci', 'changes', { ubus_rpc_session: ctx.authsession })?.changes;
    let critical = false;
    for (let package in pending)
        if (package == 'firewall' || package == 'network') critical = true;
    for (let change in pending?.dhcp)
        if (change[1] == 'wdns') critical = true;
    if (critical && system('/tmp/gd-life-lab/luci-prepare') != 0) {
        http.status(503, 'Preparation failed');
        http.prepare_content('text/plain');
        http.write('Preparation failed');
        return;
    }
    // Use the same authenticated request environment for the stock handler.
    return call(native[method], native, { ubus, ctx, http, config, dispatcher });
}

return {
    action_apply_unchecked: function() { return apply_prepared('action_apply_unchecked'); },
    action_apply_rollback: function() { return apply_prepared('action_apply_rollback'); }
};
