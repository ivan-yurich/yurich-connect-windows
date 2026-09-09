# Security Policy

## Supported versions

Security fixes are provided for the latest stable Windows release. Install updates only from the official repository:

https://github.com/ivan-yurich/yurich-connect-windows/releases

## Reporting a vulnerability

Do not publish credentials, subscription URLs, private keys, or a working exploit in a public issue. Contact the maintainer privately through the contact method listed in the GitHub profile and include:

- affected Yurich Connect version;
- Windows version;
- clear reproduction steps;
- expected and actual behavior;
- sanitized diagnostics when relevant.

Remove live subscription links, UUIDs, passwords, tokens, and private keys before sending additional files. Yurich Connect diagnostics redact known secret formats, but the report should still be reviewed by the sender.

## Update integrity

The Windows updater accepts assets only from the official GitHub release path. It verifies the installer with SHA-256 after download, when reusing a cached file, and immediately before UAC launch.

Unsigned public beta builds use the SHA-256 published with each release. Once the installed application has a valid Authenticode signature, automatic updates must also have a valid signature from the same publisher certificate.

## Release process

Windows releases are built by GitHub Actions and published as a draft first. The installer, portable archive, individual checksum files, and `SHA256SUMS.txt` must all upload successfully before the release becomes public. An existing public release is never overwritten by the workflow.

## Secrets

- Never commit `.env` files, tokens, subscription URLs, device credentials, or signing certificates.
- Store signing credentials only in the protected GitHub Actions secret store or a hardware-backed signing service.
- Release payload and diagnostic scans must pass before publication.
