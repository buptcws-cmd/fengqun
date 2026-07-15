from __future__ import annotations

import copy
import json
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPOSITORY_ROOT
    / "skills"
    / "series-task-workflow"
    / "scripts"
    / "reconcile-series-state.ps1"
)
POWERSHELL_ENGINES = tuple(
    dict.fromkeys(
        engine
        for engine in (shutil.which("pwsh"), shutil.which("powershell"))
        if engine is not None
    )
)
POWERSHELL = POWERSHELL_ENGINES[0] if POWERSHELL_ENGINES else None


class ReconcileSeriesStateIntegrationTests(unittest.TestCase):
    """Exercise the reconciler against real temporary Git worktrees."""

    @classmethod
    def setUpClass(cls) -> None:
        if not POWERSHELL_ENGINES:
            raise RuntimeError("pwsh or powershell is required for these integration tests")

    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="series-state-reconciler-", ignore_cleanup_errors=True
        )
        self.addCleanup(self._temporary_directory.cleanup)
        self.fixture_root = Path(self._temporary_directory.name)
        self.main_worktree = self.fixture_root / "main"
        self.main_worktree.mkdir()

        self._git(self.main_worktree, "init", "--initial-branch=main")
        self._git(self.main_worktree, "config", "user.name", "Series Test")
        self._git(self.main_worktree, "config", "user.email", "series-test@example.invalid")
        (self.main_worktree / "README.md").write_text("fixture\n", encoding="utf-8")
        self._git(self.main_worktree, "add", "README.md")
        self._git(self.main_worktree, "commit", "-m", "fixture: initialize main")

    def _git(self, cwd: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        if completed.returncode != 0:
            self.fail(
                f"git {' '.join(arguments)} failed with {completed.returncode}:\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        return completed.stdout.strip()

    def _create_candidate(self, candidate_id: str, branch: str) -> dict[str, str]:
        worktree = self.fixture_root / f"worktree-{candidate_id}"
        self._git(
            self.main_worktree,
            "worktree",
            "add",
            "-b",
            branch,
            str(worktree),
        )
        marker = worktree / f"{candidate_id}.txt"
        marker.write_text(f"{candidate_id}\n", encoding="utf-8")
        self._git(worktree, "add", marker.name)
        self._git(worktree, "commit", "-m", f"fixture: add {candidate_id}")
        return {
            "id": candidate_id,
            "worktree": str(worktree.resolve()),
            "branch": branch,
            "revision": self._git(worktree, "rev-parse", "HEAD"),
        }

    def _candidate_state(
        self, candidate: dict[str, str], *, status: str = "done"
    ) -> dict[str, Any]:
        revision = candidate["revision"]
        evidence = status not in {"claimed", "implementation", "running", "validation", "review"}
        return {
            **candidate,
            "status": status,
            "validations": (
                [
                    {
                        "name": "targeted-tests",
                        "revision": revision,
                        "status": "passed",
                        "interrupted": False,
                    }
                ]
                if evidence
                else []
            ),
            "reviews": (
                [
                    {
                        "reviewed_revision": revision,
                        "status": "passed",
                        "verdict": "review passed",
                    }
                ]
                if evidence
                else []
            ),
        }

    def _active_claim(self, candidate_id: str, *, run_epoch: int = 7) -> dict[str, Any]:
        return {
            "id": candidate_id,
            "status": "running",
            "run_epoch": run_epoch,
            "lease_expires": self._iso_time(hours=24),
        }

    def _state(
        self,
        candidates: list[dict[str, Any]],
        *,
        claims: list[dict[str, Any]] | None = None,
        status: str = "active",
        active_repairs: int = 2,
        cleanup_state: str = "pending",
    ) -> dict[str, Any]:
        return {
            "run_epoch": 7,
            "status": status,
            "main_revision": self._git(self.main_worktree, "rev-parse", "HEAD"),
            "wip_budget": {
                "active_repairs": active_repairs,
                "pending_reviews": 2,
                "integration_batches": 1,
            },
            "claims": claims or [],
            "candidates": candidates,
            "cleanup_state": cleanup_state,
        }

    @staticmethod
    def _iso_time(*, hours: int) -> str:
        instant = datetime.now(timezone.utc) + timedelta(hours=hours)
        return instant.isoformat().replace("+00:00", "Z")

    def _write_state(self, state: dict[str, Any], name: str = "state.json") -> Path:
        path = self.fixture_root / name
        path.write_text(json.dumps(state, indent=2), encoding="utf-8")
        return path

    def _invoke(
        self,
        *,
        cwd: Path,
        state_path: Path | None,
        engine: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self.assertTrue(
            SCRIPT_PATH.is_file(),
            f"implementation script is missing: {SCRIPT_PATH}",
        )
        command = [
            str(engine or POWERSHELL),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(SCRIPT_PATH),
        ]
        if state_path is not None:
            command.extend(["-StatePath", str(state_path)])
        return subprocess.run(
            command,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )

    def _json_payload(self, completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        stdout = completed.stdout.strip().lstrip("\ufeff")
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as error:
            self.fail(
                f"expected JSON output, got exit {completed.returncode}: {error}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        self.assertIsInstance(payload, dict)
        self.assertIn("issues", payload)
        self.assertIsInstance(payload["issues"], list)
        return payload

    def _assert_clean(
        self, completed: subprocess.CompletedProcess[str]
    ) -> dict[str, Any]:
        payload = self._json_payload(completed)
        self.assertEqual(
            0,
            completed.returncode,
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}",
        )
        self.assertEqual([], payload["issues"])
        return payload

    def _assert_issue(
        self, completed: subprocess.CompletedProcess[str], *expected_fragments: str
    ) -> dict[str, Any]:
        payload = self._json_payload(completed)
        self.assertEqual(
            2,
            completed.returncode,
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}",
        )
        self.assertTrue(payload["issues"], "exit 2 must include at least one issue")
        issue_text = json.dumps(payload["issues"], ensure_ascii=False).casefold()
        for fragment in expected_fragments:
            self.assertIn(fragment.casefold(), issue_text)
        return payload

    def test_state_path_is_mandatory_and_invalid_path_is_a_json_issue(self) -> None:
        omitted = self._invoke(cwd=self.main_worktree, state_path=None)
        self.assertNotEqual(0, omitted.returncode)
        self.assertIn("StatePath", omitted.stdout + omitted.stderr)

        missing = self.fixture_root / "does-not-exist.json"
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=missing), "state"
        )

    def test_valid_multi_candidate_state_reconciles_each_candidate(self) -> None:
        alpha = self._candidate_state(self._create_candidate("alpha", "task/alpha"))
        beta = self._candidate_state(self._create_candidate("beta", "task/beta"))
        state_path = self._write_state(self._state([alpha, beta]))

        self._assert_clean(self._invoke(cwd=self.main_worktree, state_path=state_path))

    def test_each_candidate_requires_its_own_bound_fields(self) -> None:
        candidate = self._candidate_state(
            self._create_candidate("alpha", "task/alpha")
        )
        for engine in POWERSHELL_ENGINES:
            for field in (
                "id",
                "status",
                "worktree",
                "branch",
                "revision",
                "validations",
                "reviews",
            ):
                with self.subTest(engine=Path(engine).name, field=field):
                    incomplete = copy.deepcopy(candidate)
                    fallback_value = incomplete.pop(field)
                    state = self._state([incomplete])
                    if field != "status":
                        state[field] = fallback_value
                    state_path = self._write_state(
                        state, f"missing-{Path(engine).stem}-{field}.json"
                    )
                    self._assert_issue(
                        self._invoke(
                            cwd=self.main_worktree,
                            state_path=state_path,
                            engine=engine,
                        ),
                        field,
                    )

    def test_valid_single_candidate_reconciles_on_every_engine(self) -> None:
        candidate = self._candidate_state(
            self._create_candidate("alpha", "task/alpha")
        )
        state_path = self._write_state(self._state([candidate]))

        for engine in POWERSHELL_ENGINES:
            with self.subTest(engine=Path(engine).name):
                self._assert_clean(
                    self._invoke(
                        cwd=self.main_worktree,
                        state_path=state_path,
                        engine=engine,
                    )
                )

    def test_active_claim_requires_current_epoch_and_live_lease(self) -> None:
        candidate = self._candidate_state(
            self._create_candidate("alpha", "task/alpha"), status="running"
        )
        valid_claim = self._active_claim("alpha")
        valid_state = self._write_state(
            self._state(
                [candidate], claims=[valid_claim], active_repairs=1
            ),
            "valid-claim.json",
        )
        self._assert_clean(self._invoke(cwd=self.main_worktree, state_path=valid_state))

        mutations = {
            "run_epoch": lambda claim: claim.update(run_epoch=6),
            "lease": lambda claim: claim.update(lease_expires=self._iso_time(hours=-24)),
            "missing lease": lambda claim: claim.pop("lease_expires"),
        }
        for expected, mutate in mutations.items():
            with self.subTest(expected=expected):
                claim = copy.deepcopy(valid_claim)
                mutate(claim)
                state_path = self._write_state(
                    self._state([candidate], claims=[claim], active_repairs=1),
                    f"invalid-claim-{expected.replace(' ', '-')}.json",
                )
                self._assert_issue(
                    self._invoke(cwd=self.main_worktree, state_path=state_path),
                    expected.split()[-1],
                )

    def test_wip_counts_candidates_but_ignores_unregistered_worktrees(self) -> None:
        alpha_source = self._create_candidate("alpha", "task/alpha")
        beta_source = self._create_candidate("unrelated", "scratch/unrelated")
        alpha = self._candidate_state(alpha_source, status="running")
        alpha_claim = self._active_claim("alpha")

        only_registered_candidate = self._write_state(
            self._state([alpha], claims=[alpha_claim], active_repairs=1),
            "ignore-unregistered-worktree.json",
        )
        self._assert_clean(
            self._invoke(
                cwd=self.main_worktree, state_path=only_registered_candidate
            )
        )

        beta = self._candidate_state(beta_source, status="running")
        over_budget = self._write_state(
            self._state(
                [alpha, beta],
                claims=[alpha_claim, self._active_claim("unrelated")],
                active_repairs=1,
            ),
            "over-budget.json",
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=over_budget), "wip"
        )

    def test_invocation_from_main_and_candidate_worktree_is_identical(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        candidate = self._candidate_state(source)
        state_path = self._write_state(
            self._state([candidate], active_repairs=0), "cwd-independent.json"
        )

        from_main = self._invoke(cwd=self.main_worktree, state_path=state_path)
        from_candidate = self._invoke(
            cwd=Path(source["worktree"]), state_path=state_path
        )
        main_payload = self._assert_clean(from_main)
        candidate_payload = self._assert_clean(from_candidate)
        self.assertEqual(main_payload, candidate_payload)

    def test_candidate_git_identity_and_passed_evidence_bind_exact_revision(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        candidate = self._candidate_state(source)
        main_revision = self._git(self.main_worktree, "rev-parse", "HEAD")

        mutations = {
            "branch": lambda item: item.update(branch="task/not-alpha"),
            "revision": lambda item: item.update(revision=main_revision),
            "validation": lambda item: item["validations"][0].update(
                revision=main_revision
            ),
            "review": lambda item: item["reviews"][0].update(
                reviewed_revision=main_revision
            ),
        }
        for expected, mutate in mutations.items():
            with self.subTest(expected=expected):
                drifted = copy.deepcopy(candidate)
                mutate(drifted)
                state_path = self._write_state(
                    self._state([drifted]), f"drift-{expected}.json"
                )
                self._assert_issue(
                    self._invoke(cwd=self.main_worktree, state_path=state_path),
                    "alpha",
                    expected,
                )

    def test_control_status_and_closed_state_forbid_active_execution(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        running = self._candidate_state(source, status="running")
        claim = self._active_claim("alpha")

        for control_status in ("paused", "handed-off", "cancelled"):
            with self.subTest(control_status=control_status):
                state_path = self._write_state(
                    self._state(
                        [running],
                        claims=[claim],
                        status=control_status,
                        active_repairs=1,
                    ),
                    f"{control_status}.json",
                )
                self._assert_issue(
                    self._invoke(cwd=self.main_worktree, state_path=state_path),
                    control_status,
                )

        done = self._candidate_state(source)
        not_cleaned = self._write_state(
            self._state([done], status="closed", cleanup_state="pending"),
            "closed-not-cleaned.json",
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=not_cleaned), "cleanup"
        )

        still_active = self._write_state(
            self._state(
                [running],
                status="closed",
                active_repairs=1,
                cleanup_state="cleaned",
            ),
            "closed-still-active.json",
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=still_active), "closed"
        )

        closed = self._write_state(
            self._state([done], status="closed", cleanup_state="cleaned"),
            "closed-clean.json",
        )
        self._assert_clean(self._invoke(cwd=self.main_worktree, state_path=closed))

    def test_lifecycle_statuses_are_exhaustive_and_fail_closed(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        implementation_review = self._candidate_state(
            source, status="implementation-review"
        )
        closed_with_active_candidate = self._write_state(
            self._state(
                [implementation_review], status="closed", cleanup_state="cleaned"
            ),
            "closed-implementation-review.json",
        )
        self._assert_issue(
            self._invoke(
                cwd=self.main_worktree, state_path=closed_with_active_candidate
            ),
            "implementation-review",
        )

        unknown_candidate = self._candidate_state(source, status="unknown-status")
        unknown_candidate_state = self._write_state(
            self._state([unknown_candidate]), "unknown-candidate-status.json"
        )
        self._assert_issue(
            self._invoke(
                cwd=self.main_worktree, state_path=unknown_candidate_state
            ),
            "candidate",
            "status",
        )

        done = self._candidate_state(source)
        unknown_claim_state = self._write_state(
            self._state([done], claims=[{"id": "claim-a", "status": "unknown"}]),
            "unknown-claim-status.json",
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=unknown_claim_state),
            "claim",
            "status",
        )

    def test_done_candidate_requires_passed_validation_and_review(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        done = self._candidate_state(source)

        no_validation = copy.deepcopy(done)
        no_validation["validations"] = []
        no_validation_state = self._write_state(
            self._state([no_validation]), "done-without-validation.json"
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=no_validation_state),
            "validation",
        )

        no_review = copy.deepcopy(done)
        no_review["reviews"] = []
        no_review_state = self._write_state(
            self._state([no_review]), "done-without-review.json"
        )
        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=no_review_state),
            "review",
        )

    def test_terminal_candidate_requires_latest_review_to_pass(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        done = self._candidate_state(source)
        done["reviews"].append(
            {
                "reviewed_revision": source["revision"],
                "status": "failed",
                "verdict": "review failed",
            }
        )
        state_path = self._write_state(
            self._state([done]), "done-with-latest-review-failed.json"
        )

        for engine in POWERSHELL_ENGINES:
            with self.subTest(engine=Path(engine).name):
                self._assert_issue(
                    self._invoke(
                        cwd=self.main_worktree,
                        state_path=state_path,
                        engine=engine,
                    ),
                    "review",
                )

    def test_terminal_candidate_rejects_incomplete_validation_markers(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        for marker in ("cancelled", "timed_out", "incomplete"):
            done = self._candidate_state(source)
            done["validations"][0][marker] = True
            state_path = self._write_state(
                self._state([done]), f"done-with-{marker}-validation.json"
            )

            for engine in POWERSHELL_ENGINES:
                with self.subTest(engine=Path(engine).name, marker=marker):
                    self._assert_issue(
                        self._invoke(
                            cwd=self.main_worktree,
                            state_path=state_path,
                            engine=engine,
                        ),
                        "validation",
                        marker,
                    )

    def test_closed_series_rejects_resumable_candidate_statuses(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        for candidate_status in ("paused", "handed-off"):
            candidate = self._candidate_state(source, status=candidate_status)
            state_path = self._write_state(
                self._state(
                    [candidate], status="closed", cleanup_state="cleaned"
                ),
                f"closed-with-{candidate_status}-candidate.json",
            )

            for engine in POWERSHELL_ENGINES:
                with self.subTest(
                    engine=Path(engine).name, candidate_status=candidate_status
                ):
                    self._assert_issue(
                        self._invoke(
                            cwd=self.main_worktree,
                            state_path=state_path,
                            engine=engine,
                        ),
                        "closed",
                        candidate_status,
                    )

    def test_prunable_candidate_worktree_is_not_treated_as_live(self) -> None:
        source = self._create_candidate("alpha", "task/alpha")
        candidate = self._candidate_state(source)
        shutil.rmtree(source["worktree"])
        state_path = self._write_state(
            self._state([candidate]), "prunable-worktree.json"
        )

        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=state_path),
            "worktree",
        )

    def test_invalid_wip_budget_returns_a_structured_issue(self) -> None:
        candidate = self._candidate_state(
            self._create_candidate("alpha", "task/alpha")
        )
        state = self._state([candidate])
        state["wip_budget"]["active_repairs"] = "not-an-int"
        state_path = self._write_state(state, "invalid-wip.json")

        self._assert_issue(
            self._invoke(cwd=self.main_worktree, state_path=state_path),
            "wip",
            "active_repairs",
        )


if __name__ == "__main__":
    unittest.main()
