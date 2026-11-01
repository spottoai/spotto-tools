#!/usr/bin/env bash
# Publishes the CloudFormation templates to the immutable cloudformation/v<version>/ prefix.
# Usage: publish-versioned-templates.sh <templates dir> <bucket> <version> [--promote-latest]
# A versioned file that already exists must be byte-identical. Only a successful
# exact-key listing can establish absence; all lookup errors fail before uploads.
set -euo pipefail

templates="$1" bucket="$2" version="$3"
mode="${4:-}"
if [[ ! "$version" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{1,4}$ ]]; then
  echo "::error::Invalid template version: $version"
  exit 1
fi
if [ -n "$mode" ] && [ "$mode" != --promote-latest ]; then
  echo "::error::Unknown publishing mode: $mode"
  exit 1
fi
prefix="cloudformation/v$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Returns 3 only when a successful listing proves the exact key is absent.
download_published_template() {
  local key="$1" destination="$2" published err
  # List with the authorized prefix: HeadObject cannot use prefix-scoped
  # ListBucket permission and may return 403 for an unpublished object.
  if ! published="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$key" \
      --query "Contents[?Key=='$key'].Key" --output text 2>"$work/list.err")"; then
    echo "::error::Couldn't check s3://$bucket/$key: $(cat "$work/list.err")"
    return 1
  fi
  if [ "$published" = "$key" ]; then
    if ! err="$(aws s3 cp "s3://$bucket/$key" "$destination" --only-show-errors 2>&1)"; then
      echo "::error::Couldn't download s3://$bucket/$key to compare it: $err"
      return 1
    fi
    return 0
  elif [ -z "$published" ] || [ "$published" = "None" ]; then
    return 3
  else
    echo "::error::Unexpected listing result for s3://$bucket/$key: $published"
    return 1
  fi
}

# Check every file first, so a conflict or an unreadable object publishes nothing.
for file in "$templates"/*.json; do
  key="$prefix/$(basename "$file")"
  if download_published_template "$key" "$work/published.json"; then
    if ! cmp -s "$file" "$work/published.json"; then
      echo "::error::s3://$bucket/$key already exists with different content. Bump AWS_CONNECT_TEMPLATE_VERSION and regenerate."
      exit 1
    fi
    echo "s3://$bucket/$key is already published and identical."
  else
    status=$?
    if [ "$status" -ne 3 ]; then exit 1; fi
    echo "s3://$bucket/$key isn't published yet."
  fi
done

# A rerun uses its original commit. Check all aliases before uploading anything,
# so an old run cannot promote a version below any already-published latest file.
if [ "$mode" = --promote-latest ]; then
  for file in "$templates"/*.json; do
    local_version="$(jq -er '.Metadata.TemplateVersion | select(type == "string")' "$file")" || {
      echo "::error::Invalid template version in $file"
      exit 1
    }
    if [ "$local_version" != "$version" ]; then
      echo "::error::Invalid template version in $file: expected $version, found $local_version"
      exit 1
    fi
    key="cloudformation/$(basename "$file")"
    if download_published_template "$key" "$work/latest.json"; then
      published_version="$(jq -er '.Metadata.TemplateVersion | select(type == "string")' "$work/latest.json")" || {
        echo "::error::Invalid published template version at s3://$bucket/$key"
        exit 1
      }
      if [[ ! "$published_version" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{1,4}$ ]]; then
        echo "::error::Invalid published template version at s3://$bucket/$key: $published_version"
        exit 1
      fi
      if [[ "${published_version%.*}" > "${version%.*}" ]] || {
        [[ "${published_version%.*}" = "${version%.*}" ]] &&
          ((10#${published_version##*.} > 10#${version##*.}));
      }; then
        echo "::error::Refusing to replace s3://$bucket/$key version $published_version with older version $version."
        exit 1
      fi
    else
      status=$?
      if [ "$status" -ne 3 ]; then exit 1; fi
    fi
  done
fi

aws s3 sync "$templates/" "s3://$bucket/$prefix/" --exclude "*" --include "*.json" --content-type application/json
if [ "$mode" = --promote-latest ]; then
  aws s3 sync "$templates/" "s3://$bucket/cloudformation/" --exclude "*" --include "*.json" --content-type application/json
fi
