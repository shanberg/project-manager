#!/usr/bin/env bash
# Build Swift pm binary and create a tarball for Homebrew.
#
# Usage: ./scripts/build-release-tarball.sh <version>
#   version   e.g. 0.2.0
#
# Produces: project-manager-<version>.tar.gz containing project-manager-<version>/pm (binary)
set -e

VERSION="${1:?Usage: $0 <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARBALL_NAME="project-manager-${VERSION}.tar.gz"
TARBALL_PATH="$ROOT/$TARBALL_NAME"

cd "$ROOT"

echo "==> Building Swift pm (release)"
cd pm-swift
swift build -c release
cd "$ROOT"

echo "==> Create tarball $TARBALL_NAME"
rm -f "$TARBALL_PATH"
PREFIX="project-manager-${VERSION}"
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT
mkdir -p "$TMPDIR/$PREFIX"
cp pm-swift/.build/release/pm "$TMPDIR/$PREFIX/"
tar -czf "$TARBALL_PATH" -C "$TMPDIR" "$PREFIX"

echo "==> Done. Tarball: $TARBALL_PATH"
echo "$TARBALL_PATH"
