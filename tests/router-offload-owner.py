"""Fault-test the production owner in an isolated network namespace."""
import argparse
import json
import os
from pathlib import Path
import shlex
import time
from offload_lifecycle_support import Device, save


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    p.add_argument('--known-hosts', required=True)
    p.add_argument('--ssh-libs')
    p.add_argument('--private-evidence-dir', required=True)
    p.add_argument('--binary', required=True, help='Build with tools/build-offload-test.sh')
    p.add_argument('--output', required=True)
    p.add_argument('--deadline', choices=['transaction', 'queue', 'empty-queue'], default='transaction')
    a = p.parse_args()
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1': p.error('Explicit test opt-in required')
    d = Device(a)
    directory = '/tmp/getdomains-offload-unit'
    owner = directory+'/owner'
    ns = 'gd_offload_unit'
    prefix = 'ip netns exec '+ns+' '
    holders = set()
    report = {'status': 'incomplete', 'cases': []}

    def call(action, success=True, wire=False):
        code, text = d.run(owner+(' --wire ' if wire else ' --client ')+shlex.quote(action), False)
        assert (code == 0) == success, (action, code, text)
        return text.strip()

    def status():
        row = call('STATUS').split()
        holders.update(int(x) for x in row[3:] if int(x) > 0)
        return row

    def retire():
        call('HOLD')
        row = status()
        d.upload(row[2]+'\n', directory+'/drained')
        call('RETIRE')

    def recovered():
        call('RECOVER')
        call('CONFIGURE'); call('RELEASE')
        assert status()[0:2] == ['READY', 'OK']

    try:
        d.run('test ! -e '+directory+'; ! ip netns list | grep -q "^'+ns+' "')
        d.run('mkdir -m 0700 '+directory+'; ip netns add '+ns)
        d.upload(Path(a.binary).read_bytes(), owner)
        d.run('chmod 0700 '+owner)
        # Check that an accidentally supplied production binary cannot operate
        # in this fixture's directory before allowing it to start.
        data = Path(a.binary).read_bytes()
        assert b'/tmp/getdomains-offload-unit' in data and b'/bin/touch ' in data
        d.run(prefix+'ip link add gdunita type veth peer name gdunitb')
        d.run(prefix+'ip link set gdunita up; '+prefix+'ip link set gdunitb up')
        policy = 'add flowtable inet gd_offload direct { hook ingress priority 0; devices = { "gdunita", "gdunitb" }; flags offload; }\n'
        initial = '''add table inet gd_offload { flags owner,persist; }
add chain inet gd_offload admission
add chain inet gd_offload guard { type filter hook forward priority -400; policy accept; }
'''+policy
        d.upload(initial, directory+'/initial.nft'); d.upload(policy, directory+'/policy.nft')
        d.upload('flush chain inet gd_offload admission\n', directory+'/admission.nft')
        ip = d.run('readlink -f "$(command -v ip)"')[1].strip()
        d.run('setsid '+shlex.quote(ip)+' netns exec '+ns+' '+owner+' --serve </dev/null >'+directory+'/owner.log 2>&1 &')
        time.sleep(1)
        original = status()
        assert original[0:2] == ['READY', 'OK']
        assert d.run(prefix+'nft delete table inet gd_offload', False)[0] != 0
        call('RETIRE', False); call('CONFIGURE', False); call('RELEASE', False)
        call('HOLD'); call('OPEN', False); call('RETIRE', False)
        d.upload('0\n', directory+'/drained'); call('RETIRE', False)
        d.upload(status()[2]+'\n', directory+'/drained'); call('RETIRE')
        call('RELEASE', False)
        d.upload('invalid nft syntax\n', directory+'/policy.nft'); call('CONFIGURE', False)
        assert status()[0] == 'RETIRED'
        d.upload(policy, directory+'/policy.nft'); call('CONFIGURE'); call('RELEASE')
        call('DO '+original[2]+' OPEN; delete table inet gd_offload', False, True)
        report['cases'].append({'case': 'ownership-and-phase-validation', 'passed': True})

        row = status(); old_epoch = row[2]
        d.run('kill -KILL '+row[4]); time.sleep(.5)
        assert status()[1] == 'DEGRADED' and status()[2] != old_epoch
        call('DO '+old_epoch+' OPEN', False, True)
        retire(); recovered()
        report['cases'].append({'case': 'standby-loss-and-fenced-recovery', 'passed': True})

        retire(); row = status(); old_epoch = row[2]
        d.run('kill -KILL '+row[3]); time.sleep(.5)
        row = status()
        assert row[0:2] == ['RETIRED', 'DEGRADED'] and row[2] != old_epoch
        call('RECOVER', False)  # drain acknowledgement from the old generation
        d.upload(row[2]+'\n', directory+'/drained'); recovered()
        report['cases'].append({'case': 'worker-loss-after-retire-preserves-phase', 'passed': True})

        row = status(); old_epoch = row[2]
        d.run('kill -KILL '+row[5]); time.sleep(.5)
        assert status()[1] == 'DEGRADED'
        retire(); recovered()
        report['cases'].append({'case': 'keeper-loss-and-replenishment', 'passed': True})

        # Independent keeper detects a stuck transaction even while STATUS
        # remains responsive. Its test callback deliberately cannot reboot.
        status()
        if a.deadline == 'transaction':
            d.run('mkdir '+directory+'/transaction.lock; echo 1 > '+directory+'/transaction.lock/start')
        else:
            d.run('mkdir '+directory+'/submission.lock; touch '+directory+'/await-confirm')
            if a.deadline == 'queue': d.run('echo 1 > '+directory+'/submission.lock/start')
            time.sleep(4)
            assert d.run('test -f '+directory+'/emergency', False)[0] != 0, 'Confirmation wait triggered queue deadline'
            d.run('rm -f '+directory+'/await-confirm')
        for _ in range(10):
            time.sleep(1)
            if d.run('test -f '+directory+'/emergency', False)[0] == 0: break
        else: raise RuntimeError('Independent transaction deadline was not enforced')
        assert d.run(prefix+'nft delete table inet gd_offload', False)[0] != 0
        assert 'flow add' not in d.run(prefix+'nft list chain inet gd_offload admission')[1]
        report['cases'].append({'case': 'independent-'+a.deadline+'-deadline-keeps-ownership', 'passed': True})
        report['status'] = 'passed'
    finally:
        d.run('touch '+directory+'/maintenance', False)
        for pid in holders:
            code, executable = d.run('readlink /proc/'+str(pid)+'/exe', False)
            if code == 0 and executable.strip() == owner:
                d.run('kill -KILL '+str(pid), False)
        d.run('ip netns del '+ns, False)
        # All targets are constant private fixture paths, never router config.
        d.run('rm -rf '+directory, False)
        save(a, report); d.close()
    print(json.dumps(report))


if __name__ == '__main__': main()
