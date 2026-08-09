from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SKILL_ROOT = REPOSITORY_ROOT / "skills" / "yefeng"
SOURCE_SCRIPTS = SKILL_ROOT / "scripts"
POWERSHELL_7 = shutil.which("pwsh")
WINDOWS_POWERSHELL = shutil.which("powershell")
POWERSHELL = POWERSHELL_7 or WINDOWS_POWERSHELL


class ExternalControlRepoIntegrationTests(unittest.TestCase):
    """Exercise the published yefeng control-plane scripts against real Git repos."""

    @classmethod
    def setUpClass(cls) -> None:
        if POWERSHELL is None:
            raise RuntimeError("pwsh or powershell is required for yefeng integration tests")

    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(
            prefix="yefeng-control-", ignore_cleanup_errors=True
        )
        self.addCleanup(self._temporary_directory.cleanup)
        self.fixture_root = Path(self._temporary_directory.name)

    def _run(
        self,
        command: list[str],
        *,
        cwd: Path | None = None,
        check: bool = True,
        env: dict[str, str] | None = None,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=timeout,
        )
        if check and completed.returncode != 0:
            self.fail(
                f"command failed with {completed.returncode}: {' '.join(command)}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        return completed

    def _git(self, cwd: Path, *arguments: str, check: bool = True) -> str:
        completed = self._run(["git", *arguments], cwd=cwd, check=check)
        return completed.stdout.strip()

    def _ps(
        self,
        script: Path,
        *arguments: str,
        engine: str | None = None,
        check: bool = True,
        env: dict[str, str] | None = None,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        selected_engine = engine or POWERSHELL
        assert selected_engine is not None
        return self._run(
            [selected_engine, "-NoLogo", "-NoProfile", "-File", str(script), *arguments],
            check=check,
            env=env,
            timeout=timeout,
        )

    def _json_output(self, completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        try:
            return json.loads(completed.stdout.lstrip("\ufeff").strip())
        except json.JSONDecodeError as error:
            self.fail(
                f"PowerShell output is not JSON: {error}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )

    def _read_json(self, path: Path) -> dict[str, Any]:
        return json.loads(path.read_text(encoding="utf-8"))

    def _write_json(self, path: Path, value: dict[str, Any]) -> None:
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )

    def _create_product(
        self, name: str, *, packed_branch: str | None = None
    ) -> tuple[Path, str]:
        product = self.fixture_root / name
        product.mkdir()
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Test")
        self._git(product, "config", "user.email", "yefeng-test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "fixture: product baseline")
        head = self._git(product, "rev-parse", "HEAD")
        if packed_branch is not None:
            packed_refs = product / ".git" / "packed-refs"
            packed_refs.write_bytes(
                (
                    "# pack-refs with: peeled fully-peeled sorted\n"
                    f"{head} refs/heads/{packed_branch}\n"
                ).encode("utf-8")
            )
            self.assertEqual(
                self._git(product, "rev-parse", f"refs/heads/{packed_branch}"), head
            )
        return product, head

    def _init_control(
        self,
        product: Path,
        name: str,
        *,
        branch: str = "main",
        bind_product: bool = False,
        engine: str | None = None,
    ) -> Path:
        control = self.fixture_root / f"control-{name}"
        arguments = [
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProductBranch",
            branch,
            "-ProjectName",
            f"Yefeng {name}",
            "-ProjectId",
            f"project-{name}",
            "-ScopeId",
            f"scope-{name}",
            "-ModuleGoal",
            "Validate governed external control behavior.",
        ]
        if bind_product:
            arguments.append("-BindProductGitConfig")
        result = self._json_output(
            self._ps(
                SOURCE_SCRIPTS / "init-external-control-repo.ps1",
                *arguments,
                engine=engine,
            )
        )
        self.assertEqual(Path(result["control_root"]), control)
        return control

    def _control_script(self, control: Path, name: str) -> Path:
        return control / "scripts" / "yefeng" / name

    def _validate(
        self,
        control: Path,
        product: Path,
        scope_id: str,
        *,
        committed: bool = False,
        require_binding: bool = False,
        engine: str | None = None,
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
        if require_binding:
            arguments.append("-RequireProductBinding")
        completed = self._ps(
            self._control_script(control, "validate-external-control-repo.ps1"),
            *arguments,
            engine=engine,
            check=False,
        )
        return completed, self._json_output(completed)

    def _commit_control(self, control: Path, message: str) -> str:
        self._git(control, "config", "user.name", "Yefeng Test")
        self._git(control, "config", "user.email", "yefeng-test@example.invalid")
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", message)
        return self._git(control, "rev-parse", "HEAD")

    def _prepare_active_scope(self, control: Path, scope_id: str) -> str:
        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_path = state_root / "control.json"
        roles_path = state_root / "roles.json"
        runs_path = state_root / "runs.json"
        control_state = self._read_json(control_path)
        roles_state = self._read_json(roles_path)
        runs_state = self._read_json(runs_path)
        writer_id = control_state["writer_fence"]["writer_id"]
        outcome_lock_revision = "test-outcome-lock-v1"
        control_state["outcome_lock"].update(
            {
                "status": "CONFIRMED",
                "revision": outcome_lock_revision,
                "user_visible_proof": "The governed recovery flow completes and validates.",
                "first_vertical_slice": "Recover one active scope without losing custody.",
                "mvp_scope": "Writer takeover and committed control-plane validation.",
                "non_goals": "No product capability expansion.",
                "existing_capability_inventory": "Reuse the existing writer lifecycle helpers.",
                "reuse_adapt_new_defer": "Reuse lifecycle; adapt the confirmed outcome fixture.",
                "approved_public_contract_families": "Existing external-control contract only.",
                "authorization_ceiling": "Test-only local repository mutation.",
                "auto_execution_boundary": "Run the isolated recovery fixture.",
                "ask_boundary": "No external side effects.",
                "estimate_baseline": "One bounded integration test.",
                "drift_thresholds": "Stop on any additional product scope.",
                "approved_by": "yefeng-test",
                "approved_at": datetime.now(timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%S.%f0+00:00"
                ),
            }
        )
        control_state["startup_level"] = "LEVEL_3_FULL_PARALLEL_YEFENG"

        integrator = roles_state["roles"][0]
        integrator.update(
            {
                "state": "RUNNING",
                "assigned_by": writer_id,
                "assignment_id": "assign-epoch-1-integrator",
                "session_id": "session-epoch-1-integrator",
                "process_id": 424242,
                "run_id": "run-epoch-1-integrator",
                "product_worktree": str(self.fixture_root / "worktree-integrator"),
                "current_checkpoint": "implementation",
                "outcome_lock_revision": outcome_lock_revision,
                "delivery_classification": "TEST_ONLY",
                "user_visible_proof": "The recovery fixture reaches committed validation.",
                "immediate_product_consumer": "External-control recovery contract test.",
                "lease_expires_at": (
                    datetime.now(timezone.utc) + timedelta(hours=1)
                ).isoformat(),
                "last_output": "Old writer still marked this role active.",
            }
        )
        planned = copy.deepcopy(integrator)
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
                "last_output": "Not assigned.",
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
        return writer_id

    def test_prompt_and_bound_initialization_validate(self) -> None:
        tracked_template = (
            "skills/yefeng/assets/external-control-repo/.yefeng/local/roots.json"
        )
        self._git(REPOSITORY_ROOT, "ls-files", "--error-unmatch", tracked_template)

        for mode in ("prompt", "bound"):
            with self.subTest(mode=mode):
                product, _ = self._create_product(f"product-{mode}")
                control = self._init_control(
                    product, mode, bind_product=(mode == "bound")
                )
                completed, validation = self._validate(
                    control,
                    product,
                    f"scope-{mode}",
                    require_binding=(mode == "bound"),
                )
                self.assertEqual(completed.returncode, 0, validation["issues"])
                self.assertTrue(validation["valid"])

    def test_quoted_git_branch_is_rendered_as_valid_json(self) -> None:
        branch = 'feature/foo"bar'
        product, _ = self._create_product("product-quoted", packed_branch=branch)
        control = self._init_control(product, "quoted", branch=branch)

        for json_path in control.rglob("*.json"):
            self._read_json(json_path)
        events = [
            json.loads(line)
            for line in (
                control
                / ".yefeng"
                / "series"
                / "scope-quoted"
                / "events.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertEqual(events[0]["product_branch"], branch)
        completed, validation = self._validate(
            control, product, "scope-quoted"
        )
        self.assertEqual(completed.returncode, 0, validation["issues"])

    def test_structured_identity_values_are_not_reprocessed_as_placeholders(self) -> None:
        branch = "feature/__PRODUCT_BASELINE__"
        product, _ = self._create_product("product-token-identity", packed_branch=branch)
        control = self._init_control(product, "token-identity", branch=branch)

        control_state = self._read_json(
            control
            / ".yefeng"
            / "series"
            / "scope-token-identity"
            / "state"
            / "control.json"
        )
        self.assertEqual(
            control_state["product_baselines"]["project-token-identity"]["branch"],
            branch,
        )
        events = [
            json.loads(line)
            for line in (
                control
                / ".yefeng"
                / "series"
                / "scope-token-identity"
                / "events.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertEqual(events[0]["product_branch"], branch)
        completed, validation = self._validate(
            control, product, "scope-token-identity"
        )
        self.assertEqual(completed.returncode, 0, validation["issues"])

    def test_markdown_identity_round_trips_special_branch_characters(self) -> None:
        branch = "feature/a&b|c`d"
        product, _ = self._create_product("product-markdown", packed_branch=branch)
        control = self._init_control(product, "markdown", branch=branch)

        status = (control / "docs" / "status.md").read_text(encoding="utf-8")
        branch_line = next(
            line for line in status.splitlines() if line.startswith("- product branch：")
        )
        rendered_code = branch_line.split("：", 1)[1].strip()
        match = re.fullmatch(r"(`+)(.*)\1", rendered_code)
        self.assertIsNotNone(match, rendered_code)
        visible_code = match.group(2)
        if visible_code.startswith(" ") and visible_code.endswith(" "):
            visible_code = visible_code[1:-1]
        self.assertEqual(visible_code, branch)
        self.assertNotIn("&amp;", rendered_code)
        self.assertNotIn("&#96;", rendered_code)

        registry = (
            control
            / "docs"
            / "modules"
            / "scope-markdown"
            / "registry.md"
        ).read_text(encoding="utf-8")
        registry_row = next(line for line in registry.splitlines() if "GOV-001" in line)
        escaped_branch = registry_row.split("project-markdown / ", 1)[1].split(
            " / 无", 1
        )[0]
        visible_table = escaped_branch.replace(r"\|", "|").replace(r"\`", "`")
        self.assertEqual(visible_table, branch)
        self.assertNotIn("&amp;", registry_row)
        self.assertNotIn("&#96;", registry_row)

    def test_binding_failure_does_not_publish_or_overwrite_state(self) -> None:
        product, _ = self._create_product("product-bind-failure")
        self._git(product, "config", "--local", "yefeng.controlRepoId", "prior-control")
        self._git(product, "config", "--local", "yefeng.controlRoot", "D:/prior")
        self._git(product, "config", "--local", "yefeng.scopeId", "prior-scope")
        config_lock = product / ".git" / "config.lock"
        config_lock.write_text("blocked", encoding="utf-8")
        control = self.fixture_root / "control-bind-failure"

        completed = self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProjectName",
            "Binding failure",
            "-ProjectId",
            "project-bind-failure",
            "-ScopeId",
            "scope-bind-failure",
            "-BindProductGitConfig",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(control.exists())
        self.assertEqual(
            self._git(product, "config", "--local", "--get", "yefeng.controlRepoId"),
            "prior-control",
        )
        self.assertEqual(
            self._git(product, "config", "--local", "--get", "yefeng.controlRoot"),
            "D:/prior",
        )
        self.assertEqual(
            self._git(product, "config", "--local", "--get", "yefeng.scopeId"),
            "prior-scope",
        )

    def test_partial_binding_failure_restores_every_previous_value(self) -> None:
        product, _ = self._create_product("product-bind-rollback")
        prior_values = {
            "yefeng.controlRepoId": ["prior-control", "prior-control-alt"],
            "yefeng.controlRoot": ["D:/prior"],
            "yefeng.scopeId": ["prior-scope"],
        }
        for key, values in prior_values.items():
            for value in values:
                self._git(product, "config", "--local", "--add", key, value)

        real_git = shutil.which("git")
        assert real_git is not None
        shim_root = self.fixture_root / "git-shim"
        shim_root.mkdir()
        git_shim = shim_root / "git.cmd"
        git_shim.write_text(
            "@echo off\r\n"
            "echo %* | %SystemRoot%\\System32\\findstr.exe "
            ' /C:"config --local yefeng.scopeId" >nul\r\n'
            "if not errorlevel 1 exit /b 19\r\n"
            f'"{real_git}" %*\r\n'
            "exit /b %errorlevel%\r\n",
            encoding="utf-8",
        )
        child_env = os.environ.copy()
        child_env["PATH"] = str(shim_root) + os.pathsep + child_env["PATH"]
        control = self.fixture_root / "control-bind-rollback"

        completed = self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProjectName",
            "Binding rollback",
            "-ProjectId",
            "project-bind-rollback",
            "-ScopeId",
            "scope-bind-rollback",
            "-BindProductGitConfig",
            check=False,
            env=child_env,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(control.exists())
        for key, values in prior_values.items():
            self.assertEqual(
                self._git(product, "config", "--local", "--get-all", key).splitlines(),
                values,
            )

    def test_runtime_payloads_are_excluded_from_stable_text_validation(self) -> None:
        product, _ = self._create_product("product-runtime")
        control = self._init_control(product, "runtime")
        runtime_log = (
            control
            / ".yefeng"
            / "runs"
            / "scope-runtime"
            / "role"
            / "run"
            / "large.log"
        )
        runtime_log.parent.mkdir(parents=True)
        runtime_log.write_bytes(b"__RUNTIME_VALUE__\n" + b"x" * (2 * 1024 * 1024))
        runtime_blob = control / ".runtime" / "binary.tmp"
        runtime_blob.write_bytes(b"\x00\xff__BINARY_PLACEHOLDER__")

        completed, validation = self._validate(
            control, product, "scope-runtime"
        )
        self.assertEqual(completed.returncode, 0, validation["issues"])
        self.assertTrue(validation["valid"])

    def test_invalid_scope_id_is_rejected_before_path_derivation(self) -> None:
        product, _ = self._create_product("product-traversal")
        control = self._init_control(product, "traversal")
        topology_path = control / ".yefeng" / "control-plane.json"
        topology = self._read_json(topology_path)
        topology["active_scopes"] = ["../../outside-scope"]
        topology["shared_writer"]["scope_id"] = "../../outside-scope"
        self._write_json(topology_path, topology)
        outside_marker = self.fixture_root / "outside-scope" / "secret.txt"
        outside_marker.parent.mkdir()
        outside_marker.write_text("SHOULD_NOT_BE_READ", encoding="utf-8")

        completed, validation = self._validate(
            control, product, "scope-traversal"
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse(validation["valid"])
        self.assertTrue(
            any("Invalid active scope ID" in issue for issue in validation["issues"])
        )
        self.assertNotIn("SHOULD_NOT_BE_READ", completed.stdout + completed.stderr)

    def test_writer_fence_rejects_dirty_state_concurrency_and_head_drift(self) -> None:
        product, _ = self._create_product("product-writer")
        control = self._init_control(product, "writer")
        self._commit_control(control, "fixture: bootstrap control")
        scope_id = "scope-writer"
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        writer_id = control_state["writer_fence"]["writer_id"]
        enter = self._control_script(control, "enter-control-write.ps1")
        exit_script = self._control_script(control, "exit-control-write.ps1")

        readme = control / "README.md"
        original_readme = readme.read_bytes()
        readme.write_bytes(original_readme + b"dirty\n")
        dirty = self._ps(
            enter,
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            check=False,
        )
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn("must be clean", dirty.stderr)
        readme.write_bytes(original_readme)

        lock = self._json_output(
            self._ps(
                enter,
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
            )
        )
        duplicate = self._ps(
            enter,
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            check=False,
        )
        self.assertNotEqual(duplicate.returncode, 0)
        self._ps(
            exit_script,
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

        self._git(control, "commit", "--allow-empty", "-m", "fixture: uncoordinated head")
        drift = self._ps(
            enter,
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            check=False,
        )
        self.assertNotEqual(drift.returncode, 0)
        self.assertIn("Control HEAD drift", drift.stderr)

    def test_recovery_takeover_expires_old_epoch_and_binds_only_lock_hash(self) -> None:
        product, _ = self._create_product("product-recovery")
        control = self._init_control(product, "recovery")
        scope_id = "scope-recovery"
        secondary_product, secondary_head = self._create_product(
            "product-recovery-secondary"
        )
        secondary_repo_id = "secondary-product"
        topology_path = control / ".yefeng" / "control-plane.json"
        topology = self._read_json(topology_path)
        topology["product_repositories"].append(
            {"repo_id": secondary_repo_id, "integration_branch": "main"}
        )
        self._write_json(topology_path, topology)
        roots_path = control / ".yefeng" / "local" / "roots.json"
        roots = self._read_json(roots_path)
        roots["product_roots"][secondary_repo_id] = str(secondary_product)
        self._write_json(roots_path, roots)
        control_state_path = (
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        initial_control_state = self._read_json(control_state_path)
        initial_control_state["product_baselines"][secondary_repo_id] = {
            "branch": "main",
            "commit": secondary_head,
        }
        self._write_json(control_state_path, initial_control_state)
        writer_id = self._prepare_active_scope(control, scope_id)
        self._commit_control(control, "fixture: active old-epoch assignment")

        enter = self._control_script(control, "enter-control-write.ps1")
        recover = self._control_script(control, "recover-control-write.ps1")
        prepare = self._control_script(control, "prepare-control-writer-takeover.ps1")
        exit_script = self._control_script(control, "exit-control-write.ps1")
        initial_lock = self._json_output(
            self._ps(
                enter,
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-LeaseSeconds",
                "30",
            )
        )

        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        lock_state = self._read_json(lock_path)
        fence_state = self._read_json(fence_path)
        expired_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()

        sleeper = subprocess.Popen(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 60"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: sleeper.poll() is None and sleeper.terminate())
        time.sleep(0.2)
        process_start = self._run(
            [
                POWERSHELL,
                "-NoLogo",
                "-NoProfile",
                "-Command",
                f"(Get-Process -Id {sleeper.pid}).StartTime.ToUniversalTime().ToString('o')",
            ]
        ).stdout.strip()
        lock_state.update(
            {
                "lease_expires_at": expired_at,
                "process_id": sleeper.pid,
                "process_start_time": process_start,
            }
        )
        fence_state["lease_expires_at"] = expired_at
        self._write_json(lock_path, lock_state)
        self._write_json(fence_path, fence_state)
        live_process_recovery = self._ps(
            recover,
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-AcknowledgeExpiredLease",
            check=False,
        )
        self.assertNotEqual(live_process_recovery.returncode, 0)
        self.assertIn("still alive", live_process_recovery.stderr)
        sleeper.terminate()
        sleeper.wait(timeout=10)

        recovered = self._json_output(
            self._ps(
                recover,
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-AcknowledgeExpiredLease",
            )
        )
        self.assertTrue(recovered["recovery_required"])

        transition_lock = self._json_output(
            self._ps(
                enter,
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
        prepare_command = [
            POWERSHELL,
            "-NoLogo",
            "-NoProfile",
            "-File",
            str(prepare),
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
            "The previous writer process ended after its lease expired.",
        ]
        contenders = [
            subprocess.Popen(
                prepare_command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            for _ in range(2)
        ]
        contender_results = [contender.communicate(timeout=30) for contender in contenders]
        return_codes = [contender.returncode for contender in contenders]
        self.assertEqual(return_codes.count(0), 1, contender_results)
        successful_output = contender_results[return_codes.index(0)][0]
        prepared = json.loads(successful_output.lstrip("\ufeff").strip())

        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_state = self._read_json(state_root / "control.json")
        roles_state = self._read_json(state_root / "roles.json")
        runs_state = self._read_json(state_root / "runs.json")
        self.assertEqual(control_state["run_epoch"], 2)
        self.assertEqual(control_state["writer_fence"]["writer_id"], replacement_writer)
        roles = {role["role_id"]: role for role in roles_state["roles"]}
        self.assertEqual(roles["INTEGRATOR"]["run_epoch"], 1)
        self.assertEqual(roles["INTEGRATOR"]["state"], "EXPIRED")
        self.assertEqual(roles["INTEGRATOR"]["assignment_id"], "assign-epoch-1-integrator")
        self.assertEqual(roles["INTEGRATOR"]["lease_expires_at"], "")
        self.assertEqual(roles["WORKER"]["run_epoch"], 2)
        self.assertEqual(roles["WORKER"]["state"], "PLANNED")
        self.assertEqual(runs_state["run_epoch"], 2)
        self.assertEqual(runs_state["runs"][0]["run_epoch"], 1)
        self.assertEqual(runs_state["runs"][0]["status"], "EXPIRED")

        events = [
            json.loads(line)
            for line in (
                control / ".yefeng" / "series" / scope_id / "events.jsonl"
            ).read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        recovery_events = [event for event in events if event["type"] == "RECOVERY_STARTED"]
        self.assertEqual(len(recovery_events), 1)
        recovery_event = recovery_events[0]
        self.assertNotIn("recovery_lock_token", recovery_event)
        self.assertEqual(
            recovery_event["recovery_lock_sha256"],
            hashlib.sha256(transition_lock["lock_token"].encode("utf-8")).hexdigest(),
        )
        self.assertNotIn(transition_lock["lock_token"], json.dumps(recovery_event))
        self.assertEqual(
            set(recovery_event["product_baselines"]),
            {"project-recovery", secondary_repo_id},
        )

        self._commit_control(control, "fixture: publish writer takeover")
        released = self._json_output(
            self._ps(
                exit_script,
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
            )
        )
        self.assertTrue(released["released"])
        committed, validation = self._validate(
            control, product, scope_id, committed=True
        )
        self.assertEqual(committed.returncode, 0, validation["issues"])
        self.assertTrue(validation["valid"])

        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        original_event_text = events_path.read_text(encoding="utf-8")
        mutated_events = [
            json.loads(line) for line in original_event_text.splitlines() if line.strip()
        ]
        mutated_recovery = next(
            event for event in mutated_events if event["type"] == "RECOVERY_STARTED"
        )
        mutated_recovery["product_baselines"].pop(secondary_repo_id)
        events_path.write_text(
            "\n".join(
                json.dumps(event, ensure_ascii=False) for event in mutated_events
            )
            + "\n",
            encoding="utf-8",
        )
        missing_event_result, missing_event_validation = self._validate(
            control, product, scope_id
        )
        self.assertNotEqual(missing_event_result.returncode, 0)
        self.assertTrue(
            any(
                "baseline" in issue.lower() and "set" in issue.lower()
                for issue in missing_event_validation["issues"]
            ),
            missing_event_validation["issues"],
        )
        events_path.write_text(original_event_text, encoding="utf-8")

        mutated_events = [
            json.loads(line) for line in original_event_text.splitlines() if line.strip()
        ]
        mutated_recovery = next(
            event for event in mutated_events if event["type"] == "RECOVERY_STARTED"
        )
        mutated_recovery["product_baselines"]["unexpected-product"] = {
            "branch": "main",
            "commit": secondary_head,
        }
        events_path.write_text(
            "\n".join(
                json.dumps(event, ensure_ascii=False) for event in mutated_events
            )
            + "\n",
            encoding="utf-8",
        )
        extra_event_result, extra_event_validation = self._validate(
            control, product, scope_id
        )
        self.assertNotEqual(extra_event_result.returncode, 0)
        self.assertTrue(
            any(
                "baseline" in issue.lower() and "set" in issue.lower()
                for issue in extra_event_validation["issues"]
            ),
            extra_event_validation["issues"],
        )
        events_path.write_text(original_event_text, encoding="utf-8")

        original_roles = copy.deepcopy(roles_state)
        roles_state["roles"][0]["state"] = "RUNNING"
        self._write_json(state_root / "roles.json", roles_state)
        stale_role_result, stale_role_validation = self._validate(
            control, product, scope_id
        )
        self.assertNotEqual(stale_role_result.returncode, 0)
        self.assertTrue(
            any("Stale role" in issue for issue in stale_role_validation["issues"])
        )
        self._write_json(state_root / "roles.json", original_roles)

        runs_state["runs"][0]["status"] = "RUNNING"
        self._write_json(state_root / "runs.json", runs_state)
        stale_run_result, stale_run_validation = self._validate(
            control, product, scope_id
        )
        self.assertNotEqual(stale_run_result.returncode, 0)
        self.assertTrue(
            any("Stale run" in issue for issue in stale_run_validation["issues"])
        )
        self.assertEqual(prepared["replacement_run_epoch"], 2)
        self.assertEqual(initial_lock["run_epoch"], 1)

    @unittest.skipUnless(
        WINDOWS_POWERSHELL is not None, "Windows PowerShell 5.1 is not available"
    )
    def test_windows_powershell_51_preserves_unicode_paths_and_branch(self) -> None:
        unicode_root = self.fixture_root / "中文目录"
        product = unicode_root / "产品仓"
        product.mkdir(parents=True)
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Test")
        self._git(product, "config", "user.email", "yefeng-test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "fixture: unicode")
        head = self._git(product, "rev-parse", "HEAD")
        branch = "功能/中文"
        (product / ".git" / "packed-refs").write_bytes(
            (
                "# pack-refs with: peeled fully-peeled sorted\n"
                f"{head} refs/heads/{branch}\n"
            ).encode("utf-8")
        )
        control = unicode_root / "控制仓"
        result = self._json_output(
            self._ps(
                SOURCE_SCRIPTS / "init-external-control-repo.ps1",
                "-ControlRoot",
                str(control),
                "-ProductRoot",
                str(product),
                "-ProductBranch",
                branch,
                "-ProjectName",
                "野蜂中文验证",
                "-ProjectId",
                "project-unicode",
                "-ScopeId",
                "scope-unicode",
                engine=WINDOWS_POWERSHELL,
            )
        )
        self.assertEqual(result["product_branch"], branch)
        completed, validation = self._validate(
            control,
            product,
            "scope-unicode",
            engine=WINDOWS_POWERSHELL,
        )
        self.assertEqual(completed.returncode, 0, validation["issues"])
        self.assertTrue(validation["valid"])

    @unittest.skipUnless(
        WINDOWS_POWERSHELL is not None, "Windows PowerShell 5.1 is not available"
    )
    def test_writer_helpers_support_windows_powershell_51(self) -> None:
        assert WINDOWS_POWERSHELL is not None
        product, _ = self._create_product("product-ps51")
        control = self._init_control(
            product, "ps51", engine=WINDOWS_POWERSHELL
        )
        self._commit_control(control, "fixture: bootstrap under Windows PowerShell")
        scope_id = "scope-ps51"
        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        writer_id = control_state["writer_fence"]["writer_id"]
        lock = self._json_output(
            self._ps(
                self._control_script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                engine=WINDOWS_POWERSHELL,
            )
        )
        lock_path = control / ".yefeng" / "local" / "locks" / "control-repo.write.lock"
        fence_path = (
            control / ".yefeng" / "local" / "writer-fences" / f"{scope_id}.json"
        )
        lock_state = self._read_json(lock_path)
        fence_state = self._read_json(fence_path)
        expired_at = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        lock_state.update(
            {
                "lease_expires_at": expired_at,
                "process_id": 999999,
                "process_start_time": (
                    datetime.now(timezone.utc) - timedelta(days=1)
                ).isoformat(),
            }
        )
        fence_state["lease_expires_at"] = expired_at
        self._write_json(lock_path, lock_state)
        self._write_json(fence_path, fence_state)
        recovered = self._json_output(
            self._ps(
                self._control_script(control, "recover-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-AcknowledgeExpiredLease",
                engine=WINDOWS_POWERSHELL,
            )
        )
        self.assertTrue(recovered["recovery_required"])
        transition_lock = self._json_output(
            self._ps(
                self._control_script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-RecoveryTransition",
                engine=WINDOWS_POWERSHELL,
            )
        )
        replacement_writer = "ps51-replacement"
        self._ps(
            self._control_script(control, "prepare-control-writer-takeover.ps1"),
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
            "Validate Windows PowerShell recovery transition.",
            engine=WINDOWS_POWERSHELL,
        )
        self._commit_control(control, "fixture: PowerShell 5.1 takeover")
        released = self._json_output(
            self._ps(
                self._control_script(control, "exit-control-write.ps1"),
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
                engine=WINDOWS_POWERSHELL,
            )
        )
        self.assertTrue(released["released"])
        completed, validation = self._validate(
            control,
            product,
            scope_id,
            committed=True,
            engine=WINDOWS_POWERSHELL,
        )
        self.assertEqual(completed.returncode, 0, validation["issues"])


if __name__ == "__main__":
    unittest.main()
