#!/usr/bin/env bash

# ===================== 基本变量 =====================
CONFIG_DIR="$HOME/.ftp_backup_tool"
ACCOUNTS_DIR="$CONFIG_DIR/accounts"
CONFIG_FILE="$CONFIG_DIR/ftp.conf"
TAG="# FTP_BACKUP"

RAW_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_PATH="$RAW_SCRIPT_PATH"

SCRIPT_URL="https://raw.githubusercontent.com/immiskae/test/main/test.sh"
INSTALL_PATH="/root/back.sh"

mkdir -p "$ACCOUNTS_DIR"

# ===================== 通用工具函数 =====================
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 如果是通过 bash <(curl ...) 这种方式运行，自动落盘到 INSTALL_PATH
normalize_script_path() {
    if [[ "$SCRIPT_PATH" == /dev/fd/* ]] || [[ "$SCRIPT_PATH" == /proc/*/fd/* ]] || [[ "$SCRIPT_PATH" == *"pipe:"* ]]; then
        # 如果还没有正式安装文件，就自动创建一个
        if [[ ! -f "$INSTALL_PATH" ]]; then
            echo "📥 检测到通过 bash <(curl ...) 运行，正在自动安装脚本到：$INSTALL_PATH"
            if command_exists curl; then
                curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH" || cat "$RAW_SCRIPT_PATH" > "$INSTALL_PATH"
            elif command_exists wget; then
                wget -qO "$INSTALL_PATH" "$SCRIPT_URL" || cat "$RAW_SCRIPT_PATH" > "$INSTALL_PATH"
            else
                # 没有 curl / wget，就直接把当前脚本内容拷贝过去
                cat "$RAW_SCRIPT_PATH" > "$INSTALL_PATH"
            fi
            chmod +x "$INSTALL_PATH"
            echo "✅ 安装完成，以后 crontab 将使用：$INSTALL_PATH"
        fi
        SCRIPT_PATH="$INSTALL_PATH"
    fi
}

normalize_script_path

pause() {
    echo
    read -rp "🔸 按回车键继续..." _
}

# ensure_command <cmd> <deb_pkg> <rhel_pkg> <other_pkg>
ensure_command() {
    local cmd="$1"
    local deb_pkg="$2"
    local rhel_pkg="$3"
    local other_pkg="$4"

    if command_exists "$cmd"; then
        return 0
    fi

    echo "⚙️  未检测到依赖：$cmd，尝试自动安装..."

    if command_exists apt-get; then
        # Debian / Ubuntu
        local pkg="${deb_pkg:-$cmd}"
        echo "📦 使用 apt-get 安装：$pkg"
        sudo apt-get update && sudo apt-get install -y "$pkg"
    elif command_exists yum; then
        # CentOS / AlmaLinux / Rocky
        local pkg="${rhel_pkg:-$cmd}"
        echo "📦 使用 yum 安装：$pkg"
        sudo yum install -y "$pkg"
    elif command_exists dnf; then
        # 新版 RHEL 系
        local pkg="${rhel_pkg:-$cmd}"
        echo "📦 使用 dnf 安装：$pkg"
        sudo dnf install -y "$pkg"
    elif command_exists zypper; then
        local pkg="${other_pkg:-$cmd}"
        echo "📦 使用 zypper 安装：$pkg"
        sudo zypper install -y "$pkg"
    elif command_exists pacman; then
        local pkg="${other_pkg:-$cmd}"
        echo "📦 使用 pacman 安装：$pkg"
        sudo pacman -Sy --noconfirm "$pkg"
    else
        echo "❌ 未找到适配的包管理器，请手动安装：$cmd"
        return 1
    fi

    if command_exists "$cmd"; then
        echo "✅ $cmd 安装成功。"
        return 0
    else
        echo "❌ 自动安装 $cmd 失败，请手动安装后重试。"
        return 1
    fi
}

check_dependencies() {
    # lftp：各大发行版包名基本一样
    ensure_command lftp lftp lftp lftp || exit 1

    # crontab：Debian 系 cron，RHEL 系 cronie
    ensure_command crontab cron cronie cron || true
}

# ===================== FTP 账号管理 =====================
is_ftp_configured() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob
    [[ ${#files[@]} -gt 0 ]]
}

get_ftp_count() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob
    echo ${#files[@]}
}

load_ftp_account() {
    local account_id="$1"
    local file="$ACCOUNTS_DIR/$account_id.conf"
    if [[ ! -f "$file" ]]; then
        echo "❌ 找不到 FTP 账号配置：$account_id"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$file"
    # 兼容旧配置：默认使用 ftp
    FTP_PROTO="${FTP_PROTO:-ftp}"
}

add_ftp_account() {
    echo "────────────────────────────────"
    echo "➕ 新增 FTP/SFTP 账号"
    echo "────────────────────────────────"
    read -rp "📝 为此账号起一个名称（例如 main、backup1）： " ACCOUNT_ID
    ACCOUNT_ID="${ACCOUNT_ID// /_}"  # 名称里如果有空格，替换成下划线

    if [[ -z "$ACCOUNT_ID" ]]; then
        echo "❌ 账号名称不能为空。"
        pause
        return
    fi

    local file="$ACCOUNTS_DIR/$ACCOUNT_ID.conf"
    if [[ -f "$file" ]]; then
        echo "⚠️  已存在同名账号配置，将覆盖该账号。"
    fi

    read -rp "🌐 远程主机 (例如 ftp.example.com 或 sftp.example.com)： " FTP_HOST

    echo
    echo "🔐 请选择连接协议："
    echo "  1) 普通 FTP"
    echo "  2) 加密 FTPS"
    echo "  3) SFTP (基于 SSH，默认端口 22)"
    read -rp "👉 请输入选项编号（默认 1）： " proto_choice
    case "$proto_choice" in
        2) FTP_PROTO="ftps" ;;
        3) FTP_PROTO="sftp" ;;
        *) FTP_PROTO="ftp" ;;
    esac

    # 根据协议给出不同默认端口
    local default_port
    case "$FTP_PROTO" in
        sftp) default_port=22 ;;
        *)    default_port=21 ;;
    esac

    read -rp "🔢 远程端口 (默认 $default_port，回车使用默认)： " FTP_PORT
    FTP_PORT=${FTP_PORT:-$default_port}

    read -rp "👤 用户名： " FTP_USER
    read -rp "🔒 密码： " FTP_PASS

    cat > "$file" <<EOF
ACCOUNT_ID="$ACCOUNT_ID"
FTP_HOST="$FTP_HOST"
FTP_PORT="$FTP_PORT"
FTP_USER="$FTP_USER"
FTP_PASS="$FTP_PASS"
FTP_PROTO="$FTP_PROTO"
EOF

    chmod 600 "$file"
    echo "✅ 新账号已保存：$ACCOUNT_ID （协议：$FTP_PROTO，端口：$FTP_PORT）"
    pause
}

show_ftp_accounts() {
    echo "────────────────────────────────"
    echo "📂 FTP/SFTP 账号列表"
    echo "────────────────────────────────"

    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "ℹ️  当前没有任何账号配置。"
        pause
        return
    fi

    local i=1
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        local proto="${FTP_PROTO:-ftp}"
        echo "[$i] 账号名：$ACCOUNT_ID  | 主机：$FTP_HOST  | 端口：$FTP_PORT  | 用户：$FTP_USER  | 协议：$proto"
        i=$((i+1))
    done

    pause
}

delete_ftp_account() {
    echo "────────────────────────────────"
    echo "🗑 删除 FTP/SFTP 账号"
    echo "────────────────────────────────"

    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "ℹ️  当前没有可删除的账号。"
        pause
        return
    fi

    local i=1
    declare -a ACCOUNT_IDS
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        ACCOUNT_IDS[$i]="$ACCOUNT_ID"
        echo "[$i] 账号名：$ACCOUNT_ID  | 主机：$FTP_HOST"
        i=$((i+1))
    done

    read -rp "🔢 请输入要删除的账号编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${ACCOUNT_IDS[$choice]}" ]]; then
        echo "❌ 输入编号无效。"
        pause
        return
    fi

    local target_id="${ACCOUNT_IDS[$choice]}"
    local file="$ACCOUNTS_DIR/$target_id.conf"

    read -rp "⚠️  确认删除账号 [$target_id] 以及其所有备份任务吗？(y/N)： " yn
    case "$yn" in
        y|Y)
            rm -f "$file"
            if command_exists crontab; then
                local current
                current=$(crontab -l 2>/dev/null || true)
                if [[ -n "$current" ]]; then
                    # 每个任务尾部会有 # FTP_BACKUP[account_id]
                    echo "$current" | grep -v "$TAG\[$target_id\]" | crontab -
                fi
            fi
            echo "✅ 已删除账号 [$target_id] 及其相关定时任务。"
            ;;
        *)
            echo "ℹ️  已取消删除。"
            ;;
    esac
    pause
}

CHOSEN_ACCOUNT_ID=""

select_ftp_account() {
    shopt -s nullglob
    local files=("$ACCOUNTS_DIR"/*.conf)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "❌ 当前没有账号，请先添加。"
        return 1
    fi

    echo "────────────────────────────────"
    echo "📂 可用 FTP/SFTP 账号列表："
    echo "────────────────────────────────"

    local i=1
    declare -a ACCOUNT_IDS
    for f in "${files[@]}"; do
        # shellcheck disable=SC1090
        source "$f"
        local proto="${FTP_PROTO:-ftp}"
        ACCOUNT_IDS[$i]="$ACCOUNT_ID"
        echo "[$i] 账号名：$ACCOUNT_ID  | 主机：$FTP_HOST:$FTP_PORT  | 协议：$proto"
        i=$((i+1))
    done

    echo
    read -rp "👉 请输入账号编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${ACCOUNT_IDS[$choice]}" ]]; then
        echo "❌ 输入编号无效。"
        return 1
    fi

    CHOSEN_ACCOUNT_ID="${ACCOUNT_IDS[$choice]}"
    return 0
}

# 小工具：根据协议生成 lftp 里的 SSL 配置（仅 FTP/FTPS 用）
build_ssl_lines() {
    local proto="$1"
    if [[ "$proto" == "ftps" ]]; then
        # 显式 FTPS（FTP over TLS）
        printf '%s\n' \
            "set ftp:ssl-force true" \
            "set ftp:ssl-protect-data true" \
            "set ftp:ssl-auth TLS"
    else
        # 普通 FTP / SFTP 都不需要这几行
        :
    fi
}

# 根据协议决定 lftp 连接目标
# ftp / ftps: 直接用主机名
# sftp: 使用 sftp://host
get_lftp_target() {
    local proto="$1"
    local host="$2"

    if [[ "$proto" == "sftp" ]]; then
        echo "sftp://$host"
    else
        echo "$host"
    fi
}

browse_ftp_with_account() {
    CHOSEN_ACCOUNT_ID=""
    select_ftp_account || { pause; return; }
    local ACCOUNT_ID="$CHOSEN_ACCOUNT_ID"

    load_ftp_account "$ACCOUNT_ID" || { pause; return; }

    while true; do
        clear
        local proto_label="${FTP_PROTO:-ftp}"
        echo "======================================="
        echo "🔍 远程浏览 / 下载 / 删除"
        echo "======================================="
        echo "当前账号：$ACCOUNT_ID  ($FTP_USER@$FTP_HOST:$FTP_PORT, 协议：$proto_label)"
        echo
        echo "1) 📁 列出某个远程目录内容"
        echo "2) 📥 下载远程文件到本地"
        echo "3) 📥 下载远程目录到本地"
        echo "4) ❌ 删除远程文件"
        echo "5) ⚠️ 删除远程目录"
        echo "0) ⬅ 返回上一层"
        echo
        read -rp "👉 请输入选项编号： " sub

        case "$sub" in
            1)
                read -rp "📂 请输入要查看的远程目录（例如 / 或 /backup/www）： " REMOTE_DIR
                if [[ -z "$REMOTE_DIR" ]]; then
                    echo "❌ 远程目录不能为空。"
                    pause
                    continue
                fi
                echo "📋 $REMOTE_DIR 下的内容："
                echo "────────────────────────────────"
                SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
                LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
                SSL_VERIFY_LINE=""
                if [[ "$FTP_PROTO" != "sftp" ]]; then
                    SSL_VERIFY_LINE="set ssl:verify-certificate no"
                fi
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF | awk '!($NF=="." || $NF=="..")'
$SSL_VERIFY_LINE
$SSL_LINES
cd "$REMOTE_DIR" || cd .
ls
bye
EOF
                echo "────────────────────────────────"
                pause
                ;;
            2)
                read -rp "📂 请输入远程文件所在目录（例如 /backup/www）： " RDIR
                read -rp "📄 请输入远程文件名（例如 index.html）： " RFN
                read -rp "📁 请输入下载到本地的目录（例如 /root/download）： " LDIR

                if [[ -z "$RDIR" || -z "$RFN" || -z "$LDIR" ]]; then
                    echo "❌ 目录、文件名和本地目录都不能为空。"
                    pause
                    continue
                fi

                mkdir -p "$LDIR"

                read -rp "⚠️ 确认下载文件 $RDIR/$RFN 到本地 $LDIR 并自动覆盖同名文件吗？(y/N)： " yn_dl
                case "$yn_dl" in
                    y|Y)
                        SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
                        LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
                        SSL_VERIFY_LINE=""
                        if [[ "$FTP_PROTO" != "sftp" ]]; then
                            SSL_VERIFY_LINE="set ssl:verify-certificate no"
                        fi
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
cd "$RDIR" || exit 1
get "$RFN" -o "$LDIR/$RFN"
bye
EOF
                        if [[ $? -eq 0 ]]; then
                            echo "✅ 文件已下载到：$LDIR/$RFN"
                        else
                            echo "❌ 下载失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "ℹ️ 已取消下载。"
                        pause
                        ;;
                esac
                ;;
            3)
                read -rp "📂 请输入要下载的远程目录路径（例如 /test）： " RDIR
                read -rp "📁 请输入下载到本地的目录（例如 /root/download）： " LDIR

                if [[ -z "$RDIR" || -z "$LDIR" ]]; then
                    echo "❌ 远程目录和本地目录都不能为空。"
                    pause
                    continue
                fi

                mkdir -p "$LDIR"

                read -rp "⚠️ 确认 mirror 下载整个目录 $RDIR 到本地 $LDIR 吗？(y/N)： " yn_dir
                case "$yn_dir" in
                    y|Y)
                        SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
                        LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
                        SSL_VERIFY_LINE=""
                        if [[ "$FTP_PROTO" != "sftp" ]]; then
                            SSL_VERIFY_LINE="set ssl:verify-certificate no"
                        fi
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
mirror "$RDIR" "$LDIR"
bye
EOF
                        if [[ $? -eq 0 ]]; then
                            echo "✅ 目录已成功下载到：$LDIR"
                        else
                            echo "❌ 目录下载失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "ℹ️ 已取消目录下载。"
                        pause
                        ;;
                esac
                ;;
            4)
                read -rp "📂 请输入文件所在远程目录（例如 /backup/www）： " REMOTE_DIR
                read -rp "📄 请输入要删除的文件名（例如 index.html）： " REMOTE_FILE
                if [[ -z "$REMOTE_DIR" || -z "$REMOTE_FILE" ]]; then
                    echo "❌ 目录和文件名都不能为空。"
                    pause
                    continue
                fi
                read -rp "⚠️ 确认要删除文件 $REMOTE_DIR/$REMOTE_FILE 吗？(y/N)： " yn
                case "$yn" in
                    y|Y)
                        SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
                        LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
                        SSL_VERIFY_LINE=""
                        if [[ "$FTP_PROTO" != "sftp" ]]; then
                            SSL_VERIFY_LINE="set ssl:verify-certificate no"
                        fi
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
cd "$REMOTE_DIR" || exit 1
rm "$REMOTE_FILE"
bye
EOF
                        if [[ $? -eq 0 ]]; then
                            echo "✅ 已删除远程文件：$REMOTE_DIR/$REMOTE_FILE"
                        else
                            echo "❌ 删除失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "ℹ️ 已取消删除。"
                        pause
                        ;;
                esac
                ;;
            5)
                read -rp "📂 请输入要删除的远程目录（例如 /backup/tmp）： " REMOTE_DIR
                if [[ -z "$REMOTE_DIR" ]]; then
                    echo "❌ 远程目录不能为空。"
                    pause
                    continue
                fi
                read -rp "⚠️ 确认**删除整个目录** $REMOTE_DIR 吗？此操作不可恢复！(y/N)： " yn2
                case "$yn2" in
                    y|Y)
                        SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
                        LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
                        SSL_VERIFY_LINE=""
                        if [[ "$FTP_PROTO" != "sftp" ]]; then
                            SSL_VERIFY_LINE="set ssl:verify-certificate no"
                        fi
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
rm -r "$REMOTE_DIR"
bye
EOF
                        if [[ $? -eq 0 ]]; then
                            echo "✅ 已删除远程目录：$REMOTE_DIR"
                        else
                            echo "❌ 删除失败，请检查路径和权限。"
                        fi
                        pause
                        ;;
                    *)
                        echo "ℹ️ 已取消删除目录操作。"
                        pause
                        ;;
                esac
                ;;
            0)
                break
                ;;
            *)
                echo "❌ 无效选项。"
                pause
                ;;
        esac
    done
}

ftp_account_menu() {
    while true; do
        clear
        echo "======================================="
        echo "📂 FTP/SFTP 账号管理"
        echo "======================================="
        echo "当前账号数量：$(get_ftp_count)"
        echo
        echo "1) ➕ 新增账号"
        echo "2) 📋 查看账号列表"
        echo "3) 🗑 删除账号"
        echo "4) 🔍 使用账号浏览/下载/删除远程文件"
        echo "0) ⬅ 返回主菜单"
        echo
        read -rp "👉 请输入选项编号： " choice

        case "$choice" in
            1) add_ftp_account ;;
            2) show_ftp_accounts ;;
            3) delete_ftp_account ;;
            4) browse_ftp_with_account ;;
            0) break ;;
            *) echo "❌ 无效选项。"; pause ;;
        esac
    done
}

# ===================== 实际备份逻辑 =====================
run_backup() {
    local ACCOUNT_ID="$1"
    local LOCAL_PATH="$2"
    local REMOTE_DIR="$3"

    load_ftp_account "$ACCOUNT_ID" || return 1

    if [[ ! -e "$LOCAL_PATH" ]]; then
        echo "❌ 本地路径不存在：$LOCAL_PATH"
        return 1
    fi

    echo "🚀 开始备份："
    echo "  👤 账号：$ACCOUNT_ID ($FTP_USER@$FTP_HOST:$FTP_PORT, 协议：${FTP_PROTO:-ftp})"
    echo "  📁 本地路径：$LOCAL_PATH"
    echo "  📂 远程目标目录：$REMOTE_DIR"

    SSL_LINES="$(build_ssl_lines "$FTP_PROTO")"
    LFTP_TARGET="$(get_lftp_target "$FTP_PROTO" "$FTP_HOST")"
    SSL_VERIFY_LINE=""
    if [[ "$FTP_PROTO" != "sftp" ]]; then
        SSL_VERIFY_LINE="set ssl:verify-certificate no"
    fi

    if [[ -d "$LOCAL_PATH" ]]; then
        # 目录：mirror -R
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
mkdir -p "$REMOTE_DIR"
mirror -R "$LOCAL_PATH" "$REMOTE_DIR"
bye
EOF
    else
        # 文件：put
        local filename
        filename="$(basename "$LOCAL_PATH")"
lftp -u "$FTP_USER","$FTP_PASS" -p "$FTP_PORT" "$LFTP_TARGET" <<EOF
$SSL_VERIFY_LINE
$SSL_LINES
mkdir -p "$REMOTE_DIR"
cd "$REMOTE_DIR"
put "$LOCAL_PATH" -o "$filename"
bye
EOF
    fi

    if [[ $? -eq 0 ]]; then
        echo "✅ 备份完成。"
    else
        echo "❌ 备份失败，请检查网络与配置。"
        return 1
    fi
}

# ===================== 定时任务相关 =====================
add_cron_job() {
    local CRON_EXPR="$1"
    local LOCAL_PATH="$2"
    local REMOTE_DIR="$3"
    local ACCOUNT_ID="$4"

    # 转义 "
    LOCAL_ESC=${LOCAL_PATH//\"/\\\"}
    REMOTE_ESC=${REMOTE_DIR//\"/\\\"}

    local CRON_LINE="$CRON_EXPR bash $SCRIPT_PATH run \"$ACCOUNT_ID\" \"$LOCAL_ESC\" \"$REMOTE_ESC\" $TAG[$ACCOUNT_ID]"

    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

    echo "✅ 定时任务已添加："
    echo "   $CRON_LINE"
}

list_cron_jobs() {
    echo "────────────────────────────────"
    echo "📋 当前备份任务"
    echo "────────────────────────────────"
    local lines
    lines=$(crontab -l 2>/dev/null | grep "$TAG" || true)

    if [[ -z "$lines" ]]; then
        echo "ℹ️  当前没有任何 FTP/SFTP 备份定时任务。"
        pause
        return
    fi

    local i=1
    declare -a JOBS
    while IFS= read -r line; do
        JOBS[$i]="$line"
        echo "[$i] $line"
        i=$((i+1))
    done <<< "$lines"

    echo
    read -rp "⚡ 是否选择其中一个任务立即执行一次？(y/N)： " run_now
    case "$run_now" in
        y|Y)
            read -rp "🔢 请输入任务编号： " choice
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${JOBS[$choice]}" ]]; then
                echo "❌ 输入编号无效。"
            else
                local target="${JOBS[$choice]}"
                # 去掉前 5 个字段（cron 表达式），剩下就是命令
                local cmd_part
                cmd_part=$(echo "$target" | awk '{ $1=""; $2=""; $3=""; $4=""; $5=""; sub(/^ +/, ""); print }')
                echo "⚡ 正在立即执行：$cmd_part"
                eval "$cmd_part"
            fi
            ;;
        *)
            ;;
    esac

    pause
}

delete_cron_job() {
    echo "────────────────────────────────"
    echo "🗑 删除备份任务"
    echo "────────────────────────────────"
    local lines
    lines=$(crontab -l 2>/dev/null | grep "$TAG" || true)

    if [[ -z "$lines" ]]; then
        echo "ℹ️  没有可删除的备份任务。"
        pause
        return
    fi

    local i=1
    declare -a JOBS
    while IFS= read -r line; do
        JOBS[$i]="$line"
        echo "[$i] $line"
        i=$((i+1))
    done <<< "$lines"

    read -rp "🔢 请输入要删除的任务编号： " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ -z "${JOBS[$choice]}" ]]; then
        echo "❌ 输入的编号无效。"
        pause
        return
    fi

    local target="${JOBS[$choice]}"

    crontab -l 2>/dev/null | grep -vF "$target" | crontab -

    echo "✅ 已删除任务：$target"
    pause
}

add_backup_job() {
    echo "────────────────────────────────"
    echo "➕ 新建备份任务"
    echo "────────────────────────────────"
    echo "⚠️  注意：为了避免转义问题，暂不支持路径中包含空格。"

    while true; do
        read -rp "📁 请输入要备份的本地文件/目录路径： " LOCAL_PATH

        if [[ "$LOCAL_PATH" =~ \  ]]; then
            echo "❌ 路径中包含空格，请换一个路径（可用软链接）。"
            continue
        fi

        if [[ ! -e "$LOCAL_PATH" ]]; then
            echo "❌ 路径不存在，请重新输入！"
            continue
        fi

        break
    done

    read -rp "📂 请输入远程目标目录（例如 /backup/www 或 backup）： " REMOTE_DIR

    if [[ -z "$REMOTE_DIR" ]]; then
        echo "❌ 远程目标目录不能为空。"
        pause
        return
    fi

    # 选择账号
    CHOSEN_ACCOUNT_ID=""
    select_ftp_account || { pause; return; }
    local ACCOUNT_ID="$CHOSEN_ACCOUNT_ID"

    echo
    echo "⏱ 请选择定时方式："
    echo "  1) 🕒 每天固定时间备份"
    echo "  2) 🔁 每隔 N 分钟备份"
    read -rp "👉 请输入选项编号： " mode

    local CRON_EXPR=""

    case "$mode" in
        1)
            read -rp "🕒 每天几点（0-23）： " H
            read -rp "🕒 每天几分（0-59）： " M
            if ! [[ "$H" =~ ^[0-9]+$ ]] || ! [[ "$M" =~ ^[0-9]+$ ]] || ((H < 0 || H > 23)) || ((M < 0 || M > 59)); then
                echo "❌ 时间输入不合法。"
                pause
                return
            fi
            CRON_EXPR="$M $H * * *"
            ;;
        2)
            read -rp "🔁 每隔多少分钟执行一次（1-59）： " N
            if ! [[ "$N" =~ ^[0-9]+$ ]] || ((N < 1 || N > 59)); then
                echo "❌ 输入不合法。"
                pause
                return
            fi
            CRON_EXPR="*/$N * * * *"
            ;;
        *)
            echo "❌ 无效的选项。"
            pause
            return
            ;;
    esac

    add_cron_job "$CRON_EXPR" "$LOCAL_PATH" "$REMOTE_DIR" "$ACCOUNT_ID"

    echo
    read -rp "⚡ 是否立即执行一次此备份任务？(Y/n)： " run_now
    if [[ -z "$run_now" || "$run_now" =~ ^[Yy]$ ]]; then
        run_backup "$ACCOUNT_ID" "$LOCAL_PATH" "$REMOTE_DIR"
    fi

    pause
}

uninstall_all() {
    echo "────────────────────────────────"
    echo "🧹 卸载工具"
    echo "────────────────────────────────"
    read -rp "⚠️  确定要卸载吗？这会删除所有账号配置、备份任务和脚本本体。(y/N)： " ans
    case "$ans" in
        y|Y)
            # 删除定时任务
            if command_exists crontab; then
                local current
                current=$(crontab -l 2>/dev/null || true)
                if [[ -n "$current" ]]; then
                    echo "$current" | grep -v "$TAG" | crontab -
                fi
            fi

            # 删除配置目录
            rm -rf "$CONFIG_DIR"

            # 删除脚本本体
            if [[ -f "$SCRIPT_PATH" ]]; then
                rm -f "$SCRIPT_PATH"
            fi

            echo "✅ 已卸载（已删除配置、任务和脚本本体）。"
            echo "👋 程序已退出。"
            exit 0
            ;;
        *)
            echo "ℹ️  已取消卸载。"
            ;;
    esac
    pause
}

