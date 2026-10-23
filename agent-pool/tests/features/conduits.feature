Feature: Conduit configuration registry and deny-by-default matching
  A Conduit combines a Provider, a ModelPolicy and explicit grants of Capabilities, Permissions
  and versioned Skills. The registry is a configuration-only SQLite database; matching is a pure
  function over one snapshot read from it. Every scenario uses a real database in a temporary
  directory outside the checkout.

  Scenario: Charlie cannot take a coding job that requires the exact TDD skill
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "charlie" is loaded and matched
    Then the match is denied with "missing_capability,missing_permission,missing_skill"

  Scenario: Chase takes a coding job that requires the exact TDD skill
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is eligible

  Scenario: Charlie takes a planning job
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "planning" and permissions "plan"
    When conduit "charlie" is loaded and matched
    Then the match is eligible

  Scenario: Charlie approves a revision another actor authored
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves revision "0123456789abcdef0123456789abcdef01234567" as actor "reviewer" authored by "author"
    When conduit "charlie" is loaded and matched
    Then the match is eligible

  Scenario: Chase is denied an explicit planning request
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "planning" and permissions "plan"
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_capability,missing_permission"

  Scenario: Chase is denied an explicit reviewing request
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves revision "0123456789abcdef0123456789abcdef01234567" as actor "reviewer" authored by "author"
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_capability,missing_permission"

  Scenario: Neither example conduit may merge
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "reviewing" and permissions "merge"
    When conduit "charlie" is loaded and matched
    Then the match is denied with "missing_permission"
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_capability,missing_permission"

  Scenario: A missing capability alone denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding,deploying" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_capability"

  Scenario: A missing permission alone denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test,release"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_permission"

  Scenario: A missing skill alone denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "standards" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_skill"

  Scenario: Another skill version alone denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "2.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_skill"

  Scenario: Another skill integrity alone denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with a different integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "missing_skill"

  Scenario Outline: A disabled conduit, provider, policy or grant denies
    Given a migrated registry seeded with the example conduits
    And an operator disables <table> row "<row>"
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "disabled_configuration"

    Examples:
      | table          | row           |
      | conduits       | chase         |
      | providers      | claude        |
      | model_policies | claude-sonnet |
      | capabilities   | coding        |
      | permissions    | test          |
      | skills         | tdd           |

  Scenario: An unknown conduit denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code"
    When conduit "nobody" is loaded and matched
    Then no snapshot was loaded
    And the match is denied with "unknown_conduit"

  Scenario: The author of a revision may not approve it
    Given a migrated registry with the test-only dual conduit
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves revision "0123456789abcdef0123456789abcdef01234567" as actor "author" authored by "author"
    When conduit "dual" is loaded and matched
    Then the match is denied with "self_approval"

  Scenario: The same actor through a different conduit may not approve their revision
    Given a migrated registry seeded with the example conduits
    And actor "craig-bot" authored revision "0123456789abcdef0123456789abcdef01234567" through conduit "chase"
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves that revision as actor "craig-bot"
    When conduit "charlie" is loaded and matched
    Then the match is denied with "self_approval"

  Scenario: Approval without trusted context denies
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves a revision without actor context
    When conduit "charlie" is loaded and matched
    Then the match is denied with "approval_context_missing"

  Scenario: A different actor with all grants may approve
    Given a migrated registry with the test-only dual conduit
    And a request requiring capabilities "reviewing" and permissions "review"
    And the request approves revision "0123456789abcdef0123456789abcdef01234567" as actor "reviewer" authored by "author"
    When conduit "dual" is loaded and matched
    Then the match is eligible

  Scenario: Empty requirements are an invalid request, not an unrestricted job
    Given a migrated registry seeded with the example conduits
    And a request with no required capabilities or permissions
    When conduit "chase" is loaded and matched
    Then the match is denied with "invalid_request"

  Scenario Outline: Model policy cardinality is validated when configuration is applied
    Given a migrated registry
    When a configuration with a "<kind>" policy declaring models "<models>" is applied
    Then the configuration is <outcome>

    Examples:
      | kind       | models       | outcome  |
      | fixed      | sonnet       | accepted |
      | fixed      | -            | rejected |
      | fixed      | opus,sonnet  | rejected |
      | allow_list | opus,sonnet  | accepted |
      | allow_list | -            | rejected |
      | auto       | -            | accepted |
      | auto       | sonnet       | rejected |

  Scenario: A conduit whose policy belongs to another provider is rejected
    Given a migrated registry
    When a configuration whose conduit uses another provider's policy is applied
    Then the configuration is rejected

  Scenario: A snapshot whose policy names another provider fails closed
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "planning" and permissions "plan"
    When conduit "charlie" is loaded, its policy reassigned to provider "codex", and matched
    Then the match is denied with "invalid_model_policy"

  Scenario: A stored policy that lost its fixed model fails closed on read
    Given a migrated registry seeded with the example conduits
    And an operator deletes the models of policy "claude-sonnet"
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is denied with "invalid_model_policy"

  Scenario: Configured Sonnet and auto policies are declarations, not actual-model receipts
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and matched
    Then the match is eligible
    And the snapshot declares models "sonnet" under a "fixed" policy
    And the match result records no actual model
    And the registry holds no receipt, job, claim or lease table
    And the sandbox holds only the registry database

  Scenario: A new database migrates and repeat migration is idempotent
    Given an empty sandbox
    When the registry is migrated
    Then the schema version is 1
    When the registry is migrated again
    Then the schema version is 1
    And the database file is unchanged since the first migration

  Scenario: Repeating the identical seed is a no-op
    Given a migrated registry seeded with the example conduits
    When the examples are seeded again
    Then the registry contents are unchanged

  Scenario: A newer schema version is refused without change
    Given a registry file reporting schema version 2
    When the registry is migrated expecting an error
    Then the error code is "unsupported_schema"
    And the database file is byte-for-byte unchanged

  Scenario: Conflicting seed data fails without overwriting operator edits
    Given a migrated registry seeded with the example conduits
    And an operator renames conduit "charlie" to "Charlie (edited)"
    When the examples are seeded again expecting an error
    Then the error code is "conflict"
    And the registry contents are unchanged
    And conduit "charlie" is named "Charlie (edited)"

  Scenario: Foreign keys refuse dangling grants and restrict deletion
    Given a migrated registry seeded with the example conduits
    When an operator grants conduit "charlie" the unknown capability "nonexistent"
    Then the error code is "constraint_violation"
    When an operator deletes provider "claude"
    Then the error code is "constraint_violation"
    And the registry contents are unchanged

  Scenario: Identifiers are unique
    Given a migrated registry seeded with the example conduits
    When an operator inserts provider "claude" again
    Then the error code is "constraint_violation"
    And the registry contents are unchanged

  Scenario: An interrupted transaction rolls back
    Given a migrated registry
    When seeding the examples is interrupted after 5 rows
    Then the registry contents are unchanged

  Scenario: Reading an unsupported schema is refused
    Given a registry file reporting schema version 2
    When conduit "chase" is loaded expecting an error
    Then the error code is "unsupported_schema"
    And the database file is byte-for-byte unchanged

  Scenario: Reading a missing file is refused and creates nothing
    Given an empty sandbox
    When conduit "chase" is loaded expecting an error
    Then the error code is "missing_database"
    And the sandbox is empty

  Scenario: Lock contention is bounded
    Given a migrated registry
    And another connection holds the write lock
    When the examples are seeded with a 0.3 second busy timeout expecting an error
    Then the error code is "busy"
    And the attempt gave up within 3 seconds

  Scenario: Example inputs and persisted columns are secret-free
    Given a migrated registry seeded with the example conduits
    Then the example fixture files match no credential rule
    And no persisted text column matches a credential rule

  Scenario Outline: Credential-shaped input is rejected without being echoed
    Given a migrated registry
    When a configuration whose provider name holds a synthetic "<rule>" credential is applied
    Then the configuration is rejected
    And the error names rule "<rule>" without echoing the credential
    And the registry contents are unchanged

    Examples:
      | rule                  |
      | private-key           |
      | provider-token        |
      | credential-assignment |

  Scenario: Matching produces no claim or state files and no subprocesses
    Given a migrated registry seeded with the example conduits
    And a request requiring capabilities "coding" and permissions "code,test"
    And the request requires skill "tdd" version "1.0.0" with the fixture integrity
    When conduit "chase" is loaded and then matched with effects forbidden
    Then the match is eligible
    And the sandbox holds only the registry database
