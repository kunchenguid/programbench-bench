#!/usr/bin/env python3
"""Idempotently apply local patches to the vendored programbench. Run after
re-creating cache/pb-venv. See apply-disk-cleanup-patches.sh.

Patches:
  1. programbench/container.py: remove_image() retries on transient docker
     busy/lock failures and logs warnings on permanent failure. Stock
     swallows all errors silently, which lets compiled images leak.
  2. programbench/container.py: ContainerEnvironment.execute() does an
     in-container SIGKILL sweep on host-side TimeoutExpired. Stock only
     SIGKILLs the host `docker exec` CLI, leaving the test process inside
     the container alive (orphaned). For hang-prone tasks (hwatch, chroma,
     jp2a, figlet, ...) this means the next docker exec also hangs until
     container teardown.
  3. programbench/eval/eval.py: in SingleEvaluator.run()'s finally block,
     also rmi the base `programbench/<task>:<image_tag>` image (disk M3).
  4. programbench/eval/eval.py: per-instance run_tests timeout override
     plus a lowered default (900s vs stock 3600s). Catches unknown-future
     hang-prone tasks 4x faster without needing to enumerate them all.
  5. programbench/container.py: _stream_tar_in() strips macOS AppleDouble
     `._*` files after extraction. Submission tars built on an APFS host
     carry `._*` resource-fork entries that the container's Linux tar
     materializes; java's `find -name '*.java' | javac` then compiles the
     binary `._Main.java` -> compile_failed across the whole java arm.
  6. programbench/container.py: _stream_tar_in() tar gets `--overwrite
     --recursive-unlink` so an incoming entry can replace an existing path
     of CONFLICTING TYPE. Without it, when the submission's compiled `build`
     dir collides with the test fixture's `build` file, GNU tar aborts the
     whole stream with "tar: build: Cannot open: File exists" -> RuntimeError
     -> no eval.json (hit tomnomnom__gron / guumaster__hostctl for py+java
     in codex-pilot-2). Added 2026-06-01.
"""
from __future__ import annotations

import sys
from pathlib import Path

PATCH_MARKER = "LOCAL PATCH (programbench-bench)"

CONTAINER_OLD = '''def remove_image(image_ref: str, *, executable: str = "docker") -> None:
    """Best-effort image removal."""
    try:
        subprocess.run(
            [executable, "rmi", "-f", image_ref],
            capture_output=True,
            timeout=60,
        )
    except Exception:
        pass'''

CONTAINER_NEW = '''def remove_image(image_ref: str, *, executable: str = "docker") -> None:
    """Best-effort image removal.

    LOCAL PATCH (programbench-bench): retries once on transient docker
    busy/lock failures and logs a warning on permanent failure. Untreated,
    the silent swallow lets compiled images leak and fill disk during long
    eval runs.
    """
    import time
    for attempt in (1, 2):
        try:
            result = subprocess.run(
                [executable, "rmi", "-f", image_ref],
                capture_output=True,
                timeout=60,
            )
            if result.returncode == 0:
                return
            err = (result.stderr or b"").decode("utf-8", "replace").strip()
            if "No such image" in err:
                return  # already gone
            if attempt == 1:
                log.warning("remove_image(%s) failed (attempt 1): %s; retrying", image_ref, err[:200])
                time.sleep(2)
                continue
            log.warning("remove_image(%s) failed after retry: %s", image_ref, err[:200])
            return
        except Exception as e:
            log.warning("remove_image(%s) raised: %s", image_ref, e)
            return'''

EXECUTE_OLD = '''        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            output = result.stdout + result.stderr
            return {
                "output": output,
                "returncode": result.returncode,
                "exception_info": "",
            }
        except subprocess.TimeoutExpired:
            return {
                "output": "",
                "returncode": -1,
                "exception_info": f"Command timed out after {timeout}s",
            }'''

