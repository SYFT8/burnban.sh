# Launch-day installer restore

This branch is intentionally not the GitHub Pages deployment branch. It is the
prepared launch state for `burnban.sh`.

- `/install` and `/install.sh` fetch
  `https://raw.githubusercontent.com/burnban/burnban/main/install.sh`.
- `/install.ps1` fetches the matching canonical PowerShell installer.
- Those canonical installers download archives and `checksums.txt` from
  `https://github.com/burnban/burnban/releases/latest/download/` and verify the
  selected archive before installing it.

After the public release and checksums exist, restore the live domain with one
fast-forward and mirror push:

```sh
git switch master
git merge --ff-only launch/installer-restore
git push origin master
git push op8 master
```

Do not run that sequence before the release is public and the anonymous cold
install checks have passed.
