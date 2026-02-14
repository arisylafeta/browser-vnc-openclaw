#!/usr/bin/env bash

set -u
set -o pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
MAX_BYTES="${WORKSPACE_MAX_BYTES:-1048576}"

mkdir -p "$WORKSPACE_ROOT"
WORKSPACE_ROOT_REAL="$(realpath -m "$WORKSPACE_ROOT")"

json_error() {
  local code="$1"
  local message="$2"
  jq -nc --arg code "$code" --arg message "$message" \
    '{success:false,code:$code,error:$code,message:$message}'
}

die() {
  json_error "$1" "$2"
  exit 0
}

is_within_root() {
  local target="$1"
  case "$target" in
    "$WORKSPACE_ROOT_REAL"|"$WORKSPACE_ROOT_REAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_rel_path() {
  local input="${1:-}"
  local normalized=""

  if [[ "$input" == /* ]]; then
    die "PATH_INVALID" "Absolute paths are not allowed"
  fi

  if [[ ${#input} -gt 4096 ]]; then
    die "PATH_INVALID" "Path is too long"
  fi

  IFS='/' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    if [[ -z "$part" || "$part" == "." ]]; then
      continue
    fi

    if [[ "$part" == ".." ]]; then
      die "PATH_INVALID" "Path traversal is not allowed"
    fi

    if [[ ! "$part" =~ ^[A-Za-z0-9._~\ \'-]+$ ]]; then
      die "PATH_INVALID" "Path contains invalid characters"
    fi

    if [[ -z "$normalized" ]]; then
      normalized="$part"
    else
      normalized="$normalized/$part"
    fi
  done

  printf '%s' "$normalized"
}

resolve_existing_path() {
  local rel="$1"
  local target="$WORKSPACE_ROOT_REAL"

  if [[ -n "$rel" ]]; then
    target="$WORKSPACE_ROOT_REAL/$rel"
  fi

  local resolved
  resolved="$(realpath -e "$target" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    die "NOT_FOUND" "Path not found"
  fi

  if ! is_within_root "$resolved"; then
    die "PATH_INVALID" "Resolved path is outside workspace root"
  fi

  printf '%s' "$resolved"
}

resolve_target_for_write() {
  local rel="$1"
  local parent_rel
  local base_name

  parent_rel="$(dirname "$rel")"
  base_name="$(basename "$rel")"

  local parent_target="$WORKSPACE_ROOT_REAL"
  if [[ "$parent_rel" != "." ]]; then
    parent_target="$WORKSPACE_ROOT_REAL/$parent_rel"
  fi

  local parent_real
  parent_real="$(realpath -e "$parent_target" 2>/dev/null || true)"
  if [[ -z "$parent_real" ]]; then
    die "NOT_FOUND" "Parent directory not found"
  fi

  if ! is_within_root "$parent_real"; then
    die "PATH_INVALID" "Parent directory is outside workspace"
  fi

  if [[ ! -d "$parent_real" ]]; then
    die "PATH_INVALID" "Parent path is not a directory"
  fi

  printf '%s' "$parent_real/$base_name"
}

compute_version() {
  local file_path="$1"
  local mtime_s
  local size
  mtime_s="$(stat -c %Y "$file_path" 2>/dev/null || echo 0)"
  size="$(stat -c %s "$file_path" 2>/dev/null || echo 0)"
  printf '%s:%s' "$((mtime_s * 1000))" "$size"
}

validate_text_file() {
  local file_path="$1"

  local size
  size="$(stat -c %s "$file_path" 2>/dev/null || echo 0)"
  if (( size > MAX_BYTES )); then
    die "SIZE_EXCEEDED" "File exceeds maximum size"
  fi

  if LC_ALL=C grep -qU $'\x00' "$file_path" 2>/dev/null; then
    die "PATH_INVALID" "Binary files are not supported"
  fi
}

convert_utf16_to_utf8() {
  local src="$1"
  local dst="$2"

  iconv -f UTF-16 -t UTF-8 "$src" > "$dst" 2>/dev/null \
    || iconv -f UTF-16LE -t UTF-8 "$src" > "$dst" 2>/dev/null \
    || iconv -f UTF-16BE -t UTF-8 "$src" > "$dst" 2>/dev/null
}

op_tree() {
  local rel
  rel="$(normalize_rel_path "${1:-}")"
  local target
  target="$(resolve_existing_path "$rel")"

  if [[ ! -d "$target" ]]; then
    die "PATH_INVALID" "Path is not a directory"
  fi

  local entries
  entries="$({
    find "$target" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | while IFS= read -r -d '' item; do
      local name path kind size modified mtime_s
      name="$(basename "$item")"
      path="$name"
      if [[ -n "$rel" ]]; then
        path="$rel/$name"
      fi

      mtime_s="$(stat -c %Y "$item" 2>/dev/null || echo 0)"
      modified="$(date -u -d "@$mtime_s" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")"

      if [[ -d "$item" ]]; then
        kind="directory"
        jq -nc --arg path "$path" --arg name "$name" --arg kind "$kind" --arg modified "$modified" \
          '{path:$path,name:$name,kind:$kind} + (if $modified == "" then {} else {modifiedAt:$modified} end)'
      else
        kind="file"
        size="$(stat -c %s "$item" 2>/dev/null || echo 0)"
        jq -nc --arg path "$path" --arg name "$name" --arg kind "$kind" --arg modified "$modified" --argjson size "$size" \
          '{path:$path,name:$name,kind:$kind,size:$size} + (if $modified == "" then {} else {modifiedAt:$modified} end)'
      fi
    done
  } | jq -sc '.')"

  if [[ -z "$entries" ]]; then
    entries='[]'
  fi

  jq -nc --arg parentPath "$rel" --argjson entries "$entries" \
    '{success:true,parentPath:$parentPath,entries:$entries}'
}

op_read() {
  local rel
  rel="$(normalize_rel_path "${1:-}")"
  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "File path is required"
  fi

  local target
  target="$(resolve_existing_path "$rel")"

  if [[ -d "$target" ]]; then
    die "IS_DIRECTORY" "Cannot read a directory"
  fi

  if [[ ! -f "$target" ]]; then
    die "NOT_FOUND" "File not found"
  fi

  local read_source="$target"
  local converted_tmp=""

  if LC_ALL=C grep -qU $'\x00' "$target" 2>/dev/null; then
    converted_tmp="$(mktemp)"
    if convert_utf16_to_utf8 "$target" "$converted_tmp"; then
      read_source="$converted_tmp"
    else
      rm -f "$converted_tmp"
      die "PATH_INVALID" "Binary files are not supported"
    fi
  fi

  validate_text_file "$read_source"

  local version
  version="$(compute_version "$target")"

  jq -nc --arg path "$rel" --rawfile content "$read_source" --arg version "$version" \
    '{success:true,path:$path,content:$content,encoding:"utf-8",version:$version}'

  if [[ -n "$converted_tmp" ]]; then
    rm -f "$converted_tmp"
  fi
}

op_write() {
  local rel expected_version
  rel="$(normalize_rel_path "${1:-}")"
  expected_version="${2:-}"

  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "File path is required"
  fi

  local target
  target="$(resolve_target_for_write "$rel")"

  if [[ -d "$target" ]]; then
    die "IS_DIRECTORY" "Cannot write to a directory path"
  fi

  if [[ -L "$target" ]]; then
    die "PATH_INVALID" "Refusing to write through symlink"
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT

  cat > "$tmp_file"
  validate_text_file "$tmp_file"

  if [[ -n "$expected_version" ]]; then
    if [[ ! -f "$target" ]]; then
      die "VERSION_CONFLICT" "File does not exist for expected version"
    fi

    local current_version
    current_version="$(compute_version "$target")"
    if [[ "$current_version" != "$expected_version" ]]; then
      die "VERSION_CONFLICT" "File was modified by another process"
    fi
  fi

  if ! mv "$tmp_file" "$target"; then
    die "EXECUTION_ERROR" "Failed to persist file"
  fi
  trap - EXIT

  local version
  version="$(compute_version "$target")"

  jq -nc --arg path "$rel" --arg version "$version" \
    '{success:true,path:$path,version:$version}'
}

op_mkdir() {
  local rel
  rel="$(normalize_rel_path "${1:-}")"
  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "Directory path is required"
  fi

  local target
  target="$(resolve_target_for_write "$rel")"

  if [[ -f "$target" ]]; then
    die "PATH_INVALID" "File already exists at path"
  fi

  if ! mkdir -p "$target"; then
    die "EXECUTION_ERROR" "Failed to create directory"
  fi

  jq -nc --arg path "$rel" '{success:true,path:$path}'
}

op_delete() {
  local rel recursive
  rel="$(normalize_rel_path "${1:-}")"
  recursive="${2:-false}"

  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "Path is required"
  fi

  local target
  target="$(resolve_existing_path "$rel")"

  if [[ "$target" == "$WORKSPACE_ROOT_REAL" ]]; then
    die "PATH_INVALID" "Refusing to delete workspace root"
  fi

  if [[ -d "$target" ]]; then
    if [[ "$recursive" == "true" ]]; then
      rm -rf "$target" || die "EXECUTION_ERROR" "Failed to delete directory"
    else
      rmdir "$target" 2>/dev/null || die "PATH_INVALID" "Directory is not empty (use recursive=true)"
    fi
  else
    rm -f "$target" || die "EXECUTION_ERROR" "Failed to delete file"
  fi

  jq -nc --arg path "$rel" '{success:true,path:$path}'
}

main() {
  local op="${1:-}"

  case "$op" in
    tree)
      op_tree "${2:-}"
      ;;
    read)
      op_read "${2:-}"
      ;;
    write)
      op_write "${2:-}" "${3:-}"
      ;;
    mkdir)
      op_mkdir "${2:-}"
      ;;
    delete)
      op_delete "${2:-}" "${3:-false}"
      ;;
    *)
      die "PATH_INVALID" "Unknown operation"
      ;;
  esac
}

main "$@"
