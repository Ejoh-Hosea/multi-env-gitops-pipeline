#!/usr/bin/env bash
# Convenience wrapper around the promote.yaml GitHub Actions workflow, so
# engineers don't need to remember the `gh workflow run` syntax.
#
# Usage: ./scripts/promote.sh staging abcd1234
#        ./scripts/promote.sh prod    abcd1234
set -euo pipefail

TARGET_ENV="${1:?usage: promote.sh <staging|prod> <image_tag>}"
IMAGE_TAG="${2:?usage: promote.sh <staging|prod> <image_tag>}"

if [[ "${TARGET_ENV}" != "staging" && "${TARGET_ENV}" != "prod" ]]; then
  echo "target_env must be 'staging' or 'prod'" >&2
  exit 1
fi

echo ">> Requesting promotion of ${IMAGE_TAG} to ${TARGET_ENV}..."
gh workflow run promote.yaml -f target_env="${TARGET_ENV}" -f image_tag="${IMAGE_TAG}"

echo ">> Promotion PR will appear shortly:"
echo "   gh pr list --label promotion"
