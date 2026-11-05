#!/usr/bin/env bash
# =====================================================================
# GoogleUnlimited - Native Linux & macOS Unified Manager
# Auto-Sync & Real-Time Watcher with Pixel Unlimited Backup
# =====================================================================
set -u
# Security: Enforce restrictive umask so all created files/directories are accessible only by owner (SEC-03)
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="$SCRIPT_DIR/gphotos.db"
PID_FILE="$SCRIPT_DIR/.watcher.pid"
SERVICE_NAME="google-unlimited.service"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
OS="${OS:-$(uname -s)}"

# Terminal Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m'

# Upload progress and adaptive speed tracking (BUG-05)
LAST_UPLOAD_SPEED=0
CURRENT_UPLOAD_PID=""
CURRENT_UPLOAD_TMP=""

# Supported media extensions regex
MEDIA_EXT_REGEX='^(jpg|jpeg|png|heic|heif|webp|gif|bmp|tiff|tif|svg|ico|jfif|avif|dng|raw|cr2|cr3|nef|arw|orf|rw2|pef|srw|raf|mp4|mov|mkv|avi|m4v|3gp|3g2|wmv|webm|mpg|mpeg|mts|m2ts|ts|flv|vob)$'

is_media_file() {
    local fpath="$1"
    local ext="${fpath##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    echo "$ext" | grep -qE "$MEDIA_EXT_REGEX"
}

