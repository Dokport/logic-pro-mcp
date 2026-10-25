#!/usr/bin/env bash
# Protected owner inputs only; no URL, key, private evidence or verifier report
# is printed/uploaded. The caller owns and removes this private directory.
set -euo pipefail
umask 077
mode="${1:-}"; destination="${2:-}"
[[ "$mode" = stage || "$mode" = verify || "$mode" = public ]] && test -d "$destination"
# Curl errors and ZIP integrity diagnostics can include private URLs/member
# names. Preserve details only in the caller-owned private directory.
exec 3>&2
trap 'echo "Qualified private input fetch rejected" >&3' ERR
exec > "$destination/fetch.stdout" 2> "$destination/fetch.stderr"
if [ "$mode" = public ]; then
  input_url="${QUALIFICATION_PUBLIC_ASSETS_URL:-}"
  input_sha="${QUALIFICATION_PUBLIC_ASSETS_SHA256:-}"
  archive="$destination/public-assets.zip"
  extracted="$destination/public"
else
  input_url="${QUALIFICATION_EVIDENCE_URL:-}"
  input_sha="${QUALIFICATION_EVIDENCE_SHA256:-}"
  archive="$destination/evidence.zip"
  extracted="$destination/bundle"
fi
test -n "$input_url"
[[ "$input_sha" =~ ^[a-f0-9]{64}$ ]]
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 120 \
  "$input_url" --output "$archive"
printf '%s  %s\n' "$input_sha" "$archive" | shasum -a 256 --check
python3 - "$archive" "$extracted" <<'PY'
import bisect, pathlib, shutil, stat, sys, unicodedata, zipfile
archive, destination = sys.argv[1:]
root = pathlib.Path(destination)
root.mkdir(mode=0o700)
with zipfile.ZipFile(archive) as bundle:
    # Bound expansion before writing any evidence member. These limits apply to
    # the private staged input, not to the verifier's authenticity decision.
    members = bundle.infolist()
    if len(members) > 10_000:
        raise ValueError('Too many qualified bundle members')
    names, files, total = set(), set(), 0
    for member in members:
        path = pathlib.PurePosixPath(member.filename)
        # macOS volumes can alias case and canonical Unicode forms. Compare one
        # conservative identity for both duplicates and file/directory conflicts;
        # extraction retains the original member names.
        name = unicodedata.normalize('NFD', unicodedata.normalize('NFD', path.as_posix()).casefold())
        kind = stat.S_IFMT(member.external_attr >> 16)
        if (not path.parts or path.is_absolute() or '..' in path.parts
                or '\\' in member.filename or name in names
                or kind not in (0, stat.S_IFREG, stat.S_IFDIR)):
            raise ValueError('Unsafe qualified bundle member')
        if member.file_size > (1 << 30):
            raise ValueError('Qualified bundle member exceeds 1 GiB')
        total += member.file_size
        if total > (4 << 30):
            raise ValueError('Qualified bundle expansion exceeds 4 GiB')
        names.add(name)
        if not member.is_dir():
            files.add(name)
    ordered = sorted(names)
    for name in files:
        prefix = name + '/'
        index = bisect.bisect_left(ordered, prefix)
        if index < len(ordered) and ordered[index].startswith(prefix):
            raise ValueError('Qualified bundle file conflicts with a directory')
    for member in members:
        output = root / member.filename
        if member.is_dir():
            output.mkdir(parents=True, exist_ok=True)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, output.open('xb') as target:
                shutil.copyfileobj(source, target)
PY
if [ "$mode" = stage ]; then
  test -n "${QUALIFICATION_CANDIDATE_URL:-}"
  [[ "${QUALIFICATION_CANDIDATE_SHA256:-}" =~ ^[a-f0-9]{64}$ ]]
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --max-time 120 \
    "$QUALIFICATION_CANDIDATE_URL" --output "$destination/LogicProMCP"
  printf '%s  %s\n' "$QUALIFICATION_CANDIDATE_SHA256" "$destination/LogicProMCP" | shasum -a 256 --check
  chmod 0755 "$destination/LogicProMCP"
fi
