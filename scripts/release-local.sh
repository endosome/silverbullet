#!/usr/bin/env bash
# Build and publish a release from this machine, instead of from CI.
#
#   scripts/release-local.sh <version> [--docker] [--dry-run] [--skip-tests]
#
# Steps: bump version.ts/package.json (if needed) and commit, tag, run the
# vitest suite, cross-compile the server and `sb` for the selected targets, zip
# them with the asset names `sb upgrade` and the install scripts expect, and create the GitHub
# release. With --docker it also builds and pushes the slim and default images
# to ghcr.io/<owner>/silverbullet.
#
# Needs: `gh` logged in (repo scope; docker also needs write:packages, see
# `gh auth refresh -s write:packages`), rustup, node, zip, and the cross
# C compilers listed in .cargo/config.toml.
#
# Environment:
#   RELEASE_TARGETS  space separated subset of linux-x86_64 linux-aarch64
#                    linux-armv7 windows-x86_64 (default: all four).
#                    --docker needs linux-x86_64 and linux-aarch64; adding
#                    linux-armv7 also builds the arm/v7 slim image.
#
# The release commit carries [skip ci] so the push does not start a CI run.
set -euo pipefail

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

VERSION=""
DOCKER=0
DRY_RUN=0
SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --docker) DOCKER=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h | --help) usage ;;
    -*) echo "Unknown option $arg" >&2; usage ;;
    *)
      [ -z "$VERSION" ] || usage
      VERSION="$arg"
      ;;
  esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
  { echo "Version must look like 1.2.3" >&2; exit 1; }

cd "$(dirname "$0")/.."

declare -A TARGET_TRIPLE=(
  [linux-x86_64]=x86_64-unknown-linux-musl
  [linux-aarch64]=aarch64-unknown-linux-musl
  [linux-armv7]=armv7-unknown-linux-musleabihf
  [windows-x86_64]=x86_64-pc-windows-gnu
)
declare -A TARGET_CC=(
  [linux-x86_64]=musl-gcc
  [linux-aarch64]=aarch64-linux-gnu-gcc
  [linux-armv7]=arm-linux-gnueabihf-gcc
  [windows-x86_64]=x86_64-w64-mingw32-gcc
)
declare -A DOCKER_ARCH=(
  [linux-x86_64]=amd64
  [linux-aarch64]=arm64
  [linux-armv7]=arm
)
TARGETS=${RELEASE_TARGETS:-"linux-x86_64 linux-aarch64 linux-armv7 windows-x86_64"}

OUT=release-out
DOCKER_FILES=()

