from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SKILL_ROOT = REPOSITORY_ROOT / "skills" / "yefeng"


class YefengContextEfficiencyContractTests(unittest.TestCase):
    def test_entrypoint_is_a_compact_action_router(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertLessEqual(len(skill.splitlines()), 220)
        for reference in (
            "references/startup.md",
            "references/checkpoint-lifecycle.md",
            "references/current-truth-retention.md",
            "references/total-control-operations.md",
            "references/process-backend.md",
            "references/run-evidence-retention.md",
        ):
            with self.subTest(reference=reference):
                self.assertIn(reference, skill)

    def test_yefeng_is_self_contained_instead_of_loading_series_skill(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertIn("do not additionally load `series-task-workflow`", skill)
        self.assertNotIn("Use `series-task-workflow` for", skill)
        self.assertNotIn("Inherit the `series-task-workflow`", skill)

        lifecycle = (SKILL_ROOT / "references" / "checkpoint-lifecycle.md").read_text(
            encoding="utf-8"
        )
        for required in (
            "Claim And Worktree Contract",
            "Candidate And Evidence Loop",
            "Review And Cost Breakers",
            "Integration, Pause, And Closure",
        ):
            with self.subTest(required=required):
                self.assertIn(required, lifecycle)

    def test_tracked_current_truth_has_migration_and_validation_contract(self) -> None:
        reference = (
            SKILL_ROOT / "references" / "current-truth-retention.md"
        ).read_text(encoding="utf-8")

        for required in (
            "AGENTS.md",
            "Lossless Legacy Migration",
            "validate-current-truth.ps1",
            "16384",
            "120 lines",
        ):
            with self.subTest(required=required):
                self.assertIn(required, reference)

    def test_entrypoint_requires_delta_reads_and_bounded_repair_cycles(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8").casefold()

        self.assertIn("fingerprint", skill)
        self.assertIn("cursor", skill)
        self.assertIn("candidate_attempt_limit", skill)
        self.assertIn("review_failure_limit", skill)

    def test_canonical_run_template_includes_retention_bindings(self) -> None:
        templates = (SKILL_ROOT / "references" / "templates.md").read_text(
            encoding="utf-8"
        )

        for field in (
            '"run_root"',
            '"retention_group_id"',
            '"parent_run_id"',
            '"review_gate"',
            '"control_disposition"',
        ):
            with self.subTest(field=field):
                self.assertIn(field, templates)


if __name__ == "__main__":
    unittest.main()
