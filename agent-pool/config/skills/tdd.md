# Skill: test-driven development (tdd, version 1.0.0)

A repository-owned procedure fixture for the Conduit registry examples. Its registered integrity is
the SHA-256 of this file's exact bytes, so any edit is a new skill version.

1. Read the issue's acceptance criteria and name the behaviour to add or change.
2. Write one failing test that states that behaviour through the public interface.
3. Run it and confirm it fails for the expected reason, not an import or setup error.
4. Write the least code that makes it pass; run the test and the suites the issue names.
5. Refactor with every test green; never weaken or delete a test to get there.
6. Repeat until each criterion has a test that failed before the change and passes after it.
7. Report every command run and its exit code; a gate that could not run is reported, not skipped.
