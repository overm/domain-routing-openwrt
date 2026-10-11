"""Test shared-socket standby ownership in an isolated router network namespace."""
import json
import shlex
import time
from offload_lifecycle_support import arguments, Device, save


def main():
    args = arguments(__doc__)
    d = Device(args)
    namespace = 'gd-life-owner'
    table = 'gd_life_owner'
    result = {'cases': [], 'status': 'incomplete', 'fault_model': 'one owner process at a time'}
    try:
        d.run('chmod 0700 ' + args.owner)
        d.run('ip netns add ' + namespace)
        for cycle in range(5):
            sock = f'/tmp/gd-life-lab/fault{cycle}-{time.monotonic_ns()}.sock'
            initial = (f'add table inet {table} {{ flags owner,persist; }}\n'
                       f'add chain inet {table} admission\n'
                       f'add rule inet {table} admission counter\n')
            worker, guardian = d.start_owner(initial, sock, table, namespace)
            assert d.run(f'ip netns exec {namespace} nft delete table inet {table}', False)[0] != 0

            # Standby failure must leave the worker's socket protecting the table.
            d.run(f'kill -9 {guardian}')
            time.sleep(.25)
            status = d.owner(sock, 'STATUS')[1].strip()
            assert 'ACTIVE NO_STANDBY' in status, status
            assert d.run(f'ip netns exec {namespace} nft delete table inet {table}', False)[0] != 0
            code, gate = d.run(f'ip netns exec {namespace} nft list chain inet {table} admission')
            assert 'counter packets' not in gate
            d.owner(sock, 'REPLACE')
            guardian = int(d.owner(sock, 'STATUS')[1].split()[-1])
            d.owner(sock, f'NFT add rule inet {table} admission counter')

            # A stale queued re-enable must not undo the standby's admission stop.
            epoch = d.owner(sock, 'EPOCH')[1].strip().split()[-1]
            queued = sock + '.queued'
            d.run(f'kill -STOP {worker}')
            wire = f'DO {epoch} NFT add rule inet {table} admission counter'
            d.run('setsid ' + ' '.join(shlex.quote(x) for x in
                  (args.owner, '--wire', sock, wire)) + ' >' + shlex.quote(queued) + ' 2>&1 </dev/null &')
            time.sleep(.1)

            # The foreign process races worker termination with repeated deletes.
            # No physical flowtable exists in this namespace.
            code, output = d.run(f'''kill -9 {worker}
ok=0; blocked=0
for trial in $(seq 1 100); do
 if ip netns exec {namespace} nft delete table inet {table} 2>/dev/null; then
  ok=$((ok+1))
 else
  blocked=$((blocked+1))
 fi
done
echo "$ok $blocked"
''')
            deleted, blocked = map(int, output.strip().split())
            assert deleted == 0 and blocked == 100, output
            status = d.owner(sock, 'STATUS')[1].strip()
            assert 'HELD OK' in status, status
            assert d.run('cat ' + shlex.quote(queued))[1].strip() == 'STALE'
            listing = d.run(f'ip netns exec {namespace} nft list table inet {table}')[1]
            assert 'flags owner,persist' in listing and 'counter packets' not in listing
            # Recovery controls the SAME socket through the standby IPC endpoint.
            d.owner(sock, f'NFT add rule inet {table} admission counter')
            d.owner(sock, f'NFT flush chain inet {table} admission')
            d.owner(sock, f'NFT delete table inet {table}')
            d.owner(sock, 'STOP')
            result['cases'].append({'cycle': cycle, 'standby_failure_gates_admission': True,
                                    'standby_replacement': True, 'worker_failure_gates_admission': True,
                                    'foreign_deletes_blocked': blocked, 'recovery_same_socket': True})
            result['cases'][-1]['queued_old_generation_reenable'] = 'rejected'
            print(json.dumps(result['cases'][-1]), flush=True)

        # Negative control: persist alone cannot protect a simultaneous loss of
        # every reference to the socket. This table has NO hardware flows.
        sock = '/tmp/gd-life-lab/both-dead.sock'
        worker, guardian = d.start_owner(initial, sock, table, namespace)
        d.run(f'kill -9 {worker} {guardian}')
        time.sleep(.2)
        listing = d.run(f'ip netns exec {namespace} nft list table inet {table}')[1]
        assert 'flags persist' in listing and 'owner,' not in listing
        assert d.run(f'ip netns exec {namespace} nft delete table inet {table}')[0] == 0
        result['all_processes_dead_negative_control'] = 'table survives but loses ownership'
        result['status'] = 'passed'
    finally:
        # Query current members rather than signalling potentially reused PIDs.
        d.run(f'ip netns pids {namespace} | while read pid; do kill -9 "$pid"; done', False)
        d.run(f'ip netns delete {namespace} 2>/dev/null || true', False)
        save(args, result)
        d.close()


if __name__ == '__main__':
    main()
