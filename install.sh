#!/usr/bin/env bash
# install.sh: install or update bc250-fixer (https://github.com/AnonyMap/bc250-fixer)
#
#   curl -fsSL https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/install.sh | sudo bash
#
# Options (pass them after "bash -s --"):
#   --ref REF       branch or tag to install (default: main)
#   --prefix DIR    where to put it (default: /usr/local/sbin)
#   --check         run 'bc250-fixer check' once it's installed
#   --uninstall     remove it (same as 'bc250-fixer uninstall')
# e.g.  curl -fsSL https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/install.sh | sudo bash -s -- --check
#
# Running it again updates to the latest version.
#
# Everything is inside main(), which is only called on the last line, so a download
# that's cut off part-way runs nothing at all.

main() {
  set -euo pipefail
  local repo="AnonyMap/bc250-fixer" ref="main" prefix="/usr/local/sbin" run_check=0 uninstall=0
  while (( $# )); do
    case $1 in
      --ref) ref="${2:?--ref needs a branch or tag}"; shift ;;
      --prefix) prefix="${2:?--prefix needs a directory}"; shift ;;
      --check) run_check=1 ;;
      --uninstall) uninstall=1 ;;
      -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null ||
                   echo "see https://github.com/$repo#install"; return 0 ;;
      *) echo "install.sh: unknown option '$1' (try --help)" >&2; return 2 ;;
    esac
    shift
  done
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "install.sh: '$ref' isn't a valid branch or tag" >&2; return 2; }

  local G="" Y="" R="" N=""
  [[ -t 1 ]] && { G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; }
  say()  { printf '%s==>%s %s\n' "$G" "$N" "$*"; }
  warn() { printf '%swarn:%s %s\n' "$Y" "$N" "$*" >&2; }
  die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run it as root: curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | sudo bash"
  local dest="$prefix/bc250-fixer"

  if (( uninstall )); then
    if [[ -x $dest ]]; then "$dest" uninstall; else say "nothing to remove at $dest"; fi
    return 0
  fi

  # what bc250-fixer itself needs
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "bash 4.4 or newer is needed (this is $BASH_VERSION)"
  command -v systemctl >/dev/null || warn "systemd wasn't found; most of bc250-fixer assumes it"
  command -v python3 >/dev/null || warn "python3 wasn't found; check, vram, fix and gov need it (install it with your package manager)"

  local url="${BC250_FIXER_URL:-https://raw.githubusercontent.com/$repo/$ref/bc250-fixer}"
  BC250_TMP=$(mktemp) || die "couldn't create a temporary file"   # global: the EXIT trap runs after main returns
  trap 'rm -f "${BC250_TMP:-}"' EXIT
  local tmp=$BC250_TMP
  say "downloading bc250-fixer ($ref)"
  if command -v curl >/dev/null; then curl -fsSL --retry 3 -o "$tmp" "$url" || die "download failed: $url"
  elif command -v wget >/dev/null; then wget -q -O "$tmp" "$url" || die "download failed: $url"
  else die "curl or wget is needed"; fi

  # make sure it's really the tool, complete, before it goes anywhere
  [[ -s $tmp ]] || die "the download was empty"
  [[ "$(head -n1 "$tmp")" == "#!/usr/bin/env bash" && "$(sed -n 2p "$tmp")" == "# bc250-fixer:"* ]] ||
    die "that doesn't look like bc250-fixer (wrong branch or tag? got: $(head -c 80 "$tmp" | tr -d '\0' | head -n1))"
  [[ "$(tail -n1 "$tmp")" == "esac" ]] && grep -q '^  \*) *die "unknown command' "$tmp" ||
    die "the download looks cut off; try again"
  bash -n "$tmp" || die "the download doesn't parse as bash; try again"
  local new old=""
  new=$(bash "$tmp" version 2>/dev/null) || die "the downloaded tool doesn't run"
  [[ -x $dest ]] && old=$("$dest" version 2>/dev/null || true)

  install -D -m 0755 "$tmp" "$dest" || die "couldn't write $dest"
  command -v restorecon >/dev/null && restorecon -q "$dest" 2>/dev/null || true
  if [[ -n $old && $old != "$new" ]]; then say "updated: $old -> $new ($dest)"
  elif [[ -n $old ]]; then say "already up to date: $new ($dest)"
  else say "installed: $new ($dest)"; fi

  case ":$PATH:" in *":$prefix:"*) ;; *) warn "$prefix isn't on this PATH; run it as $dest" ;; esac
  if (( run_check )); then
    say "running a health check"
    "$dest" check || true
  else
    cat <<EOF

  Start with a read-only health check, then preview the fixes:
    sudo bc250-fixer check
    sudo bc250-fixer fix --dry-run
  All commands: bc250-fixer help      Update: run this installer again
EOF
  fi
}

main "$@"
