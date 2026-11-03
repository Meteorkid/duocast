#!/usr/bin/env python3
"""把 release/windows/ 打成 zip。

关键点：给中文文件名显式置 UTF-8 标志（bit 11），
否则 Windows 资源管理器解压出来是乱码。
"""
import hashlib
import os
import shutil
import zipfile

ROOT = os.path.join(os.path.dirname(__file__), "..")
SRC = os.path.join(ROOT, "release", "windows")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(ROOT, "release", "beam-windows.zip")

# 二进制必须从 dist/ 同步，不能依赖 release/windows/ 里的旧副本。
# 这个坑踩过一次：源码改了、dist 也重新构建了，但 zip 里装的还是第一次的 exe，
# 用户解包后发现 SHA-256 与原包逐字节一致。
BINARIES = {
    "beam-windows-amd64.exe": "beam.exe",
    "beam-windows-arm64.exe": "beam-windows-arm64.exe",
}


def sync_binaries():
    for source_name, target_name in BINARIES.items():
        source = os.path.join(DIST, source_name)
        if not os.path.isfile(source):
            raise SystemExit(f"缺少构建产物：{source}（先跑 ./build.sh）")

        target = os.path.join(SRC, target_name)
        shutil.copyfile(source, target)

        digest = hashlib.sha256(open(target, "rb").read()).hexdigest()[:12]
        print(f"  sync {target_name:26} sha256={digest}")


def main():
    print("同步二进制：")
    sync_binaries()
    print()

    if os.path.exists(OUT):
        os.remove(OUT)

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(os.listdir(SRC)):
            path = os.path.join(SRC, name)
            if not os.path.isfile(path):
                continue

            info = zipfile.ZipInfo(f"windows/{name}")
            info.flag_bits |= 0x800
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16

            with open(path, "rb") as handle:
                archive.writestr(info, handle.read())

            print(f"  + windows/{name}")

    size = os.path.getsize(OUT) / 1024 / 1024
    print(f"\n{OUT}  ({size:.1f} MB)")


if __name__ == "__main__":
    main()
