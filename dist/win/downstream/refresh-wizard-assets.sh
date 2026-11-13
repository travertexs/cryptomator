#!/usr/bin/env bash
# One-time packaging-only refresh; never overwrite the tag or other release assets.
set -euo pipefail
api="repos/$GITHUB_REPOSITORY"
tag=windows-1.20.0-SNAPSHOT
rid=443788845
[[ "$GITHUB_REPOSITORY" == travertexs/cryptomator && "$APP_VERSION" == 1.20.0-SNAPSHOT ]]
[[ "$(gh api "$api/git/ref/tags/$tag" --jq .object.sha)" == f0a4038aca5dae232bae5910f223e4c3ad38c462 ]]
[[ "$(gh api "$api/releases/tags/$tag" --jq .id)" == "$rid" ]]
files=(Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi Cryptomator-1.20.0-SNAPSHOT-windows-arm64.msi.sha256)
old=(742516816 742516898)
orig=(sha256:80344a3ab0e14ac7e9c9f860376c44646d6e9de5e54e3dc1e75327363e5c0f21 sha256:153b2af7bd75ab88c68240ce98e3a400d756b35b8f24c6aa47b1804b6cac0cdd)
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
sed -i "s/These unsigned MSIs install separately from upstream Cryptomator./The x64 MSI installs separately; the ARM64 MSI now uses the upstream install location and MSI family./" "$RUNNER_TEMP/wizard-notes.md"
echo >> "$RUNNER_TEMP/wizard-notes.md"
echo "ARM64 MSI packaging update: the wizard now defaults to **C:\\Program Files\\Cryptomator**, uses the official MSI upgrade family, and migrates the old fork ARM64 installation. This is still an unofficial, unsigned build. Replacement of both the official 1.19.6 x64 MSI and the previous ARM64 MSI was tested on native Windows on Arm. The x64 MSI, portable ZIPs, application version and release tag are unchanged. [ARM64 installer source](https://github.com/$GITHUB_REPOSITORY/commit/$GITHUB_SHA) · [Migration tests](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)." >> "$RUNNER_TEMP/wizard-notes.md"
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --notes-file "$RUNNER_TEMP/wizard-notes.md"
confirmed=true
for id in "${old[@]}"; do gh api -X DELETE "$api/releases/assets/$id" --silent; done
