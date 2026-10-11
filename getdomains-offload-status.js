'use strict';
'require view';
'require request';
'require poll';
'require dom';

return view.extend({
    load: function() {
        return request.get(L.url('admin/uci/getdomains_status')).then(function(r) { return r.json(); });
    },
    render: function(data) {
        var state = E('p'), mode = E('p'), notice = E('p');
        function update(value) {
            dom.content(mode, _('Mode') + ': ' + value.mode);
            dom.content(state, _('Status') + ': ' + value.state);
            dom.content(notice, value.reboot_required ?
                _('Reboot required to guarantee application of saved settings.') : '');
        }
        update(data);
        poll.add(function() {
            return request.get(L.url('admin/uci/getdomains_status')).then(function(r) { update(r.json()); });
        }, 5);
        return E('div', {}, [E('h2', _('Domain routing acceleration')), mode, state, notice,
            E('p', _('Mode changes require reinstallation and reboot. Kill-switch disables hardware acceleration.')),
            E('p', _('Medium guarantees saved policy after reboot. Automatic network changes may leave old hardware decisions until reboot.')),
            E('p', _('Strict pauses Ethernet and disconnects current IPv4 connections before supported policy changes. Unconfirmed changes keep acceleration closed.')),
            E('a', { 'class': 'btn', 'href': L.url('admin/system/reboot') }, _('Reboot'))]);
    },
    handleSaveApply: null, handleSave: null, handleReset: null
});
