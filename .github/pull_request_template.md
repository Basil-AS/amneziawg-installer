## Summary

<!-- Brief description of changes -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] CI/CD
- [ ] Refactoring

## Checklist

- [ ] `bash -n` passes for all modified scripts
- [ ] `shellcheck -s bash -S warning` passes
- [ ] Tested on clean Ubuntu 24.04 LTS VPS (if script changes)
- [ ] Tested on Ubuntu 25.10/26.04 (noble fallback path, if PPA/install logic changes)
- [ ] Tested on Debian 12/13 (if OS-specific changes)
- [ ] CHANGELOG.md **and** CHANGELOG.en.md updated (including `[Unreleased]` comparator link)
- [ ] SCRIPT_VERSION updated (if releasing new version)
- [ ] Version badge in README.md and README.en.md updated (if version bump)
- [ ] Documentation updated (if applicable)
- [ ] Security-sensitive changes reviewed (no eval/source on user data, strict permissions)
- [ ] English script versions (`_en.sh`) synchronized (if Russian scripts modified)
- [ ] Rollback tested: `--uninstall` + fresh install (if installer changes)
- [ ] vpn:// URI generation verified (if `awg_common` changes)
