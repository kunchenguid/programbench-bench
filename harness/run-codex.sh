#!/usr/bin/env bash
# Run one ProgramBench task with the OpenAI Codex CLI as the agent.
#
# Design parallel to harness/run.sh (the Claude Code runner). The two files
# duplicate scaffolding intentionally — option (a) from the proto plan — so
# that the Claude arm stays bit-for-bit untouched while the codex arm
# develops. Once the codex arm stabilizes we can consider folding both into
# a single dispatcher driven by arms/<arm>/image + arms/<arm>/entrypoint.
#
# Topology (same as run.sh):
#   pb-agent-net (--internal)   — agent has no external connectivity
#   pb-proxy-net                — proxy bridges agent-net and outside
#   cleanroom (--network none)  — separate, fully isolated
#   agent  -> HTTPS_PROXY=proxy:8888 -> proxy -> {api.openai.com,
#                                                chatgpt.com,
#                                                auth.openai.com,
#                                                ab.chatgpt.com}
#   agent  -> docker.sock (host) -> docker exec/cp into cleanroom
#
# Auth: requires a populated ~/.codex/auth.json on the host (run
# `codex login` once). The file is bind-mounted read-only into the agent
# container at $CODEX_HOME/auth.json (/home/node/.codex/auth.json).
#
# Usage: run-codex.sh --arm <name> --task <id> [--run-name N] [--budget USD]
#                     [--model M] [--keep-image] [--rebuild]

set -euo pipefail

ARM="" TASK=""
RUN_NAME="${PB_RUN_NAME:-default}"
BUDGET="${PB_BUDGET_USD:-50}"     # informational; codex has no built-in budget
MODEL="${PB_MODEL:-gpt-5.5}"
KEEP_IMAGE=0
REBUILD=0
TIMEOUT_SEC="${PB_TIMEOUT_SEC:-7200}"
IDLE_KILL_SEC="${PB_IDLE_KILL_SEC:-180}"
PRERESULT_IDLE_SEC="${PB_PRERESULT_IDLE_SEC:-900}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm) ARM="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --run-name) RUN_NAME="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --keep-image) KEEP_IMAGE=1; shift 1 ;;
    --rebuild) REBUILD=1; shift 1 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --idle-kill) IDLE_KILL_SEC="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ARM"  ]] && { echo "missing --arm"  >&2; exit 2; }
