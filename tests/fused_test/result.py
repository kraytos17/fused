# tests/fused_test/result.py — Shared test result model.
#
# Every test function returns a TestResult or TestSuite.
# The runner aggregates them and produces one final summary.

import errno
from dataclasses import dataclass, field


@dataclass
class TestResult:
    name: str
    passed: bool
    detail: str = ""


@dataclass
class TestSuite:
    name: str
    results: list[TestResult] = field(default_factory=list)

    @property
    def passed(self) -> int:
        return sum(1 for r in self.results if r.passed)

    @property
    def failed(self) -> int:
        return sum(1 for r in self.results if not r.passed)

    @property
    def ok(self) -> bool:
        return self.failed == 0

    def add(self, result: TestResult) -> None:
        self.results.append(result)

    def add_result(self, name: str, passed: bool, detail: str = "") -> "TestResult":
        r = TestResult(name=name, passed=passed, detail=detail)
        self.results.append(r)
        return r

    def check_errno(self, name: str, fn, *args,
                    expected_errno: int = errno.ENOENT,
                    **kwargs) -> None:
        """Call fn(*args, **kwargs) and assert it raises OSError with expected_errno."""
        try:
            fn(*args, **kwargs)
            self.add_result(name, False, f"expected OSError({expected_errno}), got success")
        except OSError as e:
            if e.errno == expected_errno:
                self.add_result(name, True, detail=f"errno={e.errno}")
            else:
                self.add_result(name, False,
                                detail=f"expected errno={expected_errno}, got {e.errno}: {e.strerror}")
        except Exception as e:
            self.add_result(name, False,
                            detail=f"expected OSError, got {type(e).__name__}: {e}")

    def check_ok(self, name: str, fn, *args, **kwargs) -> None:
        """Call fn(*args, **kwargs) and assert it succeeds."""
        try:
            fn(*args, **kwargs)
            self.add_result(name, True)
        except Exception as e:
            self.add_result(name, False, detail=str(e))

    def print_summary(self, indent: str = "") -> None:
        for r in self.results:
            status = "PASS" if r.passed else "FAIL"
            suffix = f": {r.detail}" if r.detail else ""
            print(f"{indent}{status}   {r.name}{suffix}")
        print(f"{indent}=== {self.name}: {self.passed} passed, {self.failed} failed ===")
