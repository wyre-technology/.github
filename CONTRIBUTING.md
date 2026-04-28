# Contributing to WYRE Technology Projects

Thanks for your interest in contributing. This document is the default contribution guide for repositories under the [wyre-technology](https://github.com/wyre-technology) organization. Individual repos may add their own `CONTRIBUTING.md` to extend or override these rules.

## Before you open a PR

1. **Open an issue first** for non-trivial changes. Helps us avoid duplicate work and align on direction before code is written.
2. **Search existing issues and PRs** to make sure your change isn't already in flight.
3. **Read the repo's README** for project-specific setup and testing instructions.

## What we accept

- Bug fixes with a clear reproducer
- Documentation improvements (typos, clarifications, accurate examples)
- New features that have been discussed in an issue first
- Test coverage improvements
- Security fixes (please follow responsible disclosure — see [SECURITY.md](https://github.com/wyre-technology/.github/blob/main/SECURITY.md) if present, otherwise email security@wyretechnology.com)

## What we don't accept

These PRs will be closed without merge:

- **Promotional badges, links, or trust seals** added to README files. This includes third-party "security assessment" badges, directory listings, sponsorship banners, and similar additions whose primary purpose is to drive traffic to an external site. We may add such badges ourselves when we choose to; we don't accept them via unsolicited PR.
- **SEO link insertions** disguised as documentation contributions
- **Mass-generated PRs** opened by automation across many repos without context for our specific project
- **Cosmetic-only changes** (whitespace, reflowing prose) that don't improve clarity
- **Dependency updates** unsolicited from non-maintainers — we use Dependabot/Renovate for these

PRs matching well-known spam patterns (specific bot accounts, badge-insertion templates, etc.) are auto-closed by org-level tooling. If you believe your PR was closed in error, please open an issue.

## How we review

- We aim to respond to PRs within one week, though response times vary by repo activity.
- Maintainers may request changes, additional tests, or clarification before merging.
- We squash-merge by default unless a repo specifies otherwise.
- Commits should follow [Conventional Commits](https://www.conventionalcommits.org/) where the repo is configured for it (look for a `.releaserc` or `commitlint` config).

## Code style

- Follow the conventions already present in the repo. New conventions get discussed in an issue, not introduced by surprise in a PR.
- Keep PRs focused. Multi-purpose PRs (refactor + feature + docs) are harder to review and slower to land.
- Add or update tests for behavior changes.
- Update the changelog where the repo maintains one (most do — check for `CHANGELOG.md`).

## Security

Do **not** open public issues or PRs for security vulnerabilities. Email **security@wyretechnology.com** with details, and we'll coordinate responsible disclosure.

## Questions

Open a discussion or issue on the relevant repo. For org-wide questions, you can also reach out via [wyretechnology.com](https://wyretechnology.com).
