#!/usr/bin/env bash
# Build Swift pm binary (arm64 only) and create a tarball for Homebrew.
#
# Usage: ./scripts/build-release-tarball.sh <version>
#   version   e.g. 0.2.0
#
# Produces: project-manager-<version>.tar.gz containing project-manager-<version>/pm (arm64 binary)
# Run on Apple Silicon (or a Mac with arm64 toolchain) to build.
set -e

VERSION="${1:?Usage: $0 <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARBALL_NAME="project-manager-${VERSION}.tar.gz"
TARBALL_PATH="$ROOT/$TARBALL_NAME"
PM_BINARY="pm-swift/.build/arm64-apple-macosx/release/pm"

cd "$ROOT"

echo "==> Building Swift pm (release, arm64 only)"
cd pm-swift
swift build -c release --triple arm64-apple-macosx
cd "$ROOT"

if [[ ! -f "$PM_BINARY" ]]; then
  echo "Build did not produce $PM_BINARY" >&2
  exit 1
fi
if ! file "$PM_BINARY" | grep -q arm64; then
  echo "Expected arm64 binary but got: $(file "$PM_BINARY")" >&2
  exit 1
fi

echo "==> Create tarball $TARBALL_NAME"
rm -f "$TARBALL_PATH"
PREFIX="project-manager-${VERSION}"
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT
mkdir -p "$TMPDIR/$PREFIX"
cp "$PM_BINARY" "$TMPDIR/$PREFIX/pm"
tar -czf "$TARBALL_PATH" -C "$TMPDIR" "$PREFIX"

echo "==> Done. Tarball: $TARBALL_PATH"
echo "$TARBALL_PATH"