cleanup() {
  rm -rf "$OUT"
  [ ${#DOCKER_FILES[@]} -eq 0 ] || rm -f "${DOCKER_FILES[@]}"
}
trap cleanup EXIT

# --- Preflight: fail before changing anything --------------------------------
gh auth status >/dev/null
# Always the origin remote: with an upstream remote present, plain `gh` picks
# the upstream repository.
REPO=$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || { echo "origin is not a GitHub repository: $REPO" >&2; exit 1; }
OWNER=${REPO%%/*}
BRANCH=$(git symbolic-ref --short HEAD)

missing=()
for t in $TARGETS; do
  [ -n "${TARGET_TRIPLE[$t]:-}" ] || { echo "Unknown target $t" >&2; exit 1; }
  command -v "${TARGET_CC[$t]}" >/dev/null || missing+=("$t needs ${TARGET_CC[$t]}")
done
if [ ${#missing[@]} -gt 0 ]; then
  printf 'Missing cross compiler: %s\n' "${missing[@]}" >&2
  echo "Install them (see .cargo/config.toml) or narrow RELEASE_TARGETS." >&2
  exit 1
fi
if [ "$DOCKER" = 1 ]; then
  for t in linux-x86_64 linux-aarch64; do
    [[ " $TARGETS " == *" $t "* ]] || { echo "--docker needs target $t" >&2; exit 1; }
  done
  docker buildx version >/dev/null
fi
command -v zip >/dev/null || { echo "zip is required" >&2; exit 1; }
if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
  echo "Release $VERSION already exists on $REPO" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean" >&2
  exit 1
fi

# --- Version, commit, tag ------------------------------------------------
echo "Releasing $VERSION to $REPO from $BRANCH"
echo "export const version = \"$VERSION\";" > version.ts
npm version --no-git-tag-version --allow-same-version "$VERSION" >/dev/null
if [ -n "$(git status --porcelain)" ]; then
  git commit -qam "$VERSION [skip ci]"
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  [ "$(git rev-parse "$VERSION^{commit}")" = "$(git rev-parse HEAD)" ] || {
    echo "Tag $VERSION exists but is not at HEAD; move or delete it first" >&2
    exit 1
  }
else
  git tag "$VERSION"
fi

# --- Build -----------------------------------------------------------------------
# Tagged first on purpose: build/version.ts derives the embedded version from
# `git describe`, and a stale version.json would be reused.
rm -f version.json
mkdir -p "$OUT"
for t in $TARGETS; do rustup target add "${TARGET_TRIPLE[$t]}"; done
npm run build
npm run build:plug-compile

# After the build: the tests import the generated version.json.
if [ "$SKIP_TESTS" = 0 ]; then
  npx vitest run --maxWorkers=2
fi

for t in $TARGETS; do
  triple=${TARGET_TRIPLE[$t]}
  exe=""
  [ "$t" = windows-x86_64 ] && exe=".exe"
  cargo build --release -p silverbullet -p sb --target "$triple"
  for pair in "silverbullet:silverbullet-server-$t" "sb:sb-$t"; do
    bin=${pair%%:*}
    zipname=${pair##*:}.zip
    (cd "target/$triple/release" && zip -q "$OLDPWD/$OUT/$zipname" "$bin$exe")
  done
  if [ "$DOCKER" = 1 ] && [ -n "${DOCKER_ARCH[$t]:-}" ]; then
    cp "target/$triple/release/silverbullet" "silverbullet-${DOCKER_ARCH[$t]}"
    DOCKER_FILES+=("silverbullet-${DOCKER_ARCH[$t]}")
  fi
done
ls -l "$OUT"

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: built everything, not publishing"
  exit 0
fi

# --- Publish -----------------------------------------------------------------------
# Pushed only now, so a failed test or build leaves nothing on the remote.
git push origin "$BRANCH"
git push origin "refs/tags/$VERSION"
gh release create "$VERSION" -R "$REPO" --verify-tag --title "$VERSION" \
  --generate-notes \
  docs/CHANGELOG.md dist/plug-compile.js "$OUT"/*.zip

if [ "$DOCKER" = 1 ]; then
  IMAGE="ghcr.io/${OWNER,,}/silverbullet"
  gh auth token | docker login ghcr.io -u "$OWNER" --password-stdin
  slim_platforms=linux/amd64,linux/arm64
  [[ " $TARGETS " == *" linux-armv7 "* ]] && slim_platforms+=,linux/arm/v7
  docker buildx build --push --provenance=false \
    --platform "$slim_platforms" -f Dockerfile \
    -t "$IMAGE:$VERSION-slim" -t "$IMAGE:latest-slim" .
  # Chromium is not available on armv7, so the default image skips it.
  docker buildx build --push --provenance=false \
    --platform linux/amd64,linux/arm64 -f Dockerfile.runtime-api \
    --build-arg "BASE_IMAGE=$IMAGE:$VERSION-slim" \
    -t "$IMAGE:$VERSION" -t "$IMAGE:latest" \
    -t "$IMAGE:$VERSION-runtime-api" -t "$IMAGE:latest-runtime-api" .
fi

echo "Released $VERSION: https://github.com/$REPO/releases/tag/$VERSION"
