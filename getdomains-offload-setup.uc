// Checked, reversible edits of supported native LuCI views. Never edit fs.js.
import { readfile, writefile, rename, unlink } from 'fs';
let action = ARGV[0];
let dependency = "'require getdomains-offload as gdOffload';";
let profiles = [
    { path: '/www/luci-static/resources/ui.js', backup: '/etc/getdomains/ui.original',
      edits: [["request.request(L.url('admin/uci',", "gdOffload.applyRequest(L.url('admin/uci',"]] },
    { path: '/www/luci-static/resources/view/network/interfaces.js', backup: '/etc/getdomains/interfaces.original',
      edits: [["fs.exec('/sbin/ifup',[sid])", "gdOffload.execRequest('/sbin/ifup',[sid],fs.exec.bind(fs))"],
              ["fs.exec('/sbin/ifdown',[sid])", "gdOffload.execRequest('/sbin/ifdown',[sid],fs.exec.bind(fs))"]] },
    { path: '/www/luci-static/resources/view/system/startup.js', backup: '/etc/getdomains/startup.original',
      edits: [["this.callRcInit(name,action)", "gdOffload.rcRequest(name,action,this.callRcInit.bind(this))"]] }
];
function patched(profile, source) {
    for (let edit in profile.edits) source = replace(source, edit[0], edit[1]);
    return replace(source, "'use strict';", "'use strict';" + dependency);
}
if (action != 'check' && action != 'install' && action != 'remove') exit(2);
// Preflight every installed view before the first write. Unknown package
// versions fail strict installation before UCI changes. Headless is supported.
for (let profile in profiles) {
    let source = readfile(profile.path);
    if (source == null) continue;
    profile.source = source;
    if (action == 'remove') continue;
    let installed = index(source, dependency) >= 0;
    for (let edit in profile.edits)
        if (length(split(source, installed ? edit[1] : edit[0])) != 2) exit(1);
    if (index(source, "'use strict';") < 0) exit(1);
}
if (action == 'check') exit(0);
for (let profile in profiles) {
    let source = profile.source;
    if (source == null) continue;
    if (action == 'install') {
        if (index(source, dependency) >= 0) continue;
        if (!writefile(profile.backup, source)) exit(1);
        source = patched(profile, source);
    }
    else {
        let original = readfile(profile.backup);
        if (original != null && patched(profile, original) == source) source = original;
        else {
            for (let edit in profile.edits) source = replace(source, edit[1], edit[0]);
            source = replace(source, dependency, '');
        }
    }
    if (!writefile(profile.path + '.gd-new', source) || !rename(profile.path + '.gd-new', profile.path)) exit(1);
    if (action == 'remove') unlink(profile.backup);
}