# ===================== 主菜单 =====================
show_menu() {
    clear
    echo "======================================="
    echo "🌐 FTP/SFTP 备份工具（多账号版）"
    echo "======================================="
    echo
    local count
    count=$(get_ftp_count)
    if (( count > 0 )); then
        echo "🔐 账号状态：已配置 $count 个 ✅"
    else
        echo "🔐 账号状态：未配置 ❌（请先添加账号）"
    fi
    echo
    echo "1) 📂 管理账号"
    echo "2) ➕ 新建备份任务"
    echo "3) 📋 查看/立即执行备份任务"
    echo "4) 🗑 删除备份任务"
    echo "5) 🧹 卸载"
    echo "0) ❎ 退出"
    echo
    read -rp "👉 请输入选项编号： " choice

    # 没有任何账号时，只允许进账号管理 / 卸载 / 退出
    if ! is_ftp_configured && [[ "$choice" != "1" && "$choice" != "5" && "$choice" != "0" ]]; then
        echo
        echo "⚠️  当前尚未配置任何账号，请先进入“管理账号”添加。"
        pause
        return
    fi

    case "$choice" in
        1) ftp_account_menu ;;
        2) add_backup_job ;;
        3) list_cron_jobs ;;
        4) delete_cron_job ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项。"; pause ;;
    esac
}

# ===================== 入口逻辑 =====================

# crontab 调用：bash back.sh run <ACCOUNT_ID> <LOCAL_PATH> <REMOTE_DIR>
if [[ "$1" == "run" ]]; then
    run_backup "$2" "$3" "$4"
    exit $?
fi

# 交互模式
check_dependencies

while true; do
    show_menu
done
