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
old=(742627401 742627474)
orig=(sha256:49619302321105a6335da661101b0cae318c6d3a86d2db2766338a4edd576f97 sha256:2583e681a11fd77e32a60a1066e982c29e0827aeb194b9fee6c15af9783a286d)
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
sed -i '/^ARM64 MSI packaging update:/d;s/The updated installers use architecture-only names and upgrade the previous MSIs in place./The x64 installer uses an architecture-only suffix./' "$RUNNER_TEMP/wizard-notes.md"
echo >> "$RUNNER_TEMP/wizard-notes.md"
echo "ARM64 MSI packaging update: **Cryptomator** uses the upstream name, icon, MSI family and default installation folder, **C:\\Program Files\\Cryptomator**. It replaces the official MSI (tested with 1.19.5.6584 and 1.19.6); a separate former fork installation remains untouched. Unofficial, unsigned downstream build. The x64 installer, portable ZIPs, app version and tag are unchanged. [Installer source](https://github.com/$GITHUB_REPOSITORY/commit/$GITHUB_SHA) · [Windows on Arm installer tests](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)." >> "$RUNNER_TEMP/wizard-notes.md"
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --notes-file "$RUNNER_TEMP/wizard-notes.md"
confirmed=true
for id in "${old[@]}"; do gh api -X DELETE "$api/releases/assets/$id" --silent; done
