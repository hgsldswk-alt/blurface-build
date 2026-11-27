"""Export named PNG attachments from the simulator's xcresult."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory

LANGUAGES = ("en", "de", "zh-Hans", "zh-Hant", "ja")
SCENES = ("01-home", "02-detections", "03-redacted", "04-batch", "05-export")
EXPECTED = {f"store-{lang}-{scene}" for lang in LANGUAGES for scene in SCENES}
NAMES = re.compile(r"store-(?:en|de|zh-Hans|zh-Hant|ja)-\d{2}-[a-z]+(?=[_. -]|$)")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def export_manifest(raw, output):
    current = {}

    def find(node):
        if isinstance(node, list):
            for item in node:
                find(item)
        elif isinstance(node, dict):
            if "exportedFileName" not in node:
                for item in node.values():
                    find(item)
                return
            match = NAMES.search(str(node.get("suggestedHumanReadableName", "")))
            if not match or match[0] not in EXPECTED:
                return
            asset = (raw / node["exportedFileName"]).resolve()
            if not asset.is_relative_to(raw.resolve()) or not asset.is_file() or asset.suffix.lower() != ".png":
                raise ValueError(f"Invalid attachment for {match[0]}")
            with asset.open("rb") as stream:
                if stream.read(len(PNG_SIGNATURE)) != PNG_SIGNATURE:
                    raise ValueError(f"Attachment is not PNG: {match[0]}")
            if match[0] in current:
                raise ValueError(f"Duplicate attachment: {match[0]}")
            current[match[0]] = asset

    find(json.loads((raw / "manifest.json").read_text(encoding="utf-8")))
    if missing := EXPECTED - current.keys():
        raise ValueError("Missing screenshots: " + ", ".join(sorted(missing)))
    output.mkdir(parents=True, exist_ok=True)
    for name, asset in current.items():
        shutil.copy2(asset, output / f"{name}.png")


def main(result, output):
    with TemporaryDirectory(prefix="blurface-shots-") as temp:
        raw = Path(temp)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                        "--output-path", str(raw)], check=True)
        export_manifest(raw, Path(output))
    print(f"Exported {len(EXPECTED)} screenshots to {output}")


if __name__ == "__main__":
    main(*sys.argv[1:])
