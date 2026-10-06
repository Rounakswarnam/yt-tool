#!/usr/bin/env bash
set -Eeuo pipefail

APP="yttool"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yttool"
PLAYLIST_DIR="$CONFIG_DIR/playlists"
mkdir -p "$PLAYLIST_DIR"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Missing dependency:${RESET} $1"; exit 1; }; }
need_cmd yt-dlp
need_cmd ffmpeg
need_cmd ffprobe

pause() { echo; read -r -p "Press Enter to continue..." _; }
header() { clear; echo -e "${BOLD}${CYAN}yttool${RESET} — YouTube utility"; echo; }

menu() {
  local title="$1"; shift
  local -a items=("$@")
  local selected=0 key
  while true; do
    header; echo -e "${BOLD}$title${RESET}"; echo
    for i in "${!items[@]}"; do
      if (( i == selected )); then echo -e "  ${CYAN}❯ ${items[i]}${RESET}"; else echo "    ${items[i]}"; fi
    done
    echo; echo -e "${YELLOW}↑/↓${RESET} select  ${YELLOW}Enter${RESET} confirm  ${YELLOW}q${RESET} back/quit"
    IFS= read -rsn1 key || true
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 key || true
        case "$key" in
          '[A') ((selected>0)) && ((selected--));;
          '[B') ((selected<${#items[@]}-1)) && ((selected++));;
        esac ;;
      '') REPLY="$selected"; return 0;;
      q|Q) return 1;;
    esac
  done
}

ask_url() {
  local prompt="$1" url
  while true; do
    read -r -p "$prompt" url
    if [[ -n "$url" ]]; then REPLY="$url"; return 0; fi
    echo "URL cannot be empty."
  done
}

ask_dir() {
  local dir
  read -e -r -p "Download location: " dir
  [[ -z "$dir" ]] && dir="$PWD"
  [[ "$dir" == ~* ]] && dir="$HOME${dir#\~}"
  mkdir -p "$dir"
  REPLY="$(cd "$dir" && pwd)"
}

# The YouTube ID is embedded in the media's comment tag. yt-dlp's normal
# metadata and thumbnail embedding remain enabled, but no sidecar JSON is
# requested.
common_opts=(
  --no-overwrites
  --continue
  --write-thumbnail
  --embed-thumbnail
  --embed-metadata
  --parse-metadata "%(id)s:%(comment)s"
  --no-mtime
  --windows-filenames
)

quality_options() {
  local url="$1" out
  out="$(yt-dlp -F --no-warnings "$url" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk '
    /^[[:space:]]*[0-9]+[[:space:]]/ {
      h="";
      for(i=1;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+$/) { split($i,a,"x"); h=a[2]; }
      if(h ~ /^[0-9]+$/) print h;
    }' | sort -nr -u
}

