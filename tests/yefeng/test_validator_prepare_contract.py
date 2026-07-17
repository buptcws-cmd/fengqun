from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_SCRIPTS = REPOSITORY_ROOT / "skills" / "yefeng" / "scripts"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


class ValidatorPrepareContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if POWERSHELL is None:
            raise RuntimeError("pwsh or powershell is required")

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="yefeng-validator-contract-", ignore_cleanup_errors=True
        )
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_root = Path(self.temporary_directory.name)

    def _run(
        self,
        command: list[str],
        *,
        cwd: Path | None = None,
        check: bool = True,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        if check and completed.returncode != 0:
            self.fail(
                f"command failed with {completed.returncode}: {' '.join(command)}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        return completed

    def _git(self, root: Path, *arguments: str, check: bool = True) -> str:
        return self._run(["git", *arguments], cwd=root, check=check).stdout.strip()

    def _ps(
        self, script: Path, *arguments: str, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        assert POWERSHELL is not None
        return self._run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(script), *arguments],
            check=check,
        )

    def _json_output(self, completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        return json.loads(completed.stdout.lstrip("\ufeff").strip())

    def _read_json(self, path: Path) -> dict[str, Any]:
        return json.loads(path.read_text(encoding="utf-8"))

    def _write_json(self, path: Path, value: dict[str, Any]) -> None:
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )

    def _create_product(self, name: str) -> tuple[Path, str]:
        product = self.fixture_root / name
        product.mkdir()
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Contract Test")
        self._git(product, "config", "user.email", "test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "product baseline")
        return product, self._git(product, "rev-parse", "HEAD")

    def _init_control(self, name: str) -> tuple[Path, Path, str, str]:
        product, product_head = self._create_product(f"product-{name}")
        control = self.fixture_root / f"control-{name}"
        scope_id = f"scope-{name}"
        completed = self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProductBranch",
            "main",
            "-ProjectName",
            f"Contract {name}",
            "-ProjectId",
            f"project-{name}",
            "-ScopeId",
            scope_id,
            "-ModuleGoal",
            "Validate strict external control contracts.",
        )
        self._json_output(completed)
        return control, product, product_head, scope_id

    def _validate(
        self, control: Path, product: Path, scope_id: str, *, committed: bool = False
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
        arguments = [
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ExpectedScopeId",
            scope_id,
        ]
        if committed:
            arguments.append("-RequireCommitted")
        completed = self._ps(
            control / "scripts" / "yefeng" / "validate-external-control-repo.ps1",
            *arguments,
            check=False,
        )
        return completed, self._json_output(completed)

    def _commit(self, control: Path, message: str) -> str:
        self._git(control, "config", "user.name", "Yefeng Contract Test")
        self._git(control, "config", "user.email", "test@example.invalid")
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", message)
        return self._git(control, "rev-parse", "HEAD")

    def _enter(self, control: Path, scope_id: str, writer_id: str, *extra: str) -> dict[str, Any]:
        return self._json_output(
            self._ps(
                control / "scripts" / "yefeng" / "enter-control-write.ps1",
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                *extra,
            )
        )

    def _exit(self, control: Path, scope_id: str, writer_id: str, lock: dict[str, Any]) -> None:
        self._ps(
            control / "scripts" / "yefeng" / "exit-control-write.ps1",
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-LockToken",
            lock["lock_token"],
            "-ExpectedControlHead",
            lock["expected_control_head"],
        )

    def _bootstrap_committed_control(
        self, name: str
    ) -> tuple[Path, Path, str]:
        control, product, _, scope_id = self._init_control(name)
        self._commit(control, "bootstrap control")
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        writer_id = control_state["writer_fence"]["writer_id"]
        lock = self._enter(control, scope_id, writer_id)
        self._exit(control, scope_id, writer_id, lock)
        lifecycle_guard = (
            control
            / ".yefeng"
            / "local"
            / "locks"
            / "control-repo.lifecycle.guard"
        )
        self.assertTrue(lifecycle_guard.is_file())
        self.assertEqual(
            self._run(
                [
                    "git",
                    "check-ignore",
                    "-q",
                    "--no-index",
                    "--",
                    ".yefeng/local/locks/control-repo.lifecycle.guard",
                ],
                cwd=control,
                check=False,
            ).returncode,
            0,
        )
        self.assertEqual(
            self._git(
                control,
                "ls-files",
                "--",
                ".yefeng/local/locks/control-repo.lifecycle.guard",
            ),
            "",
        )
        completed, result = self._validate(control, product, scope_id, committed=True)
        self.assertEqual(completed.returncode, 0, result["issues"])
        self.assertTrue(result["valid"])
        return control, product, scope_id

    def _assert_hidden_index_flag_is_rejected(
        self,
        *,
        name: str,
        enable_flag: str,
        disable_flag: str,
        expected_tag: str,
    ) -> None:
        control, product, scope_id = self._bootstrap_committed_control(name)
        relative = "docs/status.md"
        self._git(control, "update-index", enable_flag, "--", relative)
        try:
            tagged = self._git(control, "ls-files", "-v", "--", relative)
            self.assertTrue(tagged.startswith(f"{expected_tag} "), tagged)
            with (control / relative).open("a", encoding="utf-8") as stream:
                stream.write("\nHidden worktree drift must never validate as committed.\n")
            self.assertEqual(
                self._git(control, "status", "--short", "--", relative),
                "",
                "the fixture must reproduce Git status hiding the worktree drift",
            )

            completed, result = self._validate(
                control, product, scope_id, committed=True
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result["valid"])
            self.assertTrue(
                any(
                    relative in issue and "ordinary index entry" in issue
                    for issue in result["issues"]
                ),
                result["issues"],
            )
            self.assertTrue(
                any(
                    relative in issue and "worktree content" in issue
                    for issue in result["issues"]
                ),
                result["issues"],
            )
        finally:
            self._git(control, "update-index", disable_flag, "--", relative)
            self._git(control, "restore", "--source=HEAD", "--worktree", "--", relative)

        restored_tag = self._git(control, "ls-files", "-v", "--", relative)
        self.assertTrue(restored_tag.startswith("H "), restored_tag)
        self.assertEqual(self._git(control, "status", "--short", "--", relative), "")

    def test_committed_validation_rejects_skip_worktree_hidden_drift(self) -> None:
        self._assert_hidden_index_flag_is_rejected(
            name="skip-worktree",
            enable_flag="--skip-worktree",
            disable_flag="--no-skip-worktree",
            expected_tag="S",
        )

    def test_committed_validation_rejects_assume_unchanged_hidden_drift(self) -> None:
        self._assert_hidden_index_flag_is_rejected(
            name="assume-unchanged",
            enable_flag="--assume-unchanged",
            disable_flag="--no-assume-unchanged",
            expected_tag="h",
        )

    def test_committed_validation_audits_new_tracked_archive_decision_and_handoff_files(
        self,
    ) -> None:
        control, product, scope_id = self._bootstrap_committed_control(
            "repo-wide-index"
        )
        hidden_files = {
            "archive/2026-07-17-audit.md": (
                "--skip-worktree",
                "--no-skip-worktree",
                "S",
            ),
            "docs/shared/decisions/2026-07-17-contract.md": (
                "--assume-unchanged",
                "--no-assume-unchanged",
                "h",
            ),
            f"docs/modules/{scope_id}/handoffs/worker-report.md": (
                "--skip-worktree",
                "--no-skip-worktree",
                "S",
            ),
        }
        for relative in hidden_files:
            path = control / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Tracked control-plane evidence.\n", encoding="utf-8")
        head = self._commit(control, "add dynamic control-plane evidence")
        control_head_path = control / ".yefeng" / "local" / "control-head.json"
        control_head = self._read_json(control_head_path)
        control_head["expected_control_head"] = head
        self._write_json(control_head_path, control_head)

        try:
            for relative, (enable_flag, _, expected_tag) in hidden_files.items():
                self._git(control, "update-index", enable_flag, "--", relative)
                tagged = self._git(control, "ls-files", "-v", "--", relative)
                self.assertTrue(tagged.startswith(f"{expected_tag} "), tagged)
                with (control / relative).open("a", encoding="utf-8") as stream:
                    stream.write("Hidden worktree drift.\n")
            self.assertEqual(
                self._git(control, "status", "--short", "--", *hidden_files),
                "",
                "the fixture must hide every dynamic tracked-file drift",
            )

            completed, result = self._validate(
                control, product, scope_id, committed=True
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(result["valid"])
            for relative in hidden_files:
                self.assertTrue(
                    any(
                        relative in issue and "ordinary index entry" in issue
                        for issue in result["issues"]
                    ),
                    result["issues"],
                )
                self.assertTrue(
                    any(
                        relative in issue and "worktree content" in issue
                        for issue in result["issues"]
                    ),
                    result["issues"],
                )
        finally:
            for relative, (_, disable_flag, _) in hidden_files.items():
                self._git(control, "update-index", disable_flag, "--", relative)
            self._git(
                control,
                "restore",
                "--source=HEAD",
                "--worktree",
                "--",
                *hidden_files,
            )

    def test_committed_validation_rejects_malformed_local_fence_schema_and_types(
        self,
    ) -> None:
        control, product, scope_id = self._bootstrap_committed_control(
            "local-fence-schema"
        )
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        original = self._read_json(fence_path)
        cases: list[tuple[str, Any, str]] = [
            ("unknown property", {**original, "unexpected": True}, "unknown"),
            ("string version", {**original, "version": "1"}, "integer 1"),
            (
                "string epoch",
                {**original, "run_epoch": str(original["run_epoch"])},
                "positive 32-bit integer",
            ),
            (
                "string recovery flag",
                {**original, "recovery_required": "false"},
                "native Boolean",
            ),
            (
                "numeric repository identity",
                {**original, "control_repo_id": 1},
                "native String",
            ),
            (
                "invalid lease timestamp",
                {**original, "lease_expires_at": "tomorrow"},
                "explicit offset",
            ),
            (
                "invalid lock token",
                {**original, "lock_token": "not-a-token"},
                "32 hexadecimal",
            ),
        ]
        for label, malformed, expected_issue in cases:
            with self.subTest(label=label):
                self._write_json(fence_path, malformed)
                completed, result = self._validate(
                    control, product, scope_id, committed=True
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(result["valid"])
                self.assertTrue(
                    any(expected_issue in issue for issue in result["issues"]),
                    result["issues"],
                )
        self._write_json(fence_path, original)

    def test_committed_validation_matches_local_fence_repository_identity(self) -> None:
        control, product, scope_id = self._bootstrap_committed_control(
            "local-fence-identity"
        )
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence["control_repo_id"] = "different-control-repo"
        self._write_json(fence_path, fence)

        completed, result = self._validate(control, product, scope_id, committed=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["valid"])
        self.assertTrue(
            any("repository identity mismatch" in issue for issue in result["issues"]),
            result["issues"],
        )

    def test_committed_validation_requires_all_static_template_files(self) -> None:
        control, product, scope_id = self._bootstrap_committed_control(
            "static-allowlist"
        )
        relative_paths = [
            "archive/README.md",
            "docs/shared/decisions/README.md",
            "docs/shared/contract-change-requests/README.md",
        ]
        info_exclude = control / ".git" / "info" / "exclude"
        for relative in relative_paths:
            self._git(control, "rm", "--cached", "--", relative)
        with info_exclude.open("a", encoding="utf-8") as stream:
            for relative in relative_paths:
                stream.write(f"\n/{relative}\n")
        self._git(control, "commit", "-m", "remove static files from index")
        head = self._git(control, "rev-parse", "HEAD")
        control_head_path = control / ".yefeng" / "local" / "control-head.json"
        control_head = self._read_json(control_head_path)
        control_head["expected_control_head"] = head
        self._write_json(control_head_path, control_head)

        completed, result = self._validate(control, product, scope_id, committed=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(result["valid"])
        for relative in relative_paths:
            self.assertTrue(
                any(
                    relative in issue and "not tracked" in issue
                    for issue in result["issues"]
                ),
                result["issues"],
            )
            self.assertTrue(
                any(
                    relative in issue and "ignored" in issue
                    for issue in result["issues"]
                ),
                result["issues"],
            )

    def test_committed_validation_rejects_ignored_untracked_scope_file(self) -> None:
        control, product, _, scope_id = self._init_control("committed")
        self._commit(control, "bootstrap control")
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        writer_id = control_state["writer_fence"]["writer_id"]
        self._enter(control, scope_id, writer_id)
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        fence = self._read_json(fence_path)
        fence["lease_expires_at"] = ""
        fence["lock_token"] = ""
        self._write_json(fence_path, fence)
        lock_path.unlink()

        relative = f"docs/modules/{scope_id}/registry.md"
        self._git(control, "rm", "--cached", "--", relative)
        info_exclude = control / ".git" / "info" / "exclude"
        with info_exclude.open("a", encoding="utf-8") as stream:
            stream.write(f"\n/{relative}\n")
        self._git(control, "commit", "-m", "remove scoped registry from index")
        head = self._git(control, "rev-parse", "HEAD")
        control_head_path = control / ".yefeng" / "local" / "control-head.json"
        control_head = self._read_json(control_head_path)
        control_head["expected_control_head"] = head
        self._write_json(control_head_path, control_head)

        completed, result = self._validate(control, product, scope_id, committed=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertTrue(
            any(relative in issue and "tracked" in issue for issue in result["issues"]),
            result["issues"],
        )
        self.assertTrue(
            any(relative in issue and "ignored" in issue for issue in result["issues"]),
            result["issues"],
        )

    def test_recovery_event_requires_exact_topology_baseline_set(self) -> None:
        control, product, product_head, scope_id = self._init_control("event-baselines")
        secondary, secondary_head = self._create_product("secondary-event")
        topology_path = control / ".yefeng" / "control-plane.json"
        topology = self._read_json(topology_path)
        topology["product_repositories"].append(
            {"repo_id": "secondary", "integration_branch": "main"}
        )
        self._write_json(topology_path, topology)
        roots_path = control / ".yefeng" / "local" / "roots.json"
        roots = self._read_json(roots_path)
        roots["product_roots"]["secondary"] = str(secondary)
        self._write_json(roots_path, roots)
        control_path = control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        control_state = self._read_json(control_path)
        control_state["product_baselines"]["secondary"] = {
            "branch": "main",
            "commit": secondary_head,
        }
        self._write_json(control_path, control_state)
        first_repo_id = next(iter(control_state["product_baselines"]))
        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        event = {
            "event_id": "evt-incomplete-baseline-map",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "type": "RECOVERY_STARTED",
            "control_plane_mode": "external-git",
            "control_repo_id": topology["control_repo_id"],
            "scope_id": scope_id,
            "run_epoch": 1,
            "operation_id": "recovery-incomplete-map",
            "recovery_lock_sha256": "a" * 64,
            "previous_writer_id": "old-writer",
            "replacement_writer_id": "new-writer",
            "assignment_id": None,
            "run_id": None,
            "from": "TOTAL_CONTROL",
            "to": "TOTAL_CONTROL",
            "blocking": True,
            "status": "OPEN",
            "payload": "incomplete map",
            "product_baselines": {
                first_repo_id: {"branch": "main", "commit": product_head}
            },
            "evidence": [],
        }
        with events_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")

        completed, result = self._validate(control, product, scope_id)
        self.assertNotEqual(completed.returncode, 0)
        self.assertTrue(
            any("exact product baseline set" in issue for issue in result["issues"]),
            result["issues"],
        )

    def test_recovery_event_rejects_both_raw_lock_token_field_names(self) -> None:
        control, product, _, scope_id = self._init_control("event-lock-token")
        topology = self._read_json(control / ".yefeng" / "control-plane.json")
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        event = {
            "event_id": "evt-raw-recovery-lock-tokens",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "type": "RECOVERY_STARTED",
            "control_plane_mode": "external-git",
            "control_repo_id": topology["control_repo_id"],
            "scope_id": scope_id,
            "run_epoch": control_state["run_epoch"],
            "operation_id": "recovery-raw-lock-token-fields",
            "recovery_lock_sha256": "a" * 64,
            "lock_token": "b" * 32,
            "recovery_lock_token": "c" * 32,
            "previous_writer_id": "old-writer",
            "replacement_writer_id": "new-writer",
            "assignment_id": None,
            "run_id": None,
            "from": "TOTAL_CONTROL",
            "to": "TOTAL_CONTROL",
            "blocking": True,
            "status": "OPEN",
            "payload": "raw lock token rejection",
            "product_baselines": control_state["product_baselines"],
            "evidence": [],
        }
        with events_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")

        completed, result = self._validate(control, product, scope_id)
        self.assertNotEqual(completed.returncode, 0)
        for field_name in ("lock_token", "recovery_lock_token"):
            self.assertTrue(
                any(
                    field_name in issue and "raw lock token" in issue
                    for issue in result["issues"]
                ),
                result["issues"],
            )

    def test_active_role_and_run_require_exact_session_and_worktree_identity(self) -> None:
        control, product, _, scope_id = self._init_control("role-run")
        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_path = state_root / "control.json"
        roles_path = state_root / "roles.json"
        runs_path = state_root / "runs.json"
        control_state = self._read_json(control_path)
        roles_state = self._read_json(roles_path)
        runs_state = self._read_json(runs_path)
        control_state["startup_level"] = "LEVEL_3_FULL_PARALLEL_YEFENG"
        role = roles_state["roles"][0]
        role.update(
            {
                "state": "RUNNING",
                "assigned_by": control_state["writer_fence"]["writer_id"],
                "assignment_id": "assign-role-run",
                "session_id": "session-role",
                "process_id": 101,
                "run_id": "run-role-run",
                "product_worktree": str(self.fixture_root / "role-worktree"),
                "lease_expires_at": (
                    datetime.now(timezone.utc) + timedelta(hours=1)
                ).isoformat(),
            }
        )
        runs_state["runs"] = [
            {
                "run_id": role["run_id"],
                "role_id": role["role_id"],
                "assignment_id": role["assignment_id"],
                "scope_id": scope_id,
                "run_epoch": 1,
                "control_repo_id": control_state["control_repo_id"],
                "product_repo_id": role["product_repo_id"],
                "product_baseline_commit": role["product_baseline_commit"],
                "product_branch": role["product_branch"],
                "product_worktree": str(self.fixture_root / "different-worktree"),
                "transport_mode": role["transport_mode"],
                "session_id": "session-run",
                "process_id": role["process_id"],
                "command": "codex exec",
                "cwd": str(self.fixture_root / "different-worktree"),
                "started_at": datetime.now(timezone.utc).isoformat(),
                "ended_at": "",
                "exit_code": None,
                "status": "RUNNING",
            }
        ]
        self._write_json(control_path, control_state)
        self._write_json(roles_path, roles_state)
        self._write_json(runs_path, runs_state)

        completed, result = self._validate(control, product, scope_id)
        self.assertNotEqual(completed.returncode, 0)
        self.assertTrue(
            any("Role/run execution identity mismatch" in issue for issue in result["issues"]),
            result["issues"],
        )

    @unittest.skipUnless(os.name == "nt", "junction contract is Windows-specific")
    def test_scope_junction_is_rejected_before_scope_state_read(self) -> None:
        control, product, _, scope_id = self._init_control("junction")
        series_root = control / ".yefeng" / "series"
        scope_root = series_root / scope_id
        outside_scope = self.fixture_root / "outside-scope"
        scope_root.rename(outside_scope)
        self._run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(scope_root), str(outside_scope)]
        )

        completed, result = self._validate(control, product, scope_id)
        self.assertNotEqual(completed.returncode, 0)
        self.assertTrue(
            any("reparse point" in issue for issue in result["issues"]), result["issues"]
        )

    def test_prepare_rejects_incomplete_control_baseline_set_without_writing(self) -> None:
        control, _, _, scope_id = self._init_control("prepare-baselines")
        topology_path = control / ".yefeng" / "control-plane.json"
        topology = self._read_json(topology_path)
        topology["product_repositories"].append(
            {"repo_id": "missing-product", "integration_branch": "main"}
        )
        self._write_json(topology_path, topology)
        self._commit(control, "bootstrap incomplete baseline fixture")
        control_path = control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        control_state = self._read_json(control_path)
        writer_id = control_state["writer_fence"]["writer_id"]
        initial_lock = self._enter(control, scope_id, writer_id)
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        lock = self._read_json(lock_path)
        fence = self._read_json(fence_path)
        expired_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        lock.update(
            {
                "lease_expires_at": expired_at,
                "process_id": 999999,
                "process_start_time": (
                    datetime.now(timezone.utc) - timedelta(days=1)
                ).isoformat(),
            }
        )
        fence["lease_expires_at"] = expired_at
        self._write_json(lock_path, lock)
        self._write_json(fence_path, fence)
        self._ps(
            control / "scripts" / "yefeng" / "recover-control-write.ps1",
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-AcknowledgeExpiredLease",
        )
        transition_lock = self._enter(
            control, scope_id, writer_id, "-RecoveryTransition"
        )
        before = control_path.read_bytes()
        completed = self._ps(
            control / "scripts" / "yefeng" / "prepare-control-writer-takeover.ps1",
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-CurrentWriterId",
            writer_id,
            "-ReplacementWriterId",
            "replacement-writer",
            "-LockToken",
            transition_lock["lock_token"],
            "-Reason",
            "Reject incomplete baseline map.",
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("exact topology product set", completed.stderr)
        self.assertEqual(control_path.read_bytes(), before)
        self.assertEqual(initial_lock["run_epoch"], 1)


if __name__ == "__main__":
    unittest.main()
