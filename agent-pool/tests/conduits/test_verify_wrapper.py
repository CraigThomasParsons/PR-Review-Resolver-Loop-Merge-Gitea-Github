"""verify-conduits.sh: interpreter selection, fail-closed Behave checks and the exact commands.

The gate is driven with a fake interpreter that records its arguments, answers the unittest and
Behave invocations with canned exit statuses and results, and hands anything else (the version
probe, the result checker) to the real interpreter running these tests. The real gate is never
run from here, so the suite does not recurse into itself.
"""
import json
import os
import stat
import subprocess
import sys
import unittest
from pathlib import Path

from conduit_test_support import ROOT, TESTS, sandbox

GATE = TESTS / "verify-conduits.sh"
UNITTEST_ARGS = "-m unittest discover -s agent-pool/tests/conduits -p test_*.py -v"
BEHAVE_ARGS = "-m behave agent-pool/tests/features/conduits.feature --format json --outfile "

FAKE = """#!/bin/sh
printf '%s|%s|%s\\n' "$PWD" "${PYTHONPATH:-}" "$*" >> "$FAKE_LOG"
if [ "$1" = "-m" ] && [ "$2" = "unittest" ]; then exit "${FAKE_UNITTEST_RC:-0}"; fi
if [ "$1" = "-m" ] && [ "$2" = "behave" ]; then
  if [ "${3:-}" = "--version" ]; then
    [ -z "${FAKE_NO_BEHAVE:-}" ] || exit 1
    echo "behave 1.3.3"; exit 0
  fi
  out=""; previous=""
  for argument in "$@"; do
    [ "$previous" = "--outfile" ] && out="$argument"
    previous="$argument"
  done
  if [ -n "${FAKE_BEHAVE_RESULT:-}" ] && [ -n "$out" ]; then cp "$FAKE_BEHAVE_RESULT" "$out"; fi
  exit "${FAKE_BEHAVE_RC:-0}"
fi
exec "@PYTHON@" "$@"
"""


def result(*scenario_statuses: str, step_status: str = "passed") -> list:
    return [{"keyword": "Feature", "name": "Conduits", "status": "passed", "elements": [
        {"type": "scenario", "keyword": "Scenario", "name": f"s{i}", "status": status,
         "steps": [{"keyword": "Given", "name": "x", "result": {"status": step_status, "duration": 0}}]}
        for i, status in enumerate(scenario_statuses)]}]


class Wrapper(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = sandbox(self)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.log = self.dir / "fake.log"
        self.fake = self.make_fake("fake-python")

    def make_fake(self, name: str) -> Path:
        path = self.bin / name
        path.write_text(FAKE.replace("@PYTHON@", sys.executable))
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def gate(self, *, interpreter: str | None = None, path_prefix: str = "", canned: object = None,
             **fake_env: str) -> subprocess.CompletedProcess:
        env = {"PATH": path_prefix + os.environ.get("PATH", ""), "HOME": str(self.dir),
               "FAKE_LOG": str(self.log), "PYTHONDONTWRITEBYTECODE": "1", **fake_env}
        if interpreter is not None:
            env["CONDUITS_PYTHON"] = interpreter
        if canned is not None:
            canned_path = self.dir / "canned.json"
            canned_path.write_text(json.dumps(canned))
            env["FAKE_BEHAVE_RESULT"] = str(canned_path)
        return subprocess.run(["bash", str(GATE)], cwd=self.dir, env=env, capture_output=True, text=True,
                              timeout=120)

    def calls(self) -> list[tuple[str, str, str]]:
        if not self.log.exists():
            return []
        return [tuple(line.split("|", 2)) for line in self.log.read_text().splitlines()]

    def test_the_gate_is_strict_bash(self) -> None:
        self.assertIn("set -euo pipefail", GATE.read_text().splitlines()[:20])

    def test_missing_interpreter_fails(self) -> None:
        ran = self.gate(interpreter=str(self.dir / "no-such-python"))
        self.assertNotEqual(ran.returncode, 0)
        self.assertIn("interpreter", ran.stdout + ran.stderr)
        self.assertEqual(self.calls(), [])

    def test_non_executable_interpreter_fails(self) -> None:
        plain = self.dir / "plain-file"
        plain.write_text("not a program\n")
        ran = self.gate(interpreter=str(plain))
        self.assertNotEqual(ran.returncode, 0)

    def test_missing_behave_fails_before_any_test_runs(self) -> None:
        ran = self.gate(interpreter=str(self.fake), FAKE_NO_BEHAVE="1")
        self.assertNotEqual(ran.returncode, 0)
        self.assertIn("Behave", ran.stdout + ran.stderr)
        self.assertFalse([c for c in self.calls() if "unittest" in c[2]])

    def test_selected_interpreter_runs_both_exact_commands(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=result("passed"))
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        calls = self.calls()
        unit = [c for c in calls if c[2].startswith("-m unittest")]
        gherkin = [c for c in calls if c[2].startswith("-m behave agent-pool")]
        self.assertEqual([c[2] for c in unit], [UNITTEST_ARGS])
        self.assertEqual(len(gherkin), 1)
        self.assertTrue(gherkin[0][2].startswith(BEHAVE_ARGS), gherkin[0][2])
        for cwd, pythonpath, _ in unit + gherkin:
            self.assertEqual(Path(cwd).resolve(), ROOT)
            self.assertEqual(pythonpath, "agent-pool/scripts")
        self.assertIn(str(self.fake), ran.stdout)
        self.assertIn("PYTHONPATH=agent-pool/scripts", ran.stdout)

    def test_python3_on_path_is_the_default(self) -> None:
        self.make_fake("python3")
        ran = self.gate(path_prefix=f"{self.bin}:", canned=result("passed"))
        self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
        self.assertTrue([c for c in self.calls() if c[2].startswith("-m behave agent-pool")])

    def test_zero_scenarios_fail_even_when_behave_exits_zero(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=[])
        self.assertNotEqual(ran.returncode, 0)

    def test_a_filtered_run_of_skipped_scenarios_fails(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=result("passed", "skipped"))
        self.assertNotEqual(ran.returncode, 0)

    def test_undefined_steps_fail(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=result("undefined", step_status="undefined"),
                        FAKE_BEHAVE_RC="1")
        self.assertNotEqual(ran.returncode, 0)

    def test_nonzero_behave_exit_fails_even_with_a_passing_result(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=result("passed"), FAKE_BEHAVE_RC="1")
        self.assertNotEqual(ran.returncode, 0)

    def test_a_missing_result_fails(self) -> None:
        ran = self.gate(interpreter=str(self.fake))
        self.assertNotEqual(ran.returncode, 0)

    def test_failing_unit_tests_fail(self) -> None:
        ran = self.gate(interpreter=str(self.fake), canned=result("passed"), FAKE_UNITTEST_RC="1")
        self.assertNotEqual(ran.returncode, 0)


if __name__ == "__main__":
    unittest.main()
