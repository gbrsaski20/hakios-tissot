# Compliance

## APSL 2.0 Compliance

The XNU kernel is published by Apple under the Apple Public Source License 2.0
(APSL 2.0). Our patch series (`xnu/patches-8020/0001`–`0003`) is a derivative
work.

### Requirements met

1. **Source availability**: All changes are published as source in this repository.
2. **Notice retention**: All copyright and license notices in modified files are preserved.
3. **Attribution**: The original Apple copyright notices are retained in all modified files.
4. **Change description**: Changes are clearly marked as part of the HakiOS project.

### How to verify

```bash
# Fetch xnu-8020.140.41 and apply patches 0001..0008
./xnu/apply-8020.sh
# xnu-src-8020/ then holds all original notices plus our changes
```

`apply-8020.sh` also sanity-checks that every patch left its expected markers
behind, so a partially applied series fails loudly instead of silently.

## Other Licenses

| Component | License | Source |
|-----------|---------|--------|
| `xnu/patches-8020/*` | APSL 2.0 (derivative of XNU) | This repo |
| `tools/*.py` (mkadt, make_tissot_bootimg, …) | MIT | This repo |
| `xnu/apply-8020.sh`, `xnu-build-arm64.sh` | MIT | This repo |
| XNU source | APSL 2.0 | Apple's GitHub (`apple-oss-distributions/xnu`) |
| iOS 15.6.1 IPSW | Apple EULA — **not redistributed** | Your own download from Apple |
| Mi A1 stock `boot.img` / DTB | Xiaomi — **not redistributed** | Your own firmware |

## Files intentionally not committed

`.gitignore` excludes everything that is either Apple's or large:

```
xnu-src-8020/            # Apple source, downloaded at build time
*.ipsw, *.fdmdownload    # Apple firmware
devices/tissot/dt/*.img  # Xiaomi stock boot.img
devices/tissot/dt/*.adt  # extracted from the IPSW
prebuilt/*.Image, *.img  # build outputs
```

## Items still to verify

- [ ] Confirm all modified XNU files retain their original copyright headers after patch application
- [ ] Verify that prebuilt boot images are reproducible from source + the same inputs
- [ ] Confirm `mkadt.py` output contains no Apple-proprietary payload beyond the device-tree structure needed for boot
