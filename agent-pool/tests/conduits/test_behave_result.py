"""check-behave-result.py: only a non-empty run where every scenario and step passed is accepted."""
import json
import subprocess
import sys
import unittest

from conduit_test_support import TESTS, sandbox

CHECKER = TESTS / "check-behave-result.py"


def step(status: str | None) -> dict:
    data = {"keyword": "Given", "name": "a step", "step_type": "given"}
    if status is not None:
        data["result"] = {"status": status, "duration": 0.0}
    return data


def scenario(status: str = "passed", steps: list | None = None, name: str = "a scenario") -> dict:
    return {"type": "scenario", "keyword": "Scenario", "name": name, "status": status,
            "steps": [step("passed"), step("passed")] if steps is None else steps}


def feature(*elements: dict) -> dict:
    return {"keyword": "Feature", "name": "Conduits", "status": "passed", "elements": list(elements)}


class Checker(unittest.TestCase):
    def check(self, document: object) -> subprocess.CompletedProcess:
        path = sandbox(self) / "result.json"
        path.write_text(document if isinstance(document, str) else json.dumps(document))
        return subprocess.run([sys.executable, str(CHECKER), str(path)], capture_output=True, text=True,
                              timeout=60)

    def assert_rejected(self, document: object, wanted: str) -> None:
        result = self.check(document)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(wanted, result.stdout)

    def test_all_passed_is_accepted(self) -> None:
        result = self.check([feature(scenario(name="one"), scenario(name="two"))])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("2 scenario(s) passed", result.stdout)

    def test_zero_scenarios_are_rejected(self) -> None:
        self.assert_rejected([], "no scenario")
        self.assert_rejected([feature()], "no scenario")
        self.assert_rejected([{"keyword": "Feature", "name": "Conduits", "status": "skipped"}], "no scenario")

    def test_any_non_passing_scenario_is_rejected(self) -> None:
        for status in ("skipped", "untested", "undefined", "pending", "failed", "error", "hook_error", None):
            with self.subTest(status=status):
                self.assert_rejected([feature(scenario(), scenario(status=status))], "scenario")

    def test_any_non_passing_step_is_rejected(self) -> None:
        for status in ("skipped", "untested", "undefined", "pending", "failed", "error", None):
            with self.subTest(status=status):
                broken = scenario(steps=[step("passed"), step(status)])
                self.assert_rejected([feature(broken)], "step")

    def test_a_scenario_without_steps_is_rejected(self) -> None:
        self.assert_rejected([feature(scenario(steps=[]))], "no steps")

    def test_unexpected_shapes_are_rejected(self) -> None:
        self.assert_rejected({"features": []}, "not a list")
        self.assert_rejected([feature({"type": "outline", "name": "x", "status": "passed", "steps": []})],
                             "unexpected")
        self.assert_rejected("{truncated", "unreadable")

    def test_missing_file_is_rejected(self) -> None:
        result = subprocess.run([sys.executable, str(CHECKER), str(sandbox(self) / "absent.json")],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unreadable", result.stdout)


if __name__ == "__main__":
    unittest.main()
