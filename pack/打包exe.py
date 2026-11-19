#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
赛博义肢 - 一键打包工具 (Python版本)

用法:
    python pack/打包exe.py              # 编译 .pyd + 打包 exe
    python pack/打包exe.py --clean      # 清理 .pyd / .c / build
"""
import os
import sys
import shutil
import subprocess
import time
import importlib.machinery
from pathlib import Path

# ── 路径 ──
ROOT = Path(__file__).parent.parent
PY_FILE = ROOT / "logic_gui_Tools.py"
PYD_NAME = "Cyber_Deck"  # .pyd 模块名
LAUNCHER = ROOT / "pack" / "launcher.py"
ICON = ROOT / "Arasaka" / "other" / "icon.ico"

# 打包所需依赖：包名 -> pip 安装名
BUILD_DEPS = {
    "PyInstaller": "pyinstaller",
    "Cython": "cython",
    "setuptools": "setuptools",
}


def pyd_file() -> Path:
    """当前解释器 ABI 对应的 .pyd 路径，如 Cyber_Deck.cp312-win_amd64.pyd"""
    suffix = next((s for s in importlib.machinery.EXTENSION_SUFFIXES if s.endswith(".pyd")), ".pyd")
    return ROOT / "pack" / f"{PYD_NAME}{suffix}"


def pause(msg: str = "\n按回车键退出..."):
    """交互式终端才暂停，管道/自动化调用直接跳过"""
    try:
        if sys.stdin and sys.stdin.isatty():
            input(msg)
    except (EOFError, OSError):
        pass


# ═══════════════════════════════════════════
#  Cython 编译
# ═══════════════════════════════════════════

def check_cython():
    try:
        import Cython
        print(f"[OK] Cython {Cython.__version__}")
        return True
    except ImportError:
        print("[ERROR] Cython 未安装！pip install cython")
        return False


def check_compiler():
    if sys.platform != "win32":
        return True
    try:
        from setuptools._distutils.ccompiler import new_compiler
        cc = new_compiler()
        if cc.compiler_type == 'msvc':
            cc.initialize()
            print("[OK] MSVC 编译器")
            return True
    except Exception:
        pass
    print("[WARN] 未检测到 MSVC 编译器")
    return False


def compile_pyd():
    """编译 logic_gui_Tools.py -> pack/Cyber_Deck.xxx.pyd，成功返回 Path"""
    if not PY_FILE.exists():
        print("[ERROR] 未找到 logic_gui_Tools.py")
        return None

    # 输出到 pack/ 目录
    target = pyd_file()
    out_dir = target.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"编译: {PY_FILE.name} ...", end=" ", flush=True)

    setup_code = f'''# Auto-generated
from setuptools import setup, Extension
from Cython.Build import cythonize
import sys, os
os.chdir(r"{out_dir}")
sys.argv = ['setup.py', 'build_ext', '--inplace', '--build-temp', r'{out_dir}/build']
setup(
    ext_modules=cythonize(
        [Extension("{PYD_NAME}", [r"{PY_FILE}"])],
        language_level=3, quiet=True,
        build_dir=r"{out_dir}/build",
    ),
)
'''
    tmp = out_dir / "_setup_cython_tmp.py"
    tmp.write_text(setup_code, encoding='utf-8')

    try:
        result = subprocess.run(
            [sys.executable, str(tmp)],
            capture_output=True, text=True,
            cwd=str(out_dir), timeout=300,
            encoding='utf-8', errors='replace',
        )
    finally:
        tmp.unlink(missing_ok=True)
        for c in out_dir.glob("*.c"):
            c.unlink(missing_ok=True)
        for c in out_dir.rglob("*.c"):
            c.unlink(missing_ok=True)

    if result.returncode != 0:
        print("FAILED")
        tail = "\n".join((result.stderr or result.stdout or "").strip().splitlines()[-15:])
        if tail:
            print("\n---- Cython 编译输出 ----")
            print(tail)
            print("-------------------------")
        return None

    if target.exists():
        print(f"OK -> pack/{target.name}")
        return target

    # 可能 ABI 后缀不同，尝试匹配
    matches = sorted(out_dir.glob(f"{PYD_NAME}*.pyd"))
    if matches:
        print(f"OK -> pack/{matches[0].name}")
        return matches[0]

    print("FAILED: 未生成 .pyd")
    return None


# ═══════════════════════════════════════════
#  打包
# ═══════════════════════════════════════════

def _has_module(name: str) -> bool:
    r = subprocess.run([sys.executable, "-c", f"import {name}"],
                       capture_output=True, text=True)
    return r.returncode == 0


def ensure_deps() -> bool:
    """检查打包依赖，缺失则自动 pip 安装"""
    print(f"[INFO] 解释器: {sys.executable}")
    print(f"[INFO] Python {sys.version.split()[0]}")
    print()

    missing = [pip_name for mod, pip_name in BUILD_DEPS.items() if not _has_module(mod)]
    if not missing:
        import Cython
        print(f"[OK] PyInstaller / Cython {Cython.__version__} / setuptools")
        return True

    print(f"[WARN] 缺少依赖: {', '.join(missing)}")
    print("       正在自动安装（首次打包需要联网）...")
    r = subprocess.run(
        [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", *missing],
        text=True, encoding="utf-8", errors="replace",
    )
    if r.returncode != 0:
        print("[ERROR] 依赖安装失败，请手动执行：")
        print(f"        {sys.executable} -m pip install {' '.join(missing)}")
        return False

    still = [pip_name for mod, pip_name in BUILD_DEPS.items() if not _has_module(mod)]
    if still:
        print(f"[ERROR] 安装后仍缺少: {', '.join(still)}")
        return False

    print(f"[OK] 依赖安装完成: {', '.join(missing)}")
    return True


def clean_build():
    build_dir = ROOT / "build"
    if build_dir.exists():
        shutil.rmtree(build_dir, ignore_errors=True)
    spec = ROOT / "Cyber_Deck.spec"
    if spec.exists():
        spec.unlink()


def clean_pyd():
    """清理 pack/ 下的 .pyd 和 .c 文件"""
    pack_dir = ROOT / "pack"
    for f in pack_dir.glob("*.pyd"):
        f.unlink()
        print(f"  删除: pack/{f.name}")
    for f in pack_dir.glob("*.c"):
        f.unlink()
        print(f"  删除: pack/{f.name}")
    for f in pack_dir.glob("_setup_*.py"):
        f.unlink()
        print(f"  删除: pack/{f.name}")


def kill_old_process():
    if os.name != 'nt':
        return
    try:
        r = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Cyber_Deck.exe'],
                           capture_output=True, text=True)
        if 'Cyber_Deck.exe' in r.stdout:
            print("关闭正在运行的 Cyber_Deck 进程...")
            subprocess.run(['taskkill', '/F', '/IM', 'Cyber_Deck.exe'],
                           capture_output=True)
            time.sleep(1)
    except Exception:
        pass


def build_exe(pyd: Path) -> bool:
    """打包 exe (launcher.py + .pyd)"""
    print("模式: .pyd 二进制入口")
    print("打包中，请等待...")
    print()

    # 注入随机数据到 launcher.py，确保每次打包 exe hash 不同
    import random, string
    _random_tag = ''.join(random.choices(string.ascii_letters + string.digits, k=32))
    _launcher_orig = LAUNCHER.read_text(encoding='utf-8')
    _launcher_new = _launcher_orig.rstrip() + f"\n# {_random_tag}\n"
    LAUNCHER.write_text(_launcher_new, encoding='utf-8')

    os.environ['CYBER_LIMB_BUILDING'] = '1'

    upx_exe = ROOT / "pack" / "upx.exe"
    upx_arg = [f"--upx-dir={upx_exe.parent}"] if upx_exe.exists() else []

    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--clean", "--onefile", "--noconsole",
        "--name=Cyber_Deck", "--noconfirm",
        f"--distpath={ROOT}",
        f"--workpath={ROOT}/build",
        f"--icon={ICON}",
        *upx_arg,
        "--exclude-module=matplotlib",
        "--exclude-module=numpy",
        "--exclude-module=PIL",
        "--exclude-module=tkinter.test",
        "--hidden-import=yaml",
        "--hidden-import=mss",
        "--hidden-import=customtkinter",
        "--add-binary", f"{pyd}{os.pathsep}.",
        "--add-data", f"{ICON}{os.pathsep}Arasaka/other",
        str(LAUNCHER),
    ]

    result = subprocess.run(cmd, cwd=str(ROOT))
    os.environ.pop('CYBER_LIMB_BUILDING', None)

    # 恢复 launcher.py 原样
    LAUNCHER.write_text(_launcher_orig, encoding='utf-8')

    if result.returncode != 0:
        print("\n[ERROR] 打包失败！")
        return False
    return True


def show_result(pyd: Path):
    exe = ROOT / "Cyber_Deck.exe"
    print()
    print("=" * 50)
    print("打包成功！")
    print("=" * 50)
    print()
    if exe.exists():
        print(f"输出: {exe}")
        size = exe.stat().st_size
        print(f"大小: {size:,} 字节 ({size/1024/1024:.1f} MB)")
        print()
    print("包含:")
    print(f"  - {pyd.name} (Cython 二进制，无法反编译)")
    print("  - 不内置 config.yml / keymap / class / utils / GetPixels")
    print("  -> 全部从外部 WoW 插件目录加载")
    print()


# ═══════════════════════════════════════════
#  主流程
# ═══════════════════════════════════════════

def main():
    print("=" * 50)
    print("赛博义肢 - 一键打包工具")
    print("=" * 50)
    print()

    # --clean
    if "--clean" in sys.argv:
        print("清理编译产物...")
        clean_pyd()
        clean_build()
        print("[OK] 清理完成")
        return

    # 检查环境
    if not ensure_deps():
        pause()
        sys.exit(1)
    if not check_compiler():
        print("提示: 安装 Visual Studio Build Tools（勾选 C++ 生成工具）后可编译")
        if sys.stdin and sys.stdin.isatty():
            resp = input("继续尝试？(y/n): ").strip().lower()
        else:
            resp = "y"
        if resp != 'y':
            sys.exit(1)

    # 编译 .pyd
    print()
    pyd = compile_pyd()
    if not pyd:
        print("\n[ERROR] Cython 编译失败！")
        pause()
        sys.exit(1)
    print()

    # 打包
    kill_old_process()
    clean_build()
    if not build_exe(pyd):
        pause()
        sys.exit(1)

    # 清理
    for d in [ROOT / "build", ROOT / "pack" / "build"]:
        if d.exists():
            shutil.rmtree(d, ignore_errors=True)
    spec = ROOT / "Cyber_Deck.spec"
    if spec.exists():
        spec.unlink()
    # 清理编译残留
    pack_dir = ROOT / "pack"
    for pattern in ["*.c", "*.pyd", "_setup_*.py"]:
        for f in pack_dir.glob(pattern):
            f.unlink(missing_ok=True)

    show_result(pyd)
    pause("按回车键退出...")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n已取消")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] {e}")
        pause()
        sys.exit(1)
