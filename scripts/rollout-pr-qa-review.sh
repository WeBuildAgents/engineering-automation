#!/usr/bin/env bash
set -euo pipefail

ORG="veronicanegreiro-wba"
AUTOMATION_REPO="engineering-automation"
AUTOMATION_WORKFLOW_REF="main"
ROLLOUT_BRANCH="chore/add-pr-qa-review"
WORKFLOW_FILE_PATH=".github/workflows/pr-qa-review.yml"
BASE_SLACK_ENABLED="true"
BASE_SLACK_TITLE="PR QA Review"

SKIP_REPOS=(
  "$AUTOMATION_REPO"
)

ALLOWLIST_REPOS=(
  # "repo-one"
  # "repo-two"
)

contains_element() {
  local seeking="$1"
  shift
  local element
  for element in "$@"; do
    if [[ "$element" == "$seeking" ]]; then
      return 0
    fi
  done
  return 1
}

should_process_repo() {
  local repo="$1"

  if contains_element "$repo" "${SKIP_REPOS[@]}"; then
    return 1
  fi

  if [[ ${#ALLOWLIST_REPOS[@]} -gt 0 ]]; then
    contains_element "$repo" "${ALLOWLIST_REPOS[@]}"
    return $?
  fi

  return 0
}

create_workflow_file() {
  local target_file="$1"

  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
name: PR QA Review

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  qa-review:
    uses: ${ORG}/${AUTOMATION_REPO}/.github/workflows/reusable-pr-qa-review.yml@${AUTOMATION_WORKFLOW_REF}
    secrets: inherit
    with:
      slack_enabled: ${BASE_SLACK_ENABLED}
      slack_title: "${BASE_SLACK_TITLE}"
      max_diff_chars: 120000
EOF
}

WORKDIR="$(pwd)/mass-rollout-temp"
mkdir -p "$WORKDIR"

echo "Listing repositories from organization: $ORG"
mapfile -t REPOS < <(gh repo list "$ORG" --limit 500 --json name --jq '.[].name')

for REPO in "${REPOS[@]}"; do
  if ! should_process_repo "$REPO"; then
    echo "Skipping $REPO"
    continue
  fi

  FULL_REPO="${ORG}/${REPO}"
  TARGET_DIR="${WORKDIR}/${REPO}"

  echo "======================================"
  echo "Processing ${FULL_REPO}"
  echo "======================================"

  rm -rf "$TARGET_DIR"

  if ! gh repo clone "$FULL_REPO" "$TARGET_DIR" -- --quiet; then
    echo "Failed to clone ${FULL_REPO}. Skipping."
    continue
  fi

  cd "$TARGET_DIR"

  DEFAULT_BRANCH="$(gh repo view "$FULL_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')"
  [[ -z "$DEFAULT_BRANCH" || "$DEFAULT_BRANCH" == "null" ]] && DEFAULT_BRANCH="main"

  git checkout "$DEFAULT_BRANCH"
  git pull origin "$DEFAULT_BRANCH" --quiet

  if git ls-remote --exit-code --heads origin "$ROLLOUT_BRANCH" >/dev/null 2>&1; then
    echo "Branch ${ROLLOUT_BRANCH} already exists on remote for ${FULL_REPO}. Skipping."
    cd "$WORKDIR"
    continue
  fi

  git checkout -b "$ROLLOUT_BRANCH"

  if [[ -f "$WORKFLOW_FILE_PATH" ]]; then
    echo "${WORKFLOW_FILE_PATH} already exists in ${FULL_REPO}. Skipping to avoid overwrite."
    cd "$WORKDIR"
    continue
  fi

  create_workflow_file "$WORKFLOW_FILE_PATH"

  git add "$WORKFLOW_FILE_PATH"
  git commit -m "chore: add reusable PR QA review workflow"
  git push -u origin "$ROLLOUT_BRANCH"

  PR_BODY=$(cat <<EOF
## Summary
This PR adds the reusable PR QA review workflow wrapper.

## Changes
- adds \`${WORKFLOW_FILE_PATH}\`
- wires the repository to the centralized reusable workflow in \`${ORG}/${AUTOMATION_REPO}\`

## Notes
- review logic is centralized
- secrets are inherited from organization/repository configuration
EOF
)

  gh pr create \
    --repo "$FULL_REPO" \
    --base "$DEFAULT_BRANCH" \
    --head "$ROLLOUT_BRANCH" \
    --title "chore: add reusable PR QA review workflow" \
    --body "$PR_BODY"

  cd "$WORKDIR"
done

echo "Mass rollout finished."