# Expand shell-style environment variables in a watch_dirs.txt entry without
# using eval (which would execute command substitutions or other shell syntax).
# Supports $VAR, ${VAR}, ~, and ~/... while leaving unknown variables literal.
expand_watch_path() {
    local remaining="$1"
    local expanded=""
    local token name value

    # shellcheck disable=SC2088
    case "$remaining" in
        \~) remaining="$HOME" ;;
        \~/*) remaining="$HOME/${remaining#\~/}" ;;
    esac

    while [ -n "$remaining" ]; do
        if [[ "$remaining" =~ ^\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            token="\${${name}}"
            remaining="${BASH_REMATCH[2]}"
        elif [[ "$remaining" =~ ^\$([a-zA-Z_][a-zA-Z0-9_]*)(.*)$ ]]; then
            token="\$${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[1]}"
            remaining="${BASH_REMATCH[2]}"
        else
            expanded="${expanded}${remaining:0:1}"
            remaining="${remaining:1}"
            continue
        fi

        if printenv "$name" >/dev/null 2>&1; then
            value="$(printenv "$name")"
            expanded="${expanded}${value}"
        else
            expanded="${expanded}${token}"
        fi
    done

    printf '%s\n' "$expanded"
}

# ---------------------------------------------------------------------
# UPLOAD PROGRESS TRACKING & FORMATTING (BUG-05)
# ---------------------------------------------------------------------
format_remaining_time() {
    local sec="$1"
    local s
    s=$(awk -v sec="$sec" 'BEGIN { printf "%d", sec + 0.5 }')
    if [ "$s" -ge 3600 ]; then
        local h=$((s / 3600))
        local m=$(((s % 3600) / 60))
        printf "~%dh %dm left" "$h" "$m"
    elif [ "$s" -ge 60 ]; then
        local m=$((s / 60))
        local rem_s=$((s % 60))
        printf "~%dm %ds left" "$m" "$rem_s"
    elif [ "$s" -gt 0 ]; then
        printf "~%ds left" "$s"
    else
        printf "finishing..."
    fi
}

calculate_fallback_ratio() {
    local elapsed="$1"
    local est_total="$2"
    awk -v elapsed="$elapsed" -v est_total="$est_total" 'BEGIN {
        if (elapsed < est_total) {
            r = (elapsed / est_total) * 0.90;
            if (r < 0.01) r = 0.01;
            if (r > 0.90) r = 0.90;
            printf "%.6f", r;
        } else {
            over = elapsed - est_total;
            denom = est_total > 30.0 ? est_total : 30.0;
            r = 0.90 + (0.09 * (1.0 - exp(-over / denom)));
            printf "%.6f", r;
        }
    }'
}

render_progress_bar() {
    local ratio="$1"
    local bar_width="${2:-14}"
    awk -v r="$ratio" -v w="$bar_width" 'BEGIN {
        filled = int(r * w);
        if (filled < 0) filled = 0;
        if (filled > w) filled = w;
        empty = w - filled;
        bar = "";
        for (i = 0; i < filled; i++) bar = bar "#";
        for (i = 0; i < empty; i++) bar = bar "-";
        print bar;
    }'
}

get_process_io_read() {
    local pid="$1"
    local pids=("$pid")
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    if [ -n "$children" ]; then
        for c in $children; do
            pids+=("$c")
        done
    fi

    local total=0
    for p in "${pids[@]}"; do
        if [ -r "/proc/$p/io" ]; then
            local r
            r=$(awk '/^read_bytes:/ {print $2}' "/proc/$p/io" 2>/dev/null || true)
            if [ -n "$r" ] && [ "$r" -gt 0 ]; then
                total=$((total + r))
            else
                local rc
                rc=$(awk '/^rchar:/ {print $2}' "/proc/$p/io" 2>/dev/null || true)
                if [ -n "$rc" ] && [ "$rc" -gt 0 ]; then
                    total=$((total + rc))
                fi
            fi
        fi
    done
    echo "$total"
}

# ---------------------------------------------------------------------
# CRYPTOGRAPHIC HASH & BINARY INTEGRITY (BUG-05, SEC-02)
# ---------------------------------------------------------------------
compute_content_hash() {
    local fpath="$1"
    if [ ! -f "$fpath" ]; then
        echo ""
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$fpath" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$fpath" 2>/dev/null | awk '{print $1}'
    else
        echo ""
        return 1
    fi
}

escape_sqlite_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

get_trusted_checksum() {
    local bname="$1"
    # Official trusted SHA-256 checksums from gotohp v0.11.0 release
    case "$bname" in
        gotohp-cli-macos-universal)
            echo "d697e23c648881cf5e7db7b93f815f6d3dcbd9d7718a40d0edffee90456b0557" ;;
        gotohp-cli_amd64)
            echo "945021d5dbc36a96f53121eb4f907ace39d9457cea1b43107ed1986441b29030" ;;
        gotohp-cli-x64.exe)
            echo "c272a285a03aeea02a909f0b74d36f84c4a29c235c8dee47f7de75c83f15d2b1" ;;
        gotohp-x64.exe)
            echo "5c3f757b9e6b2ffd83934b59274136cf4e67c000265e2eaaa4f34dca6a821088" ;;
        *)
            echo "" ;;
    esac
}

verify_binary() {
    local bin_path="$1"
    if [ ! -f "$bin_path" ]; then
        echo -e "${RED}[ERROR] Binary file not found: $bin_path${NC}" >&2
        return 1
    fi
    local bname
    bname="$(basename "$bin_path")"
    local expected
    expected="$(get_trusted_checksum "$bname")"
    if [ -z "$expected" ]; then
        echo -e "${YELLOW}[WARN] No trusted checksum configured for $bname (skipping hash check).${NC}"
        return 0
    fi
    local actual
    actual="$(compute_content_hash "$bin_path")"
    if [ -z "$actual" ]; then
        echo -e "${YELLOW}[WARN] Neither sha256sum nor shasum available to verify binary integrity.${NC}"
        return 0
    fi
    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}[OK] Verified $bname integrity (SHA-256: ${actual:0:16}...)${NC}"
        return 0
    else
        echo -e "${RED}[ERROR] Binary integrity verification failed for $bname!${NC}" >&2
        echo -e "${RED}  Expected: $expected${NC}" >&2
        echo -e "${RED}  Actual:   $actual${NC}" >&2
        return 1
    fi
}

do_verify() {
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  GoogleUnlimited - Binary Integrity Check${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    local bin
    bin="$(get_gotohp_bin)"
    if [ -z "$bin" ]; then
        echo -e "${RED}[ERROR] No gotohp-cli binary found in $SCRIPT_DIR${NC}" >&2
        return 1
    fi
    echo "Checking binary: $bin"
    verify_binary "$bin"
}

# ---------------------------------------------------------------------
# BINARY & CONFIG DISCOVERY
# ---------------------------------------------------------------------
get_gotohp_bin() {
    local cands=("$SCRIPT_DIR/gotohp-cli")
    if [ "$OS" = "Darwin" ]; then
        cands+=("$SCRIPT_DIR/gotohp-cli-macos-universal" "$SCRIPT_DIR/gotohp-cli-macos")
    else
        cands+=("$SCRIPT_DIR/gotohp-cli_amd64" "$SCRIPT_DIR/gotohp-cli_arm64")
    fi

    for cand in "${cands[@]}"; do
        if [ -s "$cand" ]; then
            chmod +x "$cand" 2>/dev/null || true
            echo "$cand"
            return 0
        fi
    done

    # Fallback to any other gotohp-cli binary in SCRIPT_DIR
    for cand in "$SCRIPT_DIR"/gotohp-cli*; do
        if [ -s "$cand" ] && [ "$cand" != "$SCRIPT_DIR/gotohp.config" ]; then
            chmod +x "$cand" 2>/dev/null || true
            echo "$cand"
            return 0
        fi
    done

    if command -v gotohp-cli >/dev/null 2>&1; then
        command -v gotohp-cli
        return 0
    fi
    echo ""
}

get_gotohp_cmd() {
    local bin
    bin="$(get_gotohp_bin)"
    if [ -z "$bin" ]; then
        echo "ERROR: gotohp-cli binary not found in $SCRIPT_DIR or system PATH." >&2
        echo "Please run: ./google-unlimited.sh setup" >&2
        exit 1
    fi
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        echo "$bin --config $SCRIPT_DIR/gotohp.config"
    else
        echo "$bin"
    fi
}

run_gotohp() {
    local bin
    bin="$(get_gotohp_bin)"
    if [ -z "$bin" ]; then
        echo "ERROR: gotohp-cli binary not found in $SCRIPT_DIR or system PATH." >&2
        echo "Please run: ./google-unlimited.sh setup" >&2
        exit 1
    fi
    if ! verify_binary "$bin" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Binary integrity verification failed for $bin. Aborting execution.${NC}" >&2
        exit 1
    fi
    local cmd=("$bin")
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        cmd+=("--config" "$SCRIPT_DIR/gotohp.config")
    fi
    "${cmd[@]}" "$@"
    local ret=$?
    # Security: Ensure gotohp.config retains restrictive 600 permissions
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi
    return $ret
}

# ---------------------------------------------------------------------
# DATABASE INITIALIZATION & LOGGING
# ---------------------------------------------------------------------
init_db() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] sqlite3 is not installed. Please run: ./google-unlimited.sh setup${NC}" >&2
        exit 1
    fi

    # Security: Ensure restricted permissions on database, journals, and credentials (SEC-03)
    touch "$DB" 2>/dev/null || true
    chmod 600 "$DB"* 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi

    sqlite3 "$DB" >/dev/null << 'EOF'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS uploads (
    path        TEXT PRIMARY KEY,
    media_key   TEXT,
    uploaded_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);

CREATE TABLE IF NOT EXISTS retry_queue (
    path         TEXT PRIMARY KEY,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);

CREATE TABLE IF NOT EXISTS logs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    level     TEXT NOT NULL,
    message   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_logs_ts    ON logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
EOF

    # Dual-boot cross-platform tracking and content hash migration (BUG-05)
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN file_name TEXT;" 2>/dev/null || true
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN file_size INTEGER;" 2>/dev/null || true
    sqlite3 "$DB" "ALTER TABLE uploads ADD COLUMN content_hash TEXT;" 2>/dev/null || true
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_uploads_file ON uploads(file_name, file_size);" 2>/dev/null || true
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(content_hash);" 2>/dev/null || true
}

write_log() {
    local msg="$1"
    local level="${2:-INFO}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local escaped_msg
    escaped_msg="$(escape_sqlite_literal "$msg")"
    local escaped_level
    escaped_level="$(escape_sqlite_literal "$level")"
    sqlite3 "$DB" <<EOF 2>/dev/null || true
INSERT INTO logs(level, message) VALUES ('$escaped_level', '$escaped_msg');
EOF
    echo "[$ts][$level] $msg"
}

is_uploaded() {
    local fpath="$1"
    local fname="${2:-$(basename "$fpath")}"
    local fsize="${3:-0}"
    local escaped_path
    escaped_path="$(escape_sqlite_literal "$fpath")"
    local escaped_name
    escaped_name="$(escape_sqlite_literal "$fname")"

    # Ensure fsize is numeric to prevent SQL injection
    if ! [[ "$fsize" =~ ^[0-9]+$ ]]; then
        fsize=0
    fi

    # 1. Exact path match: verify file size and hash haven't changed since previous upload
    local exact_row
    exact_row=$(sqlite3 "$DB" <<EOF 2>/dev/null || true
SELECT file_size || '|' || COALESCE(content_hash, '') FROM uploads WHERE path = '$escaped_path' LIMIT 1;
EOF
)
    if [ -n "$exact_row" ]; then
        local prev_size="${exact_row%%|*}"
        local prev_hash="${exact_row#*|}"
        if [ "$prev_size" -gt 0 ] && [ "$fsize" -gt 0 ] && [ "$prev_size" -ne "$fsize" ]; then
            return 1
        fi
        if [ -n "$prev_hash" ]; then
            local cur_hash
            cur_hash="$(compute_content_hash "$fpath")"
            if [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ]; then
                return 1
            fi
        fi
        return 0
    fi

    # 2. Dual-boot cross-platform deduplication check with content hash verification (BUG-05)
    if [ "$fsize" -gt 0 ]; then
        local match_row
        match_row=$(sqlite3 "$DB" <<EOF 2>/dev/null || true
SELECT content_hash FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND file_size > 0 LIMIT 1;
EOF
)
        if [ -n "$match_row" ]; then
            local current_hash
            current_hash="$(compute_content_hash "$fpath")"
            if [ -n "$current_hash" ]; then
                local hash_match
                hash_match=$(sqlite3 "$DB" <<EOF 2>/dev/null || echo 0
SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND content_hash = '$current_hash';
EOF
)
                if [ -n "$hash_match" ] && [ "$hash_match" -gt 0 ]; then
                    return 0
                fi
                # Check for legacy entry without content_hash
                local legacy_match
                legacy_match=$(sqlite3 "$DB" <<EOF 2>/dev/null || echo 0
SELECT COUNT(*) FROM uploads WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');
EOF
)
                if [ -n "$legacy_match" ] && [ "$legacy_match" -gt 0 ]; then
                    sqlite3 "$DB" <<EOF 2>/dev/null || true
UPDATE uploads SET content_hash = '$current_hash' WHERE file_name = '$escaped_name' AND file_size = $fsize AND (content_hash IS NULL OR content_hash = '');
EOF
                    return 0
                fi
                return 1
            else
                return 0
            fi
        fi
    fi

    return 1
}

save_upload() {
    local fpath="$1"
    local mkey="$2"
    local fname="${3:-$(basename "$fpath")}"
    local fsize="${4:-0}"
    local escaped_path
    escaped_path="$(escape_sqlite_literal "$fpath")"
    local escaped_mkey
    escaped_mkey="$(escape_sqlite_literal "$mkey")"
    local escaped_name
    escaped_name="$(escape_sqlite_literal "$fname")"
    local chash
    chash="$(compute_content_hash "$fpath")"
    local escaped_hash
    escaped_hash="$(escape_sqlite_literal "$chash")"

    if ! [[ "$fsize" =~ ^[0-9]+$ ]]; then
        fsize=0
    fi

    sqlite3 "$DB" << EOF
INSERT OR REPLACE INTO uploads(path, media_key, file_name, file_size, content_hash) VALUES ('$escaped_path', '$escaped_mkey', '$escaped_name', $fsize, '$escaped_hash');
DELETE FROM retry_queue WHERE path = '$escaped_path';
EOF
}

save_retry() {
    local fpath="$1"
    local attempts="${2:-0}"
    local escaped_path
    escaped_path="$(escape_sqlite_literal "$fpath")"
    if ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
        attempts=0
    fi
    sqlite3 "$DB" <<EOF 2>/dev/null || true
INSERT OR REPLACE INTO retry_queue(path, attempts, last_attempt) VALUES ('$escaped_path', $attempts, datetime('now','localtime'));
EOF
}

remove_retry() {
    local fpath="$1"
    local escaped_path
    escaped_path="$(escape_sqlite_literal "$fpath")"
    sqlite3 "$DB" <<EOF 2>/dev/null || true
DELETE FROM retry_queue WHERE path = '$escaped_path';
EOF
}

flush_retry_queue() {
    local retry_list
    retry_list=$(sqlite3 "$DB" "SELECT path FROM retry_queue WHERE attempts < 3;" 2>/dev/null || true)
    [ -z "$retry_list" ] && return
    while IFS= read -r rfile; do
        [ -z "$rfile" ] && continue
        if [ -f "$rfile" ]; then
            local rfname
            rfname="$(basename "$rfile")"
            local rsize_bytes
            rsize_bytes=$(stat -c%s "$rfile" 2>/dev/null || stat -f%z "$rfile" 2>/dev/null || echo 0)
            if ! is_uploaded "$rfile" "$rfname" "$rsize_bytes"; then
                invoke_upload "$rfile"
            fi
        else
            remove_retry "$rfile"
        fi
    done <<< "$retry_list"
}

# ---------------------------------------------------------------------
# ACTION: SETUP & DEPENDENCIES
# ---------------------------------------------------------------------
do_setup() {
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  GoogleUnlimited - Setup & Dependency Installer${NC}"
    echo -e "${GRAY}  Location : $SCRIPT_DIR${NC}"
    echo -e "${GRAY}  Platform : $OS ($(uname -m))${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    if [ "$OS" = "Darwin" ]; then
        local missing=()
        command -v fswatch >/dev/null 2>&1 || missing+=("fswatch")
        command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
        command -v curl >/dev/null 2>&1 || missing+=("curl")

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}[Setup] Missing required macOS tools: ${missing[*]}${NC}"
            if command -v brew >/dev/null 2>&1; then
                echo -e "${YELLOW}[Setup] Installing via Homebrew: brew install ${missing[*]}...${NC}"
                brew install "${missing[@]}"
            else
                echo -e "${RED}[ERROR] Homebrew (brew) is not installed.${NC}"
                echo "Please install Homebrew by running:"
                # shellcheck disable=SC2016
                echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                echo "Then run: brew install ${missing[*]}"
                exit 1
            fi
        else
            echo -e "${GREEN}[OK] Required packages (fswatch, sqlite3, curl) are already installed.${NC}"
        fi

        local target_bin="$SCRIPT_DIR/gotohp-cli-macos-universal"
        if [ ! -s "$target_bin" ]; then
            echo -e "${YELLOW}[Setup] Downloading gotohp-cli Universal for macOS...${NC}"
            local tmp_bin="$target_bin.dl"
            rm -f "$tmp_bin"
            if curl -fSL "https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli-macos-universal" -o "$tmp_bin"; then
                if verify_binary "$tmp_bin"; then
                    mv "$tmp_bin" "$target_bin"
                else
                    echo -e "${RED}[SECURITY ERROR] Downloaded macOS binary failed integrity verification! Removing.${NC}" >&2
                    rm -f "$tmp_bin"
                fi
            else
                echo -e "${RED}[ERROR] Failed to download gotohp-cli Universal for macOS.${NC}" >&2
                rm -f "$tmp_bin"
            fi
        else
            verify_binary "$target_bin" || true
        fi

        if [ -s "$target_bin" ]; then
            xattr -d com.apple.quarantine "$target_bin" 2>/dev/null || true
            chmod 700 "$target_bin" 2>/dev/null || true
        fi

    else
        local missing=()
        command -v inotifywait >/dev/null 2>&1 || missing+=("inotify-tools")
        command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
        command -v curl >/dev/null 2>&1 || missing+=("curl")

        if [ ${#missing[@]} -gt 0 ]; then
            echo -e "${YELLOW}[Setup] Installing required packages: ${missing[*]}...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y "${missing[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "${missing[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm "${missing[@]}"
            elif command -v zypper >/dev/null 2>&1; then
                sudo zypper install -y "${missing[@]}"
            else
                echo -e "${RED}[WARN] Could not identify package manager. Please install manually: ${missing[*]}${NC}"
            fi
        else
            echo -e "${GREEN}[OK] Required packages (inotify-tools, sqlite3, curl) are already installed.${NC}"
        fi

        local arch
        arch="$(uname -m)"
        local target_bin="$SCRIPT_DIR/gotohp-cli_amd64"
        local dl_url="https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli_amd64"
        if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
            target_bin="$SCRIPT_DIR/gotohp-cli_arm64"
            dl_url="https://github.com/xob0t/gotohp/releases/download/v0.11.0/gotohp-cli_arm64"
        fi

        if [ ! -s "$target_bin" ]; then
            echo -e "${YELLOW}[Setup] Downloading gotohp-cli for Linux ($arch)...${NC}"
            local tmp_bin="$target_bin.dl"
            rm -f "$tmp_bin"
            if curl -fSL "$dl_url" -o "$tmp_bin"; then
                if verify_binary "$tmp_bin"; then
                    mv "$tmp_bin" "$target_bin"
                else
                    echo -e "${RED}[SECURITY ERROR] Downloaded Linux binary failed integrity verification! Removing.${NC}" >&2
                    rm -f "$tmp_bin"
                fi
            else
                echo -e "${RED}[ERROR] Failed to download gotohp-cli binary.${NC}" >&2
                rm -f "$tmp_bin"
            fi
        else
            verify_binary "$target_bin" || true
        fi
        if [ -s "$target_bin" ]; then
            chmod 700 "$target_bin" 2>/dev/null || true
        fi
    fi

    # Set execution permissions on scripts and binaries
    chmod 755 "$SCRIPT_DIR"/*.sh 2>/dev/null || true
    chmod 700 "$SCRIPT_DIR"/gotohp-cli* 2>/dev/null || true

    # Security: Restrict permissions on sensitive configuration files (SEC-03)
    if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
        chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    fi
    if [ -f "$DB" ]; then
        chmod 600 "$DB"* 2>/dev/null || true
    fi
    echo -e "${GREEN}[OK] Security permissions hardened (chmod 600 on secrets, 700 on binaries).${NC}"

    # Check credentials
    local creds_out
    creds_out="$(run_gotohp creds list 2>&1 || true)"
    if echo "$creds_out" | grep -q "\*"; then
        echo -e "${GREEN}[OK] Active Google Photos account detected.${NC}"
    else
        echo ""
        echo -e "${YELLOW}==========================================================${NC}"
        echo -e "${YELLOW}  ACTION REQUIRED: Sign In to Google Photos${NC}"
        echo -e "${YELLOW}==========================================================${NC}"
        echo "  1. On any browser, open Google Embedded Setup sign-in."
        echo "  2. Retrieve your 'oauth_token' cookie from DevTools."
        local cfg_hint=""
        if [ -f "$SCRIPT_DIR/gotohp.config" ]; then
            cfg_hint="--config gotohp.config "
        fi
        echo "  3. Run (interactive hidden input - SEC-01):"
        echo "     ./google-unlimited.sh ${cfg_hint}creds add"
        echo "     Or pipe via standard input:"
        echo "     echo \"<oauth_token>\" | ./google-unlimited.sh ${cfg_hint}creds add -"
        echo -e "${YELLOW}==========================================================${NC}"
    fi

    echo ""
    echo -e "${GREEN}[Setup] Complete! You can now run: ./google-unlimited.sh${NC}"
}

# ---------------------------------------------------------------------
# ACTION: STATUS
# ---------------------------------------------------------------------
do_status() {
    init_db
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  Google Photos Sync Status${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local total_count
    total_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM uploads;" 2>/dev/null || echo 0)
    local retry_count
    retry_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM retry_queue;" 2>/dev/null || echo 0)

    echo -e "  Total Uploaded Files : ${YELLOW}$total_count${NC}"
    if [ "$retry_count" -gt 0 ]; then
        echo -e "  Pending Retries      : ${RED}$retry_count${NC}"
    else
        echo -e "  Pending Retries      : ${GREEN}0${NC}"
    fi

    echo ""
    echo -e "${CYAN}  Last 10 Uploads:${NC}"
    local last_uploads
    last_uploads=$(sqlite3 "$DB" "SELECT uploaded_at, path FROM uploads ORDER BY uploaded_at DESC LIMIT 10;" 2>/dev/null || true)
    if [ -n "$last_uploads" ]; then
        while IFS='|' read -r uploaded_at fpath; do
            fname="${fpath##*[/\\]}"
            echo -e "    ${GRAY}[$uploaded_at]${NC} $fname"
        done <<< "$last_uploads"
    else
        echo -e "    ${GRAY}(None yet)${NC}"
    fi

    if [ "$retry_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}  Pending Retries in Queue:${NC}"
        local retries
        retries=$(sqlite3 "$DB" "SELECT path, attempts FROM retry_queue;" 2>/dev/null || true)
        while IFS='|' read -r fpath attempts; do
            fname=$(basename "$fpath")
            echo -e "    ${YELLOW}$fname (attempt $attempts)${NC}"
        done <<< "$retries"
    fi

    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: ACTIVITY LOGS
# ---------------------------------------------------------------------
do_logs() {
    init_db
    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  Google Photos Sync - Activity Logs (Last 30)${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local log_rows
    log_rows=$(sqlite3 "$DB" "SELECT timestamp, level, message FROM (SELECT id, timestamp, level, message FROM logs ORDER BY id DESC LIMIT 30) ORDER BY id ASC;" 2>/dev/null || true)

    if [ -n "$log_rows" ]; then
        while IFS='|' read -r timestamp level message; do
            local color="$GRAY"
            case "$level" in
                "OK")    color="$GREEN" ;;
                "WARN")  color="$YELLOW" ;;
                "ERROR") color="$RED" ;;
            esac
            echo -e "[$timestamp][${color}$level${NC}] $message"
        done <<< "$log_rows"
    else
        echo -e "  ${GRAY}No activity logs found.${NC}"
    fi

    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: STOP WATCHER
# ---------------------------------------------------------------------
do_stop() {
    echo -e "${CYAN}Stopping Google Photos background watcher...${NC}"
    local stopped=0

    # 1. Stop via dedicated PID file if present (REL-02)
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
            local is_watcher=0
            if [ -d "/proc/$pid" ]; then
                if grep -qa "google-unlimited" "/proc/$pid/cmdline" 2>/dev/null; then
                    is_watcher=1
                fi
            elif ps -p "$pid" -o command= 2>/dev/null | grep -q "google-unlimited"; then
                is_watcher=1
            fi

            if [ "$is_watcher" -eq 1 ] && [ "$pid" != "$$" ]; then
                kill -TERM "$pid" 2>/dev/null || true
                for ((w=0; w<20; w++)); do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done
                if kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
                echo -e "${GREEN}[OK] Terminated watcher process PID $pid (from PID file)${NC}"
                stopped=1
            fi
        fi
        rm -f "$PID_FILE" 2>/dev/null || true
    fi

    # 2. Scoped fallback for any background watcher instances running this script
    local pids
    pids=$(pgrep -f "google-unlimited\.sh.*watch" || true)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if [ "$pid" != "$$" ]; then
                kill "$pid" 2>/dev/null || true
                echo -e "${GREEN}[OK] Terminated watcher PID $pid${NC}"
                stopped=1
            fi
        done
    fi

    if [ "$OS" = "Darwin" ]; then
        launchctl stop com.googleunlimited.watcher 2>/dev/null || true
        local fpids
        fpids=$(pgrep -f "fswatch.*$SCRIPT_DIR" || true)
        if [ -n "$fpids" ]; then
            for fpid in $fpids; do
                kill "$fpid" 2>/dev/null || true
                echo -e "${GREEN}[OK] Stopped fswatch listener PID $fpid${NC}"
                stopped=1
            done
        fi
    else
        local ipids
        ipids=$(pgrep -f "inotifywait -m -r -e close_write,moved_to,create" || true)
        if [ -n "$ipids" ]; then
            for ipid in $ipids; do
                kill "$ipid" 2>/dev/null || true
                echo -e "${GREEN}[OK] Stopped inotifywait listener PID $ipid${NC}"
                stopped=1
            done
        fi

        if command -v systemctl >/dev/null 2>&1; then
            if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
                echo -e "${GREEN}[OK] Stopped systemd user service '$SERVICE_NAME'${NC}"
                stopped=1
            fi
        fi
    fi

    if [ "$stopped" -eq 1 ]; then
        echo -e "${GREEN}All background watcher instances have been stopped.${NC}"
    else
        echo -e "${YELLOW}No active watcher instances were found running.${NC}"
    fi
}

# ---------------------------------------------------------------------
# ACTION: ENABLE STARTUP (launchd on macOS / systemd on Linux)
# ---------------------------------------------------------------------
do_enable_startup() {
    # Verify valid credentials before enabling startup service (REL-01)
    local creds_check
    creds_check="$(run_gotohp creds list 2>&1 || true)"
    if ! echo "$creds_check" | grep -q "\*"; then
        echo -e "${RED}[ERROR] No active Google account logged in!${NC}" >&2
        echo "Please sign in before enabling startup service:" >&2
        echo "  ./google-unlimited.sh creds add" >&2
        return 1
    fi

    if [ "$OS" = "Darwin" ]; then
        echo -e "${CYAN}Enabling Google Photos Auto-Sync on startup (macOS launchd)...${NC}"
        local plist_dir="$HOME/Library/LaunchAgents"
        local plist_file="$plist_dir/com.googleunlimited.watcher.plist"
        mkdir -p "$plist_dir"

        cat << EOF > "$plist_file"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.googleunlimited.watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/google-unlimited.sh</string>
        <string>watch</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
        chmod 644 "$plist_file"
        if command -v launchctl >/dev/null 2>&1; then
            launchctl unload "$plist_file" 2>/dev/null || true
            launchctl load -w "$plist_file"
        fi

        echo ""
        echo -e "${GREEN}==========================================================${NC}"
        echo -e "${GREEN}  *  Auto-Sync has been enabled for macOS startup!${NC}"
        echo -e "${GREEN}==========================================================${NC}"
        echo "LaunchAgent:     $plist_file"
        echo "Check status:    launchctl list | grep com.googleunlimited"
        echo "View logs:       ./google-unlimited.sh logs"
        echo "Disable anytime: ./google-unlimited.sh disable"
        echo ""
        return 0
    fi

    echo -e "${CYAN}Enabling Google Photos Auto-Sync on startup (Linux systemd)...${NC}"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] systemctl not found. Your Linux distribution does not appear to use systemd.${NC}"
        echo "You can manually add '$SCRIPT_DIR/google-unlimited.sh watch' to your desktop autostart or cron (@reboot)."
        exit 1
    fi

    mkdir -p "$USER_SYSTEMD_DIR"

    cat << EOF > "$USER_SYSTEMD_DIR/$SERVICE_NAME"
[Unit]
Description=Google Photos Unlimited Auto-Sync Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/google-unlimited.sh watch
Restart=on-failure
RestartSec=10
KillMode=mixed

[Install]
WantedBy=default.target
EOF

    echo -e "${GREEN}[OK] Service unit created at: $USER_SYSTEMD_DIR/$SERVICE_NAME${NC}"

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    systemctl --user restart "$SERVICE_NAME"

    if command -v loginctl >/dev/null 2>&1; then
        local current_user="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null || echo "")}"
        if [ -n "$current_user" ]; then
            loginctl enable-linger "$current_user" 2>/dev/null || true
        fi
    fi

    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}  *  Auto-Sync has been enabled for Linux startup!${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo "Status check:    systemctl --user status $SERVICE_NAME"
    echo "View logs:       ./google-unlimited.sh logs"
    echo "Disable anytime: ./google-unlimited.sh disable"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: DISABLE STARTUP (launchd on macOS / systemd on Linux)
# ---------------------------------------------------------------------
do_disable_startup() {
    echo -e "${CYAN}Disabling Google Photos Auto-Sync startup service...${NC}"

    if [ "$OS" = "Darwin" ]; then
        local plist_file="$HOME/Library/LaunchAgents/com.googleunlimited.watcher.plist"
        if [ -f "$plist_file" ]; then
            launchctl unload -w "$plist_file" 2>/dev/null || true
            rm -f "$plist_file"
            echo -e "${GREEN}[OK] Removed LaunchAgent: $plist_file${NC}"
        fi
        echo ""
        echo -e "${GREEN}==========================================================${NC}"
        echo -e "${GREEN}  *  Google Photos Auto-Sync startup has been disabled.${NC}"
        echo -e "${GREEN}==========================================================${NC}"
        echo ""
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    if [ -f "$USER_SYSTEMD_DIR/$SERVICE_NAME" ]; then
        rm -f "$USER_SYSTEMD_DIR/$SERVICE_NAME"
        echo -e "${GREEN}[OK] Removed service unit: $USER_SYSTEMD_DIR/$SERVICE_NAME${NC}"
    fi

    echo ""
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${GREEN}  *  Google Photos Auto-Sync startup has been disabled.${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------
# ACTION: CORE WATCHER & UPLOADER
# ---------------------------------------------------------------------
wait_for_file_ready() {
    local fpath="$1"
    [ ! -f "$fpath" ] && return 2

    local last_size=-1
    local stable_count=0

    for ((i=0; i<30; i++)); do
        [ ! -f "$fpath" ] && return 2
        local size
        size=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)

        if [ "$size" -le 0 ]; then
            sleep 1
            continue
        fi

        if [ "$size" -ne "$last_size" ]; then
            last_size="$size"
            stable_count=1
            sleep 1
            continue
        else
            stable_count=$((stable_count + 1))
        fi

        if [ "$stable_count" -ge 2 ]; then
            local locked=0
            if command -v lsof >/dev/null 2>&1; then
                if lsof "$fpath" 2>/dev/null | grep -qE " (W|u) "; then
                    locked=1
                fi
            elif command -v fuser >/dev/null 2>&1; then
                if fuser -s "$fpath" 2>/dev/null; then
                    locked=1
                fi
            fi

            if [ "$locked" -eq 1 ]; then
                sleep 1
                continue
            fi

            return 0
        fi

        sleep 1
    done
    return 1
}

invoke_upload() {
    local fpath="$1"
    [ -d "$fpath" ] && return
    # Security: Skip symbolic links to prevent arbitrary file traversal
    [ -L "$fpath" ] && return
    [ ! -f "$fpath" ] && return
    case "$fpath" in
        */Modules/*) return ;;
        *.db|*.db-wal|*.db-shm|*.config|*.tmp|*.crdownload|*.part) return ;;
    esac

    if ! is_media_file "$fpath"; then
        return
    fi

    local fname
    fname="$(basename "$fpath")"
    local size_bytes
    size_bytes=$(stat -c%s "$fpath" 2>/dev/null || stat -f%z "$fpath" 2>/dev/null || echo 0)
    local size_mb
    size_mb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.2f", b/1048576 }')

    # Dual-boot cross-platform deduplication check
    if is_uploaded "$fpath" "$fname" "$size_bytes"; then
        return
    fi

    echo ""
    echo "[$(date '+%H:%M:%S')] Detected  : $fname (${size_mb} MB)"
    echo "             Path      : $fpath"

    wait_for_file_ready "$fpath"
    local status=$?
    local escaped_path
    escaped_path="$(escape_sqlite_literal "$fpath")"

    if [ $status -eq 2 ]; then
        remove_retry "$fpath"
        return
    elif [ $status -eq 1 ]; then
        local prev
        prev=$(sqlite3 "$DB" <<EOF 2>/dev/null || echo 0
SELECT attempts FROM retry_queue WHERE path = '$escaped_path';
EOF
)
        [ -z "$prev" ] && prev=0
        write_log "File still downloading/locked ($fname) - remaining in queue." "WARN"
        save_retry "$fpath" "$prev"
        return
    fi

    # Prepare units and baseline estimation
    local bar_width=14
    local is_mb=1
    local unit_name="MB"
    local unit_div=1048576
    if [ "$size_bytes" -lt 1048576 ]; then
        is_mb=0
        unit_name="KB"
        unit_div=1024
    fi
    local total_formatted
    total_formatted=$(awk -v b="$size_bytes" -v d="$unit_div" 'BEGIN { printf "%.1f", b / d }')

    local timeout_seconds=$(( size_bytes / 51200 ))
    [ "$timeout_seconds" -lt 600 ] && timeout_seconds=600

    local est_speed
    if [ "$size_bytes" -gt 1073741824 ]; then
        est_speed=2097152
    elif [ "${LAST_UPLOAD_SPEED:-0}" -gt 0 ]; then
        est_speed="$LAST_UPLOAD_SPEED"
    else
        est_speed=3145728
    fi

    local est_total_sec
    est_total_sec=$(awk -v b="$size_bytes" -v s="$est_speed" 'BEGIN { t = b / s; if (t < 3.0) t = 3.0; printf "%.1f", t }')

    local out_tmp
    out_tmp="$(mktemp "${TMPDIR:-/tmp}/gotohp_up_XXXXXX.log")"
    chmod 600 "$out_tmp" 2>/dev/null || true
    CURRENT_UPLOAD_TMP="$out_tmp"

    local start_time
    start_time=$(date +%s)

    run_gotohp upload --no-tui "$fpath" > "$out_tmp" 2>&1 &
    local upload_pid=$!
    CURRENT_UPLOAD_PID="$upload_pid"

    local initial_read
    initial_read=$(get_process_io_read "$upload_pid")
    local timed_out=0

    while kill -0 "$upload_pid" 2>/dev/null; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            timed_out=1
            pkill -P "$upload_pid" 2>/dev/null || true
            kill -9 "$upload_pid" 2>/dev/null || true
            break
        fi

        local ratio=0.0
        local uploaded_bytes=0

        # 1. Primary real-time tracking: Process IO Transfer Counters
        local current_read
        current_read=$(get_process_io_read "$upload_pid")
        local raw_delta=$((current_read - initial_read))
        if [ "$raw_delta" -gt 0 ] && [ "$size_bytes" -gt 0 ]; then
            uploaded_bytes=$(( raw_delta > size_bytes ? size_bytes : raw_delta ))
            ratio=$(awk -v up="$uploaded_bytes" -v tot="$size_bytes" 'BEGIN {
                r = up / tot;
                if (r < 0.01) r = 0.01;
                if (r > 0.99) r = 0.99;
                printf "%.6f", r;
            }')
        fi

        # 2. Fallback tracking: Adaptive monotonic progression if IO counters unavailable
        local c_zero
        c_zero=$(awk -v r="$ratio" 'BEGIN { print (r <= 0.0) ? 1 : 0 }')
        if [ "$c_zero" -eq 1 ]; then
            ratio=$(calculate_fallback_ratio "$elapsed" "$est_total_sec")
            uploaded_bytes=$(awk -v tot="$size_bytes" -v r="$ratio" 'BEGIN { printf "%.0f", tot * r }')
        fi

        local bar
        bar=$(render_progress_bar "$ratio" "$bar_width")
        local pct
        pct=$(awk -v r="$ratio" 'BEGIN { printf "%5.1f", r * 100 }')
        local curr_formatted
        curr_formatted=$(awk -v up="$uploaded_bytes" -v d="$unit_div" 'BEGIN { printf "%.1f", up / d }')

        local eta_str=""
        local c_fin
        c_fin=$(awk -v r="$ratio" 'BEGIN { print (r >= 0.99) ? 1 : 0 }')
        if [ "$c_fin" -eq 1 ]; then
            eta_str=", finalizing..."
        else
            local c_act
            c_act=$(awk -v r="$ratio" -v el="$elapsed" 'BEGIN { print (r > 0.03 && el > 0) ? 1 : 0 }')
            if [ "$c_act" -eq 1 ]; then
                local remain_bytes=$(( size_bytes - uploaded_bytes ))
                [ "$remain_bytes" -lt 0 ] && remain_bytes=0
                local speed_bytes
                speed_bytes=$(awk -v up="$uploaded_bytes" -v el="$elapsed" 'BEGIN { printf "%.0f", up / el }')
                if [ "$speed_bytes" -gt 1024 ]; then
                    local remain_sec
                    remain_sec=$(awk -v rem="$remain_bytes" -v spd="$speed_bytes" 'BEGIN { printf "%.1f", rem / spd }')
                    eta_str=", $(format_remaining_time "$remain_sec")"
                fi
            fi
        fi

        if [ -t 1 ]; then
            printf "\r\033[2K  [%s] %s%% | %s / %s %s (%ss%s)" \
                "$bar" "$pct" "$curr_formatted" "$total_formatted" "$unit_name" "$elapsed" "$eta_str"
        fi

        sleep 0.2
    done

    wait "$upload_pid" 2>/dev/null || true
    local exit_code=$?
    if [ "$timed_out" -eq 1 ]; then
        exit_code=124
    fi

    CURRENT_UPLOAD_PID=""
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    [ "$duration" -lt 1 ] && duration=1

    local output=""
    if [ -f "$out_tmp" ]; then
        output="$(cat "$out_tmp")"
        rm -f "$out_tmp" 2>/dev/null || true
    fi
    CURRENT_UPLOAD_TMP=""

    local mkey=""
    mkey="$(echo "$output" | grep -o '"mediaKey": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "")"
    local err_msg=""
    err_msg="$(echo "$output" | grep -o '"error": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "")"
    [ -z "$err_msg" ] && err_msg="$(echo "$output" | grep -o '"message": *"[^"]*"' | head -n1 | cut -d'"' -f4 || echo "")"

    local is_success=0
    if [ $exit_code -eq 0 ] && [ $timed_out -eq 0 ] && [ -z "$err_msg" ]; then
        if echo "$output" | grep -q '"success": *true' || [ -n "$mkey" ]; then
            is_success=1
        fi
    fi

    local avg_speed=""
    if [ "$duration" -gt 0 ] && [ "$size_bytes" -gt 0 ]; then
        avg_speed=$(awk -v t="$duration" -v b="$size_bytes" 'BEGIN {
            spd = b / t;
            if (spd >= 1048576) {
                printf " (%.1f MB/s)", spd / 1048576;
            } else {
                printf " (%.1f KB/s)", spd / 1024;
            }
        }')
    fi

    local done_bar=""
    for ((i = 0; i < bar_width; i++)); do done_bar="${done_bar}#"; done
    local fail_bar=""
    for ((i = 0; i < bar_width; i++)); do fail_bar="${fail_bar}-"; done

    if [ $is_success -eq 1 ]; then
        if [ "$duration" -ge 1 ] && [ "$size_bytes" -ge 1048576 ]; then
            LAST_UPLOAD_SPEED=$(awk -v cur="${LAST_UPLOAD_SPEED:-0}" -v t="$duration" -v b="$size_bytes" 'BEGIN {
                spd = b / t;
                if (cur <= 0) cur = 3145728;
                new_spd = (cur * 0.4) + (spd * 0.6);
                if (new_spd < 204800) new_spd = 204800;
                if (new_spd > 209715200) new_spd = 209715200;
                printf "%.0f", new_spd;
            }')
        fi

        if [ -t 1 ]; then
            printf "\r\033[2K  [%s] 100.0%% [OK] Uploaded in %ss%s: %s (%s %s)\n" \
                "$done_bar" "$duration" "$avg_speed" "$fname" "$total_formatted" "$unit_name"
        else
            echo "  [$done_bar] 100.0% [OK] Uploaded in ${duration}s${avg_speed}: $fname ($total_formatted $unit_name)"
        fi
        write_log "SUCCESS | $fname ($total_formatted $unit_name in ${duration}s$avg_speed)" "OK"
        save_upload "$fpath" "$mkey" "$fname" "$size_bytes"
    else
        if [ "$timed_out" -eq 1 ]; then
            if [ -t 1 ]; then
                printf "\r\033[2K  [%s] TIMED OUT after %ss: %s\n" "$fail_bar" "$duration" "$fname"
            else
                echo "  [$fail_bar] TIMED OUT after ${duration}s: $fname"
            fi
            write_log "TIMEOUT | Upload exceeded ${timeout_seconds}s threshold: $fname" "ERROR"
        else
            if [ -t 1 ]; then
                printf "\r\033[2K  [%s] FAILED in %ss: %s\n" "$fail_bar" "$duration" "$fname"
            else
                echo "  [$fail_bar] FAILED in ${duration}s: $fname"
            fi
        fi

        local err_suffix=""
        [ -n "$err_msg" ] && err_suffix=" ($err_msg)"

        local attempts
        attempts=$(sqlite3 "$DB" <<EOF 2>/dev/null || echo 0
SELECT attempts FROM retry_queue WHERE path = '$escaped_path';
EOF
)
        [ -z "$attempts" ] && attempts=0
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 3 ]; then
            write_log "GAVE UP after $attempts upload attempts: $fname$err_suffix" "ERROR"
            remove_retry "$fpath"
        else
            write_log "FAILED upload$err_suffix (attempt $attempts/3) - queued for retry: $fname" "WARN"
            save_retry "$fpath" "$attempts"
        fi
    fi
}

# shellcheck disable=SC2120
do_watch() {
    init_db

    # Check credentials
    local creds_check
    creds_check="$(run_gotohp creds list 2>&1 || true)"
    if ! echo "$creds_check" | grep -q "\*"; then
        # Auto-recovery: If credentials exist but none has '*', activate the first available account
        local first_acc
        first_acc="$(echo "$creds_check" | grep -E -o '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -n1 || echo "")"
        if [ -n "$first_acc" ]; then
            echo -e "${YELLOW}  [Auto-Recovery] Activating Google Photos account: $first_acc${NC}"
            run_gotohp creds set "$first_acc" >/dev/null 2>&1 || true
            creds_check="$(run_gotohp creds list 2>&1 || true)"
        fi
    fi

    if ! echo "$creds_check" | grep -q "\*"; then
        echo ""
        echo -e "${RED}==========================================================${NC}"
        echo -e "${YELLOW}  ACTION REQUIRED: No Google Account Logged In!${NC}"
        echo -e "${RED}==========================================================${NC}"
        echo "  Please sign in by running:"
        echo "    ./google-unlimited.sh creds add \"<oauth_token>\""
        echo -e "${RED}==========================================================${NC}"
        exit 1
    else
        local active_acc
        active_acc="$(echo "$creds_check" | grep '\*' | grep -E -o '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | head -n1 || echo "")"
        [ -n "$active_acc" ] && echo -e "  ${GREEN}Active Account: $active_acc${NC}"
    fi

    # Check watcher dependency
    if [ "$OS" = "Darwin" ]; then
        if ! command -v fswatch >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] 'fswatch' is required on macOS for real-time file monitoring.${NC}" >&2
            echo -e "Please install it via Homebrew: ${YELLOW}brew install fswatch${NC}" >&2
            echo "Or run: ./google-unlimited.sh setup" >&2
            exit 1
        fi
    else
        if ! command -v inotifywait >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] 'inotifywait' is required on Linux for real-time file monitoring.${NC}" >&2
            echo -e "Please install inotify-tools or run: ./google-unlimited.sh setup" >&2
            exit 1
        fi
    fi

    # Discover watched folders
    local watch_dirs=()

    # 1. Custom directories passed via CLI arguments
    for custom_arg in "$@"; do
        if [ -d "$custom_arg" ]; then
            watch_dirs+=("$(cd "$custom_arg" && pwd)")
        fi
    done

    # 2. Watch directory discovery
    if [ -f "$SCRIPT_DIR/watch_dirs.txt" ]; then
        # When watch_dirs.txt exists, watch ONLY user-configured directories
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$line" ] && continue
            case "$line" in \#*) continue ;; esac
            line="$(expand_watch_path "$line")"
            if [ -d "$line" ]; then
                watch_dirs+=("$(cd "$line" && pwd)")
            fi
        done < "$SCRIPT_DIR/watch_dirs.txt"
    else
        # Default behavior: ONLY image and photo folders (Pictures, Downloads, cloud photos)
        for folder in "$HOME/Pictures" "$HOME/Downloads" "$HOME/Google Photos" "$HOME/OneDrive/Pictures" "$HOME/Pictures/iCloud Photos/Photos"; do
            if [ -d "$folder" ]; then
                watch_dirs+=("$folder")
            fi
        done
    fi

    # Deduplicate watched folders
    local unique_dirs=()
    for d in "${watch_dirs[@]+"${watch_dirs[@]}"}"; do
        local seen=0
        for u in "${unique_dirs[@]+"${unique_dirs[@]}"}"; do
            [ "$u" = "$d" ] && seen=1 && break
        done
        [ $seen -eq 0 ] && unique_dirs+=("$d")
    done
    watch_dirs=("${unique_dirs[@]+"${unique_dirs[@]}"}")

    if [ ${#watch_dirs[@]} -eq 0 ]; then
        mkdir -p "$HOME/Pictures"
        watch_dirs=("$HOME/Pictures")
    fi

    echo ""
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  GoogleUnlimited - Watcher ($OS)${NC}"
    echo -e "${GRAY}  Location: $SCRIPT_DIR${NC}"
    echo -e "${GRAY}  Database: $DB${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo "  Watched Folders:"
    for d in "${watch_dirs[@]+"${watch_dirs[@]}"}"; do
        echo "    -> $d"
    done
    echo -e "${CYAN}==========================================================${NC}"

    # Give users a moment to review the startup summary before backup begins.
    sleep 3

    # Phase 1: Startup Scan
    echo -e "${CYAN}[Phase 1] Scanning for unrecorded files...${NC}"
    local file_count=0
    while IFS= read -r -d '' file; do
        if is_media_file "$file"; then
            local fname
            fname="$(basename "$file")"
            local size_bytes
            size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
            if ! is_uploaded "$file" "$fname" "$size_bytes"; then
                file_count=$((file_count + 1))
                invoke_upload "$file"
            fi
        fi
    done < <(find "${watch_dirs[@]+"${watch_dirs[@]}"}" -type f -print0 2>/dev/null)

    # Flush any pending files from retry queue
    flush_retry_queue

    if [ "$file_count" -eq 0 ]; then
        echo -e "${GREEN}[Phase 1] [OK] Everything backed up - zero new files.${NC}"
    else
        echo -e "${GREEN}[Phase 1] [OK] Startup sync complete ($file_count file(s)).${NC}"
    fi

    # Phase 2: Real-time Watcher
    echo "$$" > "$PID_FILE"
    local watcher_pid=""
    if [ "$OS" = "Darwin" ]; then
        echo ""
        echo -e "${YELLOW}[Phase 2] Real-time watcher active (fswatch).${NC}"
        echo "  Waiting for new media... Press Ctrl+C to stop."

        fswatch -r -e "/\\." "${watch_dirs[@]+"${watch_dirs[@]}"}" 2>/dev/null | while IFS= read -r new_path; do
            invoke_upload "$new_path"
        done &
        watcher_pid=$!
    else
        echo ""
        echo -e "${YELLOW}[Phase 2] Real-time watcher active (inotifywait).${NC}"
        echo "  Waiting for new media... Press Ctrl+C to stop."

        inotifywait -m -r -e close_write,moved_to,create --format '%w%f' "${watch_dirs[@]+"${watch_dirs[@]}"}" 2>/dev/null | while IFS= read -r new_path; do
            invoke_upload "$new_path"
        done &
        watcher_pid=$!
    fi

    cleanup() {
        trap - SIGINT SIGTERM EXIT
        echo ""
        echo "Stopping watcher..."
        rm -f "$PID_FILE" 2>/dev/null || true
        if [ -n "${watcher_pid:-}" ]; then
            pkill -P "$watcher_pid" 2>/dev/null || true
            kill "$watcher_pid" 2>/dev/null || true
        fi
        if [ -n "${CURRENT_UPLOAD_PID:-}" ]; then
            pkill -P "$CURRENT_UPLOAD_PID" 2>/dev/null || true
            kill -9 "$CURRENT_UPLOAD_PID" 2>/dev/null || true
        fi
        if [ -n "${CURRENT_UPLOAD_TMP:-}" ] && [ -f "$CURRENT_UPLOAD_TMP" ]; then
            rm -f "$CURRENT_UPLOAD_TMP" 2>/dev/null || true
        fi
        if [ "$OS" = "Darwin" ]; then
            pkill -f "fswatch.*$SCRIPT_DIR" 2>/dev/null || true
        else
            pkill -f "inotifywait.*${watch_dirs[0]}" 2>/dev/null || true
        fi
        exit 0
    }
    trap cleanup SIGINT SIGTERM EXIT

    # Phase 2: periodic retry queue processor (every 30s) and safety sweep (every 15m / 900s)
    local last_sweep=0
    while kill -0 "$watcher_pid" 2>/dev/null; do
        sleep 30
        local now
        now=$(date +%s)

        # Flush retry queue every 30s
        flush_retry_queue

        # Safety sweep for missed files every 900s (15 minutes)
        if [ $((now - last_sweep)) -ge 900 ]; then
            last_sweep=$now
            while IFS= read -r -d '' file; do
                if is_media_file "$file"; then
                    local fname
                    fname="$(basename "$file")"
                    local size_bytes
                    size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
                    if ! is_uploaded "$file" "$fname" "$size_bytes"; then
                        write_log "Sweep caught missed file: $fname" "WARN"
                        invoke_upload "$file"
                    fi
                fi
            done < <(find "${watch_dirs[@]+"${watch_dirs[@]}"}" -type f -print0 2>/dev/null)
        fi
    done
}

# ---------------------------------------------------------------------
# SECURE CREDENTIALS HANDLER (SEC-01)
# ---------------------------------------------------------------------
do_creds() {
    local subcmd="${1:-}"
    shift || true

    if [ "$subcmd" = "add" ]; then
        local token="${1:-}"
        if [ -z "$token" ] || [ "$token" = "-" ]; then
            if [ -t 0 ]; then
                local stty_state=""
                stty_state="$(stty -g 2>/dev/null || true)"
                restore_stty() {
                    if [ -n "$stty_state" ]; then
                        stty "$stty_state" 2>/dev/null || true
                    fi
                }
                trap restore_stty INT TERM EXIT
                echo -n "Enter Google OAuth token (hidden): " >&2
                stty -echo 2>/dev/null || true
                read -r token
                stty echo 2>/dev/null || true
                echo "" >&2
                trap - INT TERM EXIT
                restore_stty
            else
                read -r token
            fi

            if [ -z "$token" ]; then
                echo -e "${RED}[ERROR] No OAuth token provided.${NC}" >&2
                return 1
            fi
            printf "%s\n" "$token" | run_gotohp creds add -
        else
            echo -e "${YELLOW}[SECURITY WARNING] Passing OAuth tokens via command-line arguments exposes them in process listings and shell history.${NC}" >&2
            echo -e "${YELLOW}Please use: ./google-unlimited.sh creds add (interactive hidden prompt) or pipe: creds add -${NC}" >&2
            printf "%s\n" "$token" | run_gotohp creds add -
        fi
    else
        run_gotohp creds "$subcmd" "$@"
    fi
}

# ---------------------------------------------------------------------
# APPLICATION UPDATER (SEC-PRESERVE-CONFIGS)
# ---------------------------------------------------------------------
do_update() {
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  GoogleUnlimited - Application Updater ($OS)${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "Target directory: ${GRAY}$SCRIPT_DIR${NC}"

    # 1. Protect and back up user configuration files
    local backup_dir
    backup_dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'gotohp_backup')"
    echo -e "${YELLOW}[1/3] Backing up local configuration and database...${NC}"

    local protected_files=("gotohp.config" "watch_dirs.txt" "gphotos.db" "gphotos.db-wal" "gphotos.db-shm" ".env")
    local backed_up=0
    for fn in "${protected_files[@]}"; do
        if [ -f "$SCRIPT_DIR/$fn" ]; then
            cp -p "$SCRIPT_DIR/$fn" "$backup_dir/$fn" 2>/dev/null || cp "$SCRIPT_DIR/$fn" "$backup_dir/$fn"
            ((backed_up++))
        fi
    done
    echo -e "${GREEN}      [OK] Backed up $backed_up configuration/database file(s) to safe temp storage.${NC}"

    # 2. Update via Git if available, or direct raw download
    local update_succeeded=0
    if [ -d "$SCRIPT_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        echo -e "${YELLOW}[2/3] Checking for updates via Git...${NC}"
        cd "$SCRIPT_DIR" || exit 1
        local stash_out
        stash_out=$(git stash 2>&1 || true)
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ] && current_branch="main"

        git fetch origin "$current_branch" 2>/dev/null || true
        
        local local_rev remote_rev
        local_rev=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        remote_rev=$(git rev-parse "origin/$current_branch" 2>/dev/null || echo "unknown")

        if [ "$local_rev" != "unknown" ] && [ "$local_rev" = "$remote_rev" ]; then
            echo -e "${GREEN}      [OK] Application is already up-to-date! Current commit: ${local_rev:0:7}${NC}"
            update_succeeded=1
        else
            echo -e "${CYAN}      New version found! Updating branch $current_branch from ${local_rev:0:7} to ${remote_rev:0:7}...${NC}"
            if git pull --ff-only origin "$current_branch" 2>/dev/null || git pull --rebase origin "$current_branch" 2>/dev/null; then
                echo -e "${GREEN}      [OK] Git update completed successfully!${NC}"
                update_succeeded=1
            else
                echo -e "${RED}      [!] Git pull encountered an issue. Check repository status.${NC}"
            fi
        fi
        if [[ "$stash_out" =~ "Saved working directory" ]]; then
            git stash pop 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}[2/3] Standalone mode. Fetching latest scripts from GitHub...${NC}"
        local script_files=("google-unlimited.sh" "WatchAndUpload.ps1" "GoogleUnlimited.bat" "StartPhotosWatcher.vbs")
        local base_url="https://raw.githubusercontent.com/shishir0x/GoogleUnlimited/main"
        local dl_success=1
        for sf in "${script_files[@]}"; do
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL "$base_url/$sf" -o "$SCRIPT_DIR/$sf.new"; then
                    mv "$SCRIPT_DIR/$sf.new" "$SCRIPT_DIR/$sf"
                    echo -e "${GREEN}      [OK] Updated $sf${NC}"
                else
                    rm -f "$SCRIPT_DIR/$sf.new" 2>/dev/null || true
                    dl_success=0
                fi
            fi
        done
        if [ "$dl_success" -eq 1 ]; then
            update_succeeded=1
        fi
    fi

    # 3. Ensure permissions and restore configs if necessary
    echo -e "${YELLOW}[3/3] Verifying configuration files and permissions...${NC}"
    for fn in "${protected_files[@]}"; do
        if [ -f "$backup_dir/$fn" ] && [ ! -f "$SCRIPT_DIR/$fn" ]; then
            cp "$backup_dir/$fn" "$SCRIPT_DIR/$fn"
            echo -e "${GREEN}      [RESTORED] Restored $fn from pre-update backup.${NC}"
        fi
    done
    rm -rf "$backup_dir" 2>/dev/null || true

    chmod +x "$SCRIPT_DIR/google-unlimited.sh" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/gotohp.config" ] && chmod 600 "$SCRIPT_DIR/gotohp.config" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/gphotos.db" ] && chmod 600 "$SCRIPT_DIR/gphotos.db" 2>/dev/null || true

    echo ""
    if [ "$update_succeeded" -eq 1 ]; then
        echo -e "${CYAN}==========================================================${NC}"
        echo -e "${GREEN}  *  Application is updated and ready to run!${NC}"
        echo -e "${GREEN}     Configurations and upload history database preserved.${NC}"
        echo -e "${CYAN}==========================================================${NC}"
    else
        echo -e "${YELLOW}[WARN] Update could not complete automatically. Your configurations remain intact.${NC}"
    fi
}

# ---------------------------------------------------------------------
# INTERACTIVE TERMINAL MENU
# ---------------------------------------------------------------------
show_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${GREEN}  *  GoogleUnlimited - Unix Manager ($OS)${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo "  [1] Start Live Watcher (Foreground)"
    echo "  [2] Check Backup Status"
    echo "  [3] View Activity Logs"
    echo "  [4] Run Setup & Dependency Installer"
    if [ "$OS" = "Darwin" ]; then
        echo "  [5] Enable Auto-Start on Boot (macOS launchd)"
    else
        echo "  [5] Enable Auto-Start on Boot (Linux systemd)"
    fi
    echo "  [6] Disable Auto-Start on Boot"
    echo "  [7] Stop Background Watcher"
    echo "  [8] Verify Binary Integrity"
    echo "  [9] Check / Update Application (Keep configs safe)"
    echo "  [0] Exit"
    echo -e "${CYAN}==========================================================${NC}"
    read -rp "Select an option [0-9, Default: 1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) do_watch ;;
        2) do_status ;;
        3) do_logs ;;
        4) do_setup ;;
        5) do_enable_startup ;;
        6) do_disable_startup ;;
        7) do_stop ;;
        8) do_verify ;;
        9) do_update ;;
        0) exit 0 ;;
        *) echo "Invalid option"; sleep 1; show_menu ;;
    esac
}

show_help() {
    echo "Usage: ./google-unlimited.sh [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  watch             Start live real-time sync watcher (default)"
    echo "  status            Check upload count and pending retries"
    echo "  logs              View last 30 sync activity log entries"
    echo "  setup             Install dependencies (fswatch/inotify-tools, sqlite3)"
    echo "  enable            Enable auto-start on boot (launchd on macOS / systemd on Linux)"
    echo "  disable           Disable auto-start service"
    echo "  stop              Stop running background watcher instances"
    echo "  verify            Verify gotohp-cli binary integrity using trusted SHA-256"
    echo "  creds             Manage credentials securely (creds add / creds list)"
    echo "  update            Check and update application safely (preserves configs)"
    echo "  menu              Open interactive terminal menu"
    echo "  help              Show this help message"
}

# ---------------------------------------------------------------------
# CLI DISPATCHER
# ---------------------------------------------------------------------
main() {
local CMD="${1:-}"
case "$CMD" in
    watch|--watch|run|--run)
        shift || true
        do_watch "$@"
        ;;
    status|--status|-s)
        do_status
        ;;
    logs|--logs|-l)
        do_logs
        ;;
    setup|--setup)
        do_setup
        ;;
    enable|enable-startup|--enable)
        do_enable_startup
        ;;
    disable|disable-startup|--disable)
        do_disable_startup
        ;;
    stop|--stop)
        do_stop
        ;;
    verify|--verify)
        do_verify
        ;;
    creds)
        shift
        do_creds "$@"
        ;;
    update|--update|upgrade|--upgrade)
        do_update
        ;;
    menu|--menu)
        show_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        if [ -t 0 ]; then
            show_menu
        else
            # shellcheck disable=SC2119
            do_watch
        fi
        ;;
    *)
        echo "Unknown command: $CMD"
        show_help
        exit 1
        ;;
esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
