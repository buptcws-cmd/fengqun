#!/usr/bin/env python3
"""Create and compare secret-safe Git workspace transfer manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable
from urllib.parse import urlsplit, urlunsplit


FORMAT = "cross-machine-project-handoff-manifest"
FORMAT_VERSION = "1.0"
COMPARISON_PROFILE = "git-transferable-state-v1"
TOOL_VERSION = "1.1.0"
HANDOFF_FORMAT = "cross-machine-project-handoff-receipt"
HANDOFF_VERSION = "1.0"
RESTORE_FORMAT = "cross-machine-project-handoff-restore"
VALIDATION_STATUSES = {
    "passed",
    "failed",
    "timed_out",
    "skipped",
    "inconclusive",
}
TEXT_SCAN_LIMIT = 1_000_000
DEFAULT_LARGE_FILE_BYTES = 100 * 1024 * 1024

SENSITIVE_EXACT_PATHS = {
    ".claude/settings.local.json",
    ".mcp.json",
    ".vscode/settings.local.json",
}
SENSITIVE_BASENAMES = {
    ".envrc",
    ".git-credentials",
    ".netrc",
    ".npmrc",
    ".pypirc",
    "credentials.json",
    "id_ed25519",
    "id_rsa",
    "secret.json",
    "secrets.json",
    "service-account.json",
    "service_account.json",
}
SENSITIVE_SUFFIXES = {
    ".jks",
    ".key",
    ".keystore",
    ".mobileprovision",
    ".p12",
    ".pem",
    ".pfx",
}
SAFE_ENV_SUFFIXES = (".example", ".sample", ".template")
REBUILDABLE_PATHS = (
    ".dart_tool",
    ".gradle",
    ".next",
    ".venv",
    "Pods",
    "build",
    "dist",
    "node_modules",
    "target",
    "venv",
)
DEPENDENCY_FILENAMES = {
    "Cargo.lock",
    "Gemfile.lock",
    "Package.resolved",
    "Pipfile.lock",
    "Podfile.lock",
    "bun.lock",
    "bun.lockb",
    "composer.lock",
    "deno.lock",
    "go.sum",
    "package-lock.json",
    "pnpm-lock.yaml",
    "poetry.lock",
    "pubspec.lock",
    "uv.lock",
    "yarn.lock",
}
TRACKED_SENSITIVE_DATA_SUFFIXES = {
    ".7z",
    ".csv",
    ".db",
    ".doc",
    ".docm",
    ".docx",
    ".gz",
    ".jpeg",
    ".jpg",
    ".pdf",
    ".png",
    ".ppt",
    ".pptx",
    ".sqlite",
    ".sqlite3",
    ".tar",
    ".xls",
    ".xlsx",
    ".zip",
}
SKIP_DIRS = {".git", *REBUILDABLE_PATHS, "__pycache__", ".pytest_cache"}
STATUS_NAMES = {
    "M": "modified",
    "A": "added",
    "D": "deleted",
    "R": "renamed",
    "C": "copied",
    "T": "type-changed",
    "U": "unmerged",
}
UNMERGED_STATUS_CODES = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
HEX_RE = re.compile(r"^[0-9a-f]+$")
ABSOLUTE_PATH_PATTERNS = (
    ("posix-user-home", re.compile(r"/(?:Users|home)/[^/\s\"']+/[^\s\"'<>]*")),
    ("homebrew-prefix", re.compile(r"/opt/homebrew(?:/[^\s\"'<>]*)?")),
    ("windows-drive", re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s\"'<>]*")),
    ("windows-unc", re.compile(r"\\\\[^\\\s]+\\[^\s\"'<>]*")),
)


def _run(
    args: list[str], cwd: Path, *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"Command failed ({' '.join(args)}): {message}")
    return completed


def _git(
    root: Path, *args: str, check: bool = True, strip: bool = True
) -> str:
    output = _run(["git", *args], root, check=check).stdout
    return output.strip() if strip else output


def _repository_root(workspace: Path) -> Path:
    completed = _run(
        ["git", "rev-parse", "--show-toplevel"], workspace, check=False
    )
    if completed.returncode != 0:
        raise ValueError(f"Not a Git working tree: {workspace}")
    return Path(completed.stdout.strip()).resolve()


def _normalize_path(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value.replace("\\", "/"))
    path = PurePosixPath(normalized)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"Non-portable repository path: {value}")
    return path.as_posix()


def _to_relative(root: Path, path: Path) -> str:
    return _normalize_path(path.relative_to(root).as_posix())


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_file(path: str | Path) -> str:
    """Return a file digest for receipts without exposing file contents."""
    return _sha256(Path(path))


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sanitize_remote_url(value: str) -> str:
    """Return a diagnostic endpoint without ever echoing an opaque address."""
    value = value.strip()
    helper = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*)::", value)
    if helper:
        return f"remote-helper://{helper.group(1).lower()}/<redacted>"
    if value.lower().startswith("file://") or re.match(r"^[A-Za-z]:[\\/]", value):
        return "local-path://<redacted>"
    if value.startswith(("/", "\\\\", "./", "../", ".\\", "..\\")):
        return "local-path://<redacted>"
    if "://" in value:
        parsed = urlsplit(value)
        scheme = parsed.scheme.lower()
        hostname = parsed.hostname
        if not scheme or not hostname:
            return "opaque-remote://<redacted>"
        try:
            port = parsed.port
        except ValueError:
            return f"{scheme}://<redacted>"
        if ":" in hostname and not hostname.startswith("["):
            hostname = f"[{hostname}]"
        if port:
            hostname = f"{hostname}:{port}"
        return urlunsplit((scheme, hostname, "/<redacted>", "", ""))
    if value.count("@") > 1:
        return "opaque-remote://<redacted>"
    scp = re.match(
        r"^(?:[^@\s:]+@)?([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?):",
        value,
    )
    if scp:
        return f"ssh://{scp.group(1)}/<redacted>"
    return "opaque-remote://<redacted>"


def _prepare_sensitive_paths(values: Iterable[str]) -> frozenset[str]:
    prepared = set()
    for value in values:
        path = _normalize_path(value)
        if PurePosixPath(path).parts[0] == ".git":
            raise ValueError("Sensitive declarations cannot target Git internals")
        prepared.add(path)
    return frozenset(prepared)


def _prepare_sensitive_globs(values: Iterable[str]) -> tuple[str, ...]:
    patterns = []
    for value in values:
        pattern = unicodedata.normalize("NFC", value.replace("\\", "/"))
        if (
            not pattern
            or pattern.startswith("/")
            or re.match(r"^[A-Za-z]:/", pattern)
            or any(part in {"", ".", ".."} for part in pattern.split("/"))
            or pattern.split("/", 1)[0] == ".git"
        ):
            raise ValueError(f"Non-portable sensitive glob: {value}")
        patterns.append(pattern)
    return tuple(sorted(set(patterns)))


def _is_sensitive(
    relative: str,
    custom_paths: frozenset[str] = frozenset(),
    custom_globs: tuple[str, ...] = (),
) -> bool:
    relative = relative.replace("\\", "/")
    name = PurePosixPath(relative).name
    lower_name = name.lower()
    if any(
        relative == path or relative.startswith(f"{path}/")
        for path in custom_paths
    ) or any(
        PurePosixPath(relative).match(pattern) for pattern in custom_globs
    ):
        return True
    if relative.lower() in SENSITIVE_EXACT_PATHS:
        return True
    if relative.lower().endswith("/.aws/credentials") or relative.lower() == ".aws/credentials":
        return True
    if lower_name == ".env" or (
        lower_name.startswith(".env.") and not lower_name.endswith(SAFE_ENV_SUFFIXES)
    ):
        return True
    if lower_name in SENSITIVE_BASENAMES:
        return True
    return PurePosixPath(lower_name).suffix in SENSITIVE_SUFFIXES


def _walk_project_files(root: Path) -> Iterable[Path]:
    for current_root, dirs, files in os.walk(root):
        dirs[:] = sorted(directory for directory in dirs if directory not in SKIP_DIRS)
        for filename in sorted(files):
            yield Path(current_root) / filename


def _sensitive_paths(
    root: Path,
    is_sensitive: Callable[[str], bool],
    custom_paths: frozenset[str],
    custom_globs: tuple[str, ...],
) -> tuple[list[dict[str, Any]], list[str], list[dict[str, str]]]:
    candidates: dict[str, Path] = {}
    missing_declarations = set()
    limitations: list[dict[str, str]] = []

    def add_candidate(path: Path) -> bool:
        try:
            raw_relative = path.relative_to(root).as_posix()
        except ValueError:
            limitations.append({"code": "sensitive-declaration-outside-workspace"})
            return False
        if ".git" in PurePosixPath(raw_relative).parts:
            limitations.append({"code": "sensitive-declaration-git-internals-skipped"})
            return False
        candidates[raw_relative] = path
        return True

    def add_tree(path: Path) -> None:
        if not add_candidate(path):
            return
        if not path.is_dir() or path.is_symlink():
            return

        def on_error(_: OSError) -> None:
            limitations.append({"code": "sensitive-declaration-unreadable"})

        for current_root, dirs, files in os.walk(path, onerror=on_error):
            current = Path(current_root)
            if ".git" in dirs:
                dirs.remove(".git")
                limitations.append(
                    {"code": "sensitive-declaration-git-internals-skipped"}
                )
            for directory in dirs:
                add_candidate(current / directory)
            for filename in files:
                add_candidate(current / filename)

    for path in _walk_project_files(root):
        raw_relative = path.relative_to(root).as_posix()
        relative = _normalize_path(raw_relative)
        if is_sensitive(relative):
            add_candidate(path)

    for relative in sorted(custom_paths):
        path = root / relative
        if path.exists() or path.is_symlink():
            add_tree(path)
        else:
            missing_declarations.add(relative)

    for pattern in custom_globs:
        try:
            matches = list(root.glob(pattern))
        except OSError:
            limitations.append({"code": "sensitive-glob-unreadable"})
            continue
        for path in matches:
            add_tree(path)

    records_by_path: dict[str, dict[str, Any]] = {
        relative: {"path": relative, "exists": False, "ignored": None}
        for relative in missing_declarations
    }
    for raw_relative, path in sorted(candidates.items()):
        relative = _normalize_path(raw_relative)
        ignored = (
            _run(
                ["git", "check-ignore", "-q", "--", raw_relative], root, check=False
            ).returncode
            == 0
        )
        records_by_path[relative] = {
            "path": relative,
            "exists": True,
            "ignored": ignored,
        }
    return (
        sorted(records_by_path.values(), key=lambda item: item["path"]),
        sorted(candidates),
        limitations,
    )


def _status_entries(root: Path) -> list[dict[str, str]]:
    raw = _git(
        root,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        strip=False,
    )
    parts = raw.split("\0")
    records = []
    index = 0
    while index < len(parts):
        entry = parts[index]
        if not entry:
            index += 1
            continue
        code = entry[:2]
        record = {"index_code": code[0], "working_code": code[1]}
        record["raw_path"] = entry[3:].replace("\\", "/")
        record["path"] = _normalize_path(record["raw_path"])
        if code[0] in {"R", "C"} and index + 1 < len(parts):
            index += 1
            record["raw_from_path"] = parts[index].replace("\\", "/")
            record["from_path"] = _normalize_path(record["raw_from_path"])
        records.append(record)
        index += 1
    return records


def _index_record(root: Path, path: str, state: str) -> dict[str, str]:
    record = {"state": state}
    output = _git(root, "ls-files", "--stage", "-z", "--", path, strip=False)
    for entry in filter(None, output.split("\0")):
        metadata, _, _ = entry.partition("\t")
        parts = metadata.split()
        if len(parts) == 3 and parts[2] == "0":
            record.update({"mode": parts[0], "oid": parts[1]})
            break
    return record


def _working_record(root: Path, path: str, state: str) -> tuple[dict[str, Any], str]:
    full_path = root / path
    record = {"state": state}
    if full_path.is_symlink():
        kind = "symlink"
        record["sha256"] = _sha256_bytes(os.fsencode(os.readlink(full_path)))
    elif full_path.is_file():
        kind = "file"
        record["sha256"] = _sha256(full_path)
        record["executable"] = bool(full_path.stat().st_mode & 0o111)
    elif not full_path.exists():
        kind = "missing"
    else:
        kind = "special"
    return record, kind


def _worktree_state(
    root: Path,
    entries: Iterable[dict[str, str]],
    is_sensitive: Callable[[str], bool],
    index_flags: Iterable[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    records = []
    limitations = []
    for entry in entries:
        path = entry["path"]
        io_path = entry["raw_path"]
        if is_sensitive(path) or is_sensitive(entry.get("from_path", path)):
            continue
        index_code = entry["index_code"]
        working_code = entry["working_code"]
        if f"{index_code}{working_code}" in UNMERGED_STATUS_CODES:
            limitations.append({"code": "unmerged-index-not-audited", "path": path})
        record: dict[str, Any] = {"path": path}
        if "from_path" in entry:
            record["from_path"] = entry["from_path"]
        kind = "missing"
        try:
            if index_code == "?" and working_code == "?":
                working, kind = _working_record(root, io_path, "untracked")
                record["working"] = working
                if kind == "missing":
                    limitations.append(
                        {"code": "dirty-path-vanished-during-audit", "path": path}
                    )
            else:
                if index_code not in {" ", "?"}:
                    record["index"] = _index_record(
                        root, io_path, STATUS_NAMES.get(index_code, "unknown")
                    )
                    if record["index"].get("mode") == "160000":
                        limitations.append(
                            {"code": "dirty-submodule-not-audited", "path": path}
                        )
                if working_code not in {" ", "?"}:
                    working, kind = _working_record(
                        root, io_path, STATUS_NAMES.get(working_code, "unknown")
                    )
                    record["working"] = working
                    if kind == "missing" and working_code != "D":
                        limitations.append(
                            {"code": "dirty-path-vanished-during-audit", "path": path}
                        )
                elif (root / io_path).is_symlink():
                    kind = "symlink"
                elif (root / io_path).is_file():
                    kind = "file"
                elif (root / io_path).is_dir():
                    kind = "special"
                if kind == "special":
                    limitations.append(
                        {"code": "special-dirty-path-not-audited", "path": path}
                    )
        except OSError:
            limitations.append({"code": "dirty-path-unreadable", "path": path})
        record["kind"] = kind
        records.append(record)
    recorded_paths = {item["path"] for item in records}
    for flag in index_flags:
        path = flag["path"]
        io_path = flag["raw_path"]
        if path in recorded_paths:
            continue
        if is_sensitive(path):
            limitations.append({"code": "sensitive-index-flags-not-audited"})
            continue
        try:
            working, kind = _working_record(root, io_path, "index-hidden")
            record = {
                "path": path,
                "kind": kind,
                "index": _index_record(root, io_path, "index-hidden"),
                "working": working,
            }
            if kind == "special":
                limitations.append(
                    {"code": "special-dirty-path-not-audited", "path": path}
                )
            records.append(record)
        except OSError:
            limitations.append({"code": "dirty-path-unreadable", "path": path})
    return sorted(records, key=lambda item: item["path"]), limitations


def _refs(root: Path, namespace: str) -> list[dict[str, str]]:
    output = _git(
        root,
        "for-each-ref",
        "--format=%(refname)%00%(objectname)",
        namespace,
    )
    records = []
    for line in output.splitlines():
        parts = line.split("\0")
        if len(parts) == 2:
            records.append({"name": parts[0], "oid": parts[1]})
    return sorted(records, key=lambda item: item["name"])


def _stashes(root: Path) -> list[dict[str, Any]]:
    output = _git(root, "stash", "list", "--format=%H")
    return [
        {"position": position, "oid": oid}
        for position, oid in enumerate(filter(None, output.splitlines()))
    ]


def _other_refs(root: Path) -> list[dict[str, str]]:
    excluded_prefixes = ("refs/heads/", "refs/tags/", "refs/remotes/")
    return [
        item
        for item in _refs(root, "refs")
        if item["name"] != "refs/stash"
        and not item["name"].startswith(excluded_prefixes)
    ]


def _index_flags(root: Path) -> list[dict[str, Any]]:
    raw = _git(root, "ls-files", "-v", "-z", strip=False)
    records = []
    for entry in filter(None, raw.split("\0")):
        if len(entry) < 3 or entry[1] != " ":
            continue
        tag = entry[0]
        assume_unchanged = tag.islower()
        skip_worktree = tag.upper() == "S"
        if assume_unchanged or skip_worktree:
            raw_path = entry[2:].replace("\\", "/")
            records.append(
                {
                    "raw_path": raw_path,
                    "path": _normalize_path(raw_path),
                    "assume_unchanged": assume_unchanged,
                    "skip_worktree": skip_worktree,
                }
            )
    return sorted(records, key=lambda item: item["path"])


def _remotes(root: Path) -> list[dict[str, str]]:
    return [
        {
            "name": name,
            "url": sanitize_remote_url(_git(root, "remote", "get-url", name)),
        }
        for name in filter(None, _git(root, "remote").splitlines())
    ]


def _ignored_nonrebuildable_paths(
    root: Path, is_sensitive: Callable[[str], bool]
) -> list[dict[str, str]]:
    raw = _git(
        root,
        "ls-files",
        "--others",
        "--ignored",
        "--exclude-standard",
        "--directory",
        "-z",
        strip=False,
    )
    records = []
    for entry in filter(None, raw.split("\0")):
        is_directory = entry.endswith("/")
        relative = _normalize_path(entry.rstrip("/"))
        if any(part in SKIP_DIRS for part in PurePosixPath(relative).parts):
            continue
        if is_sensitive(relative):
            continue
        records.append(
            {"path": relative, "kind": "directory" if is_directory else "file"}
        )
    return sorted(records, key=lambda item: item["path"])


def _worktrees(root: Path) -> list[dict[str, Any]]:
    output = _git(root, "worktree", "list", "--porcelain")
    records: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    for line in [*output.splitlines(), ""]:
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        if key in {"bare", "detached", "locked", "prunable"}:
            current[key] = value or True
        elif key == "branch":
            current[key] = value.removeprefix("refs/heads/")
        else:
            current[key] = value
    return records


def _git_operation_limitations(root: Path) -> list[dict[str, str]]:
    markers = {
        "MERGE_HEAD": "merge",
        "CHERRY_PICK_HEAD": "cherry-pick",
        "REVERT_HEAD": "revert",
        "REBASE_HEAD": "rebase",
        "rebase-merge": "rebase",
        "rebase-apply": "rebase-or-am",
        "sequencer": "sequencer",
        "BISECT_LOG": "bisect",
    }
    operations = set()
    for marker, operation in markers.items():
        value = _git(root, "rev-parse", "--git-path", marker, check=False)
        if not value:
            continue
        path = Path(value)
        if not path.is_absolute():
            path = root / path
        if path.exists():
            operations.add(operation)
    return [
        {"code": "git-operation-in-progress-not-audited", "operation": operation}
        for operation in sorted(operations)
    ]


def _dependency_manifests(
    root: Path, is_sensitive: Callable[[str], bool]
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    records = []
    limitations = []
    for path in _walk_project_files(root):
        if path.name not in DEPENDENCY_FILENAMES:
            continue
        relative = _to_relative(root, path)
        if is_sensitive(relative):
            continue
        try:
            records.append({"path": relative, "sha256": _sha256(path)})
        except OSError:
            limitations.append(
                {"code": "dependency-manifest-unreadable", "path": relative}
            )
    return sorted(records, key=lambda item: item["path"]), limitations


def _absolute_path_findings(
    root: Path,
    tracked_raw_paths: Iterable[str],
    is_sensitive: Callable[[str], bool],
) -> list[dict[str, Any]]:
    findings = set()
    for raw_relative in tracked_raw_paths:
        relative = _normalize_path(raw_relative)
        if is_sensitive(relative):
            continue
        path = root / raw_relative
        try:
            if not path.is_file() or path.stat().st_size > TEXT_SCAN_LIMIT:
                continue
            sample = path.read_bytes()[:8192]
            if b"\0" in sample:
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(lines, 1):
            for kind, pattern in ABSOLUTE_PATH_PATTERNS:
                if pattern.search(line):
                    findings.add((relative, line_number, kind))
    return [
        {"path": path, "line": line, "kind": kind}
        for path, line, kind in sorted(findings)
    ]


def _large_files(
    root: Path,
    tracked_raw_paths: Iterable[str],
    dirty_raw_paths: Iterable[str],
    threshold: int,
    is_sensitive: Callable[[str], bool],
) -> list[dict[str, Any]]:
    tracked = set(tracked_raw_paths)
    records = []
    for raw_relative in sorted(tracked | set(dirty_raw_paths)):
        relative = _normalize_path(raw_relative)
        if is_sensitive(relative):
            continue
        path = root / raw_relative
        try:
            if path.is_file() and path.stat().st_size >= threshold:
                records.append(
                    {
                        "path": relative,
                        "size_bytes": path.stat().st_size,
                        "tracked": raw_relative in tracked,
                    }
                )
        except OSError:
            continue
    return records


def _tool_presence() -> list[dict[str, Any]]:
    return [
        {"name": name, "available": bool(shutil.which(name))}
        for name in (
            "git",
            "python",
            "node",
            "flutter",
            "dart",
            "deno",
            "docker",
            "java",
            "ruby",
            "brew",
            "pod",
            "xcodebuild",
            "supabase",
            "openspec",
        )
    ]


def _lfs_attribute_paths(
    root: Path, tracked_raw_paths: Iterable[str]
) -> tuple[list[str], bool]:
    """Detect tracked LFS paths through Git attributes, independent of git-lfs."""
    raw_paths = list(tracked_raw_paths)
    if not raw_paths:
        return [], True
    completed = subprocess.run(
        ["git", "check-attr", "-z", "--stdin", "filter"],
        cwd=root,
        input="\0".join(raw_paths) + "\0",
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if completed.returncode != 0:
        return [], False
    fields = completed.stdout.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    if len(fields) % 3:
        return [], False
    paths = {
        _normalize_path(fields[position])
        for position in range(0, len(fields), 3)
        if fields[position + 1] == "filter" and fields[position + 2] == "lfs"
    }
    return sorted(paths), True


def _frontmatter_name(path: Path) -> str | None:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for _ in range(20):
                line = handle.readline()
                if not line:
                    break
                if line.startswith("name:"):
                    value = line.split(":", 1)[1].strip().strip('"').strip("'")
                    return value or None
    except OSError:
        return None
    return None


def inventory_codex_environment(codex_home: str | Path | None = None) -> dict[str, Any]:
    """Inventory discoverable Skill/plugin identities without reading local config."""
    if codex_home is None:
        codex_home = os.environ.get("CODEX_HOME") or Path.home() / ".codex"
    root = Path(codex_home).expanduser().resolve()
    skills_by_name: dict[str, dict[str, str]] = {}
    skill_roots = [root / "skills"]
    agents_home = os.environ.get("AGENTS_HOME")
    if agents_home:
        skill_roots.append(Path(agents_home).expanduser().resolve() / "skills")
    elif root.name.casefold() == ".codex":
        skill_roots.append(root.parent / ".agents" / "skills")
    for skills_root in skill_roots:
        if skills_root.is_dir():
            for skill_file in skills_root.rglob("SKILL.md"):
                name = _frontmatter_name(skill_file)
                if name:
                    skills_by_name[name] = {"name": name}

    plugins_by_identity: dict[tuple[str, str | None], dict[str, Any]] = {}
    plugins_root = root / "plugins" / "cache"
    if plugins_root.is_dir():
        for manifest_path in plugins_root.rglob("plugin.json"):
            if manifest_path.parent.name != ".codex-plugin":
                continue
            try:
                payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError, UnicodeError):
                continue
            if not isinstance(payload, dict):
                continue
            plugin_id = payload.get("id") or payload.get("name")
            version = payload.get("version")
            if not isinstance(plugin_id, str) or not plugin_id.strip():
                continue
            normalized_version = version.strip() if isinstance(version, str) else None
            record: dict[str, Any] = {"id": plugin_id.strip()}
            if normalized_version:
                record["version"] = normalized_version
            plugins_by_identity[(record["id"], normalized_version)] = record

    return {
        "available": root.is_dir(),
        "skills": [skills_by_name[name] for name in sorted(skills_by_name)],
        "plugins": [
            plugins_by_identity[key]
            for key in sorted(plugins_by_identity, key=lambda item: (item[0], item[1] or ""))
        ],
    }


def _tracked_sensitive_candidates(
    root: Path, tracked_raw_paths: Iterable[str]
) -> list[dict[str, Any]]:
    """List metadata for tracked files that may contain private/business data."""
    records = []
    for raw_path in tracked_raw_paths:
        relative = _normalize_path(raw_path)
        suffix = PurePosixPath(relative).suffix.lower()
        if suffix not in TRACKED_SENSITIVE_DATA_SUFFIXES:
            continue
        path = root / raw_path
        try:
            size = path.stat().st_size
        except OSError:
            continue
        records.append({"path": relative, "extension": suffix, "size_bytes": size})
    return sorted(records, key=lambda item: item["path"])


def _prepare_credential_labels(values: Iterable[str]) -> list[str]:
    labels = set()
    for raw in values:
        value = raw.strip()
        if not value or len(value) > 120:
            raise ValueError("Compromised credential labels must contain 1-120 characters")
        if any(not (character.isalnum() or character in "-_.:/") for character in value):
            raise ValueError(
                "Compromised credential labels may only contain letters, digits, - _ . : /"
            )
        labels.add(value)
    return sorted(labels)


def _path_collision_limitations(paths: Iterable[str]) -> list[dict[str, str]]:
    unicode_groups: dict[str, set[str]] = {}
    case_groups: dict[str, set[str]] = {}
    for value in paths:
        raw = value.replace("\\", "/")
        normalized = unicodedata.normalize("NFC", raw)
        unicode_groups.setdefault(normalized, set()).add(raw)
        case_groups.setdefault(normalized.casefold(), set()).add(normalized)
    limitations = [
        {
            "code": "unicode-normalization-collision",
            "path": " | ".join(sorted(group)),
        }
        for group in unicode_groups.values()
        if len(group) > 1
    ]
    limitations.extend(
        {"code": "case-collision", "path": " | ".join(sorted(group))}
        for group in case_groups.values()
        if len(group) > 1
    )
    return sorted(limitations, key=lambda item: (item["code"], item["path"]))


def audit_workspace(
    workspace: str | Path,
    *,
    scan_absolute_paths: bool = True,
    large_file_threshold_bytes: int = DEFAULT_LARGE_FILE_BYTES,
    sensitive_paths: Iterable[str] = (),
    sensitive_globs: Iterable[str] = (),
    compromised_credential_labels: Iterable[str] = (),
    codex_home: str | Path | None = None,
) -> dict[str, Any]:
    """Audit one Git working tree without reading recognized secret contents."""
    requested = Path(workspace).expanduser().resolve()
    if not requested.is_dir():
        raise ValueError(f"Workspace is not a directory: {requested}")
    root = _repository_root(requested)
    custom_sensitive_paths = _prepare_sensitive_paths(sensitive_paths)
    custom_sensitive_globs = _prepare_sensitive_globs(sensitive_globs)
    compromised_labels = _prepare_credential_labels(compromised_credential_labels)
    is_sensitive = lambda path: _is_sensitive(
        path, custom_sensitive_paths, custom_sensitive_globs
    )
    status_entries = _status_entries(root)
    index_flag_entries = _index_flags(root)
    index_flags = [
        {
            "path": item["path"],
            "assume_unchanged": item["assume_unchanged"],
            "skip_worktree": item["skip_worktree"],
        }
        for item in index_flag_entries
    ]
    worktree_state, limitations = _worktree_state(
        root, status_entries, is_sensitive, index_flag_entries
    )
    dependencies, dependency_limitations = _dependency_manifests(root, is_sensitive)
    limitations.extend(dependency_limitations)
    sensitive, sensitive_raw_paths, sensitive_limitations = _sensitive_paths(
        root, is_sensitive, custom_sensitive_paths, custom_sensitive_globs
    )
    limitations.extend(sensitive_limitations)
    ignored_local = _ignored_nonrebuildable_paths(root, is_sensitive)
    tracked_raw_paths = [
        item
        for item in _git(root, "ls-files", "-z", strip=False).split("\0")
        if item
    ]
    tracked_sensitive_candidates = _tracked_sensitive_candidates(root, tracked_raw_paths)
    lfs_attribute_paths, lfs_attributes_complete = _lfs_attribute_paths(
        root, tracked_raw_paths
    )
    if not lfs_attributes_complete:
        limitations.append({"code": "git-attributes-not-audited"})
    worktrees = _worktrees(root)
    if len(worktrees) > 1:
        limitations.append({"code": "additional-worktree-not-audited"})
    limitations.extend(_git_operation_limitations(root))
    submodules = []
    if (root / ".gitmodules").exists():
        submodules = [
            line
            for line in _git(
                root, "submodule", "status", "--recursive", check=False
            ).splitlines()
            if line
        ]
        if any(line[0] in {"-", "+", "U"} for line in submodules):
            limitations.append({"code": "submodule-state-incomplete"})
    collision_paths = list(tracked_raw_paths)
    collision_paths.extend(entry["raw_path"] for entry in status_entries)
    collision_paths.extend(
        entry["raw_from_path"]
        for entry in status_entries
        if "raw_from_path" in entry
    )
    collision_paths.extend(sensitive_raw_paths)
    limitations.extend(_path_collision_limitations(collision_paths))
    unique_limitations = sorted(
        {json.dumps(item, sort_keys=True): item for item in limitations}.values(),
        key=lambda item: (item["code"], item.get("path", "")),
    )

    head_ref = _git(root, "symbolic-ref", "--quiet", "HEAD", check=False) or None
    head_oid = _git(root, "rev-parse", "--verify", "HEAD", check=False) or None
    upstream = _git(
        root,
        "rev-parse",
        "--abbrev-ref",
        "--symbolic-full-name",
        "@{upstream}",
        check=False,
    ) or None
    ahead = behind = None
    if upstream and head_oid:
        counts = _git(root, "rev-list", "--left-right", "--count", f"HEAD...{upstream}")
        ahead, behind = (int(value) for value in counts.split())
    object_format = _git(root, "rev-parse", "--show-object-format", check=False) or "sha1"
    lfs_version = _run(["git", "lfs", "version"], root, check=False)
    lfs_files = []
    if lfs_version.returncode == 0:
        lfs_files = [
            line
            for line in _git(root, "lfs", "ls-files", "-n", check=False).splitlines()
            if line
        ]
    lfs_files = sorted(set(lfs_files) | set(lfs_attribute_paths))
    findings = (
        _absolute_path_findings(root, tracked_raw_paths, is_sensitive)
        if scan_absolute_paths
        else []
    )
    dirty_raw_paths = [entry["raw_path"] for entry in status_entries]
    dirty_raw_paths.extend(item["raw_path"] for item in index_flag_entries)
    risks = []
    if worktree_state:
        risks.append({"code": "dirty-worktree", "severity": "warning"})
    if _stashes(root):
        risks.append({"code": "stash-not-carried-by-clone", "severity": "warning"})
    if sensitive:
        risks.append({"code": "machine-local-sensitive-state", "severity": "warning"})
    if findings:
        risks.append({"code": "machine-specific-absolute-paths", "severity": "warning"})
    if ignored_local:
        risks.append(
            {"code": "ignored-local-state-requires-classification", "severity": "warning"}
        )
    if tracked_sensitive_candidates:
        risks.append(
            {"code": "tracked-sensitive-data-review-required", "severity": "warning"}
        )
    if compromised_labels:
        risks.append({"code": "credential-rotation-required", "severity": "blocking"})

    return {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "comparison_profile": COMPARISON_PROFILE,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tool": {"name": "audit-project-transfer", "version": TOOL_VERSION},
        "portable": {
            "git": {
                "object_format": object_format,
                "head": {"oid": head_oid, "ref": head_ref},
                "refs": {
                    "heads": _refs(root, "refs/heads"),
                    "tags": _refs(root, "refs/tags"),
                    "stashes": _stashes(root),
                    "other": _other_refs(root),
                },
                "index_flags": index_flags,
                "worktree": worktree_state,
            },
            "dependency_manifests": dependencies,
            "sensitive_paths": sensitive,
        },
        "coverage": {
            "scope": "single-git-working-tree-portable-state-only",
            "complete": not unique_limitations,
            "limitations": unique_limitations,
        },
        "machine_local": {
            "workspace": {"name": root.name, "root": str(root)},
            "machine": {
                "os": platform.system(),
                "release": platform.release(),
                "architecture": platform.machine(),
                "python": platform.python_version(),
                "tools": _tool_presence(),
            },
            "collaboration": {"codex": inventory_codex_environment(codex_home)},
            "data_review": {
                "tracked_sensitive_candidates": tracked_sensitive_candidates,
            },
            "security": {
                "compromised_credential_labels": compromised_labels,
            },
            "git": {
                "upstream": upstream,
                "ahead": ahead,
                "behind": behind,
                "remotes": _remotes(root),
                "configuration": {
                    "core_autocrlf": _git(
                        root, "config", "--get", "core.autocrlf", check=False
                    )
                    or None,
                    "core_ignorecase": _git(
                        root, "config", "--get", "core.ignorecase", check=False
                    )
                    or None,
                    "core_filemode": _git(
                        root, "config", "--get", "core.filemode", check=False
                    )
                    or None,
                },
                "worktrees": worktrees,
                "submodules": submodules,
                "lfs": {
                    "available": lfs_version.returncode == 0,
                    "files": sorted(lfs_files),
                },
            },
            "project": {
                "large_files": _large_files(
                    root,
                    tracked_raw_paths,
                    dirty_raw_paths,
                    large_file_threshold_bytes,
                    is_sensitive,
                )
            },
            "local_state": {
                "rebuildable_paths": [
                    {"path": item, "exists": (root / item).exists()}
                    for item in REBUILDABLE_PATHS
                ],
                "ignored_nonrebuildable_paths": ignored_local,
            },
            "portability": {"absolute_path_findings": findings},
            "risks": risks,
        },
    }


def _portable_path_valid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return _normalize_path(value) == value
    except ValueError:
        return False


def _oid_valid(value: Any, object_format: str, *, allow_none: bool = False) -> bool:
    if value is None:
        return allow_none
    expected_length = {"sha1": 40, "sha256": 64}.get(object_format)
    return (
        isinstance(value, str)
        and expected_length is not None
        and len(value) == expected_length
        and bool(HEX_RE.fullmatch(value))
    )


def _sha256_valid(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and bool(HEX_RE.fullmatch(value))
    )


def _unique_portable_paths(records: Any) -> bool:
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        return False
    paths = [item.get("path") for item in records]
    return (
        len(paths) == len(set(paths))
        and all(_portable_path_valid(path) for path in paths)
    )


def _manifest_problem(manifest: dict[str, Any]) -> str | None:
    try:
        if not isinstance(manifest, dict) or manifest.get("format") != FORMAT:
            return "unsupported or missing format"
        version = manifest.get("format_version")
        if not isinstance(version, str) or not re.fullmatch(r"1\.\d+", version):
            return "unsupported format major version"
        if manifest.get("comparison_profile") != COMPARISON_PROFILE:
            return "unsupported comparison profile"
        if not isinstance(manifest.get("created_at"), str):
            return "missing creation time"
        tool = manifest.get("tool")
        if not isinstance(tool, dict) or not all(
            isinstance(tool.get(key), str) for key in ("name", "version")
        ):
            return "invalid tool identity"

        portable = manifest.get("portable")
        coverage = manifest.get("coverage")
        if not isinstance(portable, dict) or not isinstance(coverage, dict):
            return "missing portable or coverage object"
        if set(portable) != {"git", "dependency_manifests", "sensitive_paths"}:
            return "invalid portable state fields"
        if set(coverage) != {"scope", "complete", "limitations"}:
            return "invalid coverage fields"
        if coverage.get("scope") != "single-git-working-tree-portable-state-only":
            return "unsupported coverage scope"
        if not isinstance(coverage.get("complete"), bool) or not isinstance(
            coverage.get("limitations"), list
        ):
            return "invalid coverage state"
        if not all(
            isinstance(item, dict) and isinstance(item.get("code"), str)
            for item in coverage["limitations"]
        ):
            return "invalid coverage limitation"
        if coverage["complete"] == bool(coverage["limitations"]):
            return "coverage completeness contradicts limitations"

        git = portable.get("git")
        if not isinstance(git, dict):
            return "missing portable Git state"
        if set(git) != {"object_format", "head", "refs", "index_flags", "worktree"}:
            return "invalid portable Git fields"
        object_format = git.get("object_format")
        if object_format not in {"sha1", "sha256"}:
            return "invalid Git object format"
        head = git.get("head")
        if not isinstance(head, dict) or set(head) != {"oid", "ref"}:
            return "invalid HEAD record"
        if not _oid_valid(head["oid"], object_format, allow_none=True):
            return "invalid HEAD object id"
        if head["ref"] is not None and not (
            isinstance(head["ref"], str) and head["ref"].startswith("refs/heads/")
        ):
            return "invalid HEAD reference"
        if head["oid"] is None and head["ref"] is None:
            return "HEAD lacks both object and branch"

        refs = git.get("refs")
        if not isinstance(refs, dict) or not all(
            isinstance(refs.get(key), list)
            for key in ("heads", "tags", "stashes", "other")
        ):
            return "missing portable Git refs"
        if set(refs) != {"heads", "tags", "stashes", "other"}:
            return "invalid portable Git ref fields"
        for ref_kind, prefix in (
            ("heads", "refs/heads/"),
            ("tags", "refs/tags/"),
            ("other", "refs/"),
        ):
            names = []
            for item in refs[ref_kind]:
                if not isinstance(item, dict) or set(item) != {"name", "oid"}:
                    return f"invalid {ref_kind} ref record"
                if not isinstance(item["name"], str) or not item["name"].startswith(prefix):
                    return f"invalid {ref_kind} ref name"
                if ref_kind == "other" and (
                    item["name"] == "refs/stash"
                    or item["name"].startswith(
                        ("refs/heads/", "refs/tags/", "refs/remotes/")
                    )
                ):
                    return "invalid other ref namespace"
                if not _oid_valid(item["oid"], object_format):
                    return f"invalid {ref_kind} ref object id"
                names.append(item["name"])
            if len(names) != len(set(names)):
                return f"duplicate {ref_kind} ref"
        for position, item in enumerate(refs["stashes"]):
            if not isinstance(item, dict) or set(item) != {"position", "oid"}:
                return "invalid stash record"
            if item["position"] != position or not _oid_valid(
                item["oid"], object_format
            ):
                return "invalid stash position or object id"

        index_flags = git.get("index_flags")
        if not _unique_portable_paths(index_flags):
            return "invalid index flag paths"
        for item in index_flags:
            if set(item) != {"path", "assume_unchanged", "skip_worktree"}:
                return "invalid index flag record"
            if not isinstance(item["assume_unchanged"], bool) or not isinstance(
                item["skip_worktree"], bool
            ):
                return "invalid index flag values"
            if not item["assume_unchanged"] and not item["skip_worktree"]:
                return "empty index flag record"

        worktree = git.get("worktree")
        if not _unique_portable_paths(worktree):
            return "invalid worktree paths"
        states = set(STATUS_NAMES.values()) | {"index-hidden", "untracked"}
        for item in worktree:
            if not set(item).issubset(
                {"path", "from_path", "kind", "index", "working"}
            ) or not {"path", "kind"}.issubset(item):
                return "invalid worktree record"
            if item["kind"] not in {"file", "symlink", "missing", "special"}:
                return "invalid worktree kind"
            if "from_path" in item and not _portable_path_valid(item["from_path"]):
                return "invalid worktree source path"
            if "index" not in item and "working" not in item:
                return "worktree record lacks index and working state"
            if "index" in item:
                index = item["index"]
                if not isinstance(index, dict) or not set(index).issubset(
                    {"state", "mode", "oid"}
                ) or "state" not in index:
                    return "invalid worktree index record"
                if index["state"] not in states:
                    return "invalid worktree index state"
                if "mode" in index and not (
                    isinstance(index["mode"], str)
                    and bool(re.fullmatch(r"[0-7]{6}", index["mode"]))
                ):
                    return "invalid worktree index mode"
                if "oid" in index and not _oid_valid(index["oid"], object_format):
                    return "invalid worktree index object id"
            if "working" in item:
                working = item["working"]
                if not isinstance(working, dict) or not set(working).issubset(
                    {"state", "sha256", "executable"}
                ) or "state" not in working:
                    return "invalid working file record"
                if working["state"] not in states:
                    return "invalid working file state"
                if "sha256" in working and not _sha256_valid(working["sha256"]):
                    return "invalid working file digest"
                if "executable" in working and not isinstance(
                    working["executable"], bool
                ):
                    return "invalid working executable flag"
                if item["kind"] == "file" and working["state"] != "deleted":
                    if "sha256" not in working or "executable" not in working:
                        return "incomplete working file record"
                if item["kind"] == "missing" and working["state"] in {
                    "untracked",
                    "modified",
                    "added",
                    "type-changed",
                }:
                    return "non-deleted working path is missing"

        dependencies = portable.get("dependency_manifests")
        if not _unique_portable_paths(dependencies):
            return "invalid dependency manifest paths"
        for item in dependencies:
            if set(item) != {"path", "sha256"} or not _sha256_valid(item["sha256"]):
                return "invalid dependency manifest digest"

        sensitive = portable.get("sensitive_paths")
        if not _unique_portable_paths(sensitive):
            return "invalid sensitive paths"
        for item in sensitive:
            if set(item) != {"path", "exists", "ignored"}:
                return "invalid sensitive path record"
            if not isinstance(item["exists"], bool):
                return "invalid sensitive existence flag"
            if item["exists"]:
                if not isinstance(item["ignored"], bool):
                    return "invalid sensitive ignore flag"
            elif item["ignored"] is not None:
                return "missing sensitive path must use ignored=null"
        if "machine_local" in manifest and not isinstance(
            manifest["machine_local"], dict
        ):
            return "invalid machine-local diagnostics"
        return None
    except (KeyError, TypeError, ValueError):
        return "malformed nested manifest structure"


def _sorted_records(records: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    return sorted(records, key=lambda item: item[key])


def _compare_manifests(source: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    """Compare portable state and keep machine-local differences diagnostic."""
    failures: list[dict[str, str]] = []
    warnings: list[dict[str, str]] = []
    limitations: list[dict[str, Any]] = []
    problems = [problem for problem in (_manifest_problem(source), _manifest_problem(target)) if problem]
    if problems:
        limitations.extend({"code": "invalid-manifest", "message": item} for item in problems)
        status = "inconclusive"
    elif not source["coverage"]["complete"] or not target["coverage"]["complete"]:
        limitations.extend(source["coverage"]["limitations"])
        limitations.extend(target["coverage"]["limitations"])
        status = "inconclusive"
    else:
        source_git = source["portable"]["git"]
        target_git = target["portable"]["git"]

        def compare(field: str, source_value: Any, target_value: Any) -> None:
            if source_value != target_value:
                failures.append({"field": field, "message": "portable state differs"})

        compare("portable.git.object_format", source_git["object_format"], target_git["object_format"])
        compare("portable.git.head", source_git["head"], target_git["head"])
        for ref_kind in ("heads", "tags", "other"):
            compare(
                f"portable.git.refs.{ref_kind}",
                _sorted_records(source_git["refs"][ref_kind], "name"),
                _sorted_records(target_git["refs"][ref_kind], "name"),
            )
        compare(
            "portable.git.refs.stashes",
            source_git["refs"]["stashes"],
            target_git["refs"]["stashes"],
        )
        compare(
            "portable.git.index_flags",
            _sorted_records(source_git["index_flags"], "path"),
            _sorted_records(target_git["index_flags"], "path"),
        )
        compare(
            "portable.git.worktree",
            _sorted_records(source_git["worktree"], "path"),
            _sorted_records(target_git["worktree"], "path"),
        )
        compare(
            "portable.dependency_manifests",
            _sorted_records(source["portable"]["dependency_manifests"], "path"),
            _sorted_records(target["portable"]["dependency_manifests"], "path"),
        )

        source_sensitive = {
            item["path"]: item for item in source["portable"]["sensitive_paths"]
        }
        target_sensitive = {
            item["path"]: item for item in target["portable"]["sensitive_paths"]
        }
        for path in sorted(set(source_sensitive) | set(target_sensitive)):
            source_item = source_sensitive.get(
                path, {"path": path, "exists": False, "ignored": None}
            )
            target_item = target_sensitive.get(
                path, {"path": path, "exists": False, "ignored": None}
            )
            if source_item["exists"] and not target_item["exists"]:
                failures.append(
                    {"field": "portable.sensitive_paths", "message": "source sensitive path is missing on target"}
                )
                continue
            if (source_item["exists"] and not source_item["ignored"]) or (
                target_item["exists"] and not target_item["ignored"]
            ):
                failures.append(
                    {"field": "portable.sensitive_paths", "message": "sensitive path is not Git-ignored"}
                )
                continue
            if source_item["exists"] or target_item["exists"]:
                warnings.append(
                    {
                        "field": "portable.sensitive_paths",
                        "message": "recognized secret presence is checked; contents are not compared",
                    }
                )
        if source.get("machine_local") != target.get("machine_local"):
            warnings.append(
                {"field": "machine_local", "message": "machine-local diagnostics differ"}
            )
        status = "mismatch" if failures else ("match_with_warnings" if warnings else "match")

    return {
        "format": "cross-machine-project-handoff-verification",
        "format_version": FORMAT_VERSION,
        "compared_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "status": status,
        "failures": failures,
        "warnings": warnings,
        "limitations": sorted(
            {json.dumps(item, sort_keys=True): item for item in limitations}.values(),
            key=lambda item: (item.get("code", ""), item.get("path", "")),
        ),
    }


def compare_manifests(source: dict[str, Any], target: dict[str, Any]) -> dict[str, Any]:
    """Compare portable state and return structured inconclusive on malformed input."""
    try:
        return _compare_manifests(source, target)
    except (KeyError, TypeError, ValueError, IndexError) as error:
        return {
            "format": "cross-machine-project-handoff-verification",
            "format_version": FORMAT_VERSION,
            "compared_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "status": "inconclusive",
            "failures": [],
            "warnings": [],
            "limitations": [
                {
                    "code": "invalid-manifest",
                    "message": f"malformed nested manifest structure ({type(error).__name__})",
                }
            ],
        }


def _write_json(payload: dict[str, Any], destination: str) -> None:
    rendered = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if destination == "-":
        sys.stdout.write(rendered)
        return
    path = Path(destination).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def _load_json(path: str) -> dict[str, Any]:
    payload = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Manifest must be a JSON object: {path}")
    return payload


def _path_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _prepare_empty_directory(
    value: str | Path,
    *,
    forbidden_roots: Iterable[Path] = (),
) -> Path:
    destination = Path(value).expanduser().resolve()
    for root in forbidden_roots:
        root = root.resolve()
        if _path_within(destination, root):
            raise ValueError(f"Output directory must be outside {root}")
    if destination.exists():
        if not destination.is_dir() or any(destination.iterdir()):
            raise ValueError(f"Output directory must be empty or absent: {destination}")
    else:
        destination.mkdir(parents=True)
    return destination


def _write_private_text(value: str, destination: Path) -> None:
    destination.write_text(value.rstrip() + "\n", encoding="utf-8")
    try:
        destination.chmod(0o600)
    except OSError:
        pass


def _clean_line(value: Any, field: str, *, maximum: int = 500) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    cleaned = value.strip()
    if not cleaned or len(cleaned) > maximum or any(
        character in cleaned for character in "\r\n\0"
    ):
        raise ValueError(f"{field} must be a non-empty single line")
    return cleaned


def _clean_unique_lines(
    values: Iterable[str], field: str, *, maximum: int = 200
) -> list[str]:
    return sorted(
        {
            _clean_line(value, field, maximum=maximum)
            for value in values
        }
    )


def _load_validation_records(path: str | Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    source = Path(path).expanduser().resolve()
    payload = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise ValueError("Validation evidence must be a JSON array")
    allowed = {
        "name",
        "status",
        "command_label",
        "exit_code",
        "duration_seconds",
        "summary",
        "evidence_label",
    }
    records: list[dict[str, Any]] = []
    for position, item in enumerate(payload):
        if not isinstance(item, dict) or not set(item).issubset(allowed):
            raise ValueError(f"Invalid validation record at position {position}")
        name = _clean_line(item.get("name"), "validation name", maximum=120)
        status = item.get("status")
        if status not in VALIDATION_STATUSES:
            raise ValueError(f"Unsupported validation status for {name}: {status}")
        record: dict[str, Any] = {"name": name, "status": status}
        for field, maximum in (
            ("command_label", 240),
            ("summary", 500),
            ("evidence_label", 240),
        ):
            if field in item:
                record[field] = _clean_line(item[field], field, maximum=maximum)
        if "exit_code" in item:
            if not isinstance(item["exit_code"], int) or isinstance(
                item["exit_code"], bool
            ):
                raise ValueError(f"exit_code must be an integer for {name}")
            record["exit_code"] = item["exit_code"]
        if "duration_seconds" in item:
            duration = item["duration_seconds"]
            if (
                not isinstance(duration, (int, float))
                or isinstance(duration, bool)
                or duration < 0
            ):
                raise ValueError(f"duration_seconds must be non-negative for {name}")
            record["duration_seconds"] = duration
        records.append(record)
    names = [item["name"] for item in records]
    if len(names) != len(set(names)):
        raise ValueError("Validation evidence names must be unique")
    return records


def _assert_packable(
    manifest: dict[str, Any], *, approve_tracked_data_review: bool
) -> None:
    problem = _manifest_problem(manifest)
    if problem:
        raise ValueError(f"Source audit manifest is invalid: {problem}")
    git = manifest["portable"]["git"]
    machine = manifest["machine_local"]
    if git["worktree"]:
        raise ValueError("Pack requires a clean worktree; commit or classify all changes")
    if git["index_flags"]:
        raise ValueError("Pack refuses assume-unchanged or skip-worktree index flags")
    if git["refs"]["stashes"]:
        raise ValueError("Pack requires an empty stash list")
    ignored = machine["local_state"]["ignored_nonrebuildable_paths"]
    if ignored:
        raise ValueError("Pack refuses unclassified ignored local state")
    compromised = machine["security"]["compromised_credential_labels"]
    if compromised:
        raise ValueError(
            "Rotate compromised credentials before packing and remove their labels from a fresh audit"
        )
    candidates = machine["data_review"]["tracked_sensitive_candidates"]
    if candidates and not approve_tracked_data_review:
        raise ValueError(
            "Pack requires explicit tracked data review approval for document or archive candidates"
        )
    if not manifest["coverage"]["complete"]:
        codes = ", ".join(
            item["code"] for item in manifest["coverage"]["limitations"]
        )
        raise ValueError(f"Pack requires complete audit coverage: {codes}")
    if not git["head"]["oid"] or not git["head"]["ref"]:
        raise ValueError("Pack requires a committed symbolic branch HEAD")
    if machine["git"]["submodules"]:
        raise ValueError("Pack does not yet carry submodule repositories")
    if machine["git"]["lfs"]["files"]:
        raise ValueError("Pack does not yet carry Git LFS object storage")


def _artifact_record(path: Path) -> dict[str, Any]:
    return {
        "filename": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": _sha256(path),
    }


def _render_handoff_capsule(receipt: dict[str, Any]) -> str:
    source = receipt["source"]
    intent = receipt["intent"]
    validation = receipt["validation"]
    validation_lines = [
        f"- {item['name']}: {item['status']}"
        + (f" — {item['summary']}" if item.get("summary") else "")
        for item in validation
    ] or ["- 未提供；目标机不得把未运行的检查声称为通过。"]
    non_goals = [f"- {item}" for item in intent["non_goals"]] or ["- 未声明。"]
    return "\n".join(
        [
            "# 跨电脑项目交接胶囊",
            "",
            f"- 项目：{source['workspace_name']}",
            f"- 精确提交：{source['head_oid']}",
            f"- 分支引用：{source['head_ref']}",
            f"- 交接状态：{receipt['transfer_state']}",
            "",
            "## 当前目标",
            "",
            intent["objective"],
            "",
            "## 非目标",
            "",
            *non_goals,
            "",
            "## 验证证据",
            "",
            *validation_lines,
            "",
            "## 下一动作",
            "",
            intent["next_action"],
        ]
    )


def _render_new_session_prompt(receipt: dict[str, Any]) -> str:
    source = receipt["source"]
    intent = receipt["intent"]
    requirements = receipt["requirements"]
    validations = ", ".join(
        f"{item['name']}={item['status']}" for item in receipt["validation"]
    ) or "未提供"
    skills = "、".join(requirements["skills"]) or "无额外声明"
    plugins = "、".join(requirements["plugins"]) or "无额外声明"
    docs = "、".join(requirements["docs"]) or "无额外声明"
    non_goals = "；".join(intent["non_goals"]) or "未声明"
    sensitive = receipt["artifacts"]["encrypted_secret_archive"]
    sensitive_instruction = (
        "已附带用户确认经过独立加密的敏感归档；工具未做密码学验证。只能通过批准的密钥通道解密，禁止在对话、日志或命令行参数中暴露口令。"
        if sensitive
        else "未附带敏感归档；若源清单记录了敏感状态，先通过独立安全通道补齐，再做最终 verify。"
    )
    return "\n".join(
        [
            "请使用 $cross-machine-project-handoff 的 restore/verify 工作流接手此项目。",
            "",
            f"交接收据格式：{receipt['format']} {receipt['format_version']}",
            f"项目：{source['workspace_name']}",
            f"必须恢复并核对的提交：{source['head_oid']}",
            f"分支引用：{source['head_ref']}",
            f"目标：{intent['objective']}",
            f"非目标：{non_goals}",
            f"下一动作：{intent['next_action']}",
            f"源端验证证据：{validations}",
            f"所需 Skills：{skills}",
            f"所需 Plugins：{plugins}",
            f"必须先读文档：{docs}",
            sensitive_instruction,
            "",
            "恢复到不存在或空目录；先校验 bundle、清单与收据中的 SHA-256，再恢复 Git 引用。",
            "不要覆盖现有工作区，不要打印敏感文件内容，不要把 timed_out/skipped/inconclusive 当作 passed。",
            "敏感状态恢复后重新运行 audit 与 verify；只有结构化收据为 match/match_with_warnings 才可宣称交接完成。",
        ]
    )


def create_handoff_package(
    workspace: str | Path,
    output_dir: str | Path,
    *,
    objective: str,
    next_action: str,
    non_goals: Iterable[str] = (),
    validation_file: str | Path | None = None,
    required_skills: Iterable[str] = (),
    required_plugins: Iterable[str] = (),
    required_docs: Iterable[str] = (),
    encrypted_secret_archive: str | Path | None = None,
    confirm_secret_archive_encrypted: bool = False,
    approve_tracked_data_review: bool = False,
    sensitive_paths: Iterable[str] = (),
    sensitive_globs: Iterable[str] = (),
    compromised_credential_labels: Iterable[str] = (),
    codex_home: str | Path | None = None,
) -> dict[str, Any]:
    """Create a deterministic clean-Git handoff control package."""
    requested = Path(workspace).expanduser().resolve()
    root = _repository_root(requested)
    intent = {
        "objective": _clean_line(objective, "objective"),
        "non_goals": _clean_unique_lines(non_goals, "non-goal"),
        "next_action": _clean_line(next_action, "next_action"),
    }
    prepared_skills = set(_clean_unique_lines(required_skills, "required skill"))
    prepared_skills.add("cross-machine-project-handoff")
    requirements = {
        "skills": sorted(prepared_skills),
        "plugins": _clean_unique_lines(required_plugins, "required plugin"),
        "docs": sorted({_normalize_path(item) for item in required_docs}),
    }
    validations = _load_validation_records(validation_file)
    source_archive = None
    if encrypted_secret_archive is not None:
        if not confirm_secret_archive_encrypted:
            raise ValueError(
                "Use confirm_secret_archive_encrypted only after independently confirming the archive is encrypted"
            )
        source_archive = Path(encrypted_secret_archive).expanduser().resolve()
        if not source_archive.is_file():
            raise ValueError(
                f"Encrypted secret archive is not a regular file: {source_archive}"
            )
    elif confirm_secret_archive_encrypted:
        raise ValueError(
            "confirm_secret_archive_encrypted requires encrypted_secret_archive"
        )
    manifest = audit_workspace(
        root,
        sensitive_paths=sensitive_paths,
        sensitive_globs=sensitive_globs,
        compromised_credential_labels=compromised_credential_labels,
        codex_home=codex_home,
    )
    _assert_packable(
        manifest, approve_tracked_data_review=approve_tracked_data_review
    )
    destination = _prepare_empty_directory(output_dir, forbidden_roots=[root])

    manifest_path = destination / "source-manifest.json"
    bundle_path = destination / "repository.bundle"
    _write_json(manifest, str(manifest_path))
    _run(["git", "bundle", "create", str(bundle_path), "--all"], root)
    _run(["git", "bundle", "verify", str(bundle_path)], root)

    encrypted_record = None
    if source_archive is not None:
        suffix = source_archive.suffix if source_archive.suffix else ".bin"
        archive_path = destination / f"encrypted-secrets{suffix}"
        shutil.copy2(source_archive, archive_path)
        encrypted_record = _artifact_record(archive_path)

    sensitive_exists = any(
        item["exists"] for item in manifest["portable"]["sensitive_paths"]
    )
    transfer_state = (
        "ready"
        if not sensitive_exists or encrypted_record is not None
        else "ready_code_sensitive_archive_pending"
    )
    receipt = {
        "format": HANDOFF_FORMAT,
        "format_version": HANDOFF_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tool": {"name": "audit-project-transfer", "version": TOOL_VERSION},
        "transfer_state": transfer_state,
        "source": {
            "workspace_name": root.name,
            "object_format": manifest["portable"]["git"]["object_format"],
            "head_oid": manifest["portable"]["git"]["head"]["oid"],
            "head_ref": manifest["portable"]["git"]["head"]["ref"],
            "codex_environment": manifest["machine_local"]["collaboration"]["codex"],
        },
        "intent": intent,
        "requirements": requirements,
        "validation": validations,
        "approvals": {
            "tracked_data_review": bool(approve_tracked_data_review),
            "tracked_sensitive_candidates": manifest["machine_local"]["data_review"][
                "tracked_sensitive_candidates"
            ],
        },
        "artifacts": {
            "repository_bundle": _artifact_record(bundle_path),
            "source_manifest": _artifact_record(manifest_path),
            "encrypted_secret_archive": encrypted_record,
        },
        "security": {
            "secret_values_recorded": False,
            "encrypted_secret_archive_auto_extract": False,
            "encrypted_secret_archive_user_attested": bool(encrypted_record),
            "encrypted_secret_archive_cryptographic_verification": "not_performed",
            "credential_rotation_required": False,
        },
    }
    _write_json(receipt, str(destination / "handoff-receipt.json"))
    _write_private_text(
        _render_handoff_capsule(receipt), destination / "handoff-capsule.txt"
    )
    _write_private_text(
        _render_new_session_prompt(receipt), destination / "new-session-prompt.txt"
    )
    return receipt


def _receipt_artifact(package_dir: Path, record: Any, field: str) -> Path:
    if not isinstance(record, dict) or set(record) != {
        "filename",
        "size_bytes",
        "sha256",
    }:
        raise ValueError(f"Invalid {field} artifact record")
    filename = record.get("filename")
    if (
        not isinstance(filename, str)
        or not filename
        or filename != Path(filename).name
    ):
        raise ValueError(f"Unsafe {field} artifact filename")
    path = package_dir / filename
    if not path.is_file():
        raise ValueError(f"Missing {field} artifact: {filename}")
    if path.stat().st_size != record.get("size_bytes") or _sha256(path) != record.get(
        "sha256"
    ):
        raise ValueError(f"{field} artifact integrity check failed")
    return path


def restore_handoff_package(
    receipt_path: str | Path,
    target_dir: str | Path,
    *,
    output_dir: str | Path,
    codex_home: str | Path | None = None,
) -> dict[str, Any]:
    """Restore a clean Git bundle without extracting sensitive state."""
    receipt_file = Path(receipt_path).expanduser().resolve()
    receipt = _load_json(str(receipt_file))
    if (
        receipt.get("format") != HANDOFF_FORMAT
        or receipt.get("format_version") != HANDOFF_VERSION
    ):
        raise ValueError("Unsupported handoff receipt")
    package_dir = receipt_file.parent
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ValueError("Receipt lacks artifact records")
    bundle_path = _receipt_artifact(
        package_dir, artifacts.get("repository_bundle"), "repository bundle"
    )
    manifest_path = _receipt_artifact(
        package_dir, artifacts.get("source_manifest"), "source manifest"
    )
    encrypted_record = artifacts.get("encrypted_secret_archive")
    if encrypted_record is not None:
        _receipt_artifact(
            package_dir, encrypted_record, "encrypted secret archive"
        )
    source_manifest = _load_json(str(manifest_path))
    problem = _manifest_problem(source_manifest)
    if problem:
        raise ValueError(f"Source manifest is invalid: {problem}")
    source_record = receipt.get("source")
    expected_source_identity = {
        "object_format": source_manifest["portable"]["git"]["object_format"],
        "head_oid": source_manifest["portable"]["git"]["head"]["oid"],
        "head_ref": source_manifest["portable"]["git"]["head"]["ref"],
    }
    if not isinstance(source_record, dict) or any(
        source_record.get(field) != value
        for field, value in expected_source_identity.items()
    ):
        raise ValueError("Handoff receipt source identity does not match its manifest")
    requirements = receipt.get("requirements")
    if not isinstance(requirements, dict) or any(
        not isinstance(requirements.get(field), list)
        or not all(isinstance(item, str) and item for item in requirements[field])
        for field in ("skills", "plugins", "docs")
    ):
        raise ValueError("Invalid handoff receipt requirements")

    target = Path(target_dir).expanduser().resolve()
    if target.exists():
        if not target.is_dir() or any(target.iterdir()):
            raise ValueError(f"Restore target must be empty or absent: {target}")
    if _path_within(target, package_dir):
        raise ValueError("Restore target must be outside the handoff package")
    evidence_dir = _prepare_empty_directory(
        output_dir, forbidden_roots=[target, package_dir]
    )

    head = source_manifest["portable"]["git"]["head"]
    branch = head["ref"].removeprefix("refs/heads/")
    _run(
        [
            "git",
            "clone",
            "--no-checkout",
            "--no-tags",
            "--branch",
            branch,
            str(bundle_path),
            str(target),
        ],
        package_dir,
    )
    refs = source_manifest["portable"]["git"]["refs"]
    for item in refs["heads"] + refs["tags"] + refs["other"]:
        _git(target, "cat-file", "-e", f"{item['oid']}^{{object}}")
        _git(target, "update-ref", item["name"], item["oid"])
    _git(target, "symbolic-ref", "HEAD", head["ref"])
    _git(target, "reset", "--hard", head["oid"])
    _git(target, "fsck", "--full")

    declared_sensitive_paths = [
        item["path"] for item in source_manifest["portable"]["sensitive_paths"]
    ]
    target_manifest = audit_workspace(
        target,
        scan_absolute_paths=False,
        sensitive_paths=declared_sensitive_paths,
        codex_home=codex_home,
    )
    comparison = compare_manifests(source_manifest, target_manifest)
    target_sensitive = {
        item["path"]: item
        for item in target_manifest["portable"]["sensitive_paths"]
    }
    missing_sensitive = [
        item["path"]
        for item in source_manifest["portable"]["sensitive_paths"]
        if item["exists"]
        and not target_sensitive.get(
            item["path"], {"exists": False}
        )["exists"]
    ]

    inventory = target_manifest["machine_local"]["collaboration"]["codex"]
    available_skills = {item["name"] for item in inventory.get("skills", [])}
    available_plugins = {item["id"] for item in inventory.get("plugins", [])}
    missing_skills = sorted(set(requirements.get("skills", [])) - available_skills)
    missing_plugins = sorted(
        set(requirements.get("plugins", [])) - available_plugins
    )
    if missing_sensitive:
        status = "awaiting_sensitive_restore"
    elif missing_skills or missing_plugins:
        status = "awaiting_toolchain_restore"
    elif comparison["status"] in {"match", "match_with_warnings"}:
        status = "restored_and_manifest_match"
    else:
        status = "restore_verification_incomplete"

    _write_json(target_manifest, str(evidence_dir / "target-manifest.json"))
    report = {
        "format": RESTORE_FORMAT,
        "format_version": HANDOFF_VERSION,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "status": status,
        "restored": {
            "head_oid": _git(target, "rev-parse", "HEAD"),
            "head_ref": _git(target, "symbolic-ref", "--quiet", "HEAD"),
        },
        "comparison": comparison,
        "pending": {
            "sensitive_paths": missing_sensitive,
            "skills": missing_skills,
            "plugins": missing_plugins,
        },
        "security": {
            "encrypted_secret_archive_extracted": False,
            "secret_values_recorded": False,
        },
    }
    _write_json(report, str(evidence_dir / "restore-report.json"))
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Audit, pack, restore, and compare Git state for a cross-machine handoff."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    audit = subparsers.add_parser("audit", help="Create a secret-safe source manifest.")
    audit.add_argument("--workspace", default=".", help="Git working tree path.")
    audit.add_argument("--output", default="-", help="JSON output path, or - for stdout.")
    audit.add_argument(
        "--no-absolute-path-scan",
        action="store_true",
        help="Skip the tracked-text scan for machine-specific absolute paths.",
    )
    audit.add_argument(
        "--large-file-threshold-mb",
        type=float,
        default=100.0,
        help="Report tracked or dirty files at or above this size.",
    )
    audit.add_argument(
        "--sensitive-path",
        action="append",
        default=[],
        metavar="PATH",
        help="Treat this repository-relative path and descendants as sensitive; repeat as needed.",
    )
    audit.add_argument(
        "--sensitive-glob",
        action="append",
        default=[],
        metavar="GLOB",
        help="Treat matching repository-relative paths as sensitive; repeat as needed.",
    )
    audit.add_argument(
        "--compromised-credential-label",
        action="append",
        default=[],
        metavar="LABEL",
        help="Record a non-secret label for a credential that must be rotated; never pass the secret value.",
    )
    audit.add_argument(
        "--codex-home",
        help="Optional Codex home to inventory; config and credential files are never read.",
    )

    pack = subparsers.add_parser(
        "pack", help="Create a clean Git bundle, receipt, capsule, and target prompt."
    )
    pack.add_argument("--workspace", default=".", help="Git working tree path.")
    pack.add_argument("--output-dir", required=True, help="Empty package directory outside the workspace.")
    pack.add_argument("--objective", required=True, help="Current project objective, without secrets.")
    pack.add_argument("--next-action", required=True, help="First concrete action on the target computer.")
    pack.add_argument("--non-goal", action="append", default=[], help="Explicit non-goal; repeat as needed.")
    pack.add_argument("--validation-file", help="JSON array of structured validation evidence.")
    pack.add_argument("--required-skill", action="append", default=[], help="Required Codex skill name; repeat as needed.")
    pack.add_argument("--required-plugin", action="append", default=[], help="Required Codex plugin id; repeat as needed.")
    pack.add_argument("--required-doc", action="append", default=[], help="Required repository-relative document; repeat as needed.")
    pack.add_argument(
        "--encrypted-secret-archive",
        help="Already-encrypted sensitive archive to copy; this tool never accepts its password.",
    )
    pack.add_argument(
        "--confirm-secret-archive-encrypted",
        action="store_true",
        help="Attest that the supplied archive was encrypted independently; the tool cannot cryptographically prove this.",
    )
    pack.add_argument(
        "--approve-tracked-data-review",
        action="store_true",
        help="Confirm that all tracked document/archive candidates were reviewed for authorized transfer.",
    )
    pack.add_argument("--sensitive-path", action="append", default=[], metavar="PATH")
    pack.add_argument("--sensitive-glob", action="append", default=[], metavar="GLOB")
    pack.add_argument(
        "--compromised-credential-label",
        action="append",
        default=[],
        metavar="LABEL",
        help="Non-secret label only; any value here blocks packing until rotation.",
    )
    pack.add_argument("--codex-home", help="Optional Codex home to inventory safely.")

    restore = subparsers.add_parser(
        "restore", help="Restore a verified clean bundle without extracting sensitive state."
    )
    restore.add_argument("--receipt", required=True, help="handoff-receipt.json path.")
    restore.add_argument("--target", required=True, help="Empty or absent target workspace directory.")
    restore.add_argument("--output-dir", required=True, help="Empty restore-evidence directory outside package and target.")
    restore.add_argument("--codex-home", help="Optional target Codex home to inventory safely.")

    verify = subparsers.add_parser("verify", help="Compare source and target manifests.")
    verify.add_argument("--source", required=True, help="Source manifest JSON.")
    verify.add_argument("--target", required=True, help="Target manifest JSON.")
    verify.add_argument("--output", default="-", help="JSON output path, or - for stdout.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "audit":
            if args.large_file_threshold_mb <= 0:
                raise ValueError("--large-file-threshold-mb must be greater than zero")
            payload = audit_workspace(
                args.workspace,
                scan_absolute_paths=not args.no_absolute_path_scan,
                large_file_threshold_bytes=int(args.large_file_threshold_mb * 1024 * 1024),
                sensitive_paths=args.sensitive_path,
                sensitive_globs=args.sensitive_glob,
                compromised_credential_labels=args.compromised_credential_label,
                codex_home=args.codex_home,
            )
            _write_json(payload, args.output)
            return 0
        if args.command == "pack":
            receipt = create_handoff_package(
                args.workspace,
                args.output_dir,
                objective=args.objective,
                next_action=args.next_action,
                non_goals=args.non_goal,
                validation_file=args.validation_file,
                required_skills=args.required_skill,
                required_plugins=args.required_plugin,
                required_docs=args.required_doc,
                encrypted_secret_archive=args.encrypted_secret_archive,
                confirm_secret_archive_encrypted=args.confirm_secret_archive_encrypted,
                approve_tracked_data_review=args.approve_tracked_data_review,
                sensitive_paths=args.sensitive_path,
                sensitive_globs=args.sensitive_glob,
                compromised_credential_labels=args.compromised_credential_label,
                codex_home=args.codex_home,
            )
            _write_json(receipt, "-")
            return 0
        if args.command == "restore":
            report = restore_handoff_package(
                args.receipt,
                args.target,
                output_dir=args.output_dir,
                codex_home=args.codex_home,
            )
            _write_json(report, "-")
            return 0 if report["status"] == "restored_and_manifest_match" else 1
        if args.command == "verify":
            report = compare_manifests(_load_json(args.source), _load_json(args.target))
            _write_json(report, args.output)
            return {"match": 0, "match_with_warnings": 0, "mismatch": 1}.get(
                report["status"], 2
            )
        raise ValueError(f"Unsupported command: {args.command}")
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
