"""Samples system memory and per-process private working sets every couple of seconds
and writes them as one JSON document to the path given on the command line. Exits when
the parent process (the aquarium) goes away. Standard library only."""

import ctypes
import json
import os
import struct
import sys
import time
from ctypes import wintypes

ntdll = ctypes.WinDLL("ntdll")
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
SYSTEM_PROCESS_INFORMATION = 5
SYNCHRONIZE = 0x00100000


class MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD),
                ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]


class PERFORMANCE_INFORMATION(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("CommitTotal", ctypes.c_size_t), ("CommitLimit", ctypes.c_size_t),
                ("CommitPeak", ctypes.c_size_t), ("PhysicalTotal", ctypes.c_size_t),
                ("PhysicalAvailable", ctypes.c_size_t), ("SystemCache", ctypes.c_size_t),
                ("KernelTotal", ctypes.c_size_t), ("KernelPaged", ctypes.c_size_t),
                ("KernelNonpaged", ctypes.c_size_t), ("PageSize", ctypes.c_size_t),
                ("HandleCount", wintypes.DWORD), ("ProcessCount", wintypes.DWORD),
                ("ThreadCount", wintypes.DWORD)]


def system():
    ms = MEMORYSTATUSEX(dwLength=ctypes.sizeof(MEMORYSTATUSEX))
    kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
    pi = PERFORMANCE_INFORMATION(cb=ctypes.sizeof(PERFORMANCE_INFORMATION))
    kernel32.K32GetPerformanceInfo(ctypes.byref(pi), pi.cb)
    page = pi.PageSize
    return {
        "total": ms.ullTotalPhys,
        "avail": ms.ullAvailPhys,
        "commit": pi.CommitTotal * page,
        "commit_limit": pi.CommitLimit * page,
        "nonpaged": pi.KernelNonpaged * page,
        "paged": pi.KernelPaged * page,
        "cache": pi.SystemCache * page,
    }


def processes():
    size = 1 << 20
    while True:
        buf = ctypes.create_string_buffer(size)
        need = wintypes.ULONG()
        status = ntdll.NtQuerySystemInformation(SYSTEM_PROCESS_INFORMATION, buf, size, ctypes.byref(need)) & 0xFFFFFFFF
        if status == STATUS_INFO_LENGTH_MISMATCH:
            size = max(size * 2, need.value + 65536)
            continue
        if status != 0:
            return []
        break
    base = ctypes.addressof(buf)
    raw = buf.raw
    out, off = [], 0
    while True:
        nxt = struct.unpack_from("<I", raw, off)[0]
        private_ws = struct.unpack_from("<q", raw, off + 8)[0]
        name_len, _, name_ptr = struct.unpack_from("<HHxxxxQ", raw, off + 56)
        pid = struct.unpack_from("<Q", raw, off + 80)[0]
        ws = struct.unpack_from("<Q", raw, off + 144)[0]
        if pid != 0:
            name = ctypes.wstring_at(name_ptr, name_len // 2) if name_ptr else "System"
            if name.lower().endswith(".exe"):
                name = name[:-4]
            # Memory Compression's store is not counted as private working set.
            mem = ws if name == "Memory Compression" else private_ws
            out.append({"pid": pid, "name": name, "mem": mem})
        if nxt == 0:
            break
        off += nxt
    return out


def parent_alive(handle):
    return kernel32.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT


def main():
    path, ppid = sys.argv[1], int(sys.argv[2])
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
    parent = kernel32.OpenProcess(SYNCHRONIZE, False, ppid)
    tmp = path + ".tmp"
    while parent and parent_alive(parent):
        snap = system()
        snap["procs"] = processes()
        snap["self_pid"] = os.getpid()
        snap["t"] = time.time()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snap, f, separators=(",", ":"))
        os.replace(tmp, path)
        time.sleep(interval)


if __name__ == "__main__":
    main()
