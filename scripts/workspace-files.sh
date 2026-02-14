#!/usr/bin/env bash

set -u
set -o pipefail

WORKSPACE_ROOT="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
MAX_TEXT_BYTES="${WORKSPACE_MAX_BYTES:-1048576}"
MAX_BINARY_TRANSFER_BYTES="${WORKSPACE_MAX_BINARY_TRANSFER_BYTES:-15728640}"

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

get_file_size() {
  local file_path="$1"
  stat -c %s "$file_path" 2>/dev/null || echo 0
}

get_modified_at() {
  local file_path="$1"
  local mtime_s
  mtime_s="$(stat -c %Y "$file_path" 2>/dev/null || echo 0)"
  date -u -d "@$mtime_s" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
}

get_extension() {
  local name="$1"
  if [[ "$name" == *.* ]]; then
    printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]'
  else
    printf ''
  fi
}

detect_mime_type() {
  local file_path="$1"
  local file_name="$2"
  local ext

  if command -v file >/dev/null 2>&1; then
    file -b --mime-type "$file_path" 2>/dev/null || true
    return
  fi

  ext="$(get_extension "$file_name")"
  case "$ext" in
    md) echo "text/markdown" ;;
    txt) echo "text/plain" ;;
    json) echo "application/json" ;;
    yml|yaml) echo "application/x-yaml" ;;
    js) echo "application/javascript" ;;
    ts) echo "application/typescript" ;;
    tsx|jsx) echo "text/plain" ;;
    html|htm) echo "text/html" ;;
    css) echo "text/css" ;;
    pdf) echo "application/pdf" ;;
    png) echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    webp) echo "image/webp" ;;
    svg) echo "image/svg+xml" ;;
    mp4) echo "video/mp4" ;;
    mov) echo "video/quicktime" ;;
    ppt|pptx) echo "application/vnd.openxmlformats-officedocument.presentationml.presentation" ;;
    doc|docx) echo "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ;;
    xls|xlsx) echo "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ;;
    zip) echo "application/zip" ;;
    *) echo "application/octet-stream" ;;
  esac
}

