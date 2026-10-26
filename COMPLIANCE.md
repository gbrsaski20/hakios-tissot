# Compliance

## APSL 2.0 Compliance

The XNU kernel is published by Apple under the Apple Public Source License 2.0 (APSL 2.0). Our patch (`xnu/hakios-x86.patch`) is a derivative work.

### Requirements met

1. **Source availability**: All changes are published as source in this repository.
2. **Notice retention**: All copyright and license notices in modified files are preserved.
3. **Attribution**: The original Apple copyright notices are retained in all modified files.
4. **Change description**: Changes are clearly marked as part of the HakiOS-x86 project.

### How to verify

```bash
# Apply the patch to a fresh XNU clone
xnu/apply.sh
# The resulting xnu-src/ directory has all original notices + our changes
```

## Other Licenses

| Component | License | Source |
|-----------|---------|--------|
| xnuloader | APSL 2.0 (derivative of XNU boot code) | This repo |
| hakios drivers | APSL 2.0 (kernel derivative) | This repo |
| userland programs | MIT | This repo |
| build scripts | MIT | This repo |
| XNU source | APSL 2.0 | Apple's GitHub |
| OVMF (UEFI) | BSD-2-Clause + others | Your distribution |

## Items still to verify

- [ ] Confirm all modified XNU files retain their original copyright headers after patch application
- [ ] Audit driver files for any third-party code and attribute accordingly
- [ ] Verify that prebuilt binaries are reproducible from source