[[ -z "$TASK" ]] && { echo "missing --task" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$REPO/arms/$ARM" ]] || { echo "arm not found: $ARM" >&2; exit 2; }

CODEX_AUTH_HOST="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
[[ -f "$CODEX_AUTH_HOST" ]] || {
  echo "missing $CODEX_AUTH_HOST" >&2
  echo "Run 'codex login' on the host first." >&2
  exit 2
}

# PB_PILOT2=1 selects the codex-pilot-2 topology: the agent cleanroom IS the
# per-task `:task` eval image (Ubuntu 22.04, ships gcc/rust/go/python natively),
# instead of pilot-1's `:task_cleanroom` overlaid onto a debian `pb/clean-lang-*`
# base. This makes cleanroom == eval by construction (see plans/codex-pilot-2.md).
PB_PILOT2="${PB_PILOT2:-0}"
if [[ "$PB_PILOT2" == "1" ]]; then
  IMAGE="programbench/${TASK//__/_1776_}:task"
else
  IMAGE="programbench/${TASK//__/_1776_}:task_cleanroom"
fi
SUFFIX="${ARM}-${TASK//[^a-zA-Z0-9]/-}-$$"
CLEANROOM="pb-clean-$SUFFIX"
PROXY="pb-proxy-$SUFFIX"
AGENT="pb-agent-$SUFFIX"
NET_INTERNAL="pb-agent-net-$SUFFIX"
NET_BRIDGE="pb-proxy-net-$SUFFIX"

RUN_OUT="$REPO/runs/$RUN_NAME/$ARM/$TASK"
LOG_OUT="$REPO/logs/$RUN_NAME/$ARM/$TASK"
mkdir -p "$RUN_OUT" "$LOG_OUT"

cleanup() {
  set +e
  docker rm -f "$AGENT" "$PROXY" "$CLEANROOM" >/dev/null 2>&1
  docker network rm "$NET_INTERNAL" "$NET_BRIDGE" >/dev/null 2>&1
}
trap cleanup EXIT

echo "[sandbox-codex] task=$TASK arm=$ARM run=$RUN_NAME budget=\$$BUDGET keep_image=$KEEP_IMAGE model=$MODEL"

# --- Build images (cached) ---
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/codex:latest >/dev/null 2>&1; then
  echo "[sandbox-codex] building pb/codex (this can take a minute)..."
  docker build --platform linux/amd64 -t pb/codex:latest -f "$REPO/harness/sandbox/Dockerfile.codex" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-codex.log" 2>&1
fi
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/proxy:latest >/dev/null 2>&1; then
  echo "[sandbox-codex] building pb/proxy..."
  docker build --platform linux/amd64 -t pb/proxy:latest -f "$REPO/harness/sandbox/Dockerfile.proxy" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-proxy.log" 2>&1
fi

# --- Networks ---
docker network create --internal "$NET_INTERNAL" >/dev/null
docker network create "$NET_BRIDGE" >/dev/null

# --- Cleanroom ---
# For most arms the cleanroom IS the upstream programbench/<task>:task image.
# For per-language-evaluation arms (codex-lang-<X>) we instead start the
# cleanroom from pb/clean-lang-<X>:latest (which carries only the mandated
# toolchain + a deps volume mount) and overlay /workspace contents from
# the upstream image. See plans/per-language-evaluation.md for rationale.
# Skip pull when image is already local. `docker pull` would phone home to
# check the manifest, which counts against Docker Hub's rate limit even on
# a cache hit. With our pipeline pulling the same task images across 8 arms,
# that adds up fast (we hit 429s on the JS arm and on TS scoring after this
# bit was unconditional).
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[sandbox-codex] cleanroom image $IMAGE already local; skipping pull"
  echo "image cached locally; pull skipped" > "$LOG_OUT/docker-pull.log"
else
  echo "[sandbox-codex] pulling cleanroom image $IMAGE"
  docker pull --platform linux/amd64 "$IMAGE" >"$LOG_OUT/docker-pull.log" 2>&1
fi

if [[ "$PB_PILOT2" == "1" ]]; then
  # ===== codex-pilot-2 topology =====
  # Cleanroom IS the `:task` eval image. Mount the per-arm toolchain volumes
  # at the SAME paths the eval mounts them (so cleanroom == eval byte-for-byte),
  # start the container, then run the arm's setup.sh (activation: PATH +
  # offline package config + toolkit symlinks; NO dpkg). The very same
  # setup.sh is injected as the eval compile-prelude below, so both sides are
  # configured identically. For mandated arms we additionally neutralize the
  # other languages' toolchains in the cleanroom (mandate integrity).
  #
  # `:task` natively ships gcc/rust/go/python3.10/perl, so c/rust/go/python
  # need no toolkit volume - only their deps volume for offline packages.
  # js/ts/ruby/java + codex-free pull node/ruby/jdk from the Ubuntu-native
  # pb-toolkit2 volume (the old debian pb-all-langs-toolkit segfaults here).
  P2_MOUNTS=()
  p2_mount_vol() {  # name mountpoint  (skip silently if volume absent? no - hard error for required)
    local v="$1" m="$2"
    docker volume inspect "$v" >/dev/null 2>&1 || {
      echo "[sandbox-codex] error: required volume $v missing for arm $ARM" >&2; exit 3; }
    P2_MOUNTS+=(-v "${v}:${m}:ro")
  }
  P2_KEEPLANG=""   # for mandated arms, the one language to keep; "" = free (keep all)
  case "$ARM" in
    codex-free|codex-free-tdd)
      # Free language choice (all toolchains). codex-free-tdd is codex-free +
      # the test-driven-development skill (shipped in arms/codex-free-tdd/skills/,
      # installed into $CODEX_HOME/skills by entrypoint-codex.sh); its topology
      # is identical to codex-free, so it shares this branch.
      p2_mount_vol pb-toolkit2 /opt/tk2
      for _l in rust go python js ts ruby java; do p2_mount_vol "pb-deps-${_l}" "/opt/deps/${_l}"; done
      ;;
    codex-lang-c)      P2_KEEPLANG=c ;;
    codex-lang-rust)   P2_KEEPLANG=rust;   p2_mount_vol pb-deps-rust   /opt/deps/rust ;;
    codex-lang-go)     P2_KEEPLANG=go;     p2_mount_vol pb-deps-go     /opt/deps/go ;;
    codex-lang-python) P2_KEEPLANG=python; p2_mount_vol pb-deps-python /opt/deps/python ;;
    codex-lang-js)     P2_KEEPLANG=js;     p2_mount_vol pb-toolkit2 /opt/tk2; p2_mount_vol pb-deps-js   /opt/deps/js ;;
    codex-lang-ts)     P2_KEEPLANG=ts;     p2_mount_vol pb-toolkit2 /opt/tk2; p2_mount_vol pb-deps-ts   /opt/deps/ts ;;
    codex-lang-ruby)   P2_KEEPLANG=ruby;   p2_mount_vol pb-toolkit2 /opt/tk2; p2_mount_vol pb-deps-ruby /opt/deps/ruby ;;
    codex-lang-java)   P2_KEEPLANG=java;   p2_mount_vol pb-toolkit2 /opt/tk2; p2_mount_vol pb-deps-java /opt/deps/java ;;
    *) echo "[sandbox-codex] unsupported pilot-2 arm: $ARM" >&2; exit 3 ;;
  esac

  echo "[sandbox-codex] pilot-2 cleanroom from $IMAGE (keeplang=${P2_KEEPLANG:-free})"
  docker run -d --platform linux/amd64 \
    --name "$CLEANROOM" --network none --cpus 4 -w /workspace \
    "${P2_MOUNTS[@]}" \
    "$IMAGE" sleep 8h >"$LOG_OUT/cleanroom.log" 2>&1

  # Activation: run the arm's setup.sh inside the cleanroom (same script the
  # eval will run via the injected prelude).
  SETUP="$REPO/arms/$ARM/setup.sh"
  if [[ -f "$SETUP" ]]; then
    docker cp "$SETUP" "$CLEANROOM:/opt/pb-setup.sh" >/dev/null
    docker exec "$CLEANROOM" bash /opt/pb-setup.sh > "$LOG_OUT/cleanroom-setup.log" 2>&1 \
      || { echo "[sandbox-codex] WARN: setup.sh returned non-zero (see cleanroom-setup.log)" >&2; }
  fi

  # Mandate integrity: neutralize the other native languages in the cleanroom
  # (cleanroom-only; eval gets a fresh container and needs none of this).
  if [[ -n "$P2_KEEPLANG" ]]; then
    docker exec "$CLEANROOM" bash -c '
      keep="'"$P2_KEEPLANG"'"
      [ "$keep" = rust ]   || rm -rf /usr/local/cargo /usr/local/rustup /usr/local/bin/cargo /usr/local/bin/rustc /usr/local/bin/rustup 2>/dev/null
      [ "$keep" = go ]     || rm -rf /usr/local/go /usr/local/bin/go /usr/local/bin/gofmt 2>/dev/null
      if [ "$keep" != python ]; then
        for p in python3 python; do
          printf "#!/bin/sh\necho \"python is not available in the %s-mandated arm\" >&2\nexit 127\n" "$keep" > /usr/local/bin/$p
          chmod +x /usr/local/bin/$p
        done
      fi
      true' >> "$LOG_OUT/cleanroom-setup.log" 2>&1
  fi

  # Reference-tool strip (de-pollution re-run): if PB_STRIP_REF=1 and a per-task
  # strip script exists, remove the reference binary/libs/source/build-tree from
  # the cleanroom so the agent MUST genuinely reimplement (paper-faithful: keep
  # only the execute-only ./executable + docs). Cleanroom-only; eval unaffected.
  if [[ "${PB_STRIP_REF:-0}" == "1" && -f "$REPO/harness/strip-ref/$TASK.sh" ]]; then
    docker cp "$REPO/harness/strip-ref/$TASK.sh" "$CLEANROOM:/tmp/strip-ref.sh" >/dev/null
    docker exec "$CLEANROOM" bash /tmp/strip-ref.sh >> "$LOG_OUT/cleanroom-setup.log" 2>&1
    echo "[sandbox-codex] PB_STRIP_REF: stripped reference tool from cleanroom ($TASK)"
  elif [[ "${PB_STRIP_REF:-0}" == "1" ]]; then
    echo "[sandbox-codex] WARN: PB_STRIP_REF=1 but no strip script harness/strip-ref/$TASK.sh" >&2
  fi
  echo "[sandbox-codex] pilot-2 cleanroom ready (arm=$ARM)"

