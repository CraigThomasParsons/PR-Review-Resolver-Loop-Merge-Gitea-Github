"""Pure deny-by-default matching: match_conduit(snapshot, request) with hand-built snapshots."""
import dataclasses
import unittest
from unittest import mock

import conduit_test_support  # noqa: F401  (puts agent-pool/scripts on sys.path)
from conduit_registry import (
    DENIAL_CODES, ConduitSnapshot, Grant, MatchRequest, MatchResult, ModelPolicySnapshot,
    ProviderSnapshot, SkillGrant, SkillRequirement, match_conduit,
)

TDD = "a" * 64
OTHER = "b" * 64
REVISION = "c" * 40


def snapshot(**changes: object) -> ConduitSnapshot:
    base = ConduitSnapshot(
        id="chase",
        name="Chase",
        enabled=True,
        provider_id="claude",
        model_policy_id="claude-sonnet",
        provider=ProviderSnapshot(id="claude", name="Claude", enabled=True),
        model_policy=ModelPolicySnapshot(id="claude-sonnet", provider_id="claude", kind="fixed",
                                         enabled=True, declared_models=("sonnet",)),
        executable="claude",
        invocation=("claude",),
        capabilities=(Grant("coding", True),),
        permissions=(Grant("code", True), Grant("test", True)),
        skills=(SkillGrant("tdd", "1.0.0", TDD, True),),
    )
    return dataclasses.replace(base, **changes)


def coding_request(**changes: object) -> MatchRequest:
    base = MatchRequest(
        required_capabilities=("coding",),
        required_permissions=("code", "test"),
        required_skills=(SkillRequirement("tdd", "1.0.0", TDD),),
    )
    return dataclasses.replace(base, **changes)


class EligibleAndDenied(unittest.TestCase):
    def test_all_grants_present_is_eligible(self) -> None:
        self.assertEqual(match_conduit(snapshot(), coding_request()), MatchResult(True, ()))

    def test_absent_snapshot_returns_only_unknown_conduit(self) -> None:
        self.assertEqual(match_conduit(None, coding_request()), MatchResult(False, ("unknown_conduit",)))
        self.assertEqual(match_conduit(None, MatchRequest((), ())), MatchResult(False, ("unknown_conduit",)))

    def test_missing_capability_denies(self) -> None:
        result = match_conduit(snapshot(capabilities=()), coding_request())
        self.assertEqual(result, MatchResult(False, ("missing_capability",)))

    def test_missing_permission_denies(self) -> None:
        result = match_conduit(snapshot(permissions=(Grant("code", True),)), coding_request())
        self.assertEqual(result, MatchResult(False, ("missing_permission",)))

    def test_missing_skill_denies(self) -> None:
        result = match_conduit(snapshot(skills=()), coding_request())
        self.assertEqual(result, MatchResult(False, ("missing_skill",)))

    def test_other_skill_version_denies(self) -> None:
        request = coding_request(required_skills=(SkillRequirement("tdd", "2.0.0", TDD),))
        self.assertEqual(match_conduit(snapshot(), request), MatchResult(False, ("missing_skill",)))

    def test_other_skill_integrity_denies(self) -> None:
        request = coding_request(required_skills=(SkillRequirement("tdd", "1.0.0", OTHER),))
        self.assertEqual(match_conduit(snapshot(), request), MatchResult(False, ("missing_skill",)))

    def test_all_reasons_are_returned_sorted_and_distinct(self) -> None:
        request = coding_request(required_capabilities=("coding", "planning", "reviewing"),
                                 required_permissions=("merge", "plan"),
                                 required_skills=(SkillRequirement("tdd", "9", TDD),
                                                  SkillRequirement("x", "1", TDD)))
        result = match_conduit(snapshot(enabled=False), request)
        self.assertFalse(result.eligible)
        self.assertEqual(result.reasons, ("disabled_configuration", "missing_capability",
                                          "missing_permission", "missing_skill"))

    def test_codes_are_the_documented_stable_set(self) -> None:
        self.assertEqual(set(DENIAL_CODES), {
            "unknown_conduit", "invalid_request", "disabled_configuration", "invalid_model_policy",
            "missing_capability", "missing_skill", "missing_permission", "approval_context_missing",
            "self_approval"})

    def test_result_carries_no_actual_model(self) -> None:
        self.assertEqual([f.name for f in dataclasses.fields(MatchResult)], ["eligible", "reasons"])


