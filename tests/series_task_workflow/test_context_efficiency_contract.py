from __future__ import annotations

import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SKILL_ROOT = REPOSITORY_ROOT / "skills" / "series-task-workflow"


class SeriesContextEfficiencyContractTests(unittest.TestCase):
    def test_entrypoint_stays_small_and_routes_detailed_state_rules(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")

        self.assertLessEqual(len(skill.splitlines()), 190)
        self.assertIn("references/control-state.md", skill)
        self.assertIn("incremental read", skill.casefold())

    def test_control_reference_defines_resume_and_cost_breakers(self) -> None:
        reference = (SKILL_ROOT / "references" / "control-state.md").read_text(
            encoding="utf-8"
        )

        for required in (
            "instruction_fingerprints",
            "event_cursors",
            "candidate_attempt_limit",
            "review_failure_limit",
            "pre-audit-ready",
            "final-review-ready",
        ):
            with self.subTest(required=required):
                self.assertIn(required, reference)


if __name__ == "__main__":
    unittest.main()
