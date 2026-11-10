#!/usr/bin/env bash
set -euo pipefail

: "${SITE_URL:?SITE_URL must be set}"
site_url="${SITE_URL%/}"

html="$(curl --fail --silent --show-error "$site_url/")"
robots="$(curl --fail --silent --show-error "$site_url/robots.txt")"

grep -Fq 'name="robots" content="noindex, nofollow, noarchive"' <<<"$html"
grep -Fxq 'User-agent: *' <<<"$robots"
grep -Fxq 'Disallow: /' <<<"$robots"

echo "Smoke test passed: $site_url"