EXECUTE_NEW = '''        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            output = result.stdout + result.stderr
            return {
                "output": output,
                "returncode": result.returncode,
                "exception_info": "",
            }
        except subprocess.TimeoutExpired:
            # LOCAL PATCH (programbench-bench): host-side TimeoutExpired sends
            # SIGKILL only to the local `docker exec` CLI; processes spawned
            # inside the container keep running (the container itself was
            # started with sleep-as-PID-1 and stays up). For hang-prone tasks
            # this leaves zombies that chew CPU during retries and prevent
            # subsequent docker exec calls from completing. Sweep them by
            # SIGKILL-ing every non-PID-1 process inside the container.
            try:
                subprocess.run(
                    [
                        self.executable,
                        "exec",
                        self.container_id,
                        "bash",
                        "-c",
                        "kill -KILL -1 2>/dev/null; sleep 0.2; kill -KILL -1 2>/dev/null; true",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
            except Exception as _e:
                log.warning("in-container teardown after timeout failed: %s", _e)
            return {
                "output": "",
                "returncode": -1,
                "exception_info": f"Command timed out after {timeout}s",
            }'''

EVAL_OLD = '''        finally:
            if compile_env is not None:
                compile_env.cleanup()
            if committed_image is not None:
                remove_image(committed_image, executable=DOCKER_EXECUTABLE)'''

EVAL_NEW = '''        finally:
            if compile_env is not None:
                compile_env.cleanup()
            if committed_image is not None:
                remove_image(committed_image, executable=DOCKER_EXECUTABLE)
            # LOCAL PATCH (programbench-bench): demand-based eviction of the
            # base `programbench/<task>:<image_tag>` image.
            #
            # Background: when the same set of task images is re-used by
            # multiple arms (per-language-evaluation pipeline pulls the same
            # 200 images for each of 8 arms), eagerly evicting on every eval
            # causes the next arm to re-pull and exhausts Docker Hub's rate
            # limit (429s). Keeping every image forever bloats disk past
            # available capacity (~1.2 TB peak for 200 tasks).
            #
            # Compromise: only evict when free disk drops below a threshold
            # (default 30 GB), and only the image whose eval just finished
            # (oldest-recently-used proxy). This lets the working set live
            # cached across arms while disk is healthy, and yields space
            # gracefully under pressure.
            import shutil as _shutil
            import os as _os
            free_bytes = _shutil.disk_usage("/").free
            threshold_gb = float(_os.environ.get("PB_DISK_EVICT_GB", "30"))
            base_image = f"{self.image_name}:{self.image_tag}"
            if (not base_image.startswith("programbench-compiled/")
                    and free_bytes < threshold_gb * (1 << 30)):
                log.warning(
                    "eviction triggered: free=%.1f GB < threshold=%.1f GB; "
                    "removing %s",
                    free_bytes / (1 << 30), threshold_gb, base_image,
                )
                remove_image(base_image, executable=DOCKER_EXECUTABLE)'''

RUN_TESTS_OLD = '''            self._run_step(
                run_cmd,
                env=env,
                log_buf=log_buf,
                step_name="run_tests",
                accept_failure=True,
                timeout=3600,
            )
            xml = self._copy_file_from_container(
                env=env,
                log_buf=log_buf,
                container_path=f"{WORKSPACE_DIR}/eval/results.xml",
                step_name="results_read",
                timeout=60,
            )
            log_buf[-1]["branch"] = branch
            return xml'''