else
  # ===== codex-pilot-1 topology (unchanged) =====
LANG_OVERLAY=""
if [[ "$ARM" == codex-lang-* ]]; then
  LANG_OVERLAY="${ARM#codex-lang-}"
elif [[ "$ARM" == "codex-vanilla-clean" ]]; then
  # Fair free-choice control: same stripped-sandbox topology as the
  # mandated arms, but ALL toolchains present (pb/clean-lang-all) so the
  # agent's language choice is genuinely free. Removes the original
  # codex-vanilla arm's two advantages (system-binary wrapping + never
  # suffering the cleanroom-vs-eval env mismatch). See
  # memory:project_codex-pilot-1-env-confound.
  LANG_OVERLAY="all"
fi

if [[ -n "$LANG_OVERLAY" ]]; then
  LANG_IMAGE="pb/clean-lang-${LANG_OVERLAY}:latest"
  # Self-heal: if the lang base or per-lang image is missing (fresh checkout,
  # docker prune, machine wipe), build it on demand. The Dockerfiles are
  # checked in; persisting the built image is a docker-state detail we
  # cannot assume. Mirrors the pb/codex auto-build above.
  if ! docker image inspect pb/clean-lang-base:latest >/dev/null 2>&1; then
    echo "[sandbox-codex] building pb/clean-lang-base (one-time)..."
    docker build --platform linux/amd64 -t pb/clean-lang-base:latest \
      -f "$REPO/harness/sandbox/Dockerfile.clean-lang-base" "$REPO/harness/sandbox" \
      > "$LOG_OUT/build-clean-lang-base.log" 2>&1
  fi
  if ! docker image inspect "$LANG_IMAGE" >/dev/null 2>&1; then
    echo "[sandbox-codex] building $LANG_IMAGE (one-time)..."
    docker build --platform linux/amd64 -t "$LANG_IMAGE" \
      -f "$REPO/harness/sandbox/Dockerfile.clean-lang-${LANG_OVERLAY}" "$REPO/harness/sandbox" \
      > "$LOG_OUT/build-clean-lang-${LANG_OVERLAY}.log" 2>&1
  fi

  # Per-language deps volume. C has no separate volume (its 'deps' are dev
  # headers baked into the C image). Other languages each have one named
  # volume populated by harness/build-deps-volume-<lang>.sh.
  VOLUME_ARGS=()
  mount_deps() {
    local lang_name="$1"
    local volume_name="pb-deps-${lang_name}"
    docker volume inspect "$volume_name" >/dev/null 2>&1 || {
      echo "[sandbox-codex] error: $volume_name volume not present; run harness/build-deps-volume-${lang_name}.sh" >&2
      exit 3
    }
    VOLUME_ARGS=(-v "${volume_name}:/opt/deps/${lang_name}:ro")
  }
  case "$LANG_OVERLAY" in
    rust)   mount_deps rust   ;;
    python) mount_deps python ;;
    go)     mount_deps go     ;;
    js)     mount_deps js     ;;
    ts)     mount_deps ts     ;;
    ruby)   mount_deps ruby   ;;
    java)   mount_deps java   ;;
    c) : ;;  # C has no separate deps volume; dev headers are in the image
    all)
      # Free-choice clean arm: mount every language's deps volume so the
      # agent can resolve offline packages in whatever language it picks
      # (C needs none - its dev headers are baked into clean-lang-all).
      for _l in rust python go js ts ruby java; do
        _v="pb-deps-${_l}"
        docker volume inspect "$_v" >/dev/null 2>&1 || {
          echo "[sandbox-codex] error: $_v volume not present; run harness/build-deps-volume-${_l}.sh" >&2
          exit 3
        }
        VOLUME_ARGS+=(-v "${_v}:/opt/deps/${_l}:ro")
      done
      ;;
    *)
      echo "[sandbox-codex] unsupported language overlay: $LANG_OVERLAY" >&2
      exit 3
      ;;
  esac

  echo "[sandbox-codex] starting language cleanroom $LANG_IMAGE"
  docker run -d --platform linux/amd64 \
    --name "$CLEANROOM" --network none --cpus 4 -w /workspace \
    "${VOLUME_ARGS[@]}" \
    "$LANG_IMAGE" sleep 8h >"$LOG_OUT/cleanroom.log" 2>&1

  # Overlay /workspace contents from the upstream task image. docker create
  # (not run) avoids spinning a process; docker cp reads from created
  # containers. Tar pipe preserves mode + ownership, which is critical for
  # the executable's root:root --x--x--x anti-cheat (must stay execute-only,
  # not readable, after the overlay).
  UPSTREAM_TMP="${CLEANROOM}-upstream-tmp"
  docker create --platform linux/amd64 --name "$UPSTREAM_TMP" "$IMAGE" >/dev/null
  docker cp "$UPSTREAM_TMP:/workspace/." - \
    | docker exec -i "$CLEANROOM" tar -C /workspace -xpf - \
    || { echo "[sandbox-codex] /workspace overlay failed" >&2; docker rm "$UPSTREAM_TMP" >/dev/null 2>&1; exit 3; }
  docker rm "$UPSTREAM_TMP" >/dev/null

  echo "[sandbox-codex] /workspace overlay complete; cleanroom toolchain: $LANG_OVERLAY"
