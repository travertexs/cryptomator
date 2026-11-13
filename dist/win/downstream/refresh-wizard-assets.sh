#!/usr/bin/env bash
# One-time packaging-only refresh; never overwrite the tag or other release assets.
set -euo pipefail
api="repos/$GITHUB_REPOSITORY"
tag=windows-1.20.0-SNAPSHOT
rid=443788845
[[ "$GITHUB_REPOSITORY" == travertexs/cryptomator && "$APP_VERSION" == 1.20.0-SNAPSHOT ]]
[[ "$(gh api "$api/git/ref/tags/$tag" --jq .object.sha)" == f0a4038aca5dae232bae5910f223e4c3ad38c462 ]]
[[ "$(gh api "$api/releases/tags/$tag" --jq .id)" == "$rid" ]]
files=(Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi.sha256 Cryptomator-1.20.0-SNAPSHOT-windows-x64.msi Cryptomator-1.20.0-SNAPSHOT-windows-x64.msi.sha256)
old=(742148632 742148630 742148629 742148650)
orig=(sha256:aef611f39e23511b4e8a84b516d9231a8a150021eaaab675cd8bb7908fe98549 sha256:af3be9d2e5c2d5d3e848702c14dd634b9179d7728583229e68244ebf3bb12cdf sha256:5924cf30873a07b11e2965353fb97ddd48aca1018cbddfc7f79c23ff2c447a4c sha256:bb9607249bb412acc7c509465a9fefcc9812fb9f6214a626cb73bbdece1a0ee3)
new=()
confirmed=false
rename_asset() { gh api -X PATCH "$api/releases/assets/$1" -f "name=$2" --silent; }
restore() {
  local rc=$?
  trap - EXIT
  if [[ $rc != 0 && "$confirmed" == false ]]; then
    set +e
    # All replacement uploads have unique names. Restore only IDs from this run.
    for i in "${!new[@]}"; do rename_asset "${new[i]}" "${files[i]}.staged-$GITHUB_RUN_ID"; done
    for i in "${!old[@]}"; do rename_asset "${old[i]}" "${files[i]}"; done
    for id in "${new[@]}"; do gh api -X DELETE "$api/releases/assets/$id" --silent; done
  fi
  exit "$rc"
}
for i in "${!files[@]}"; do
  f=${files[i]}
  gh api "$api/releases/assets/${old[i]}" | jq -e --arg n "$f" --arg h "${orig[i]}" '.name==$n and .digest==$h' >/dev/null
  [[ -s "$f" ]]
done
sha256sum -c Cryptomator-*msi.sha256
trap restore EXIT
for i in "${!files[@]}"; do
  f=${files[i]}; staged="$f.staged-$GITHUB_RUN_ID"
  cp "$f" "$staged"
  gh release upload "$tag" "$staged" --repo "$GITHUB_REPOSITORY"
  item=$(gh api "$api/releases/$rid/assets?per_page=100" | jq -ce --arg n "$staged" '.[] | select(.name==$n)')
  new+=("$(jq -r .id <<<"$item")")
  [[ "$(jq -r .digest <<<"$item")" == "sha256:$(sha256sum "$f" | cut -d' ' -f1)" ]]
done
for i in "${!files[@]}"; do
  rename_asset "${old[i]}" "${files[i]}.previous-$GITHUB_RUN_ID"
  rename_asset "${new[i]}" "${files[i]}"
done
for i in "${!files[@]}"; do
  f=${files[i]}
  gh api "$api/releases/assets/${new[i]}" | jq -e --arg n "$f" --arg h "sha256:$(sha256sum "$f" | cut -d' ' -f1)" '.name==$n and .state=="uploaded" and .digest==$h' >/dev/null
done
gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body --jq '.body' > "$RUNNER_TEMP/wizard-notes.md"
echo >> "$RUNNER_TEMP/wizard-notes.md"
echo "Installer update: **Double-click the ARM64 or x64 MSI for the interactive setup wizard** (license, destination folder, Start-menu shortcut choice, Install and Finish). The updated installers use architecture-only names and upgrade the previous MSIs in place. The application payload, upstream version, portable downloads and release tag have not changed. [Installer packaging source](https://github.com/$GITHUB_REPOSITORY/commit/$GITHUB_SHA) · [Tests of both visible wizards](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)." >> "$RUNNER_TEMP/wizard-notes.md"
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --notes-file "$RUNNER_TEMP/wizard-notes.md"
confirmed=true
for id in "${old[@]}"; do gh api -X DELETE "$api/releases/assets/$id" --silent; done