RUN_TESTS_NEW = '''            # LOCAL PATCH (programbench-bench): per-instance run_tests timeout
            # override + lowered default + fast-fail to results_read_failed.
            #
            # Default lowered from 3600s to 900s. Rationale: many programbench
            # tasks are CLI tools (watchers, TUIs, network listeners) whose
            # tests spawn subprocesses that don't terminate cleanly on
            # pytest-timeout SIGALRM. The 3600s stock + retry wastes 2hr per
            # hang task per arm. Legit baselines for known-slow tasks top out
            # at ~8 min (xsv 8.3, i3-style 7.1, srgn 5.5); 900s gives ~2x
            # margin. The companion patch in container.py.execute() sweeps the
            # in-container process tree on timeout, preventing zombies.
            #
            # Per-instance entries below override the default for tasks where
            # eval naturally takes longer than 900s OR where the hang signature
            # is well-known and we want a tighter cap.
            import os as _os
            _default_to = int(_os.environ.get("PB_RUN_TESTS_TIMEOUT_SEC", "900"))
            _per_instance = {
                "alecthomas__chroma.8d04def": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_CHROMA_SEC", "300")
                ),
                # srgn baseline ~5.5 min, i3-style baseline ~7.1 min. Both
                # repeatedly hang in some arms (results_read_failed). 1200s
                # ceiling bounds hang waste to 20 min instead of 60 while
                # leaving ~3x margin over baseline for legitimate eval.
                "alexpovel__srgn.89f943b": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_SRGN_SEC", "1200")
                ),
                "altdesktop__i3-style.f93821b": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_I3STYLE_SEC", "1200")
                ),
                # xsv baseline ~8.3 min, oranda observed hung to 1h.
                # 1200s ceiling = ~2.4x baseline margin for xsv.
                "burntsushi__xsv.f430466": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_XSV_SEC", "1200")
                ),
                "axodotdev__oranda.27d60c7": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_ORANDA_SEC", "1200")
                ),
                "ekzhang__bore.8e059cd": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_BORE_SEC", "1200")
                ),
                "eradman__entr.8e2e8b4": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_ENTR_SEC", "1200")
                ),
                "kyoheiu__felix.95df390": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_FELIX_SEC", "1200")
                ),
                # Discovered during codex-pilot-1 resume (2026-05-22/23). All
                # exhibit watcher/TUI/infinite-loop hang patterns. 600s caps
                # them while remaining well above any realistic eval (none has
                # a known good baseline since they always hang).
                "blacknon__hwatch.edfcb62": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_HWATCH_SEC", "600")
                ),
                "cslarsen__jp2a.61d205f": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_JP2A_SEC", "600")
                ),
                "cmatsuoka__figlet.202a0a8": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_FIGLET_SEC", "600")
                ),
                # BLOCKLISTED structurally-broken tasks (codex-pilot-2,
                # 2026-06-02). not_run identical across arms AND unchanged
                # 300s->6h => task defect, not capability/timeout signal.
                # Dropped from REPORTING (analyze.py BLOCKLIST). hyperfine
                # balloons memory -> short cap fires before the OOM-wedge;
                # pixterm/silver_searcher hang on a fixed branch subset. 60s
                # caps them fast since their scores are dropped anyway.
                "sharkdp__hyperfine.327d5f4": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_HYPERFINE_SEC", "60")
                ),
                "eliukblau__pixterm.1a93fd5": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_PIXTERM_SEC", "60")
                ),
                "ggreer__the_silver_searcher.a61f178": int(
                    _os.environ.get("PB_RUN_TESTS_TIMEOUT_AG_SEC", "60")
                ),
            }
            _to = _per_instance.get(self.instance_id, _default_to)
            _r = self._run_step(
                run_cmd,
                env=env,
                log_buf=log_buf,
                step_name="run_tests",
                accept_failure=True,
                timeout=_to,
            )
            if _r.get("returncode") == -1:
                log.warning(
                    "[%s] branch %s: run_tests timed out after %ds; "
                    "skipping results_read",
                    self.instance_id or "?", branch, _to,
                )
                raise EvalStepError(
                    "results_read_failed",
                    f"run_tests timed out after {_to}s; results.xml not produced",
                )
            xml = self._copy_file_from_container(
                env=env,
                log_buf=log_buf,
                container_path=f"{WORKSPACE_DIR}/eval/results.xml",
                step_name="results_read",
                timeout=60,
            )
            log_buf[-1]["branch"] = branch
            return xml'''


APPLEDOUBLE_OLD = '''            if cp.returncode != 0:
                raise RuntimeError(f"tar stream into container failed: {cp.stderr.strip()}")'''

