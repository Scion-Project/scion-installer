# Licensing

This file is a plain-English map of who may use what under which licence. It does not replace the licence files.

The repository-level `LICENSE` is MIT and is not changed.

## Original work: MIT-0

Files that the Scion project wrote entirely from scratch (every commit by the project's authors, no third-party notice, nothing ported or derived from another codebase) are licensed **MIT-0** (MIT No Attribution, SPDX `MIT-0`; text in `LICENSES/MIT-0.txt`). Each such file carries `SPDX-License-Identifier: MIT-0` in its first lines, except the files listed in the table below, which cannot hold a comment.

MIT-0 paths (top-level location, number of files):

- `.github`: 2 files
- `(top level)`: 3 files
- `repo`: 5 files
- `tools`: 1 file
- `universal`: 5 files

The full per-file list is in the pull request that introduced this file, and every file's own first lines are authoritative.

## Files that keep their existing licence

- Anything not listed above, and any file that has no explicit `SPDX-License-Identifier: MIT-0` tag, stays under the repository's existing licence, as before.
- `tools/gpt-plan.py` (GPT readers adapted from scion-blazer, MIT, another author) and its tests.
- `universal/scion-install.sh` and its tests: left out as a close call (see the PR).
- `NOTICE` and `repo/LICENSES.md`: third-party notices.

## MIT-0 files without an in-file tag

These files cannot carry a comment (or begin with front matter that must stay first), so they are covered by this table instead.

| Path | Licence |
|---|---|
| `universal/TESTING.txt` | MIT-0 |

