## Summary

<!-- What changes for the user, and why. -->

## Verification

- [ ] `python3 -I docs/scripts/check_app.py` prints OK
- [ ] `python3 -I -m unittest discover -s docs/scripts -v` passes
- [ ] `swift test --package-path app` passes
- [ ] Feature patch re-recorded with `docs/scripts/record_feature.py` (if `app/` changed)
- [ ] Checked on: <!-- simulator / device, watch size, watchOS version -->
- [ ] UI changes checked at the largest Text Size, with Reduce Motion, and in Always On
      <!-- say which were not checked, and what was simulator-only -->

## Notes for reviewers

<!-- Risks, follow-ups, screenshots. -->
