# tests/fused_test/io.py — Shared file I/O helpers for FUSE test suites.

def read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def write(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)