else
  docker run -d --platform linux/amd64 \
    --name "$CLEANROOM" --network none --cpus 4 -w /workspace \
    "$IMAGE" sleep 8h >"$LOG_OUT/cleanroom.log" 2>&1
fi
fi  # end PB_PILOT2 branch

# --- Proxy ---
docker run -d --platform linux/amd64 \
  --name "$PROXY" --network "$NET_BRIDGE" \
  pb/proxy:latest >"$LOG_OUT/proxy.log" 2>&1
docker network connect "$NET_INTERNAL" "$PROXY" --alias proxy

# --- Agent ---
# Bind-mount the Codex auth.json read-only at the path Codex expects inside
# the container ($CODEX_HOME/auth.json = /home/node/.codex/auth.json).
TRANSCRIPT="$LOG_OUT/transcript.jsonl"
docker run -d --platform linux/amd64 \
  --name "$AGENT" --network "$NET_INTERNAL" \
  -v "$REPO":/pb \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$CODEX_AUTH_HOST":/home/node/.codex/auth.json:ro \
  -e PB_REPO=/pb \
  -e PB_ARM="$ARM" \
  -e PB_TASK="$TASK" \
  -e PB_RUN_NAME="$RUN_NAME" \
  -e PB_BUDGET="$BUDGET" \
  -e PB_MODEL="$MODEL" \
  -e PB_CLEANROOM="$CLEANROOM" \
  -e CODEX_HOME=/home/node/.codex \
  -e HTTPS_PROXY="http://proxy:8888" \
  -e HTTP_PROXY="http://proxy:8888" \
  -e NO_PROXY="" \
  pb/codex:latest \
  >/dev/null 2>&1

