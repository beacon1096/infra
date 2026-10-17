#!/usr/bin/env bash
# Shared Tinybird Local credential intake for OpenStatus preparation scripts.
# Source this file. It rejects ambiguous or unusable input before a caller
# writes a header, and it never prints a credential value.
#
# Contract:
# - Management identity is TINYBIRD_ADMIN_TOKEN or TINYBIRD_ADMIN_TOKEN_FILE.
# - Read, create, and restore identities use the same ENV / ENV_FILE pair.
# - TINY_BIRD_API_KEY and TINYBIRD_TOKEN are application credentials. This
#   file does not read them and they do not satisfy the admin role.
# - Setting both the environment variable and the *_FILE path is an error.
#   A bad file never falls back to the environment variable.
# - A usable file is a regular file containing one token and at most one
#   trailing newline. Empty, unreadable, embedded newline, CR, space, other
#   control characters, or NUL are refused before any header is written.
# - Callers write the value only into a mode-0600 header file. Release the
#   exported token variables in the process that is about to exec curl,
#   after the header exists, so the value is not copied into child
#   environments. A parent that only checks presence must not release the
#   exported variables if its children still consume them.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "tinybird credential: source utils/openstatus-tinybird-auth.sh; it is not a command" >&2
  exit 2
fi

openstatus_tinybird_role_names() {
  local role="$1"
  case "$role" in
    admin)
      openstatus_role_env=TINYBIRD_ADMIN_TOKEN
      openstatus_role_file=TINYBIRD_ADMIN_TOKEN_FILE
      ;;
    read)
      openstatus_role_env=TINYBIRD_READ_TOKEN
      openstatus_role_file=TINYBIRD_READ_TOKEN_FILE
      ;;
    create)
      openstatus_role_env=TINYBIRD_CREATE_TOKEN
      openstatus_role_file=TINYBIRD_CREATE_TOKEN_FILE
      ;;
    restore)
      openstatus_role_env=TINYBIRD_RESTORE_TOKEN
      openstatus_role_file=TINYBIRD_RESTORE_TOKEN_FILE
      ;;
    *)
      echo "tinybird credential: unknown role" >&2
      return 2
      ;;
  esac
}

openstatus_tinybird_prepare_credential() {
  local role="$1"
  local env_value="" file_path="" raw="" stripped=""
  openstatus_credential_state=""
  unset openstatus_credential_value
  openstatus_tinybird_role_names "$role" || return 2
  env_value="${!openstatus_role_env-}"
  file_path="${!openstatus_role_file-}"
  if [[ -n "$env_value" && -n "$file_path" ]]; then
    openstatus_credential_state="ambiguous"
    return 0
  fi
  if [[ -z "$env_value" && -z "$file_path" ]]; then
    openstatus_credential_state="absent"
    return 0
  fi
  if [[ -n "$file_path" ]]; then
    if [[ ! -e "$file_path" ]]; then
      openstatus_credential_state="missing-file"
      return 0
    fi
    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
      openstatus_credential_state="unreadable"
      return 0
    fi
    raw=""
    IFS= read -r -d '' raw <"$file_path" || true
    # Bash strings cannot hold NUL. A shorter read than the file means the
    # file contains NUL and cannot be a single header token.
    raw_bytes="$(printf '%s' "$raw" | wc -c | awk '{print $1}')"
    file_bytes="$(wc -c <"$file_path" | awk '{print $1}')"
    if [[ "$raw_bytes" != "$file_bytes" ]]; then
      openstatus_credential_state="illegal"
      return 0
    fi
    if [[ "$raw" == *$'\n' ]]; then
      stripped="${raw%$'\n'}"
    else
      stripped="$raw"
    fi
  else
    stripped="$env_value"
  fi
  if [[ -z "$stripped" || "$stripped" == *$'\n'* || "$stripped" == *$'\r'* ||
    "$stripped" == *' '* || "$stripped" =~ [[:cntrl:]] ||
    ${#stripped} -gt 4096 ]]; then
    openstatus_credential_state="illegal"
    return 0
  fi
  openstatus_credential_state="ready"
  openstatus_credential_value="$stripped"
}

openstatus_tinybird_explain_credential() {
  local role="$1"
  case "$openstatus_credential_state" in
    absent)
      echo "tinybird credential: ${role} identity is absent; set only ${openstatus_role_env} or only ${openstatus_role_file}" >&2
      ;;
    ambiguous)
      echo "tinybird credential: ${role} environment variable and ${openstatus_role_file} are both set; refusing the ambiguous source" >&2
      ;;
    missing-file)
      echo "tinybird credential: ${role} file is missing; not falling back to an environment variable" >&2
      ;;
    unreadable)
      echo "tinybird credential: ${role} file is not a readable regular file" >&2
      ;;
    illegal)
      echo "tinybird credential: ${role} value is empty or is not a single header token" >&2
      ;;
    ready) ;;
    *)
      echo "tinybird credential: ${role} identity could not be classified" >&2
      ;;
  esac
}

openstatus_tinybird_write_bearer_header() {
  local dest="$1"
  [[ "$openstatus_credential_state" == "ready" && -n "${openstatus_credential_value:-}" ]] || return 2
  umask 077
  printf 'Authorization: Bearer %s\n' "$openstatus_credential_value" >"$dest"
  unset openstatus_credential_value
}

# Check a role. On success the secret remains only in the original environment
# variable or file; the in-process copy is dropped. When dest is supplied, a
# mode-0600 bearer header is written first.
openstatus_tinybird_require_credential() {
  local role="$1"
  local dest="${2:-}"
  openstatus_tinybird_prepare_credential "$role" || return 2
  if [[ "$openstatus_credential_state" != "ready" ]]; then
    openstatus_tinybird_explain_credential "$role"
    unset openstatus_credential_value
    return 2
  fi
  if [[ -n "$dest" ]]; then
    openstatus_tinybird_write_bearer_header "$dest" || return 2
  else
    unset openstatus_credential_value
  fi
}

# Optional read credential. Returns 0 when a header was written, 1 when the
# role is simply absent, and 2 when the supplied source is unusable.
openstatus_tinybird_optional_header() {
  local role="$1"
  local dest="$2"
  openstatus_tinybird_prepare_credential "$role" || return 2
  case "$openstatus_credential_state" in
    absent)
      unset openstatus_credential_value
      return 1
      ;;
    ready)
      openstatus_tinybird_write_bearer_header "$dest"
      ;;
    *)
      openstatus_tinybird_explain_credential "$role"
      unset openstatus_credential_value
      return 2
      ;;
  esac
}

openstatus_tinybird_release_exported_tokens() {
  unset TINYBIRD_ADMIN_TOKEN TINYBIRD_READ_TOKEN TINYBIRD_CREATE_TOKEN \
    TINYBIRD_RESTORE_TOKEN openstatus_credential_value
}