APPLEDOUBLE_NEW = '''            if cp.returncode != 0:  # LOCAL PATCH (programbench-bench): strip ._* AppleDouble below
                raise RuntimeError(f"tar stream into container failed: {cp.stderr.strip()}")

        # macOS submission tars (run-codex.sh on an APFS host) carry AppleDouble
        # `._*` resource-fork entries that the container's Linux tar materializes
        # as real files. Java's `find src/main/java -name '*.java' | javac` then
        # compiles `._Main.java` (binary, full of NUL bytes) -> compile_failed
        # across the whole java arm (other langs' builds ignore `._*`). They are
        # never real sources, so delete them post-extraction for every arm.
        # Permanent upstream fix would be COPYFILE_DISABLE=1 when run-codex.sh tars.
        subprocess.run(
            [self.executable, "exec", self.container_id,
             "find", container_path, "-name", "._*", "-delete"],
            capture_output=True, text=True, timeout=60,
        )'''


TAROVERWRITE_OLD = '''        tar_flags = "-xzf" if compressed else "-xf"
        cmd = [self.executable, "exec", "-i", self.container_id, "tar", "-C", container_path, tar_flags, "-"]'''

TAROVERWRITE_NEW = '''        tar_flags = "-xzf" if compressed else "-xf"
        # LOCAL PATCH (programbench-bench): --overwrite --recursive-unlink so an
        # incoming entry replaces an existing path of CONFLICTING TYPE (e.g. the
        # test fixture's `build` file over the submission's compiled `build` dir).
        # Without these, GNU tar aborts the whole stream with
        # "tar: build: Cannot open: File exists" -> RuntimeError -> no eval.json
        # (hit by tomnomnom__gron / guumaster__hostctl for python+java arms).
        cmd = [self.executable, "exec", "-i", self.container_id, "tar", "-C", container_path,
               "--overwrite", "--recursive-unlink", tar_flags, "-"]'''


def patch(path: Path, old: str, new: str, label: str, sentinel: str) -> bool:
    """Apply a text patch idempotently.

    `sentinel` MUST be a substring that appears ONLY in `new` (the patched
    form), never in stock upstream. The previous detection used `new[:80]`,
    but several patches wrap stock code so their first 80 chars are stock
    text that is always present - once any sibling patch wrote PATCH_MARKER
    into the same file, those checks false-positived as "already patched"
    and silently skipped applying. (This masked the execute() SIGKILL-sweep
    patch on the 1.0.2 upgrade, 2026-05-26.) A unique per-patch sentinel
    fixes that. Note `old` can be a substring of `new` (we wrap stock code),
    so `old in src` is NOT a reliable "unpatched" signal - only the sentinel
    is authoritative.
    """
    src = path.read_text()
    if sentinel in src:
        print(f"[skip] {label}: already patched")
        return False
    if old not in src:
        print(f"[error] {label}: stock text not found in {path} - upstream changed?", file=sys.stderr)
        return False
    path.write_text(src.replace(old, new))
    print(f"[ok]   {label}: patched {path}")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: _apply_patches.py <path-to-vendored-programbench>", file=sys.stderr)
        return 2
    pb = Path(sys.argv[1])
    if not (pb / "container.py").exists():
        print(f"error: {pb} does not look like a vendored programbench", file=sys.stderr)
        return 2
    patch(pb / "container.py", CONTAINER_OLD, CONTAINER_NEW, "container.py remove_image",
          sentinel="retries once on transient docker")
    patch(pb / "container.py", EXECUTE_OLD, EXECUTE_NEW, "container.py execute() in-container kill on timeout",
          sentinel="in-container teardown after timeout failed")
    patch(pb / "eval" / "eval.py", EVAL_OLD, EVAL_NEW, "eval/eval.py finally cleanup",
          sentinel="demand-based eviction of the")
    patch(pb / "eval" / "eval.py", RUN_TESTS_OLD, RUN_TESTS_NEW, "eval/eval.py run_tests timeout",
          sentinel="per-instance run_tests timeout")
    patch(pb / "container.py", APPLEDOUBLE_OLD, APPLEDOUBLE_NEW, "container.py strip macOS AppleDouble ._* on tar extract",
          sentinel="strip ._* AppleDouble below")
    patch(pb / "container.py", TAROVERWRITE_OLD, TAROVERWRITE_NEW, "container.py tar --overwrite --recursive-unlink on stream-in",
          sentinel="recursive-unlink")
    return 0


if __name__ == "__main__":
    sys.exit(main())