class DisabledConfiguration(unittest.TestCase):
    def assert_disabled(self, conduit: ConduitSnapshot) -> None:
        self.assertEqual(match_conduit(conduit, coding_request()),
                         MatchResult(False, ("disabled_configuration",)))

    def test_disabled_conduit(self) -> None:
        self.assert_disabled(snapshot(enabled=False))

    def test_disabled_provider(self) -> None:
        self.assert_disabled(snapshot(provider=ProviderSnapshot("claude", "Claude", False)))

    def test_missing_provider(self) -> None:
        self.assert_disabled(snapshot(provider=None))

    def test_disabled_policy(self) -> None:
        policy = dataclasses.replace(snapshot().model_policy, enabled=False)
        self.assert_disabled(snapshot(model_policy=policy))

    def test_disabled_capability_grant(self) -> None:
        self.assert_disabled(snapshot(capabilities=(Grant("coding", False),)))

    def test_disabled_permission_grant(self) -> None:
        self.assert_disabled(snapshot(permissions=(Grant("code", True), Grant("test", False))))

    def test_disabled_skill_grant(self) -> None:
        self.assert_disabled(snapshot(skills=(SkillGrant("tdd", "1.0.0", TDD, False),)))

    def test_disabled_grant_that_is_not_required_does_not_deny(self) -> None:
        conduit = snapshot(capabilities=(Grant("coding", True), Grant("planning", False)))
        self.assertTrue(match_conduit(conduit, coding_request()).eligible)


class ModelPolicyValidation(unittest.TestCase):
    def policy(self, kind: str, models: tuple[str, ...], provider: str = "claude") -> ConduitSnapshot:
        return snapshot(model_policy=ModelPolicySnapshot("claude-sonnet", provider, kind, True, models))

    def test_policy_other_than_the_conduits_fails_closed(self) -> None:
        conduit = snapshot(model_policy=ModelPolicySnapshot("elsewhere", "claude", "auto", True, ()))
        self.assertEqual(match_conduit(conduit, coding_request()), MatchResult(False, ("invalid_model_policy",)))

    def test_valid_cardinalities(self) -> None:
        for kind, models in (("fixed", ("sonnet",)), ("allow_list", ("sonnet",)),
                             ("allow_list", ("opus", "sonnet")), ("auto", ())):
            with self.subTest(kind=kind, models=models):
                self.assertTrue(match_conduit(self.policy(kind, models), coding_request()).eligible)

    def test_invalid_cardinalities_fail_closed(self) -> None:
        for kind, models in (("fixed", ()), ("fixed", ("opus", "sonnet")), ("allow_list", ()),
                             ("auto", ("sonnet",)), ("random", ("sonnet",)), ("fixed", ("",)),
                             ("allow_list", ("sonnet", "sonnet"))):
            with self.subTest(kind=kind, models=models):
                self.assertEqual(match_conduit(self.policy(kind, models), coding_request()),
                                 MatchResult(False, ("invalid_model_policy",)))

    def test_provider_mismatch_fails_closed(self) -> None:
        self.assertEqual(match_conduit(self.policy("auto", (), provider="codex"), coding_request()),
                         MatchResult(False, ("invalid_model_policy",)))

    def test_missing_policy_fails_closed(self) -> None:
        self.assertEqual(match_conduit(snapshot(model_policy=None), coding_request()),
                         MatchResult(False, ("invalid_model_policy",)))


