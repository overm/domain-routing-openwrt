"""Read-only hardware probe and isolated board/consent fixtures on OpenWrt.

The original driver, sysfs, PPE dumps and interface topology remain real.
Only board metadata and consent files are redirected to a private /tmp fixture.
Passing this fixture does not qualify a different physical router model.
"""
import json
from pathlib import Path
import shlex
from offload_lifecycle_support import arguments, Device, save

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = '/tmp/getdomains-offload-platform-unit'


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'board_identity_simulated': True, 'cases': []}
    original = json.loads(device.run('cat /etc/board.json')[1])
    fixture = json.loads(json.dumps(original))
    fixture['model']['id'] = 'getdomains,unqualified-hardware-fixture'
    try:
        device.run('test ! -e ' + DIRECTORY + ' && mkdir -m 0700 ' + DIRECTORY)
        source = (ROOT/'getdomains-offload.sh').read_text().split('\n# Device dispatcher:', 1)[0]
        source = source.replace('/etc/board.json', DIRECTORY+'/board.json').replace(
            '/etc/getdomains/', DIRECTORY+'/').replace('GD_DIR=/tmp/getdomains-offload', 'GD_DIR='+DIRECTORY)
        source += '''
case $1 in
    profile) gd_platform_profile;;
    supported) gd_supported;;
esac
'''
        device.upload(source, DIRECTORY+'/probe.sh')

        def probe(label, board, mode, consent, expected_code, expected_profile=None):
            device.upload(json.dumps(board), DIRECTORY+'/board.json')
            device.upload(mode+'\n', DIRECTORY+'/offload-mode')
            device.upload(consent, DIRECTORY+'/offload-experimental-board')
            operation = 'profile' if expected_profile else 'supported'
            code, output = device.run('sh '+DIRECTORY+'/probe.sh '+shlex.quote(operation), False)
            assert (code == 0) == (expected_code == 0), (label, code, output)
            if expected_profile:
                assert output.strip() == expected_profile, (label, output)
            report['cases'].append({'case': label, 'passed': True})

        probe('qualified-profile-uses-real-hardware', original, 'strict', '', 0, 'qualified')
        probe('unqualified-profile-matches-real-driver-ppe-and-ports', fixture, 'medium', '', 0, 'experimental')
        board_id = fixture['model']['id']+'\n'
        probe('medium-requires-consent', fixture, 'medium', '', 1)
        probe('medium-accepts-board-bound-consent', fixture, 'medium', board_id, 0)
        probe('other-board-consent-is-rejected', fixture, 'medium', 'getdomains,other-board\n', 1)
        probe('consent-cannot-enable-strict', fixture, 'strict', board_id, 1)
        probe('consent-cannot-enable-disabled-mode', fixture, 'disable', board_id, 1)
        probe('qualified-strict-retains-existing-support', original, 'strict', '', 0)
        report['status'] = 'passed'
    finally:
        device.run('rm -rf '+DIRECTORY, False)
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
