"""Verify real scheduled delivery on a fresh, explicitly selected Android emulator.

Requires a debug APK using http://127.0.0.1:8090/api/v1 and a running local backend.
Refuses to replace an existing app's preferences. No real API key is needed.
"""

import argparse
import shlex
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

PACKAGE = "kr.frontier.daehwa_donghaeng"
PREFS = "shared_prefs/FlutterSharedPreferences.xml"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--adb", default="adb")
parser.add_argument("--serial", required=True)
parser.add_argument("--api", default="http://127.0.0.1:8090/api/v1")
parser.add_argument("--artifacts", type=Path, default=Path("/tmp/daehwa-android-e2e"))
args = parser.parse_args()
if not args.serial.startswith("emulator-"):
    raise SystemExit(
        "This test only supports an explicitly selected disposable emulator."
    )


def adb(*command, check=True, data=None):
    result = subprocess.run(
        [args.adb, "-s", args.serial, *command],
        input=data,
        capture_output=True,
        timeout=90,
        check=check,
    )
    return result


if adb("shell", "getprop sys.boot_completed").stdout.strip() != b"1":
    raise SystemExit("Android has not finished booting.")
probe = adb("shell", f"run-as {PACKAGE} test -f {PREFS}", check=False)
if probe.returncode == 0:
    raise SystemExit(
        "Existing preferences found; use a fresh emulator/app installation."
    )
adb("reverse", "tcp:8090", "tcp:8090")
adb("shell", f"pm grant {PACKAGE} android.permission.POST_NOTIFICATIONS")
adb("shell", f"appops set {PACKAGE} SCHEDULE_EXACT_ALARM allow")

with httpx.Client(base_url=args.api, timeout=20, trust_env=False) as client:
    device = str(uuid.uuid4())
    headers = {"X-Device-ID": device}

    def request(method, path, **kwargs):
        response = client.request(method, path, headers=headers, **kwargs)
        response.raise_for_status()
        return response.json() if response.content else None

    request(
        "POST",
        "/users/bootstrap",
        json={"device_id": device, "display_name": "Android E2E"},
    )
    request(
        "PUT",
        "/users/me/consents",
        json={
            "analysis_allowed": False,
            "caregiver_share_allowed": False,
            "onboarding_completed": True,
        },
    )
    medication = request(
        "POST",
        "/medications/batch",
        json={
            "request_id": str(uuid.uuid4()),
            "items": [{"name": "Android 알림 테스트약"}],
        },
    )[0]
    guest_now = int(adb("shell", "date +%s").stdout.strip())
    when = datetime.fromtimestamp(guest_now, timezone(timedelta(hours=9))) + timedelta(
        minutes=3
    )
    schedule_path = f"/medications/{medication['id']}/schedules"
    request(
        "PUT",
        schedule_path,
        json={
            "schedules": [
                {
                    "time_slot": "custom",
                    "remind_at": when.strftime("%H:%M:00"),
                }
            ]
        },
    )
    preferences = ET.Element("map")
    for key, value in {
        "flutter.device_id": device,
        "flutter.display_name:http://127.0.0.1:8090/api/v1": "Android E2E",
    }.items():
        ET.SubElement(preferences, "string", name=key).text = value
    command = shlex.quote(f"mkdir -p shared_prefs && cat > {PREFS}")
    adb(
        "shell",
        "-T",
        f"run-as {PACKAGE} sh -c {command}",
        data=ET.tostring(preferences, encoding="utf-8", xml_declaration=True),
    )
    adb("shell", f"am start -n {PACKAGE}/.MainActivity")
    print("App started; waiting for the native daily reminder reservation.", flush=True)
    deadline = time.monotonic() + 300
    reserved = False
    while time.monotonic() < deadline:
        alarms = adb("shell", "dumpsys alarm").stdout.decode(errors="replace")
        if PACKAGE in alarms and "ScheduledNotificationReceiver" in alarms:
            reserved = True
        notifications = adb("shell", "dumpsys notification --noredact").stdout.decode(
            errors="replace"
        )
        if (
            reserved
            and f"pkg={PACKAGE}" in notifications
            and "약을 드실 시간이에요" in notifications
        ):
            print("PASS: native reservation and notification delivery.", flush=True)
            break
        print("Waiting for Android alarm delivery...", flush=True)
        time.sleep(10)
    else:
        raise AssertionError("Native reminder was not delivered within five minutes.")
    args.artifacts.mkdir(parents=True, exist_ok=True)
    adb("shell", "cmd statusbar expand-notifications")
    (args.artifacts / "notification.png").write_bytes(
        adb("exec-out", "screencap", "-p").stdout
    )
    request("PUT", schedule_path, json={"schedules": []})
    adb("shell", "input keyevent KEYCODE_HOME")
    adb("shell", f"am start -n {PACKAGE}/.MainActivity")
    for _ in range(12):
        alarms = adb("shell", "dumpsys alarm").stdout.decode(errors="replace")
        # The plugin persists scheduled work; verify directly without matching old history dumps.
        stored = adb(
            "shell",
            f"run-as {PACKAGE} cat shared_prefs/scheduled_notifications.xml",
            check=False,
        )
        if b"[]" in stored.stdout:
            print(
                "PASS: schedule cancellation removed native pending reminders.",
                flush=True,
            )
            break
        time.sleep(2)
    else:
        raise AssertionError(
            "The removed reminder remains in native scheduling storage."
        )
