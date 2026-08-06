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
            "references/total-control-operations.md",
            "references/process-backend.md",
            "references/run-evidence-retention.md",
        ):
            with self.subTest(reference=reference):
                self.assertIn(reference, skill)

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
