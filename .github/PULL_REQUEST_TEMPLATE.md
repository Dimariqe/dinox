## Description

<!-- Briefly describe what this PR does -->

## Related Issues

<!-- Link related issues -->
Fixes #
Closes #
Related to #

## Type of Change

<!-- Mark with [x] -->
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Code style / refactoring (no functional changes)
- [ ] Performance improvement
- [ ] Test addition / modification
- [ ] Security fix

## Testing Done

<!-- Describe the tests you ran -->
- [ ] Tested manually on: ___
- [ ] Unit tests pass (`meson test -C build`)
- [ ] MQTT tests pass (`./build/plugins/mqtt/mqtt-test`)
- [ ] No compiler warnings (`ninja -C build 2>&1 | grep -i warning`)
- [ ] Tested with multiple accounts
- [ ] Tested encryption (if applicable)
- [ ] Tested calls (if applicable)

**Test Environment**:
- OS: <!-- e.g. Ubuntu 24.04, Arch Linux, Windows 11 -->
- Desktop: <!-- e.g. GNOME 47, KDE Plasma 6 -->
- Display: <!-- Wayland / X11 -->
- DinoX Version: <!-- e.g. 1.1.4.6 -->

## Screenshots

<!-- If UI changes, add before/after screenshots -->

<details>
<summary>Before</summary>

<!-- Screenshot -->

</details>

<details>
<summary>After</summary>

<!-- Screenshot -->

</details>

## Checklist

<!-- Mark completed items with [x] -->

### Code Quality
- [ ] Code compiles without warnings (`-Werror`-clean)
- [ ] Follows [CODING_GUIDELINES.md](../docs/internal/CODING_GUIDELINES.md)
- [ ] Passes [REVIEW_CHECKLIST.md](../docs/internal/REVIEW_CHECKLIST.md)
- [ ] Follows [SECURITY_GUIDELINES.md](../docs/internal/SECURITY_GUIDELINES.md) (for crypto / auth / DB code)
- [ ] No commented-out code or debug prints left
- [ ] Proper error handling — every `catch` logs at minimum `debug()`

### Testing
- [ ] All Meson tests pass (689 tests)
- [ ] All MQTT standalone tests pass (101 tests)
- [ ] Added tests for new functionality
- [ ] Manually tested changes
- [ ] No regressions in existing features

### Documentation
- [ ] Updated relevant documentation
- [ ] Added/updated code comments
- [ ] Updated [CHANGELOG.md](../docs/internal/CHANGELOG.md) if needed
- [ ] Updated README XEP table if added XEP support
- [ ] Updated [TESTING.md](../docs/internal/TESTING.md) if tests were added

### Database (if applicable)
- [ ] Schema migration uses VERSION increment
- [ ] No `exec()` for DML queries (use Qlite ORM)
- [ ] Queries have appropriate LIMIT clauses

### Commit Messages
- [ ] Commit messages follow conventional format
- [ ] Each commit is atomic and logical

### Database
- [ ] No database schema changes
- [ ] Or: Database migration added and tested
- [ ] Or: Migration documented in commit message

## Additional Notes

<!-- Any additional information for reviewers -->

## Review Checklist (for maintainers)

- [ ] Code review completed
- [ ] Tested locally
- [ ] Documentation adequate
- [ ] Follows project conventions
- [ ] Ready to merge
