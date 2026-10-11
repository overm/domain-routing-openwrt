"""Read-only quiet-load resource sample of the installed controller and holders."""
import json
import re
import time
from offload_lifecycle_support import arguments, Device, save


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'cases': [], 'sample_seconds': 10,
              'cpu_units': 'percent of one core; Linux USER_HZ=100',
              'scope': 'quiet load with SSH measurement activity; no bulk-load qualification'}
    try:
        assert 'state=READY' in device.run('/usr/libexec/getdomains-offload status')[1]
        initial = device.run('/usr/libexec/getdomains-offload-owner --client STATUS')[1].split()
        roles = dict(zip(('worker', 'standby', 'keeper'), map(int, initial[3:6])))
        roles['supervisor'] = int(device.run('cat /tmp/getdomains-offload/supervisor.pid')[1])

        def sample():
            row = device.run('cat /proc/stat')[1].splitlines()[0].split()[1:9]
            system = list(map(int, row))
            result = {'system_total': sum(system), 'system_idle': system[3] + system[4], 'roles': {}}
            for role, pid in roles.items():
                base = '/proc/' + str(pid)
                fields = device.run('cat ' + base + '/stat')[1].rsplit(')', 1)[1].split()
                status = device.run('cat ' + base + '/status')[1]
                pss = device.run('cat ' + base + '/smaps_rollup', False)[1]
                memory = re.search(r'^VmRSS:\s+(\d+)', status, re.M)
                shared = re.search(r'^Pss:\s+(\d+)', pss, re.M)
                result['roles'][role] = {
                    'ticks_including_reaped_children': sum(int(fields[k]) for k in range(11, 15)),
                    'rss_kib': int(memory[1]) if memory else None,
                    'pss_kib': int(shared[1]) if shared else None,
                    'open_fds': int(device.run('ls ' + base + '/fd | wc -l')[1])}
            return result

        first = sample()
        began = time.monotonic()
        time.sleep(10)
        last = sample()
        elapsed = time.monotonic() - began
        report['actual_elapsed_seconds'] = round(elapsed, 2)
        report['roles'] = {}
        for role in roles:
            before, after = first['roles'][role], last['roles'][role]
            delta = after['ticks_including_reaped_children'] - before['ticks_including_reaped_children']
            report['roles'][role] = {
                'cpu_core_percent': round(delta / elapsed, 2),
                'rss_kib': after['rss_kib'], 'pss_kib': after['pss_kib'],
                'open_fds_before': before['open_fds'], 'open_fds_after': after['open_fds']}
        total = last['system_total'] - first['system_total']
        idle = last['system_idle'] - first['system_idle']
        report['system_busy_percent_all_cores'] = round(100 * (total - idle) / total, 2)
        assert device.run('/usr/libexec/getdomains-offload-owner --client STATUS')[1].split() == initial
        assert 'state=READY' in device.run('/usr/libexec/getdomains-offload status')[1]
        report['cases'].append({'case': 'quiet-load-live-process-resource-sample', 'passed': True})
        report['status'] = 'passed'
    finally:
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
