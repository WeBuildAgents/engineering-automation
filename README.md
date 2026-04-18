# PR QA Review System

This repository is integrated with the automated PR QA Review agent.

## Overview

All Pull Requests are automatically analyzed for:
- Code quality
- Test coverage
- Security vulnerabilities
- Validation gaps

The agent posts a structured review and may block unsafe changes from being merged.

## Mandatory Rules

• Every repo must include `.github/workflows/pr-qa-review.yml`  
• All changes must be done via Pull Requests (no direct commits to main)  
• The QA agent only runs on PR events and enforces validation + quality gates  
• PRs without this workflow or bypassing PR flow will not be reviewed or validated  
• This is mandatory to ensure consistent code quality and safe merges across all repos  

## Behavior

Each PR receives one of the following outcomes:

- **APPROVE** → Safe to merge  
- **NEEDS TESTS** → Missing validation  
- **BLOCK** → Unsafe, merge is prevented  

If configured (`fail_on_block: true`), PRs with **BLOCK** will fail the workflow and cannot be merged.

## Setup Requirement

Make sure the workflow file exists:

```yaml
.github/workflows/pr-qa-review.yml