# Watchdog (identical semantics to run.sh): kill if timeout exceeded, or if
# transcript stops growing past idle threshold. Codex emits JSONL "events"
# rather than Claude's `type:"result"` events, so we don't probe for that
# specific marker — we rely on the size-growth signal alone, which is
# strictly weaker but still catches frozen-child cases.
START_TS=$(date +%s)
LAST_GROW_TS=$START_TS
LAST_SIZE=0
while docker inspect -f '{{.State.Running}}' "$AGENT" 2>/dev/null | grep -q true; do
  sleep 10
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if (( ELAPSED >= TIMEOUT_SEC )); then
    echo "[sandbox-codex] timeout ${TIMEOUT_SEC}s reached; killing agent container" >&2
    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    break
  fi
  if [[ -f "$TRANSCRIPT" ]]; then
    SIZE=$(wc -c <"$TRANSCRIPT" 2>/dev/null || echo 0)
    if (( SIZE > LAST_SIZE )); then
      LAST_SIZE=$SIZE
      LAST_GROW_TS=$NOW
    fi
    IDLE=$((NOW - LAST_GROW_TS))
    # Pre-result-vs-post-result distinction collapses here because we don't
    # parse codex JSONL events; use the larger of the two thresholds.
    if (( IDLE >= PRERESULT_IDLE_SEC )); then
      echo "[sandbox-codex] transcript idle ${IDLE}s; killing agent container" >&2
      docker rm -f "$AGENT" >/dev/null 2>&1 || true
      break
    fi
  fi
