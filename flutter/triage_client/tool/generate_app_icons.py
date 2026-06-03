#!/usr/bin/env python3
import subprocess
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_SVG = ROOT / "assets/app_icon.svg"
MACOS_ICON_DIR = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
IOS_ICON_DIR = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
WEB_DIR = ROOT / "web/icons"
FAVICON = ROOT / "web/favicon.png"


IOS_ICON_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}


def render_png(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    inkscape = shutil.which("inkscape")
    if inkscape is None:
        raise SystemExit("missing required command: inkscape")
    subprocess.run(
        [
            inkscape,
            str(SOURCE_SVG),
            "--export-type=png",
            f"--export-filename={path}",
            f"--export-width={size}",
            f"--export-height={size}",
            "--export-background-opacity=0",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def write_macos_icons() -> None:
    for path in MACOS_ICON_DIR.glob("app_icon_*.png"):
        size = int(path.stem.rsplit("_", 1)[1])
        render_png(path, size)


def write_ios_icons() -> None:
    if not IOS_ICON_DIR.exists():
        return
    for filename, size in IOS_ICON_SIZES.items():
        render_png(IOS_ICON_DIR / filename, size)


def write_web_icons() -> None:
    for name, size in [
        ("Icon-192.png", 192),
        ("Icon-maskable-192.png", 192),
        ("Icon-512.png", 512),
        ("Icon-maskable-512.png", 512),
    ]:
        render_png(WEB_DIR / name, size)
    render_png(FAVICON, 32)


def main() -> None:
    if not SOURCE_SVG.exists():
        raise SystemExit(f"missing icon source: {SOURCE_SVG}")
    write_macos_icons()
    write_ios_icons()
    write_web_icons()


if __name__ == "__main__":
    main()
