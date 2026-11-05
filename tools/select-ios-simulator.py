"""Select a real available iPhone simulator from simctl's JSON output."""
import json
import sys

payload = json.load(sys.stdin)
choices = []
for runtime, devices in payload.get("devices", {}).items():
    if "iOS-26" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            choices.append(device)
if not choices:
    raise SystemExit("No available iOS 26 iPhone simulator was found.")
choices.sort(key=lambda d: (
    d.get("state") != "Booted",
    "Pro" not in d["name"],
    d["name"],
))
print(choices[0]["udid"])
