from __future__ import annotations

import json
import hashlib
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


class ExitRecoverContractTests(unittest.TestCase):
    """Security and lifecycle contracts for the copied writer helpers."""

    @classmethod
    def setUpClass(cls) -> None:
        if POWERSHELL is None:
            raise RuntimeError("pwsh or powershell is required")

    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="yefeng-exit-recover-", ignore_cleanup_errors=True
        )
        self.addCleanup(self._temporary_directory.cleanup)
        self.root = Path(self._temporary_directory.name)

    def _run(
        self,
        command: list[str],
        *,
        cwd: Path | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )
        if check and completed.returncode != 0:
            self.fail(
                f"command failed with {completed.returncode}: {' '.join(command)}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        return completed

    def _git(self, cwd: Path, *arguments: str) -> str:
        return self._run(["git", *arguments], cwd=cwd).stdout.strip()

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

    def _create_control(self, name: str) -> tuple[Path, Path, str, str]:
        product = self.root / f"product-{name}"
        product.mkdir()
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Test")
        self._git(product, "config", "user.email", "yefeng-test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "product baseline")

        control = self.root / f"control-{name}"
        scope_id = f"scope-{name}"
        self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProjectName",
            f"Yefeng {name}",
            "-ProjectId",
            f"project-{name}",
            "-ScopeId",
            scope_id,
        )
        self._git(control, "config", "user.name", "Yefeng Test")
        self._git(control, "config", "user.email", "yefeng-test@example.invalid")
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "control bootstrap")
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        return product, control, scope_id, control_state["writer_fence"]["writer_id"]

    def _script(self, control: Path, name: str) -> Path:
        return control / "scripts" / "yefeng" / name

    def _enter(self, control: Path, scope_id: str, writer_id: str) -> dict[str, Any]:
        return self._json_output(
            self._ps(
                self._script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
            )
        )

    def _exit(
        self,
        control: Path,
        scope_id: str,
        writer_id: str,
        lock: dict[str, Any],
        *,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self._ps(
            self._script(control, "exit-control-write.ps1"),
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
            check=check,
        )

    def _prepare_committed_recovery_transition(
        self,
        control: Path,
        scope_id: str,
        writer_id: str,
        *,
        replacement_writer: str = "replacement-writer",
    ) -> tuple[dict[str, Any], str]:
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence["recovery_required"] = True
        self._write_json(fence_path, fence)

        transition_lock = self._json_output(
            self._ps(
                self._script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-RecoveryTransition",
            )
        )
        self._ps(
            self._script(control, "prepare-control-writer-takeover.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-CurrentWriterId",
            writer_id,
            "-ReplacementWriterId",
            replacement_writer,
            "-LockToken",
            transition_lock["lock_token"],
            "-Reason",
            "Exercise committed-crash recovery validation.",
        )
        return transition_lock, replacement_writer

    def _expire_writer_lock(self, control: Path, scope_id: str) -> Path:
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        lock = self._read_json(lock_path)
        fence = self._read_json(fence_path)
        expired_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        lock.update(
            {
                "lease_expires_at": expired_at,
                "process_id": 2_000_000_000,
                "process_start_time": (
                    datetime.now(timezone.utc) - timedelta(days=1)
                ).isoformat(),
            }
        )
        fence["lease_expires_at"] = expired_at
        self._write_json(lock_path, lock)
        self._write_json(fence_path, fence)
        return lock_path

    def _set_writer_lock_tokens(
        self,
        control: Path,
        scope_id: str,
        lock_token: str,
        fence_token: str | None = None,
    ) -> tuple[Path, Path]:
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        lock = self._read_json(lock_path)
        fence = self._read_json(fence_path)
        lock["lock_token"] = lock_token
        fence["lock_token"] = lock_token if fence_token is None else fence_token
        self._write_json(lock_path, lock)
        self._write_json(fence_path, fence)
        return lock_path, fence_path

    def _activate_old_epoch_role_and_run(
        self, control: Path, scope_id: str, writer_id: str
    ) -> None:
        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_path = state_root / "control.json"
        roles_path = state_root / "roles.json"
        runs_path = state_root / "runs.json"
        control_state = self._read_json(control_path)
        roles_state = self._read_json(roles_path)
        runs_state = self._read_json(runs_path)
        control_state["startup_level"] = "LEVEL_3_FULL_PARALLEL_YEFENG"

        integrator = roles_state["roles"][0]
        integrator.update(
            {
                "state": "RUNNING",
                "assigned_by": writer_id,
                "assignment_id": "old-assignment",
                "session_id": "old-session",
                "process_id": 424242,
                "run_id": "old-run",
                "product_worktree": str(self.root / "old-worktree"),
                "current_checkpoint": "implementation",
                "lease_expires_at": (
                    datetime.now(timezone.utc) + timedelta(hours=1)
                ).isoformat(),
            }
        )
        planned = json.loads(json.dumps(integrator))
        planned.update(
            {
                "role_id": "WORKER",
                "role_name": "Planned worker",
                "state": "PLANNED",
                "assigned_by": None,
                "assignment_id": None,
                "session_id": None,
                "process_id": None,
                "run_id": None,
                "product_worktree": None,
                "current_checkpoint": "planned",
                "lease_expires_at": "",
            }
        )
        roles_state["roles"] = [integrator, planned]
        product_repo_id = integrator["product_repo_id"]
        baseline = control_state["product_baselines"][product_repo_id]
        runs_state["runs"] = [
            {
                "run_id": integrator["run_id"],
                "role_id": integrator["role_id"],
                "assignment_id": integrator["assignment_id"],
                "scope_id": scope_id,
                "run_epoch": 1,
                "control_repo_id": control_state["control_repo_id"],
                "product_repo_id": product_repo_id,
                "product_baseline_commit": baseline["commit"],
                "product_branch": baseline["branch"],
                "product_worktree": integrator["product_worktree"],
                "transport_mode": "control-spool",
                "session_id": integrator["session_id"],
                "process_id": integrator["process_id"],
                "command": "codex exec",
                "cwd": integrator["product_worktree"],
                "started_at": datetime.now(timezone.utc).isoformat(),
                "ended_at": "",
                "exit_code": None,
                "status": "RUNNING",
            }
        ]
        self._write_json(control_path, control_state)
        self._write_json(roles_path, roles_state)
        self._write_json(runs_path, runs_state)

    def _recover(
        self,
        control: Path,
        scope_id: str,
        writer_id: str,
        *,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self._ps(
            self._script(control, "recover-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-AcknowledgeExpiredLease",
            check=check,
        )

    def test_only_the_one_time_bootstrap_head_binding_may_exit_without_commit(self) -> None:
        _, control, scope_id, writer_id = self._create_control("zero")

        bootstrap_lock = self._enter(control, scope_id, writer_id)
        self._exit(control, scope_id, writer_id, bootstrap_lock)

        ordinary_lock = self._enter(control, scope_id, writer_id)
        rejected = self._exit(
            control, scope_id, writer_id, ordinary_lock, check=False
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("must publish exactly one control commit", rejected.stderr)
        self.assertTrue(
            (control / ".yefeng" / "local" / "locks" / "control-repo.write.lock").exists()
        )

    def test_recovery_rejects_unparseable_process_identity_even_when_pid_is_absent(self) -> None:
        _, control, scope_id, writer_id = self._create_control("identity")
        self._enter(control, scope_id, writer_id)
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        lock = self._read_json(lock_path)
        fence = self._read_json(fence_path)
        expired_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        lock["lease_expires_at"] = expired_at
        lock["process_id"] = 2_000_000_000
        lock["process_start_time"] = "not-a-timestamp"
        fence["lease_expires_at"] = expired_at
        self._write_json(lock_path, lock)
        self._write_json(fence_path, fence)

        rejected = self._ps(
            self._script(control, "recover-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-AcknowledgeExpiredLease",
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("process_start_time", rejected.stderr)
        self.assertTrue(lock_path.exists())

    def test_normal_recovery_reenters_after_local_fence_write_before_lock_delete(
        self,
    ) -> None:
        _, control, scope_id, writer_id = self._create_control("normal-reentry")
        entered_lock = self._enter(control, scope_id, writer_id)
        lock_path = self._expire_writer_lock(control, scope_id)
        expired_lock = self._read_json(lock_path)
        self.assertFalse(expired_lock["recovery_transition"])

        # Reproduce the durable state after recover wrote its local mirrors but
        # crashed immediately before the lock-token CAS deletion.
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence.update(
            {
                "writer_id": writer_id,
                "run_epoch": expired_lock["run_epoch"],
                "lease_expires_at": None,
                "lock_token": None,
                "recovery_required": True,
            }
        )
        self._write_json(fence_path, fence)

        head_path = control / ".yefeng" / "local" / "control-head.json"
        head_state = self._read_json(head_path)
        head_state["expected_control_head"] = self._git(control, "rev-parse", "HEAD")
        head_state["updated_at"] = datetime.now(timezone.utc).isoformat()
        self._write_json(head_path, head_state)

        archive_path = (
            control
            / ".yefeng"
            / "quarantine"
            / scope_id
            / f"writer-lock-{entered_lock['lock_token']}.json"
        )
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_json(
            archive_path,
            {
                "version": 1,
                "recovered_at": datetime.now(timezone.utc).isoformat(),
                "reason": "expired lease and non-authoritative recorded process",
                "actual_control_head": self._git(control, "rev-parse", "HEAD"),
                "lock": expired_lock,
            },
        )

        recovered = self._json_output(self._recover(control, scope_id, writer_id))

        self.assertTrue(recovered["recovered_local_lock"])
        self.assertTrue(recovered["recovery_required"])
        self.assertFalse(lock_path.exists())
        recovered_fence = self._read_json(fence_path)
        self.assertEqual(recovered_fence["writer_id"], writer_id)
        self.assertEqual(recovered_fence["run_epoch"], expired_lock["run_epoch"])
        self.assertIsNone(recovered_fence["lease_expires_at"])
        self.assertIsNone(recovered_fence["lock_token"])
        self.assertTrue(recovered_fence["recovery_required"])

    def test_recovery_rejects_case_variant_held_fence_token(self) -> None:
        _, control, scope_id, writer_id = self._create_control("held-token-case")
        self._enter(control, scope_id, writer_id)
        authoritative_token = "abcdef0123456789abcdef0123456789"
        lock_path, _ = self._set_writer_lock_tokens(
            control,
            scope_id,
            authoritative_token,
            authoritative_token.swapcase(),
        )
        self._expire_writer_lock(control, scope_id)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("allowed pre-entry, held", rejected.stderr)
        self.assertTrue(lock_path.exists())
        archive_path = (
            control
            / ".yefeng"
            / "quarantine"
            / scope_id
            / f"writer-lock-{authoritative_token}.json"
        )
        self.assertFalse(archive_path.exists())

    def test_recovery_rejects_case_variant_existing_archive_token(self) -> None:
        _, control, scope_id, writer_id = self._create_control("archive-token-case")
        self._enter(control, scope_id, writer_id)
        authoritative_token = "abcdef0123456789abcdef0123456789"
        lock_path, _ = self._set_writer_lock_tokens(
            control, scope_id, authoritative_token
        )
        self._expire_writer_lock(control, scope_id)
        archive_path = (
            control
            / ".yefeng"
            / "quarantine"
            / scope_id
            / f"writer-lock-{authoritative_token}.json"
        )
        archive_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_json(
            archive_path,
            {"lock": {"lock_token": authoritative_token.swapcase()}},
        )

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Existing recovery evidence conflicts", rejected.stderr)
        self.assertTrue(lock_path.exists())
        self.assertEqual(
            self._read_json(archive_path)["lock"]["lock_token"],
            authoritative_token.swapcase(),
        )

    def test_normal_recovery_accepts_old_empty_fence_before_local_write(self) -> None:
        _, control, scope_id, writer_id = self._create_control("normal-pre-local")
        self._enter(control, scope_id, writer_id)
        lock_path = self._expire_writer_lock(control, scope_id)
        expired_lock = self._read_json(lock_path)
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence.update(
            {
                "lease_expires_at": None,
                "lock_token": None,
                "recovery_required": False,
            }
        )
        self._write_json(fence_path, fence)

        recovered = self._json_output(self._recover(control, scope_id, writer_id))

        self.assertTrue(recovered["recovered_local_lock"])
        self.assertTrue(recovered["recovery_required"])
        self.assertFalse(lock_path.exists())
        self.assertTrue(self._read_json(fence_path)["recovery_required"])
        self.assertFalse(expired_lock["recovery_transition"])

    def test_normal_recovery_rejects_a_held_fence_with_recovery_mode(self) -> None:
        _, control, scope_id, writer_id = self._create_control("normal-held-mode")
        self._enter(control, scope_id, writer_id)
        lock_path = self._expire_writer_lock(control, scope_id)
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence["recovery_required"] = True
        self._write_json(fence_path, fence)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Held local writer fence recovery mode", rejected.stderr)
        self.assertTrue(lock_path.exists())

    def test_recovery_transition_requires_old_empty_fence_recovery_mode(self) -> None:
        _, control, scope_id, writer_id = self._create_control("transition-old-empty")
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence["recovery_required"] = True
        self._write_json(fence_path, fence)
        transition_lock = self._json_output(
            self._ps(
                self._script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-RecoveryTransition",
            )
        )
        lock_path = self._expire_writer_lock(control, scope_id)
        fence = self._read_json(fence_path)
        fence.update(
            {
                "lease_expires_at": None,
                "lock_token": None,
                "recovery_required": False,
            }
        )
        self._write_json(fence_path, fence)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertTrue(transition_lock["recovery_transition"])
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("old-writer fence", rejected.stderr)
        self.assertTrue(lock_path.exists())

    def test_committed_recovery_rejects_replacement_empty_fence_recovery_mode(
        self,
    ) -> None:
        _, control, scope_id, writer_id = self._create_control(
            "replacement-empty-mode"
        )
        _, replacement_writer = self._prepare_committed_recovery_transition(
            control, scope_id, writer_id
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "committed replacement")
        lock_path = self._expire_writer_lock(control, scope_id)
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence.update(
            {
                "writer_id": replacement_writer,
                "run_epoch": 2,
                "lease_expires_at": None,
                "lock_token": None,
                "recovery_required": True,
            }
        )
        self._write_json(fence_path, fence)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("replacement fence must not require recovery", rejected.stderr)
        self.assertTrue(lock_path.exists())

    def test_exit_rejects_non_boolean_recovery_transition_and_invalid_scope(self) -> None:
        _, control, scope_id, writer_id = self._create_control("schema")
        lock = self._enter(control, scope_id, writer_id)
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        malformed = self._read_json(lock_path)
        malformed["recovery_transition"] = "false"
        self._write_json(lock_path, malformed)

        rejected = self._exit(control, scope_id, writer_id, lock, check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("native Boolean", rejected.stderr)

        invalid_scope = self._ps(
            self._script(control, "recover-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            "../../outside",
            "-WriterId",
            writer_id,
            "-AcknowledgeExpiredLease",
            check=False,
        )
        self.assertNotEqual(invalid_scope.returncode, 0)
        self.assertIn("Invalid ScopeId", invalid_scope.stderr)

    def test_recovery_exit_requires_the_exact_topology_baseline_snapshot(self) -> None:
        _, control, scope_id, writer_id = self._create_control("snapshot")
        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_path = state_root / "control.json"
        roles_path = state_root / "roles.json"
        runs_path = state_root / "runs.json"
        transport_path = state_root / "transport.json"
        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )

        control_state = self._read_json(control_path)
        roles_state = self._read_json(roles_path)
        runs_state = self._read_json(runs_path)
        role = roles_state["roles"][0]
        role.update(
            {
                "state": "RUNNING",
                "assigned_by": writer_id,
                "assignment_id": "assign-old",
                "session_id": "session-old",
                "process_id": 424242,
                "run_id": "run-old",
                "product_worktree": str(self.root / "old-worktree"),
                "lease_expires_at": (
                    datetime.now(timezone.utc) + timedelta(hours=1)
                ).isoformat(),
            }
        )
        product_repo_id = role["product_repo_id"]
        baseline = control_state["product_baselines"][product_repo_id]
        runs_state["runs"] = [
            {
                "run_id": "run-old",
                "role_id": role["role_id"],
                "assignment_id": "assign-old",
                "scope_id": scope_id,
                "run_epoch": 1,
                "control_repo_id": control_state["control_repo_id"],
                "product_repo_id": product_repo_id,
                "product_baseline_commit": baseline["commit"],
                "product_branch": baseline["branch"],
                "product_worktree": role["product_worktree"],
                "transport_mode": "control-spool",
                "session_id": "session-old",
                "process_id": 424242,
                "status": "RUNNING",
            }
        ]
        self._write_json(roles_path, roles_state)
        self._write_json(runs_path, runs_state)
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "active old epoch")

        fence = self._read_json(fence_path)
        fence["recovery_required"] = True
        self._write_json(fence_path, fence)
        transition_lock = self._json_output(
            self._ps(
                self._script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-RecoveryTransition",
            )
        )

        replacement_writer = "replacement-writer"
        control_state["run_epoch"] = 2
        control_state["lifecycle_state"] = "RECOVERING"
        control_state["writer_fence"].update(
            {
                "writer_id": replacement_writer,
                "fence_epoch": 2,
                "lease_expires_at": None,
            }
        )
        roles_state["run_epoch"] = 2
        role.update({"state": "EXPIRED", "lease_expires_at": ""})
        runs_state["run_epoch"] = 2
        runs_state["runs"][0]["status"] = "EXPIRED"
        transport_state = self._read_json(transport_path)
        transport_state["run_epoch"] = 2
        recovery_event = {
            "event_id": "evt-snapshot-recovery",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "type": "RECOVERY_STARTED",
            "control_plane_mode": "external-git",
            "control_repo_id": control_state["control_repo_id"],
            "scope_id": scope_id,
            "run_epoch": 2,
            "operation_id": "writer-recovery-snapshot",
            "recovery_lock_sha256": hashlib.sha256(
                transition_lock["lock_token"].encode("utf-8")
            ).hexdigest(),
            "previous_writer_id": writer_id,
            "replacement_writer_id": replacement_writer,
            "blocking": True,
            "status": "OPEN",
            "product_baselines": {},
        }
        self._write_json(control_path, control_state)
        self._write_json(roles_path, roles_state)
        self._write_json(runs_path, runs_state)
        self._write_json(transport_path, transport_state)
        events = [
            json.loads(line)
            for line in events_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        events.append(recovery_event)
        events_path.write_text(
            "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events),
            encoding="utf-8",
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "invalid recovery snapshot")

        exit_arguments = [
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-LockToken",
            transition_lock["lock_token"],
            "-ExpectedControlHead",
            transition_lock["expected_control_head"],
            "-ReplacementWriterId",
            replacement_writer,
            "-ReplacementRunEpoch",
            "2",
        ]
        rejected = self._ps(
            self._script(control, "exit-control-write.ps1"),
            *exit_arguments,
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("product baselines identity set mismatch", rejected.stderr)

        recovery_event["product_baselines"] = {
            product_repo_id: {
                "branch": baseline["branch"],
                "commit": baseline["commit"],
            }
        }
        events[-1] = recovery_event
        events_path.write_text(
            "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events),
            encoding="utf-8",
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "--amend", "--no-edit")
        released = self._json_output(
            self._ps(
                self._script(control, "exit-control-write.ps1"), *exit_arguments
            )
        )
        self.assertTrue(released["released"])

    def test_committed_crash_recovery_accepts_a_complete_lock_bound_snapshot(self) -> None:
        _, control, scope_id, writer_id = self._create_control("crash-valid")
        self._activate_old_epoch_role_and_run(control, scope_id, writer_id)
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "active old epoch")
        _, replacement_writer = self._prepare_committed_recovery_transition(
            control, scope_id, writer_id
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "valid committed recovery transition")
        lock_path = self._expire_writer_lock(control, scope_id)

        recovered = self._json_output(
            self._recover(control, scope_id, writer_id)
        )

        self.assertTrue(recovered["recovered_local_lock"])
        self.assertFalse(recovered["recovery_required"])
        self.assertEqual(recovered["current_writer_id"], replacement_writer)
        self.assertEqual(recovered["current_run_epoch"], 2)
        self.assertFalse(lock_path.exists())

    def test_committed_crash_recovery_rejects_missing_or_extra_baselines(self) -> None:
        for mutation in (
            "control-missing",
            "control-extra",
            "event-missing",
            "event-extra",
        ):
            with self.subTest(mutation=mutation):
                _, control, scope_id, writer_id = self._create_control(
                    f"crash-baseline-{mutation}"
                )
                self._prepare_committed_recovery_transition(
                    control, scope_id, writer_id
                )
                state_root = control / ".yefeng" / "series" / scope_id
                control_path = state_root / "state" / "control.json"
                events_path = state_root / "events.jsonl"
                control_state = self._read_json(control_path)
                events = [
                    json.loads(line)
                    for line in events_path.read_text(encoding="utf-8").splitlines()
                    if line.strip()
                ]
                recovery_event = next(
                    event for event in events if event["type"] == "RECOVERY_STARTED"
                )
                product_repo_id = next(iter(control_state["product_baselines"]))
                if mutation == "control-missing":
                    control_state["product_baselines"].pop(product_repo_id)
                elif mutation == "event-missing":
                    recovery_event["product_baselines"].pop(product_repo_id)
                elif mutation == "control-extra":
                    extra_baseline = {
                        "branch": "main",
                        "commit": self._git(control, "rev-parse", "HEAD"),
                    }
                    control_state["product_baselines"]["unexpected-product"] = (
                        extra_baseline
                    )
                else:
                    extra_baseline = {
                        "branch": "main",
                        "commit": self._git(control, "rev-parse", "HEAD"),
                    }
                    recovery_event["product_baselines"]["unexpected-product"] = (
                        extra_baseline
                    )
                self._write_json(control_path, control_state)
                events_path.write_text(
                    "".join(
                        json.dumps(event, separators=(",", ":")) + "\n"
                        for event in events
                    ),
                    encoding="utf-8",
                )
                self._git(control, "add", "--all")
                self._git(control, "commit", "-m", f"invalid {mutation} baseline")
                lock_path = self._expire_writer_lock(control, scope_id)

                rejected = self._recover(
                    control, scope_id, writer_id, check=False
                )

                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("product baselines identity set mismatch", rejected.stderr)
                self.assertTrue(lock_path.exists())

    def test_committed_crash_recovery_rejects_a_raw_lock_token_event(self) -> None:
        _, control, scope_id, writer_id = self._create_control("crash-raw-token")
        transition_lock, _ = self._prepare_committed_recovery_transition(
            control, scope_id, writer_id
        )
        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        events = [
            json.loads(line)
            for line in events_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        recovery_event = next(
            event for event in events if event["type"] == "RECOVERY_STARTED"
        )
        recovery_event["lock_token"] = transition_lock["lock_token"]
        events_path.write_text(
            "".join(
                json.dumps(event, separators=(",", ":")) + "\n" for event in events
            ),
            encoding="utf-8",
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "invalid raw recovery token")
        lock_path = self._expire_writer_lock(control, scope_id)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("must not contain a raw lock token", rejected.stderr)
        self.assertTrue(lock_path.exists())

    def test_committed_crash_recovery_rejects_an_active_replacement_epoch_role(
        self,
    ) -> None:
        _, control, scope_id, writer_id = self._create_control("crash-active-role")
        self._prepare_committed_recovery_transition(control, scope_id, writer_id)
        roles_path = (
            control / ".yefeng" / "series" / scope_id / "state" / "roles.json"
        )
        roles_state = self._read_json(roles_path)
        replacement_role = next(
            role for role in roles_state["roles"] if role["run_epoch"] == 2
        )
        replacement_role.update(
            {
                "state": "RUNNING",
                "assigned_by": "replacement-writer",
                "assignment_id": "replacement-assignment",
            }
        )
        self._write_json(roles_path, roles_state)
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "invalid active replacement role")
        lock_path = self._expire_writer_lock(control, scope_id)

        rejected = self._recover(control, scope_id, writer_id, check=False)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("non-PLANNED replacement-epoch role", rejected.stderr)
        self.assertTrue(lock_path.exists())

    @unittest.skipUnless(shutil.which("powershell"), "junction test requires Windows")
    def test_enter_rejects_an_internal_junction_before_writing_the_lock(self) -> None:
        _, control, scope_id, writer_id = self._create_control("junction")
        outside = self.root / "outside-locks"
        outside.mkdir()
        locks = control / ".yefeng" / "local" / "locks"
        assert POWERSHELL is not None
        created = self._run(
            [
                "powershell",
                "-NoLogo",
                "-NoProfile",
                "-Command",
                f"New-Item -ItemType Junction -Path '{locks}' -Target '{outside}' | Out-Null",
            ],
            check=False,
        )
        if created.returncode != 0:
            self.skipTest(f"could not create junction: {created.stderr}")

        rejected = self._ps(
            self._script(control, "enter-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("reparse point", rejected.stderr)
        self.assertFalse((outside / "control-repo.write.lock").exists())


if __name__ == "__main__":
    unittest.main()