class InvalidRequests(unittest.TestCase):
    def assert_invalid(self, request: object) -> None:
        self.assertEqual(match_conduit(snapshot(), request), MatchResult(False, ("invalid_request",)))

    def test_empty_capabilities_are_not_an_unrestricted_job(self) -> None:
        self.assert_invalid(coding_request(required_capabilities=()))

    def test_empty_permissions_are_not_an_unrestricted_job(self) -> None:
        self.assert_invalid(coding_request(required_permissions=()))

    def test_malformed_fields(self) -> None:
        for changes in ({"required_capabilities": ("Coding",)}, {"required_capabilities": ["coding"]},
                        {"required_permissions": ("",)},
                        {"required_skills": (SkillRequirement("tdd", "1.0.0", "short"),)},
                        {"required_skills": ("tdd",)},
                        {"approves_revision": "yes"}, {"revision_sha": "not-a-sha"},
                        {"actor_id": ""}, {"authored_by": ("ok", "")}):
            with self.subTest(changes=changes):
                self.assert_invalid(coding_request(**changes))

    def test_not_a_request(self) -> None:
        self.assert_invalid({"required_capabilities": ["coding"]})


class Approval(unittest.TestCase):
    def reviewer(self) -> ConduitSnapshot:
        return snapshot(id="charlie", capabilities=(Grant("reviewing", True),),
                        permissions=(Grant("review", True),), skills=())

    def approval(self, **changes: object) -> MatchRequest:
        base = MatchRequest(required_capabilities=("reviewing",), required_permissions=("review",),
                            actor_id="reviewer", revision_sha=REVISION, authored_by=("author",),
                            approves_revision=True)
        return dataclasses.replace(base, **changes)

    def test_a_different_actor_with_all_grants_may_approve(self) -> None:
        self.assertEqual(match_conduit(self.reviewer(), self.approval()), MatchResult(True, ()))

    def test_the_author_may_not_approve_their_revision(self) -> None:
        result = match_conduit(self.reviewer(), self.approval(actor_id="author"))
        self.assertEqual(result, MatchResult(False, ("self_approval",)))

    def test_any_co_author_is_excluded_case_insensitively(self) -> None:
        result = match_conduit(self.reviewer(), self.approval(actor_id="Author", authored_by=("x", "author")))
        self.assertEqual(result, MatchResult(False, ("self_approval",)))

    def test_missing_context_denies(self) -> None:
        for changes in ({"actor_id": None}, {"revision_sha": None}, {"authored_by": ()}):
            with self.subTest(changes=changes):
                self.assertEqual(match_conduit(self.reviewer(), self.approval(**changes)),
                                 MatchResult(False, ("approval_context_missing",)))

    def test_context_is_not_needed_without_approval(self) -> None:
        request = self.approval(approves_revision=False, actor_id=None, revision_sha=None, authored_by=())
        self.assertEqual(match_conduit(self.reviewer(), request), MatchResult(True, ()))

    def test_self_approval_is_independent_of_grants(self) -> None:
        dual = snapshot(capabilities=(Grant("coding", True), Grant("reviewing", True)),
                        permissions=(Grant("code", True), Grant("review", True)))
        result = match_conduit(dual, self.approval(actor_id="author"))
        self.assertEqual(result, MatchResult(False, ("self_approval",)))


class Purity(unittest.TestCase):
    def test_matching_touches_no_file_process_or_network(self) -> None:
        def forbidden(*args: object, **kwargs: object) -> None:
            raise AssertionError("match_conduit must not perform effects")

        with mock.patch("builtins.open", forbidden), mock.patch("os.open", forbidden), \
                mock.patch("subprocess.Popen", forbidden), mock.patch("os.fork", forbidden), \
                mock.patch("socket.socket", forbidden), mock.patch("os.system", forbidden):
            self.assertTrue(match_conduit(snapshot(), coding_request()).eligible)
            self.assertFalse(match_conduit(None, coding_request()).eligible)

    def test_snapshot_and_result_are_immutable(self) -> None:
        conduit = snapshot()
        with self.assertRaises(dataclasses.FrozenInstanceError):
            conduit.enabled = False  # type: ignore[misc]
        with self.assertRaises(dataclasses.FrozenInstanceError):
            match_conduit(conduit, coding_request()).eligible = False  # type: ignore[misc]
        self.assertIsInstance(conduit.capabilities, tuple)


if __name__ == "__main__":
    unittest.main()
