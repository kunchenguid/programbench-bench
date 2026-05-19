#!/usr/bin/env python3
"""Drop-in wrapper around `programbench eval` that mounts our per-language
deps volumes and the all-langs toolkit into every eval container.

This exists because programbench's stock eval container is the upstream
`programbench/<task>:task` image, which only carries C/Rust/Go/Python/Perl
toolchains. Per-language-evaluation arms for JS/TS/Ruby/Java need their
runtimes installed; agents in those arms also depend on vendored deps
volumes. Rather than fork programbench or build 200 per-task derived
images, we monkey-patch the (empty by default)
`programbench.constants.DOCKER_RUN_ARGS` so every eval container gets the
extra `-v` mounts.

For lang-* arms, agent compile.sh adds /opt/all-langs/bin to PATH (and
JAVA_HOME / GEM_PATH where relevant). For non-lang arms the extra mounts
are inert.

The wrapper is RESILIENT: any docker volume that doesn't exist on this
host is silently skipped. This means it's safe to run as the universal
scorer even on a fresh machine where the lang infra hasn't been built.

Usage: identical to `programbench` - just exec this script in place of it.
"""
import subprocess
import sys

import programbench.constants

# (volume_name, container_mount_path)
# pb-toolkit2 (Ubuntu-native node/jdk/ruby) is the codex-pilot-2 toolkit; the
# pilot-1 pb-all-langs-toolkit (debian) stays for pilot-1 re-evals. Both are
# inert unless a submission's compile.sh references their mount path, so mounting
# both is safe. pilot-2 setup.sh references /opt/tk2 (+ /opt/deps/<lang>).
_CANDIDATE_VOLUMES = [
    ("pb-toolkit2",          "/opt/tk2"),
    ("pb-all-langs-toolkit", "/opt/all-langs"),
    ("pb-deps-go",           "/opt/deps/go"),
    ("pb-deps-js",           "/opt/deps/js"),
    ("pb-deps-ts",           "/opt/deps/ts"),
    ("pb-deps-ruby",         "/opt/deps/ruby"),
    ("pb-deps-java",         "/opt/deps/java"),
    ("pb-deps-python",       "/opt/deps/python"),
    ("pb-deps-rust",         "/opt/deps/rust"),
]


def _volume_exists(name: str) -> bool:
    """True if a docker named volume with `name` exists on this host."""
    result = subprocess.run(
        ["docker", "volume", "inspect", name],
        capture_output=True, text=True, check=False,
    )
    return result.returncode == 0


def _build_mount_args() -> list[str]:
    args: list[str] = []
    for vol, mnt in _CANDIDATE_VOLUMES:
        if _volume_exists(vol):
            args += ["-v", f"{vol}:{mnt}:ro"]
    return args


def main() -> None:
    extra = _build_mount_args()
    # Append rather than replace so any pre-existing settings (none in
    # stock programbench) are preserved.
    programbench.constants.DOCKER_RUN_ARGS = [
        *programbench.constants.DOCKER_RUN_ARGS,
        *extra,
    ]
    if extra:
        mounted = [m.split(":")[1] for m in extra if not m.startswith("-")]
        sys.stderr.write(f"[score-with-toolkit] mounting volumes: {mounted}\n")
    else:
        sys.stderr.write("[score-with-toolkit] no pb-deps-* or pb-all-langs-toolkit volumes present; running stock programbench eval\n")

    from programbench.cli.main import app
    app()


if __name__ == "__main__":
    main()
