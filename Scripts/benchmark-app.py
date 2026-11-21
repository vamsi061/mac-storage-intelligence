"""Sample the packaged macOS GUI with an isolated, warm fixture and external writes."""
import ctypes
import pathlib
import re
import subprocess
import tempfile
import time


class Usage(ctypes.Structure):
    # Darwin rusage_info_v2 (sys/resource.h)
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user system package_wakes interrupt_wakes pageins wired rss footprint start exit "
            "child_user child_system child_package_wakes child_interrupt_wakes child_pageins "
            "child_elapsed read written"
        ).split()
    ]


def sample(pid):
    usage = Usage()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        raise OSError("Unable to sample GUI process")
    cpu = subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], text=True)
    minutes, seconds = re.fullmatch(r"(\d+):(\d+(?:\.\d+)?)", cpu.strip()).groups()
    return time.monotonic(), int(minutes) * 60 + float(seconds), usage.rss, usage.read, usage.written


def report(name, samples):
    start, end = samples[0], samples[-1]
    duration = end[0] - start[0]
    print(f"{name}: {duration:.2f}s, CPU {100 * (end[1] - start[1]) / duration:.2f}% of one core, "
          f"peak sampled RSS {max(x[2] for x in samples) / 2**20:.1f} MiB, "
          f"physical disk read {end[3] - start[3]} B, written {end[4] - start[4]} B")


libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
app = pathlib.Path(__file__).resolve().parents[1] / "dist/Mac Storage Intelligence.app"
with tempfile.TemporaryDirectory(prefix="msi-gui-benchmark-") as temp:
    root = pathlib.Path(temp).resolve()
    for group in range(16):
        folder = root / str(group) / "nested"
        folder.mkdir(parents=True)
        for index in range(128):
            (folder / str(index)).write_bytes(b"x" * 32)
    process = subprocess.Popen([str(app / "Contents/MacOS/MacStorageIntelligence"),
                                "-inventory.allMounts", "NO", "-storage.lastScannedFolder", str(root)])
    try:
        time.sleep(3)
        for phase in ("idle", "changes"):
            readings = [sample(process.pid)]
            for index in range(24):
                if phase == "changes":
                    (root / str(index % 16) / "nested/live").write_bytes(b"x" * (1024 + index))
                time.sleep(0.5)
                readings.append(sample(process.pid))
            report(phase, readings)
    finally:
        process.terminate()
        process.wait(timeout=10)