choose_quality() {
  local url="$1"; local -a qs
  mapfile -t qs < <(quality_options "$url")
  if ((${#qs[@]}==0)); then
    echo "Could not determine available video qualities." >&2
    return 1
  fi
  local -a labels=()
  local q
  for q in "${qs[@]}"; do labels+=("${q}p"); done
  menu "Available video qualities" "${labels[@]}" || return 1
  REPLY="${qs[$REPLY]}"
}

# Read the yt-dlp video ID embedded in the file's comment tag.
# A file without a valid embedded ID is simply ignored; it must NEVER make
# the whole maintenance operation exit under `set -e`.
file_video_id() {
  local file="$1"
  local value=""

  value="$(ffprobe -v error \
    -show_entries format_tags=comment \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file" 2>/dev/null | head -n1 || true)"

  # Already a raw YouTube video ID
  if [[ "$value" =~ ^[[:alnum:]_-]{11}$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  # Extract ID from a normal YouTube watch URL
  if [[ "$value" =~ youtube\.com/watch\?v=([[:alnum:]_-]{11}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  # Extract ID from youtu.be/ID URLs
  if [[ "$value" =~ youtu\.be/([[:alnum:]_-]{11}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 0
}

# Delete temporary thumbnail files created for embedding. Only a sidecar with
# exactly the same basename as an existing media file is removed.
cleanup_thumbnails() {
  local root="$1" file stem ext
  [[ -d "$root" ]] || return 0

  while IFS= read -r -d '' file; do
    stem="${file%.*}"
    for ext in webp jpg jpeg png avif; do
      rm -f -- "$stem.$ext"
    done
  done < <(find "$root" -type f \( \
    -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mkv' \
    -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.flac' \
    -o -iname '*.ogg' -o -iname '*.opus' \
  \) -print0)

  return 0
}

# Remove any sidecar metadata JSON files that may have been created by an
# older yttool version or by a previous run.
cleanup_metadata_json() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  find "$root" -type f -name '*.info.json' -delete
  return 0
}

# Build a temporary, authoritative set of IDs from media that actually exists.
build_local_id_list() {
  local media_dir="$1" out_file="$2"
  : > "$out_file"

  [[ -d "$media_dir" ]] || return 0

  while IFS= read -r -d '' file; do
    local id=""
    id="$(file_video_id "$file")"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id" >> "$out_file"
    fi
  done < <(find "$media_dir" -type f \( \
    -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.mkv' \
    -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.flac' \
    -o -iname '*.ogg' -o -iname '*.opus' \
  \) -print0)

  sort -u -o "$out_file" "$out_file"
  return 0
}

rebuild_archive_from_ids() {
  local ids_file="$1" archive="$2" tmp
  tmp="$(mktemp "${archive}.XXXXXX")"
  while IFS= read -r id; do
    [[ -n "$id" ]] && printf 'youtube %s\n' "$id"
  done < "$ids_file" > "$tmp"
  mv "$tmp" "$archive"
  return 0
}

single_video() {
  header; echo -e "${BOLD}Download single video${RESET}"; echo
  ask_url "YouTube URL: "; local url="$REPLY"
  echo "Checking available qualities..."
  choose_quality "$url" || return 0
  local quality="$REPLY"
  ask_dir; local dir="$REPLY"
  echo; echo -e "${GREEN}Downloading at up to ${quality}p → $dir${RESET}"; echo

  yt-dlp "${common_opts[@]}" \
    -f "bv*[height<=${quality}]+ba/b[height<=${quality}]/bv*+ba/b" \
    --merge-output-format mp4 \
    -o "$dir/%(title)s.%(ext)s" "$url"

  cleanup_thumbnails "$dir"
  cleanup_metadata_json "$dir"
  pause
}

single_song() {
  header; echo -e "${BOLD}Download single song${RESET}"; echo
  ask_url "YouTube URL: "; local url="$REPLY"
  ask_dir; local dir="$REPLY"
  echo; echo -e "${GREEN}Downloading best available audio → MP3${RESET}"; echo

  yt-dlp "${common_opts[@]}" \
    -f "bestaudio/best" -x --audio-format mp3 --audio-quality 0 \
    -o "$dir/%(title)s.%(ext)s" "$url"

  cleanup_thumbnails "$dir"
  cleanup_metadata_json "$dir"
  pause
}

playlist_id() {
  yt-dlp --flat-playlist --playlist-items 1 --print '%(playlist_id)s' --no-warnings "$1" 2>/dev/null | head -n1
}

playlist_title() {
  yt-dlp --flat-playlist --playlist-items 1 --print '%(playlist_title)s' --no-warnings "$1" 2>/dev/null | head -n1
}

# Ask yt-dlp for the actual output path it would use. This preserves the same
# filename sanitization rules as the download itself.
playlist_folder_name() {
  local root="$1" url="$2" path folder
  path="$(yt-dlp --flat-playlist --playlist-items 1 --skip-download \
    --windows-filenames --print filename \
    -o "$root/%(playlist_title)s/%(playlist_index)03d - %(title)s.%(ext)s" \
    --no-warnings "$url" 2>/dev/null | head -n1)"
  if [[ -n "$path" ]]; then
    folder="$(dirname "$path")"
    folder="${folder#"$root/"}"
    printf '%s\n' "$folder"
  else
    playlist_title "$url"
  fi
}

save_config() {
  local id="$1" url="$2" dir="$3" mode="$4" quality="${5:-}" folder="$6"
  local base="$PLAYLIST_DIR/$id"
  mkdir -p "$base"
  printf '%s\n' "$url" > "$base/url"
  printf '%s\n' "$dir" > "$base/location"
  printf '%s\n' "$mode" > "$base/mode"
  printf '%s\n' "$quality" > "$base/quality"
  printf '%s\n' "$folder" > "$base/folder"
  touch "$base/archive.txt"
}

load_config() {
  local id="$1" base="$PLAYLIST_DIR/$id"
  [[ -f "$base/url" && -f "$base/location" && -f "$base/mode" && -f "$base/quality" && -f "$base/archive.txt" ]] || return 1
  CFG_URL="$(<"$base/url")"
  CFG_DIR="$(<"$base/location")"
  CFG_MODE="$(<"$base/mode")"
  CFG_QUALITY="$(<"$base/quality")"
  CFG_ARCHIVE="$base/archive.txt"
  CFG_FOLDER=""
  [[ -f "$base/folder" ]] && CFG_FOLDER="$(<"$base/folder")"
  return 0
}

new_playlist() {
  header; echo -e "${BOLD}Download new playlist${RESET}"; echo
  ask_url "Playlist URL: "; local url="$REPLY"
  echo "Reading playlist..."
  local id; id="$(playlist_id "$url")" || true
  [[ -n "$id" ]] || { echo -e "${RED}Could not determine playlist ID.${RESET}"; pause; return 0; }

  ask_dir; local dir="$REPLY"
  local folder; folder="$(playlist_folder_name "$dir" "$url")" || true
  [[ -n "$folder" ]] || folder="$id"
  menu "Maintain this playlist?" "Yes" "No" || return 0
  local maintain=$REPLY mode quality=""
  menu "Download as" "Audio (MP3)" "Video (MP4)" || return 0
  if (( REPLY == 0 )); then mode=audio; else mode=video; fi

  if [[ "$mode" == video ]]; then
    echo "Checking video qualities from the playlist..."
    local first_url
    first_url="$(yt-dlp --flat-playlist --playlist-items 1 --print '%(webpage_url)s' --no-warnings "$url" 2>/dev/null | head -n1)"
    [[ -n "$first_url" ]] || { echo -e "${RED}Could not inspect the first playlist item.${RESET}"; pause; return 0; }
    choose_quality "$first_url" || return 0
    quality="$REPLY"
  fi

  local playlist_dir="$dir/$folder"
  mkdir -p "$playlist_dir"
  local archive_args=()

  if (( maintain == 0 )); then
    save_config "$id" "$url" "$dir" "$mode" "$quality" "$folder"
    echo -e "${GREEN}Playlist registered for future maintenance.${RESET}"
    archive_args=(--download-archive "$PLAYLIST_DIR/$id/archive.txt")
  fi

  echo; echo -e "${GREEN}Starting playlist download...${RESET}"; echo
  if [[ "$mode" == audio ]]; then
    yt-dlp "${common_opts[@]}" --ignore-errors "${archive_args[@]}" \
      -f "bestaudio/best" -x --audio-format mp3 --audio-quality 0 \
      -o "$dir/%(playlist_title)s/%(playlist_index)03d - %(title)s.%(ext)s" "$url"
  else
    yt-dlp "${common_opts[@]}" --ignore-errors "${archive_args[@]}" \
      -f "bv*[height<=${quality}]+ba/b[height<=${quality}]/bv*+ba/b" \
      --merge-output-format mp4 \
      -o "$dir/%(playlist_title)s/%(playlist_index)03d - %(title)s.%(ext)s" "$url"
  fi

  cleanup_thumbnails "$dir"
  cleanup_metadata_json "$dir"

  if (( maintain == 0 )); then
    local ids_file
    ids_file="$(mktemp)"
    build_local_id_list "$playlist_dir" "$ids_file"
    rebuild_archive_from_ids "$ids_file" "$PLAYLIST_DIR/$id/archive.txt"
    rm -f "$ids_file"
  fi

  echo -e "${GREEN}Playlist download complete.${RESET}"
  pause
}

maintain_playlist() {
  header; echo -e "${BOLD}Maintain existing playlist${RESET}"; echo
  ask_url "Playlist URL: "; local url="$REPLY"
  echo "Looking for saved playlist configuration..."
  local id; id="$(playlist_id "$url")" || true
  [[ -n "$id" ]] || { echo -e "${RED}Could not determine playlist ID.${RESET}"; pause; return 0; }

  if ! load_config "$id"; then
    echo -e "${YELLOW}This playlist is not registered yet.${RESET}"
    echo "Use 'Download a new playlist' and choose Maintain = Yes first."
    pause; return 0
  fi

  # Migration for configs created by v1/v2, which had no saved folder name.
  if [[ -z "$CFG_FOLDER" ]]; then
    CFG_FOLDER="$(playlist_folder_name "$CFG_DIR" "$CFG_URL")" || true
    [[ -n "$CFG_FOLDER" ]] || CFG_FOLDER="$id"
    printf '%s\n' "$CFG_FOLDER" > "$PLAYLIST_DIR/$id/folder"
  fi

  echo "Mode: ${CFG_MODE^^}"
  [[ "$CFG_MODE" == video ]] && echo "Quality target: ${CFG_QUALITY}p"
  echo "Location: $CFG_DIR"
  echo "Playlist folder: $CFG_FOLDER"
  mkdir -p "$CFG_DIR/$CFG_FOLDER"

  local playlist_root="$CFG_DIR/$CFG_FOLDER"
  local local_ids playlist_ids missing_ids
  local_ids="$(mktemp)"
  playlist_ids="$(mktemp)"
  missing_ids="$(mktemp)"

  # Always clean up our temporary files, but never install a RETURN trap that
  # can interfere with nested function calls under set -e.
  cleanup_maintenance_tmp() {
    rm -f "$local_ids" "$playlist_ids" "$missing_ids"
  }
  trap cleanup_maintenance_tmp RETURN

  echo "Scanning local media..."
  build_local_id_list "$playlist_root" "$local_ids"

  echo "Reading current playlist..."
  yt-dlp --flat-playlist --print '%(id)s' --no-warnings "$CFG_URL" 2>/dev/null \
    | awk 'NF' | sort -u > "$playlist_ids"

  # IDs in the playlist but absent from actual local media.
  comm -23 "$playlist_ids" "$local_ids" > "$missing_ids"
  local missing_count
  missing_count="$(wc -l < "$missing_ids")"

  # The archive is only a cache. Rebuild it from files that really exist.
  rebuild_archive_from_ids "$local_ids" "$CFG_ARCHIVE"

  if (( missing_count == 0 )); then
    echo -e "${GREEN}Playlist is already up to date.${RESET}"
    trap - RETURN
    cleanup_maintenance_tmp
    pause
    return 0
  fi

  echo -e "${GREEN}${missing_count} missing item(s) detected. Downloading...${RESET}"; echo

  if [[ "$CFG_MODE" == audio ]]; then
    yt-dlp "${common_opts[@]}" --ignore-errors \
      --download-archive "$CFG_ARCHIVE" \
      -f "bestaudio/best" -x --audio-format mp3 --audio-quality 0 \
      -o "$CFG_DIR/%(playlist_title)s/%(playlist_index)03d - %(title)s.%(ext)s" "$CFG_URL"
  else
    yt-dlp "${common_opts[@]}" --ignore-errors \
      --download-archive "$CFG_ARCHIVE" \
      -f "bv*[height<=${CFG_QUALITY}]+ba/b[height<=${CFG_QUALITY}]/bv*+ba/b" \
      --merge-output-format mp4 \
      -o "$CFG_DIR/%(playlist_title)s/%(playlist_index)03d - %(title)s.%(ext)s" "$CFG_URL"
  fi

  cleanup_thumbnails "$CFG_DIR/$CFG_FOLDER"
  cleanup_metadata_json "$CFG_DIR/$CFG_FOLDER"

  # Final self-healing archive rebuild. A failed/partial download cannot leave
  # a stale archive entry behind.
  build_local_id_list "$playlist_root" "$local_ids"
  rebuild_archive_from_ids "$local_ids" "$CFG_ARCHIVE"

  echo
  echo -e "${GREEN}Playlist maintenance complete.${RESET}"
  trap - RETURN
  cleanup_maintenance_tmp
  pause
}

main() {
  while true; do
    menu "Main menu" "Download a single video" "Download a single song" "Download a new playlist" "Maintain an existing playlist" "Quit" || exit 0
    case "$REPLY" in
      0) single_video;; 1) single_song;; 2) new_playlist;; 3) maintain_playlist;; 4) exit 0;;
    esac
  done
}

main "$@"
