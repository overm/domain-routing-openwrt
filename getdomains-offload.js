'use strict';
'require request';
'require baseclass';

// The native ui.changes logic retains connectivity checks, confirm and rollback.
// Only transport of a strict critical apply is replaced with asynchronous polls.
return baseclass.extend({
    execRequest: function(command, params, native) {
        return this.applyRequest(L.url('admin/uci/getdomains_command'), {
            method: 'post', query: { sid: L.env.sessionid, token: L.env.token,
                command: command, argument: params[0] }
        }).then(function(response) {
            if (response.status !== 200) throw new Error(response.responseText || 'Operation failed');
            var result = response.json();
            if (result.native) return native(command, params);
            return result;
        });
    },
    rcRequest: function(name, action, native) {
        if (!/^(network|firewall|sing-box)$/.test(name) || !/^(start|stop|restart|reload)$/.test(action))
            return native(name, action);
        return this.execRequest('/etc/init.d/' + name, [action], function() {
            return native(name, action).then(function(code) { return { code: code }; });
        }).then(function(result) { return result.code; });
    },
    applyRequest: function(url, options) {
        return request.request(url, options).then(function(response) {
            if (response.status !== 202) return response;
            var job = response.json().getdomains_job;
            if (!/^[0-9a-f]{32}$/.test(job)) throw new Error('Invalid apply job');
            var deadline = Date.now() + 180000;
            function again() {
                if (Date.now() >= deadline) throw new Error('Apply status timed out; check the router');
                return new Promise(function(resolve) { window.setTimeout(resolve, 1500); }).then(poll);
            }
            function poll() {
                return request.request(L.url('admin/uci/getdomains_job'), {
                    method: 'get', query: { job: job, sid: L.env.sessionid }
                }).then(function(r) {
                    if (r.status !== 200) return again();
                    var value = r.json();
                    if (value.pending) return again();
                    return { status: value.status, json: function() { return value.body; },
                        responseText: typeof value.body === 'string' ? value.body : '',
                        statusText: '' };
                }, again);
            }
            return poll();
        });
    }
});
