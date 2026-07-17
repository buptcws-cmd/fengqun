from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_SCRIPTS = REPOSITORY_ROOT / "skills" / "yefeng" / "scripts"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


class PrepareLifecycleHardeningTests(unittest.TestCase):
    """Exercise prepare and lifecycle guards through real PowerShell processes."""

    @classmethod
    def setUpClass(cls) -> None:
        if POWERSHELL is None:
            raise RuntimeError("pwsh or powershell is required")

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="yefeng-prepare-hardening-", ignore_cleanup_errors=True
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

    def _git(self, root: Path, *arguments: str) -> str:
        return self._run(["git", *arguments], cwd=root).stdout.strip()

    def _ps(
        self, script: Path, *arguments: str, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        assert POWERSHELL is not None
        return self._run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-File", str(script), *arguments],
            check=check,
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

    def _script(self, control: Path, name: str) -> Path:
        return control / "scripts" / "yefeng" / name

    def _create_bootstrapped_control(self, name: str) -> tuple[Path, str, str]:
        product = self.fixture_root / f"product-{name}"
        product.mkdir()
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Hardening Test")
        self._git(product, "config", "user.email", "test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "product baseline")

        control = self.fixture_root / f"control-{name}"
        scope_id = f"scope-{name}"
        initialized = self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProductBranch",
            "main",
            "-ProjectName",
            f"Lifecycle hardening {name}",
            "-ProjectId",
            f"project-{name}",
            "-ScopeId",
            scope_id,
            "-ModuleGoal",
            "Verify strict prepare and lifecycle failure boundaries.",
        )
        self._json_output(initialized)

        self._git(control, "config", "user.name", "Yefeng Hardening Test")
        self._git(control, "config", "user.email", "test@example.invalid")
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "bootstrap control")

        control_state = self._read_json(
            control / ".yefeng" / "series" / scope_id / "state" / "control.json"
        )
        writer_id = str(control_state["writer_fence"]["writer_id"])

        bootstrap_lock = self._enter(control, scope_id, writer_id)
        released = self._json_output(
            self._ps(
                self._script(control, "exit-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                "-LockToken",
                str(bootstrap_lock["lock_token"]),
                "-ExpectedControlHead",
                str(bootstrap_lock["expected_control_head"]),
            )
        )
        self.assertTrue(released["released"])
        self.assertEqual(self._git(control, "status", "--short"), "")
        return control, scope_id, writer_id

    def _enter(
        self, control: Path, scope_id: str, writer_id: str, *extra: str
    ) -> dict[str, Any]:
        return self._json_output(
            self._ps(
                self._script(control, "enter-control-write.ps1"),
                "-ControlRoot",
                str(control),
                "-ScopeId",
                scope_id,
                "-WriterId",
                writer_id,
                *extra,
            )
        )

    def _arm_recovery_transition(
        self, control: Path, scope_id: str, writer_id: str
    ) -> dict[str, Any]:
        fence_path = (
            control
            / ".yefeng"
            / "local"
            / "writer-fences"
            / f"{scope_id}.json"
        )
        fence = self._read_json(fence_path)
        fence["recovery_required"] = True
        self._write_json(fence_path, fence)
        return self._enter(control, scope_id, writer_id, "-RecoveryTransition")

    def _set_authoritative_lock_token(
        self, control: Path, scope_id: str, lock_token: str
    ) -> dict[str, Any]:
        lock_path = (
            control
            / ".yefeng"
            / "local"
            / "locks"
            / "control-repo.write.lock"
        )
        fence_path = (
            control
            / ".yefeng"
            / "local"
            / "writer-fences"
            / f"{scope_id}.json"
        )
        lock = self._read_json(lock_path)
        fence = self._read_json(fence_path)
        lock["lock_token"] = lock_token
        fence["lock_token"] = lock_token
        self._write_json(lock_path, lock)
        self._write_json(fence_path, fence)
        return lock

    def _prepare(
        self,
        control: Path,
        scope_id: str,
        writer_id: str,
        lock_token: str,
        reason: str,
    ) -> subprocess.CompletedProcess[str]:
        return self._ps(
            self._script(control, "prepare-control-writer-takeover.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-CurrentWriterId",
            writer_id,
            "-ReplacementWriterId",
            "replacement-writer",
            "-LockToken",
            lock_token,
            "-Reason",
            reason,
            check=False,
        )

    def _stable_snapshot(self, control: Path, scope_id: str) -> dict[str, bytes]:
        scope_root = control / ".yefeng" / "series" / scope_id
        paths = (
            scope_root / "state" / "control.json",
            scope_root / "state" / "roles.json",
            scope_root / "state" / "runs.json",
            scope_root / "state" / "transport.json",
            scope_root / "events.jsonl",
        )
        return {
            path.relative_to(control).as_posix(): path.read_bytes() for path in paths
        }

    def _assert_stable_snapshot(
        self, control: Path, scope_id: str, expected: dict[str, bytes]
    ) -> None:
        actual = self._stable_snapshot(control, scope_id)
        self.assertEqual(actual.keys(), expected.keys())
        for relative_path, expected_bytes in expected.items():
            with self.subTest(path=relative_path):
                self.assertEqual(actual[relative_path], expected_bytes)
        self.assertEqual(self._git(control, "status", "--short"), "")

    def test_prepare_rejects_string_recovery_transition_without_stable_writes(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "lock-boolean"
        )
        lock = self._arm_recovery_transition(control, scope_id, writer_id)
        expected = self._stable_snapshot(control, scope_id)

        lock_path = (
            control
            / ".yefeng"
            / "local"
            / "locks"
            / "control-repo.write.lock"
        )
        malformed_lock = self._read_json(lock_path)
        malformed_lock["recovery_transition"] = "true"
        self._write_json(lock_path, malformed_lock)

        completed = self._prepare(
            control,
            scope_id,
            writer_id,
            str(lock["lock_token"]),
            "Reject a string writer-lock Boolean.",
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "Writer lock recovery_transition must be a native Boolean.",
            completed.stdout + completed.stderr,
        )
        self._assert_stable_snapshot(control, scope_id, expected)

    def test_prepare_rejects_string_recovery_required_without_stable_writes(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "fence-boolean"
        )
        lock = self._arm_recovery_transition(control, scope_id, writer_id)
        expected = self._stable_snapshot(control, scope_id)

        fence_path = (
            control
            / ".yefeng"
            / "local"
            / "writer-fences"
            / f"{scope_id}.json"
        )
        malformed_fence = self._read_json(fence_path)
        malformed_fence["recovery_required"] = "true"
        self._write_json(fence_path, malformed_fence)

        completed = self._prepare(
            control,
            scope_id,
            writer_id,
            str(lock["lock_token"]),
            "Reject a string local-fence Boolean.",
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "Local writer fence recovery_required must be a native Boolean.",
            completed.stdout + completed.stderr,
        )
        self._assert_stable_snapshot(control, scope_id, expected)

    def test_prepare_rejects_reason_over_utf8_limit_without_stable_writes(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "reason-limit"
        )
        lock = self._arm_recovery_transition(control, scope_id, writer_id)
        expected = self._stable_snapshot(control, scope_id)
        oversized_reason = "界" * 10_923
        self.assertGreater(len(oversized_reason.encode("utf-8")), 32_768)

        completed = self._prepare(
            control,
            scope_id,
            writer_id,
            str(lock["lock_token"]),
            oversized_reason,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "Recovery reason exceeds the 32768-byte UTF-8 limit.",
            completed.stdout + completed.stderr,
        )
        self._assert_stable_snapshot(control, scope_id, expected)

    def test_prepare_rejects_lock_token_in_reason_case_insensitively_without_stable_writes(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "reason-token"
        )
        self._arm_recovery_transition(control, scope_id, writer_id)
        authoritative_token = "aBcDeF0123456789aBcDeF0123456789"
        lock = self._set_authoritative_lock_token(
            control, scope_id, authoritative_token
        )
        expected = self._stable_snapshot(control, scope_id)

        for reason in (authoritative_token, authoritative_token.swapcase()):
            with self.subTest(reason=reason):
                completed = self._prepare(
                    control,
                    scope_id,
                    writer_id,
                    str(lock["lock_token"]),
                    reason,
                )

                self.assertNotEqual(completed.returncode, 0)
                self.assertIn(
                    "RECOVERY_STARTED event must not contain the raw writer lock token.",
                    completed.stdout + completed.stderr,
                )
                self._assert_stable_snapshot(control, scope_id, expected)

    def test_prepare_requires_case_sensitive_authoritative_lock_token_without_stable_writes(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "token-identity"
        )
        self._arm_recovery_transition(control, scope_id, writer_id)
        authoritative_token = "aBcDeF0123456789aBcDeF0123456789"
        self._set_authoritative_lock_token(control, scope_id, authoritative_token)
        expected = self._stable_snapshot(control, scope_id)

        completed = self._prepare(
            control,
            scope_id,
            writer_id,
            authoritative_token.swapcase(),
            "Verify case-sensitive writer-lock identity.",
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "Recovery transition lock token/lease mismatch.",
            completed.stdout + completed.stderr,
        )
        self._assert_stable_snapshot(control, scope_id, expected)

    def test_exit_rejects_committed_recovery_event_payload_containing_lock_token(
        self,
    ) -> None:
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "exit-token-payload"
        )
        self._arm_recovery_transition(control, scope_id, writer_id)
        authoritative_token = "aBcDeF0123456789aBcDeF0123456789"
        lock = self._set_authoritative_lock_token(
            control, scope_id, authoritative_token
        )
        prepared = self._prepare(
            control,
            scope_id,
            writer_id,
            authoritative_token,
            "Prepare a recovery event that will be tampered before commit.",
        )
        self.assertEqual(
            prepared.returncode,
            0,
            msg=f"stdout: {prepared.stdout}\nstderr: {prepared.stderr}",
        )

        events_path = control / ".yefeng" / "series" / scope_id / "events.jsonl"
        events = [
            json.loads(line)
            for line in events_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertEqual(events[-1]["type"], "RECOVERY_STARTED")
        events[-1]["payload"] = authoritative_token.swapcase()
        events_path.write_text(
            "".join(
                json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
                for event in events
            ),
            encoding="utf-8",
        )
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "inject raw lock token into recovery event")

        lock_path = (
            control
            / ".yefeng"
            / "local"
            / "locks"
            / "control-repo.write.lock"
        )
        fence_path = (
            control
            / ".yefeng"
            / "local"
            / "writer-fences"
            / f"{scope_id}.json"
        )
        control_head_path = control / ".yefeng" / "local" / "control-head.json"
        local_snapshot = {
            path: path.read_bytes() for path in (lock_path, fence_path, control_head_path)
        }

        completed = self._ps(
            self._script(control, "exit-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            "-LockToken",
            str(lock["lock_token"]),
            "-ExpectedControlHead",
            str(lock["expected_control_head"]),
            "-ReplacementWriterId",
            "replacement-writer",
            "-ReplacementRunEpoch",
            "2",
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "RECOVERY_STARTED event must not contain the raw writer lock token.",
            completed.stdout + completed.stderr,
        )
        for path, expected_bytes in local_snapshot.items():
            with self.subTest(path=path):
                self.assertTrue(path.is_file())
                self.assertEqual(path.read_bytes(), expected_bytes)
        self.assertEqual(self._git(control, "status", "--short"), "")

    def test_enter_respects_exclusive_lifecycle_guard_then_succeeds_after_release(
        self,
    ) -> None:
        assert POWERSHELL is not None
        control, scope_id, writer_id = self._create_bootstrapped_control(
            "lifecycle-guard"
        )
        guard_path = (
            control
            / ".yefeng"
            / "local"
            / "locks"
            / "control-repo.lifecycle.guard"
        )
        self.assertTrue(guard_path.is_file())
        writer_lock_path = guard_path.with_name("control-repo.write.lock")
        self.assertFalse(writer_lock_path.exists())

        holder_environment = os.environ.copy()
        holder_environment["YEFENG_TEST_GUARD_PATH"] = str(guard_path)
        holder_script = """
$ErrorActionPreference = 'Stop'
$stream = [System.IO.File]::Open(
  $env:YEFENG_TEST_GUARD_PATH,
  [System.IO.FileMode]::OpenOrCreate,
  [System.IO.FileAccess]::ReadWrite,
  [System.IO.FileShare]::None
)
try {
  [Console]::Out.WriteLine('READY')
  [Console]::Out.Flush()
  $null = [Console]::In.ReadLine()
} finally {
  $stream.Dispose()
}
"""
        holder = subprocess.Popen(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-Command", holder_script],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=holder_environment,
        )
        self.addCleanup(self._stop_guard_holder, holder)
        assert holder.stdout is not None
        ready = holder.stdout.readline().strip()
        if ready != "READY":
            stdout, stderr = holder.communicate(timeout=10)
            self.fail(
                f"guard holder did not become ready: {ready!r}\n"
                f"stdout: {stdout}\nstderr: {stderr}"
            )

        blocked = self._ps(
            self._script(control, "enter-control-write.ps1"),
            "-ControlRoot",
            str(control),
            "-ScopeId",
            scope_id,
            "-WriterId",
            writer_id,
            check=False,
        )
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn(
            "Another control lock lifecycle operation is already in progress.",
            blocked.stdout + blocked.stderr,
        )
        self.assertFalse(writer_lock_path.exists())

        assert holder.stdin is not None
        holder.stdin.write("\n")
        holder.stdin.flush()
        holder.wait(timeout=10)
        self.assertEqual(holder.returncode, 0)

        lock = self._enter(control, scope_id, writer_id)
        self.assertEqual(lock["scope_id"], scope_id)
        self.assertEqual(lock["writer_id"], writer_id)
        self.assertTrue(writer_lock_path.is_file())

    def _stop_guard_holder(self, holder: subprocess.Popen[str]) -> None:
        try:
            if holder.poll() is None:
                try:
                    if holder.stdin is not None:
                        holder.stdin.write("\n")
                        holder.stdin.flush()
                    holder.wait(timeout=5)
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    holder.terminate()
                    try:
                        holder.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        holder.kill()
                        holder.wait(timeout=5)
        finally:
            for stream in (holder.stdin, holder.stdout, holder.stderr):
                if stream is not None and not stream.closed:
                    stream.close()


if __name__ == "__main__":
    unittest.main()
