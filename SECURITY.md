# Security Policy

## Supported versions

Only the latest release and the `main` branch get security fixes.

## Reporting a vulnerability

**Please do not open a public issue.** Report it privately through
[GitHub Security Advisories](https://github.com/eexxio/orbit/security/advisories/new) instead.

Please include:

- a description of the issue and its impact,
- steps to reproduce or a proof of concept,
- the orbit, iOS, and Hermes versions involved.

We aim to acknowledge a report within 5 working days and to keep you updated until it's fixed.

## Scope

orbit stores your Hermes password and Cloudflare Access secret in the iOS Keychain, and caches recent
conversations in Application Support, excluded from backups. Problems with how credentials, tokens, or cached
conversations are handled are in scope. Vulnerabilities in the Hermes Agent server itself should go to that
project.