done
echo "[sandbox-codex] agent container terminated"

# --- Extract submission from cleanroom ---
if docker exec -u agent "$CLEANROOM" test -f /workspace/submission.tar.gz; then
  docker cp "$CLEANROOM:/workspace/submission.tar.gz" "$RUN_OUT/submission.tar.gz"
  echo "[sandbox-codex] submission saved: $RUN_OUT/submission.tar.gz ($(wc -c < "$RUN_OUT/submission.tar.gz") bytes)"
else
  echo "[sandbox-codex] WARNING: no submission.tar.gz produced" >&2
  tar czf "$RUN_OUT/submission.tar.gz" -T /dev/null
fi

# --- Auto-prepend per-language compile.sh prelude ---
# For codex-lang-* arms, the evaluation runs in the upstream programbench
# cleanroom which doesn't have node/ruby/java natively and doesn't have our
# toolkit volumes mounted on PATH. Prepending the arm's compile-prelude.sh
# in front of the agent's compile.sh sets the env vars and (for ruby/java)
# dpkg-installs the missing toolchains from the staged .debs in
# /opt/all-langs/debs. This keeps orchestration prompts simpler since
# agents don't have to remember the toolkit-PATH boilerplate.
# pilot-2 injects the arm's setup.sh (the SAME activation script run in the
# cleanroom at start), so eval configures the toolchain identically. pilot-1
# injects compile-prelude.sh (the dpkg band-aids).
if [[ "$PB_PILOT2" == "1" ]]; then
  PRELUDE="$REPO/arms/$ARM/setup.sh"
else
  PRELUDE="$REPO/arms/$ARM/compile-prelude.sh"
fi
if [[ -f "$PRELUDE" ]] && [[ -s "$RUN_OUT/submission.tar.gz" ]]; then
  echo "[sandbox-codex] injecting compile-prelude.sh into submission"
  PREP_TMP="$(mktemp -d -t pb-prep-XXXX)"
  if tar -xzf "$RUN_OUT/submission.tar.gz" -C "$PREP_TMP" 2>/dev/null && [[ -f "$PREP_TMP/compile.sh" ]]; then
    # Preserve the agent's shebang line; sandwich the prelude between it
    # and the rest of the script. This guarantees `#!/bin/bash` (or
    # whatever) stays first - prepending raw bytes ahead of the shebang
    # would silently break execve.
    shebang="$(head -n1 "$PREP_TMP/compile.sh")"
    rest="$(tail -n +2 "$PREP_TMP/compile.sh")"
    {
      printf '%s\n' "$shebang"
      echo "# ===== compile-prelude (auto-injected by harness/run-codex.sh) ====="
      cat "$PRELUDE"
      echo "# ===== end compile-prelude ====="
      printf '%s\n' "$rest"
    } > "$PREP_TMP/compile.sh.new"
    mv "$PREP_TMP/compile.sh.new" "$PREP_TMP/compile.sh"
    chmod +x "$PREP_TMP/compile.sh"
    # COPYFILE_DISABLE=1: this re-tar runs on the macOS host, where BSD tar
    # otherwise emits an AppleDouble `._*` resource-fork companion for every
    # file. Those materialize in the Linux eval container and broke the java
    # arm's `find -name '*.java' | javac` (binary `._Foo.java` -> compile_failed).
    # patch #5 strips `._*` at eval extraction, but disabling it at the source
    # is the robust permanent fix and protects every arm. See AGENTS.md.
    (cd "$PREP_TMP" && COPYFILE_DISABLE=1 tar -czf "$RUN_OUT/submission.tar.gz" .)
  else
    echo "[sandbox-codex] WARN: submission has no compile.sh; skipping prelude inject" >&2
  fi
  rm -rf "$PREP_TMP"
fi

# --- Image prune (cleanroom; agent/proxy images stay cached) ---
docker rm -f "$CLEANROOM" >/dev/null 2>&1 || true
if [[ "$KEEP_IMAGE" -eq 0 ]]; then
  echo "[sandbox-codex] pruning cleanroom image $IMAGE"
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
else
  echo "[sandbox-codex] keeping cleanroom image $IMAGE (--keep-image)"
fi

echo "[sandbox-codex] done."
