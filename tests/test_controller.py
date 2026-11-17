#!/usr/bin/env python3
"""Offline fault simulation for the SleepFix shell controller.

All executable data is synthetic and generated below. No LG firmware or patched
LG executable is included or read by these tests. Constants are rewritten only
in a temporary COPY of the production controller; the shipped controller has no
environment-based test bypass. Mounts, process images, systemd, and PID 1's view
are modelled in an isolated temporary tree. No real mount/service is touched.

This verifies control flow and recovery, not execution on webOS or ARM.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
OFFSET = 128
_fixture = bytearray((i * 13 + 7) % 256 for i in range(1024))
_prefix = b"SYNTHETIC SLEEPFIX TEST DATA!!"
_fixture[:len(_prefix)] = _prefix
_fixture[OFFSET:OFFSET + 4] = bytes.fromhex("4df0bdfb")
ORIGINAL = bytes(_fixture)
_fixture[OFFSET:OFFSET + 4] = bytes.fromhex("00bf00bf")
PATCHED = bytes(_fixture)
ORIGINAL_SHA = hashlib.sha256(ORIGINAL).hexdigest()
PATCHED_SHA = hashlib.sha256(PATCHED).hexdigest()
del _fixture, _prefix


MOCK = r'''#!/usr/bin/python3
import sys, os, json, pathlib, shutil
p = pathlib.Path(os.environ['SLEEPFIX_SIMULATION'])
s = json.loads((p / 'state.json').read_text())
cmd = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
target = p / 'usr/sbin/tv-reservation-agent'
payload = p / 'install/tv-reservation-agent.sleepfix'
host_target = p / 'host/usr/sbin/tv-reservation-agent'
proc = p / 'proc'
unit = 'tv-reservation-agent.service'

def save():
    (p / 'state.json').write_text(json.dumps(s))

def record(event):
    s.setdefault('events', []).append(event)

def mount_line():
    return '1 0 0:0 / ' + str(target) + ' rw - mock mock rw\n'

def host_link():
    host_target.unlink(missing_ok=True)
    os.link(target, host_target)

def new_proc():
    if s.get('pid'):
        shutil.rmtree(proc / str(s['pid']), ignore_errors=True)
    s['counter'] += 1
    s['pid'] = s['counter']
    s['active'] = True
    d = proc / str(s['pid'])
    d.mkdir(parents=True)
    # A running process keeps its old image across a later simulated mount.
    (d / 'exe').write_bytes(host_target.read_bytes())
    (d / 'cgroup').write_text('1:name=systemd:/system.slice/' + unit + '\n')

if cmd == 'id':
    print(s.get('uid', 0))
    sys.exit(0)
if cmd == 'sleep':
    sys.exit(0)
if cmd == 'stat':
    try:
        st = os.stat(a[-1])
    except OSError:
        sys.exit(1)
    if a[-2] == '%u':
        print(s.get('state_owner', 0))
    elif a[-2] == '%h':
        print(st.st_nlink)
    elif a[-2] == '%d:%i':
        print(str(st.st_dev) + ':' + str(st.st_ino))
    else:
        raise Exception('Unexpected stat arguments: ' + repr(a))
    sys.exit(0)
if cmd == 'readlink':
    path = pathlib.Path(a[-1])
    if path.name == 'exe' and proc in path.parents:
        if not path.exists():
            sys.exit(1)
        print(target)
        sys.exit(0)
    try:
        print(os.readlink(path))
        sys.exit(0)
    except OSError:
        sys.exit(1)
if cmd == 'mount':
    if a != ['--bind', str(payload), str(target)]:
        raise Exception('Unsafe/unexpected mount arguments: ' + repr(a))
    s['mount_calls'] += 1
    record('mount')
    if s.get('mount_fail'):
        save()
        sys.exit(1)
    os.rename(target, p / 'stock-underneath')
    os.link(payload, target)
    (proc / 'self/mountinfo').write_text(mount_line())
    s['mounted'] = True
    if not s.get('isolated_mount'):
        host_link()
        (p / 'host/mountinfo').write_text(mount_line())
    save()
    sys.exit(0)
if cmd == 'umount':
    if a != [str(target)]:
        raise Exception('Forced/lazy/unexpected unmount: ' + repr(a))
    s['unmount_calls'] += 1
    record('umount')
    if s.get('mounted') and s.get('active') and not s.get('isolated_mount'):
        raise Exception('Attempted to unmount a live host executable before stop')
    if s.get('unmount_fail'):
        save()
        sys.exit(1)
    target.unlink()
    os.rename(p / 'stock-underneath', target)
    if not s.get('stale_host_after_unmount'):
        host_link()
    (proc / 'self/mountinfo').write_text('')
    (p / 'host/mountinfo').write_text('')
    s['mounted'] = False
    save()
    sys.exit(0)
if cmd == 'systemctl':
    if 'show' in a:
        fields = [a[i + 1] for i, value in enumerate(a) if value == '-p']
        values = {
            'ExecStart': '{ path=' + str(target) + ' ; argv[]=' + str(target) + ' ; }',
            'LoadState': 'loaded', 'MainPID': str(s.get('pid', 0)),
            'RefuseManualStop': s.get('refuse_stop', 'no'),
            'OnFailure': s.get('onfailure', ''), 'FailureAction': 'none',
            'StartLimitAction': 'none', 'Id': unit,
            'ActiveState': 'active' if s.get('active') else 'inactive',
            'SubState': 'running' if s.get('active') else 'dead',
            'Type': 'simple', 'Restart': 'always', 'FragmentPath': '/mock/unit',
        }
        if s.get('wrong_exec'):
            values['ExecStart'] = '{ path=/usr/sbin/tvpowerd ; argv[]=/usr/sbin/tvpowerd ; }'
        if s.get('wrong_pid'):
            values['MainPID'] = '9999'
        for key in fields:
            print(key + '=' + values.get(key, ''))
        sys.exit(0)
    if 'is-active' in a:
        sys.exit(0 if s.get('active') else 3)
    if a[-1] != unit:
        raise Exception('Attempt to control unrelated service: ' + repr(a))
    if 'stop' in a:
        s['stops'] += 1
        record('stop')
        if s.get('stop_fail'):
            save()
            sys.exit(1)
        shutil.rmtree(proc / str(s.get('pid', 0)), ignore_errors=True)
        s['pid'] = 0
        s['active'] = False
        save()
        sys.exit(0)
    if 'start' in a:
        s['starts'] += 1
        record('start')
        new_proc()
        save()
        sys.exit(0)
    if 'restart' in a:
        s['restarts'] += 1
        record('restart')
        if s.get('fail_first_restart') and s['restarts'] == 1:
            shutil.rmtree(proc / str(s.get('pid', 0)), ignore_errors=True)
            s['pid'] = 0
            s['active'] = False
            save()
            sys.exit(0)  # systemd accepted the request, but the service then failed.
        new_proc()
        save()
        sys.exit(0)
    raise Exception('Unexpected systemctl arguments: ' + repr(a))
raise Exception('Unexpected command: ' + cmd)
'''


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sleepfix-synthetic-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)
        self.root = self.p / "install"
        self.target = self.p / "usr/sbin/tv-reservation-agent"
        self.host_target = self.p / "host/usr/sbin/tv-reservation-agent"
        self.hook = self.p / "init.d/99-lgc1-sleepfix"
        self.app = self.p / "app"
        self.script = self.app / "bin/sleepfixctl.sh"
        for relative in ("usr/sbin", "host/usr/sbin", "proc/self/ns", "proc/1/ns", "proc/100", "bin", "init.d", "app/bin"):
            (self.p / relative).mkdir(parents=True, exist_ok=True)
        (self.p / "proc/self/ns/mnt").symlink_to("mnt:[4026531840]")
        (self.p / "proc/1/ns/mnt").symlink_to("mnt:[4026531840]")
        self.target.write_bytes(ORIGINAL)
        self.target.chmod(0o755)
        os.link(self.target, self.host_target)
        (self.p / "proc/100/exe").write_bytes(ORIGINAL)
        (self.p / "proc/100/cgroup").write_text("1:name=systemd:/system.slice/tv-reservation-agent.service\n")
        (self.p / "proc/self/mountinfo").write_text("")
        (self.p / "host/mountinfo").write_text("")
        (self.app / "appinfo.json").write_text('{"id":"io.github.tojala1998.sleepfix"}\n')
        self.save_state({"counter": 100, "pid": 100, "active": True, "restarts": 0,
                         "stops": 0, "starts": 0, "mount_calls": 0, "unmount_calls": 0,
                         "mounted": False, "events": []})
        driver = self.p / "bin/mock"
        driver.write_text(MOCK)
        driver.chmod(0o755)
        for command in ("id", "sleep", "stat", "readlink", "mount", "umount", "systemctl"):
            (self.p / "bin" / command).symlink_to(driver)

        source = (PROJECT / "app/bin/sleepfixctl.sh").read_text()
        constants = {
            "PATH": str(self.p / "bin") + ":/usr/sbin:/usr/bin:/sbin:/bin",
            "APP": str(self.app), "ROOT": str(self.root), "PROC": str(self.p / "proc"),
            "HOST_TARGET": str(self.host_target), "HOST_MOUNTS": str(self.p / "host/mountinfo"),
            "TARGET": str(self.target), "HOOK": str(self.hook), "LOCK": str(self.p / "lock"),
            "ORIGINAL_SHA": ORIGINAL_SHA, "PATCH_SHA": PATCHED_SHA,
        }
        for name, value in constants.items():
            source, count = re.subn(r"^" + name + r"=.*$", name + "=" + value, source, flags=re.MULTILINE)
            self.assertEqual(count, 1, "Fixture must replace exactly one constant: " + name)
        for old, new in (("skip=199070 count=4", "skip=%d count=4" % OFFSET),
                         ("seek=199070 conv=notrunc", "seek=%d conv=notrunc" % OFFSET)):
            self.assertEqual(source.count(old), 1, "Unexpected production patch recipe")
            source = source.replace(old, new)
        self.script.write_text(source)
        self.script.chmod(0o755)
        hook_source = (PROJECT / "app/bin/boot-hook.sh").read_text()
        for name in ("APP", "ROOT", "PATH"):
            hook_source = re.sub(r"^" + name + r"=.*$", name + "=" + constants[name], hook_source, flags=re.MULTILINE)
        (self.app / "bin/boot-hook.sh").write_text(hook_source)
        (self.app / "bin/boot-hook.sh").chmod(0o755)

    def state(self):
        return json.loads((self.p / "state.json").read_text())

    def save_state(self, state):
        (self.p / "state.json").write_text(json.dumps(state))

    def change(self, **changes):
        state = self.state()
        state.update(changes)
        self.save_state(state)

    def runctl(self, *args, ok=True):
        shell = shlex.split(os.environ.get("SLEEPFIX_TEST_SHELL", "/bin/dash"))
        result = subprocess.run(shell + [str(self.script), *args],
                                env={**os.environ, "SLEEPFIX_SIMULATION": str(self.p)},
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        if ok:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return result

    def status(self):
        return json.loads(self.runctl("status-json").stdout)

    def seed_payload(self):
        (self.root / "reference").mkdir(parents=True, exist_ok=True)
        (self.root / "reference/tv-reservation-agent.original").write_bytes(ORIGINAL)
        (self.root / "tv-reservation-agent.sleepfix").write_bytes(PATCHED)
        (self.root / "tv-reservation-agent.sleepfix").chmod(0o555)

    def corrupt_payload(self):
        payload = self.root / "tv-reservation-agent.sleepfix"
        payload.chmod(0o755)
        payload.write_bytes(b"synthetic corrupted payload")

    def simulate_reboot(self):
        # Model the kernel dropping the bind mount and systemd starting stock.
        if self.state()["mounted"]:
            self.target.unlink()
            os.rename(self.p / "stock-underneath", self.target)
        self.host_target.unlink()
        os.link(self.target, self.host_target)
        (self.p / "proc/self/mountinfo").write_text("")
        (self.p / "host/mountinfo").write_text("")
        state = self.state()
        state.update(mounted=False, active=True)
        self.save_state(state)
        (self.p / "proc" / str(state["pid"]) / "exe").write_bytes(ORIGINAL)

    def assert_stock_running(self):
        self.assertFalse(self.state()["mounted"])
        self.assertTrue(self.state()["active"])
        self.assertEqual(self.target.read_bytes(), ORIGINAL)
        self.assertEqual((self.p / "proc" / str(self.state()["pid"]) / "exe").read_bytes(), ORIGINAL)

    def test_check_is_read_only_without_installation(self):
        self.runctl("check")
        self.assertFalse(self.root.exists())
        self.assertEqual(self.state()["events"], [])

    def test_fresh_start_generates_only_the_four_byte_patch(self):
        self.runctl("start", "--timers-off")
        self.assertEqual(self.target.read_bytes(), PATCHED)
        self.assertEqual((self.p / "stock-underneath").read_bytes(), ORIGINAL)
        self.assertEqual((self.root / "reference/tv-reservation-agent.original").read_bytes(), ORIGINAL)
        changes = [i for i, (a, b) in enumerate(zip(ORIGINAL, self.target.read_bytes())) if a != b]
        self.assertEqual(changes, list(range(OFFSET, OFFSET + 4)))
        self.assertFalse(self.hook.exists())
        self.assertTrue(self.status()["running"])

    def test_start_is_idempotent(self):
        self.runctl("start", "--timers-off")
        self.runctl("start", "--timers-off")
        self.assertEqual(self.state()["mount_calls"], 1)
        self.assertEqual(self.state()["restarts"], 1)

    def test_stop_restores_stock_and_keeps_boot_preference(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        self.runctl("stop", "--timers-off")
        self.assert_stock_running()
        status = self.status()
        self.assertFalse(status["running"])
        self.assertTrue(status["bootEnabled"])
        self.assertTrue(status["bootHookValid"])
        self.assertEqual(self.state()["events"][-3:], ["stop", "umount", "start"])

    def test_boot_off_does_not_stop_running_fix(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        events = self.state()["events"]
        self.runctl("boot-off")
        self.assertEqual(self.state()["events"], events)
        self.assertTrue(self.status()["running"])
        self.assertFalse(self.status()["bootEnabled"])

    def test_boot_on_does_not_start_now(self):
        self.runctl("boot-on")
        self.assert_stock_running()
        self.assertEqual(self.state()["events"], [])
        self.assertTrue(self.status()["bootEnabled"])
        self.assertFalse(self.status()["running"])

    def test_boot_reapplies_after_kernel_drops_overlay(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        self.simulate_reboot()
        self.assertFalse(self.status()["running"])
        self.runctl("boot")
        self.assertTrue(self.status()["running"])
        self.assertEqual(self.state()["restarts"], 2)

    def test_boot_without_enable_marker_is_noop(self):
        self.runctl("boot")
        self.assertEqual(self.state()["events"], [])
        self.assertFalse(self.root.exists())

    def test_corrupt_boot_payload_disarms_persistence(self):
        self.runctl("boot-on")
        self.corrupt_payload()
        self.runctl("boot", ok=False)
        self.assert_stock_running()
        self.assertFalse((self.root / "enabled").exists())
        self.assertFalse(self.hook.is_symlink())

    def test_legacy_boot_link_is_adopted_without_second_restart(self):
        self.runctl("start", "--timers-off")
        (self.root / "enabled").write_text(PATCHED_SHA + "\n")
        legacy = self.root / "boot-hook.sh"
        legacy.write_text("#!/bin/sh\nexit 0\n")
        legacy.chmod(0o700)
        self.hook.symlink_to(legacy)
        self.assertTrue(self.status()["legacyHook"])
        self.runctl("start", "--timers-off")
        self.assertEqual(os.readlink(self.hook), str(self.app / "bin/boot-hook.sh"))
        self.assertFalse(self.status()["legacyHook"])
        self.assertEqual(self.state()["restarts"], 1)

    def test_stop_failure_disarms_and_never_unmounts_live_service(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        self.change(stop_fail=True)
        self.runctl("stop", "--timers-off", ok=False)
        self.assertEqual(self.state()["unmount_calls"], 0)
        self.assertTrue(self.state()["mounted"])
        self.assertFalse((self.root / "enabled").exists())
        self.assertFalse(self.hook.is_symlink())

    def test_unmount_failure_disarms_without_force_or_restart(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        self.change(unmount_fail=True)
        self.runctl("stop", "--timers-off", ok=False)
        self.assertTrue(self.state()["mounted"])
        self.assertFalse(self.state()["active"])
        self.assertEqual(self.state()["starts"], 0)
        self.assertFalse((self.root / "enabled").exists())
        self.assertFalse(self.hook.is_symlink())

    def test_failed_restart_rolls_back_and_disarms(self):
        self.runctl("boot-on")
        self.change(fail_first_restart=True)
        self.runctl("start", "--timers-off", ok=False)
        self.assert_stock_running()
        self.assertEqual(self.state()["events"], ["mount", "restart", "stop", "umount", "start"])
        self.assertFalse((self.root / "enabled").exists())

    def test_wrong_original_checksum_rejects_before_mount(self):
        self.target.write_bytes(b"different synthetic firmware")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])
        self.assertFalse(self.root.exists())

    def test_bad_existing_payload_is_rejected(self):
        self.seed_payload()
        self.corrupt_payload()
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_wrong_unit_rejected_before_mount(self):
        self.change(wrong_exec=True)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_wrong_main_pid_rejected_before_mount(self):
        self.change(wrong_pid=True)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_failure_handler_rejected_before_mount(self):
        self.change(onfailure="emergency-reboot.service")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_start_and_stop_require_timer_acknowledgment(self):
        self.runctl("start", ok=False)
        self.runctl("stop", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_foreign_boot_hook_is_not_overwritten(self):
        self.hook.write_text("foreign hook\n")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.hook.read_text(), "foreign hook\n")
        self.assertEqual(self.state()["events"], [])

    def test_foreign_overlay_is_rejected(self):
        line = "1 0 0:0 / %s rw - mock other rw\n" % self.target
        (self.p / "proc/self/mountinfo").write_text(line)
        (self.p / "host/mountinfo").write_text(line)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])
        self.assertEqual(self.status()["overlay"], "other")
        self.assertFalse(self.status()["canStart"])

    def test_multiple_overlays_are_rejected(self):
        line = "1 0 0:0 / %s rw - mock other rw\n" % self.target
        (self.p / "proc/self/mountinfo").write_text(line + line)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_missing_payload_can_still_be_rolled_back(self):
        self.runctl("start", "--timers-off")
        (self.root / "tv-reservation-agent.sleepfix").unlink()
        self.runctl("rollback")
        self.assert_stock_running()

    def test_corrupt_mounted_payload_can_be_rolled_back(self):
        self.runctl("start", "--timers-off")
        self.corrupt_payload()
        self.runctl("rollback")
        self.assert_stock_running()

    def test_mount_failure_keeps_stock_running(self):
        self.change(mount_fail=True)
        self.runctl("start", "--timers-off", ok=False)
        self.assert_stock_running()
        self.assertEqual(self.state()["restarts"], 0)

    def test_unrecognized_running_image_is_rejected(self):
        (self.p / "proc/100/exe").write_bytes(b"unknown process image")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_multiple_matching_processes_are_rejected(self):
        shutil.copytree(self.p / "proc/100", self.p / "proc/101")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_existing_different_host_view_is_rejected(self):
        self.host_target.unlink()
        self.host_target.write_bytes(ORIGINAL)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])

    def test_mount_isolation_is_detected_before_any_restart(self):
        self.change(isolated_mount=True)
        result = self.runctl("start", "--timers-off", ok=False)
        self.assertIn("Mount isolation detected", result.stderr)
        self.assertEqual(self.state()["events"], ["mount", "umount"])
        self.assert_stock_running()

    def test_different_namespace_rejects_start_before_mount(self):
        ns = self.p / "proc/self/ns/mnt"
        ns.unlink()
        ns.symlink_to("mnt:[4026532000]")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], [])
        self.assertFalse(self.status()["canStart"])
        self.assertFalse(self.status()["canStop"])

    def test_different_namespace_rejects_stop_before_service_change(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        events = self.state()["events"]
        ns = self.p / "proc/self/ns/mnt"
        ns.unlink()
        ns.symlink_to("mnt:[4026532000]")
        self.runctl("stop", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], events)
        self.assertTrue(self.state()["mounted"])
        self.assertFalse((self.root / "enabled").exists())

    def test_changed_host_view_refuses_stop_before_stopping_service(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        events = self.state()["events"]
        self.host_target.unlink()
        self.host_target.write_bytes(ORIGINAL)
        self.runctl("stop", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], events)
        self.assertFalse((self.root / "enabled").exists())

    def test_stale_host_view_after_unmount_refuses_to_start_unknown_image(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        self.change(stale_host_after_unmount=True)
        self.runctl("stop", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"][-2:], ["stop", "umount"])
        self.assertFalse(self.state()["active"])
        self.assertEqual(self.state()["starts"], 0)
        self.assertEqual(self.target.read_bytes(), ORIGINAL)
        self.assertEqual(self.host_target.read_bytes(), PATCHED)
        self.assertFalse((self.root / "enabled").exists())

    def test_stop_policy_failure_disarms_without_service_request(self):
        self.runctl("start", "--timers-off")
        self.runctl("boot-on")
        events = self.state()["events"]
        self.change(refuse_stop="yes")
        self.runctl("stop", "--timers-off", ok=False)
        self.assertEqual(self.state()["events"], events)
        self.assertFalse((self.root / "enabled").exists())

    def test_detached_patched_process_can_be_stopped(self):
        self.runctl("start", "--timers-off")
        self.target.unlink()
        os.rename(self.p / "stock-underneath", self.target)
        self.host_target.unlink()
        os.link(self.target, self.host_target)
        (self.p / "proc/self/mountinfo").write_text("")
        (self.p / "host/mountinfo").write_text("")
        self.change(mounted=False)
        # The process keeps its patched image even though the path is stock.
        status = self.status()
        self.assertEqual(status["runningSha256"], PATCHED_SHA)
        self.assertEqual(status["systemSha256"], ORIGINAL_SHA)
        self.assertEqual(status["overlay"], "absent")
        self.assertTrue(status["canStop"])
        self.runctl("stop", "--timers-off")
        self.assert_stock_running()
        self.assertEqual(self.state()["restarts"], 2)

    def test_symlinked_lock_is_rejected_without_touching_destination(self):
        outside = self.p / "lock-destination"
        outside.write_text("do not truncate\n")
        (self.p / "lock").symlink_to(outside)
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(outside.read_text(), "do not truncate\n")
        self.assertEqual(self.state()["events"], [])

    def test_hardlinked_lock_is_rejected_without_touching_destination(self):
        outside = self.p / "lock-destination"
        outside.write_text("do not truncate\n")
        os.link(outside, self.p / "lock")
        self.runctl("start", "--timers-off", ok=False)
        self.assertEqual(outside.read_text(), "do not truncate\n")
        self.assertEqual(self.state()["events"], [])

    def test_status_reports_operation_lock_and_second_start_refuses(self):
        with (self.p / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(self.status()["operationInProgress"])
            result = self.runctl("start", "--timers-off", ok=False)
            self.assertIn("operation is in progress", result.stderr)
            self.assertEqual(self.state()["events"], [])
        self.assertFalse(self.status()["operationInProgress"])

    def test_unsupported_status_does_not_claim_running_or_supported(self):
        self.target.write_bytes(b"unsupported synthetic firmware")
        status = self.status()
        self.assertFalse(status["supported"])
        self.assertFalse(status["running"])
        self.assertFalse(status["canStart"])
        self.assertFalse(status["canStop"])
        self.assertEqual(status["systemSha256"], hashlib.sha256(self.target.read_bytes()).hexdigest())

    def test_hash_alone_does_not_make_foreign_overlay_ours(self):
        self.seed_payload()
        self.target.write_bytes(PATCHED)
        (self.p / "proc/100/exe").write_bytes(PATCHED)
        line = "1 0 0:0 / %s rw - mock other rw\n" % self.target
        (self.p / "proc/self/mountinfo").write_text(line)
        (self.p / "host/mountinfo").write_text(line)
        status = self.status()
        self.assertEqual(status["overlay"], "other")
        self.assertFalse(status["running"])
        self.assertFalse(status["canStart"])

    def test_nonroot_status_reports_root_requirement(self):
        self.change(uid=1000)
        status = self.status()
        self.assertFalse(status["returnValue"])
        self.assertFalse(status["root"])
        self.assertEqual(self.state()["events"], [])

    def test_symlinked_state_file_is_rejected(self):
        self.seed_payload()
        outside = self.p / "outside"
        outside.write_text("preserve\n")
        (self.root / "enabled").symlink_to(outside)
        self.runctl("boot-on", ok=False)
        self.assertEqual(outside.read_text(), "preserve\n")
        self.assertEqual(self.state()["events"], [])

    def test_enabled_marker_without_valid_hook_is_reported(self):
        self.seed_payload()
        (self.root / "enabled").write_text(PATCHED_SHA + "\n")
        status = self.status()
        self.assertTrue(status["bootEnabled"])
        self.assertFalse(status["bootHookValid"])
        self.assertFalse(status["running"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
