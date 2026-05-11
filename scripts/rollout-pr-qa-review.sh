#!/usr/bin/env bash
set -euo pipefail

ORG="WeBuildAgents"
AUTOMATION_REPO="engineering-automation"
AUTOMATION_WORKFLOW_REF="main"
ROLLOUT_BRANCH="chore/add-qa-review-workflows"
BASE_SLACK_ENABLED="true"

SKIP_REPOS=(
  "$AUTOMATION_REPO"
)

ALLOWLIST_REPOS=(
  # "repo-one"
  # "repo-two"
)

PR_WORKFLOW_FILE_PATH=".github/workflows/pr-qa-review.yml"
COMMIT_WORKFLOW_FILE_PATH=".github/workflows/commit-qa-review.yml"

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

create_pr_workflow_file() {
  local target_file="$1"

  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
name: PR QA Review

on:
  pull_request:
    types: [opened, synchronize, reopened]

# Top-level permissions set the default for every job in this workflow.
# Some org/repo policies force a restrictive default for GITHUB_TOKEN
# (\`pull-requests: none\`); declaring the same permissions at the job level
# anchors the scope for the reusable workflow call.
permissions:
  contents: read
  pull-requests: write

jobs:
  qa-review:
    permissions:
      contents: read
      pull-requests: write
    uses: ${ORG}/${AUTOMATION_REPO}/.github/workflows/reusable-pr-qa-review.yml@${AUTOMATION_WORKFLOW_REF}
    secrets: inherit
    with:
      slack_enabled: ${BASE_SLACK_ENABLED}
      slack_title: "PR QA Review"
      # Inherits the reusable workflow default (400000) unless overridden.
      max_diff_chars: 400000
      fail_on_block: true
EOF
}

create_commit_workflow_file() {
  local target_file="$1"

  mkdir -p "$(dirname "$target_file")"

  cat > "$target_file" <<EOF
name: Commit QA Review

on:
  push:
    branches:
      - '**'

# The reusable workflow posts the review as a commit comment via
# \`repos.createCommitComment\`, which requires \`contents: write\`.
# Declare \`permissions:\` at both workflow and job level so restrictive
# org/repo defaults cannot demote the scope to \`contents: read\`.
permissions:
  contents: write
  pull-requests: read

jobs:
  commit-review:
    permissions:
      contents: write
      pull-requests: read
    uses: ${ORG}/${AUTOMATION_REPO}/.github/workflows/reusable-commit-qa-review.yml@${AUTOMATION_WORKFLOW_REF}
    secrets: inherit
    with:
      slack_enabled: ${BASE_SLACK_ENABLED}
      slack_title: "Commit QA Review"
      max_diff_chars: 400000
      fail_on_block: false
      skip_if_pr_open: true
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

  PR_ADDED=false
  COMMIT_ADDED=false

  if [[ -f "$PR_WORKFLOW_FILE_PATH" ]]; then
    echo "${PR_WORKFLOW_FILE_PATH} already exists in ${FULL_REPO}. Skipping PR workflow."
  else
    create_pr_workflow_file "$PR_WORKFLOW_FILE_PATH"
    git add "$PR_WORKFLOW_FILE_PATH"
    PR_ADDED=true
  fi

  if [[ -f "$COMMIT_WORKFLOW_FILE_PATH" ]]; then
    echo "${COMMIT_WORKFLOW_FILE_PATH} already exists in ${FULL_REPO}. Skipping commit workflow."
  else
    create_commit_workflow_file "$COMMIT_WORKFLOW_FILE_PATH"
    git add "$COMMIT_WORKFLOW_FILE_PATH"
    COMMIT_ADDED=true
  fi

  if [[ "$PR_ADDED" == "false" && "$COMMIT_ADDED" == "false" ]]; then
    echo "Nothing to add for ${FULL_REPO}. Skipping."
    cd "$WORKDIR"
    continue
  fi

  CHANGES_DESCRIPTION=""
  if [[ "$PR_ADDED" == "true" ]]; then
    CHANGES_DESCRIPTION+="- adds \`${PR_WORKFLOW_FILE_PATH}\`\n"
  fi
  if [[ "$COMMIT_ADDED" == "true" ]]; then
    CHANGES_DESCRIPTION+="- adds \`${COMMIT_WORKFLOW_FILE_PATH}\`\n"
  fi

  git commit -m "chore: add QA review workflows (PR and commit)"
  git push -u origin "$ROLLOUT_BRANCH"

  PR_BODY=$(cat <<EOF
## Summary
This PR adds the QA review workflows for PRs and individual commits.

## Changes
$(echo -e "$CHANGES_DESCRIPTION")
- wires the repository to the centralized reusable workflows in \`${ORG}/${AUTOMATION_REPO}\`

## Notes
- PR review runs on \`pull_request\` events and blocks merge on BLOCK
- Commit review runs on every \`push\` and skips automatically when the commit belongs to an open PR (avoids duplication)
- Review logic is centralized in the automation repo
- Secrets are inherited from organization/repository configuration
EOF
)

  gh pr create \
    --repo "$FULL_REPO" \
    --base "$DEFAULT_BRANCH" \
    --head "$ROLLOUT_BRANCH" \
    --title "chore: add QA review workflows (PR and commit)" \
    --body "$PR_BODY"

  cd "$WORKDIR"
done

echo "Mass rollout finished."