is_text_mime() {
  local mime="$1"
  case "$mime" in
    text/*|application/json|application/xml|application/javascript|application/typescript|application/x-yaml|application/x-sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_previewable_mime() {
  local mime="$1"
  case "$mime" in
    text/*|image/*|application/pdf)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

file_contains_null_bytes() {
  local file_path="$1"
  LC_ALL=C grep -qU $'\x00' "$file_path" 2>/dev/null
}

convert_utf16_to_utf8() {
  local src="$1"
  local dst="$2"

  iconv -f UTF-16 -t UTF-8 "$src" > "$dst" 2>/dev/null \
    || iconv -f UTF-16LE -t UTF-8 "$src" > "$dst" 2>/dev/null \
    || iconv -f UTF-16BE -t UTF-8 "$src" > "$dst" 2>/dev/null
}

validate_text_size() {
  local file_path="$1"
  local size
  size="$(get_file_size "$file_path")"
  if (( size > MAX_TEXT_BYTES )); then
    die "SIZE_EXCEEDED" "File exceeds text size limit"
  fi
}

validate_binary_transfer_size() {
  local file_path="$1"
  local size
  size="$(get_file_size "$file_path")"
  if (( size > MAX_BINARY_TRANSFER_BYTES )); then
    die "SIZE_EXCEEDED" "File exceeds transfer size limit"
  fi
}

entry_json() {
  local rel_path="$1"
  local abs_path="$2"
  local base_name kind modified size ext mime is_text can_edit can_preview can_download

  base_name="$(basename "$abs_path")"
  modified="$(get_modified_at "$abs_path")"

  if [[ -d "$abs_path" ]]; then
    kind="directory"
    size=0
    ext=""
    mime="inode/directory"
    is_text="false"
    can_edit="false"
    can_preview="false"
    can_download="false"
  else
    kind="file"
    size="$(get_file_size "$abs_path")"
    ext="$(get_extension "$base_name")"
    mime="$(detect_mime_type "$abs_path" "$base_name")"
    if [[ -z "$mime" ]]; then
      mime="application/octet-stream"
    fi

    if is_text_mime "$mime"; then
      is_text="true"
      can_edit="true"
    else
      is_text="false"
      can_edit="false"
    fi

    if is_previewable_mime "$mime"; then
      can_preview="true"
    else
      can_preview="false"
    fi

    can_download="true"
  fi

  jq -nc \
    --arg path "$rel_path" \
    --arg name "$base_name" \
    --arg kind "$kind" \
    --arg modified "$modified" \
    --arg ext "$ext" \
    --arg mime "$mime" \
    --argjson size "$size" \
    --argjson isText "$is_text" \
    --argjson canRead true \
    --argjson canEdit "$can_edit" \
    --argjson canPreview "$can_preview" \
    --argjson canDownload "$can_download" \
    '{
      path:$path,
      name:$name,
      kind:$kind,
      size:(if $kind == "file" then $size else null end),
      modifiedAt:(if $modified == "" then null else $modified end),
      extension:(if $ext == "" then null else $ext end),
      mimeType:$mime,
      isText:(if $kind == "file" then $isText else null end),
      capabilities:{
        canRead:$canRead,
        canEdit:$canEdit,
        canPreview:$canPreview,
        canDownload:$canDownload
      }
    } | del(..|nulls)'
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
      local name child_rel
      name="$(basename "$item")"
      child_rel="$name"
      if [[ -n "$rel" ]]; then
        child_rel="$rel/$name"
      fi
      entry_json "$child_rel" "$item"
    done
  } | jq -sc '.')"

  if [[ -z "$entries" ]]; then
    entries='[]'
  fi

  jq -nc --arg parentPath "$rel" --argjson entries "$entries" \
    '{success:true,parentPath:$parentPath,entries:$entries}'
}

op_stat() {
  local rel
  rel="$(normalize_rel_path "${1:-}")"
  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "Path is required"
  fi

  local target
  target="$(resolve_existing_path "$rel")"

  local entry
  entry="$(entry_json "$rel" "$target")"

  if [[ -f "$target" ]]; then
    jq -nc --argjson entry "$entry" --arg version "$(compute_version "$target")" \
      '{success:true,entry:$entry,version:$version}'
  else
    jq -nc --argjson entry "$entry" '{success:true,entry:$entry}'
  fi
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

  local mime
  mime="$(detect_mime_type "$target" "$(basename "$target")")"
  if ! is_text_mime "$mime"; then
    die "PATH_INVALID" "Binary files are not supported in text read"
  fi

  local read_source="$target"
  local converted_tmp=""

  if file_contains_null_bytes "$target"; then
    converted_tmp="$(mktemp)"
    if convert_utf16_to_utf8 "$target" "$converted_tmp"; then
      read_source="$converted_tmp"
    else
      rm -f "$converted_tmp"
      die "PATH_INVALID" "Binary files are not supported in text read"
    fi
  fi

  validate_text_size "$read_source"

  local version
  version="$(compute_version "$target")"

  jq -nc \
    --arg path "$rel" \
    --rawfile content "$read_source" \
    --arg version "$version" \
    '{success:true,path:$path,content:$content,encoding:"utf-8",version:$version}'

  if [[ -n "$converted_tmp" ]]; then
    rm -f "$converted_tmp"
  fi
}

op_download() {
  local rel
  rel="$(normalize_rel_path "${1:-}")"
  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "File path is required"
  fi

  local target
  target="$(resolve_existing_path "$rel")"

  if [[ -d "$target" ]]; then
    die "IS_DIRECTORY" "Cannot download a directory"
  fi

  if [[ ! -f "$target" ]]; then
    die "NOT_FOUND" "File not found"
  fi

  validate_binary_transfer_size "$target"

  local file_name mime size version content_b64
  file_name="$(basename "$target")"
  mime="$(detect_mime_type "$target" "$file_name")"
  size="$(get_file_size "$target")"
  version="$(compute_version "$target")"
  content_b64="$(base64 -w 0 "$target" 2>/dev/null || base64 "$target" | tr -d '\n')"

  jq -nc \
    --arg path "$rel" \
    --arg fileName "$file_name" \
    --arg mimeType "$mime" \
    --arg version "$version" \
    --arg contentBase64 "$content_b64" \
    --argjson size "$size" \
    '{success:true,path:$path,fileName:$fileName,mimeType:$mimeType,size:$size,version:$version,contentBase64:$contentBase64}'
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
  validate_text_size "$tmp_file"

  if file_contains_null_bytes "$tmp_file"; then
    die "PATH_INVALID" "Binary files are not supported in text write"
  fi

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

  jq -nc --arg path "$rel" --arg version "$(compute_version "$target")" \
    '{success:true,path:$path,version:$version}'
}

op_upload() {
  local rel expected_version
  rel="$(normalize_rel_path "${1:-}")"
  expected_version="${2:-}"

  if [[ -z "$rel" ]]; then
    die "PATH_INVALID" "File path is required"
  fi

  local target
  target="$(resolve_target_for_write "$rel")"

  if [[ -d "$target" ]]; then
    die "IS_DIRECTORY" "Cannot upload to a directory path"
  fi

  if [[ -L "$target" ]]; then
    die "PATH_INVALID" "Refusing to write through symlink"
  fi

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

  local tmp_input tmp_file
  tmp_input="$(mktemp)"
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_input" "$tmp_file"' EXIT

  cat > "$tmp_input"

  if base64 -d "$tmp_input" > "$tmp_file" 2>/dev/null; then
    :
  else
    cp "$tmp_input" "$tmp_file"
  fi

  validate_binary_transfer_size "$tmp_file"

  if ! mv "$tmp_file" "$target"; then
    die "EXECUTION_ERROR" "Failed to persist file"
  fi
  trap - EXIT

  local file_name mime size version
  file_name="$(basename "$target")"
  mime="$(detect_mime_type "$target" "$file_name")"
  size="$(get_file_size "$target")"
  version="$(compute_version "$target")"

  jq -nc \
    --arg path "$rel" \
    --arg version "$version" \
    --arg mimeType "$mime" \
    --argjson size "$size" \
    '{success:true,path:$path,version:$version,mimeType:$mimeType,size:$size}'
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

op_rename() {
  local from_rel to_rel
  from_rel="$(normalize_rel_path "${1:-}")"
  to_rel="$(normalize_rel_path "${2:-}")"

  if [[ -z "$from_rel" || -z "$to_rel" ]]; then
    die "PATH_INVALID" "Both source and destination paths are required"
  fi

  local from_target to_target
  from_target="$(resolve_existing_path "$from_rel")"
  to_target="$(resolve_target_for_write "$to_rel")"

  if [[ -e "$to_target" ]]; then
    die "PATH_INVALID" "Destination already exists"
  fi

  mv "$from_target" "$to_target" || die "EXECUTION_ERROR" "Failed to rename item"
  jq -nc --arg from "$from_rel" --arg to "$to_rel" '{success:true,fromPath:$from,toPath:$to}'
}

op_move() {
  op_rename "${1:-}" "${2:-}"
}

op_copy() {
  local from_rel to_rel
  from_rel="$(normalize_rel_path "${1:-}")"
  to_rel="$(normalize_rel_path "${2:-}")"

  if [[ -z "$from_rel" || -z "$to_rel" ]]; then
    die "PATH_INVALID" "Both source and destination paths are required"
  fi

  local from_target to_target
  from_target="$(resolve_existing_path "$from_rel")"
  to_target="$(resolve_target_for_write "$to_rel")"

  if [[ -e "$to_target" ]]; then
    die "PATH_INVALID" "Destination already exists"
  fi

  if [[ -d "$from_target" ]]; then
    cp -R "$from_target" "$to_target" || die "EXECUTION_ERROR" "Failed to copy directory"
  else
    cp "$from_target" "$to_target" || die "EXECUTION_ERROR" "Failed to copy file"
  fi

  jq -nc --arg from "$from_rel" --arg to "$to_rel" '{success:true,fromPath:$from,toPath:$to}'
}

main() {
  local op="${1:-}"

  case "$op" in
    tree)
      op_tree "${2:-}"
      ;;
    stat)
      op_stat "${2:-}"
      ;;
    read)
      op_read "${2:-}"
      ;;
    download)
      op_download "${2:-}"
      ;;
    write)
      op_write "${2:-}" "${3:-}"
      ;;
    upload)
      op_upload "${2:-}" "${3:-}"
      ;;
    mkdir)
      op_mkdir "${2:-}"
      ;;
    delete)
      op_delete "${2:-}" "${3:-false}"
      ;;
    rename)
      op_rename "${2:-}" "${3:-}"
      ;;
    move)
      op_move "${2:-}" "${3:-}"
      ;;
    copy)
      op_copy "${2:-}" "${3:-}"
      ;;
    *)
      die "PATH_INVALID" "Unknown operation"
      ;;
  esac
}

main "$@"
