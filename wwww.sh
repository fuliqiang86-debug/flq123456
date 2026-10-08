#!/usr/bin/env bash
# ============================================================================
# wwww.sh —— Ubuntu + SRBMiner-MULTI + Kryptex（直连）一键静默安装
#   CPU 固定挖 XMR；GPU 在 PRL / QTC 之间按实时收益自动切换。
#   全程使用默认值，不需要回答任何问题；装完用 mine 命令查看 / 修改。
#
# 用法：
#   sudo bash wwww.sh                     # 静默安装 / 升级（可反复执行，不覆盖已有配置）
#   sudo MINE_WORKER=rig01 bash wwww.sh   # 可选：首次安装时指定矿工名（默认 zd + 4 位随机数）
#   sudo bash wwww.sh --force             # 强制重新下载矿机
# ============================================================================
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
    echo "请使用 root 运行：sudo bash $0"
    exit 1
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/lib"

cat > "$T/install.sh" <<'__INSTALL_SH__'
#!/usr/bin/env bash
# 安装/升级 mine 工程：复制到 /opt/mine，注册 mine 命令，然后静默部署。
set -Eeuo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "请使用 root 运行：sudo bash $0"; exit 1; }
[[ -d $SRC/bin && -d $SRC/lib ]] || { echo "找不到 bin/ 与 lib/，安装包不完整。"; exit 1; }
[[ $SRC != /opt/mine ]] || { echo "请不要在 /opt/mine 里运行 install.sh。"; exit 1; }
install -d -m 0755 /opt/mine
rm -rf /opt/mine/bin /opt/mine/lib
cp -a "$SRC/bin" "$SRC/lib" /opt/mine/
chmod 0755 /opt/mine/bin/mine
ln -sfn /opt/mine/bin/mine /usr/local/bin/mine
exec /opt/mine/bin/mine install "$@"
__INSTALL_SH__

cat > "$T/bin/mine" <<'__FILE__'
#!/usr/bin/env bash
# ============================================================================
# mine —— 入口。只负责：找到工程目录 → 加载 lib/*.sh（按文件名顺序）→ 分发命令。
#   lib/00-defaults.sh  所有写死的常量（钱包、Kryptex 节点、路径、默认策略）
#   lib/10-common.sh    日志 / 校验 / 交互输入 / 文件读写
#   lib/20-config.sh    配置读写与旧版迁移
#   lib/30-net.sh       网络（全部直连）与 Kryptex 节点测速
#   lib/40-system.sh    时区 / 依赖 / systemd / 诊断 / 卸载
#   lib/50-gpu.sh       GPU 检测与 NVIDIA 功耗
#   lib/55-ask.sh       交互提问（只在 mine set ... 时用）
#   lib/60-miner.sh     矿机：GitHub 下载 / 启动参数 / 服务控制
#   lib/65-settings.sh  设置项
#   lib/70-hashrate.sh  算力解析
#   lib/80-market.sh    收益数据（Kryptex 10 分钟缓存 × CoinGecko）
#   lib/85-autoswitch.sh 自动切换 + 节点健康检查
#   lib/90-menu.sh      菜单
#   lib/95-cli.sh       命令分发
# ============================================================================
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SELF")")"
export SELF ROOT

if [[ ${MINE_DEBUG:-0} == 1 ]]; then
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

trap 'printf "\033[1;31m[错误]\033[0m 脚本异常退出：%s 第 %s 行：%s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

for f in "$ROOT"/lib/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
done

main "$@"
__FILE__

cat > "$T/lib/00-defaults.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 00-defaults.sh —— 全部“写死”的常量集中在这里
# ============================================================================

# ---- 账户 -------------------------------------------------------------------
readonly WALLET_BASE="krxY4N297J"        # 钱包前缀，最终为 前缀.矿工名

# ---- Kryptex 矿池（全部直连，不走代理）---------------------------------------
# 节点 = <币>[-<地区>].kryptex.network:<端口>，安装时自动测速取最快的 3 个
readonly KRX_DOMAIN="kryptex.network"
readonly KRX_REGIONS="eu us br sg hk ru ae"   # 另外还有不带地区的主节点
readonly XMR_PORT="7029"
readonly PRL_PORT="7048"
readonly QTC_PORT="7049"

# ---- 外部接口（全部直连）-----------------------------------------------------
readonly GH_REPO="doktor83/SRBMiner-Multi"
readonly KRYPTEX_API="https://pool.kryptex.com/api/v1/daily-revenue"
readonly KRYPTEX_CACHE_TTL=600
readonly CG_URL="https://api.coingecko.com/api/v3/simple/price"
readonly CG_PRL_ID="pearl-2"
readonly CG_QTC_ID="quantus"

# ---- 系统 -------------------------------------------------------------------
readonly TZ_CN="Asia/Shanghai"

# ---- 路径 -------------------------------------------------------------------
readonly APP_DIR="/opt/mine"
readonly CMD_LINK="/usr/local/bin/mine"
readonly CONF_DIR="/etc/mine"
readonly CONF_FILE="${CONF_DIR}/mine.conf"
readonly CONF_DONE="${CONF_DIR}/.configured"
readonly STATE_DIR="/var/lib/mine"
readonly STATE_FILE="${STATE_DIR}/autoswitch.state"
readonly CACHE_FILE="${STATE_DIR}/kryptex.cache"
readonly RUN_POOLS="/run/mine-pools"                 # 矿机当前实际连接的节点（健康检查用）
readonly LOCK_DAEMON="/run/mine-autoswitch.lock"
readonly LOCK_CHECK="/run/mine-autoswitch-check.lock"

readonly MINER_DIR="/opt/srbminer"
readonly MINER_BIN="${MINER_DIR}/SRBMiner-MULTI"
readonly MINER_VERSION_FILE="${MINER_DIR}/VERSION"
readonly MINER_SERVICE="srbminer.service"
readonly AUTO_SERVICE="kryptex-auto-switch.service"
readonly MINER_UNIT="/etc/systemd/system/${MINER_SERVICE}"
readonly AUTO_UNIT="/etc/systemd/system/${AUTO_SERVICE}"
readonly SHORTCUTS="/usr/local/bin/qtc /usr/local/bin/prl"

# ---- 旧版 wwww.sh 遗留（只用于迁移 / 清理）-----------------------------------
readonly OLD_APP_DIR="/root/aaa"
readonly OLD_SERVICE="kryptex-miner.service"
readonly OLD_RUNNER="/usr/local/sbin/srbminer-run"
readonly OLD_AUTO_LINK="/usr/local/sbin/kryptex-auto-switch"

# ---- 默认值 -----------------------------------------------------------------
readonly DEF_GPU_COIN="prl"              # 仅在收益接口请求失败时使用；正常情况首次安装按收益自动选
readonly DEF_PRL_HASHRATE="311TH"        # 收益对比用的算力，装完用 mine hashrate 改成你的真实值
readonly DEF_QTC_HASHRATE="1200MH"

# 自动切换推荐策略：5 分钟 / 4% / $0.20/day / 连续 3 次 / 最短驻留 20 分钟
readonly STRAT_CHECK_INTERVAL="300"
readonly STRAT_ADVANTAGE_PERCENT="4"
readonly STRAT_MIN_DAILY_USD="0.20"
readonly STRAT_CONFIRM_COUNT="3"
readonly STRAT_MIN_HOLD_SECONDS="1200"

# 节点健康：矿机正在用的节点连续 N 轮 TCP 不通 → 重启矿机自动换下一个节点
readonly POOL_FAIL_LIMIT=3
__FILE__

cat > "$T/lib/10-common.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 10-common.sh —— 日志 / 校验 / 交互输入 / 文件读写
# ============================================================================

LOG_TS=0
_log() {  # _log <fd> <颜色> <标签> <消息...>
    local fd=$1 color=$2 tag=$3 ts="" c0="" c1=""
    shift 3
    if (( LOG_TS )); then printf -v ts '%(%F %T)T ' -1; fi
    if [[ -t $fd ]]; then c0=$color; c1=$'\033[0m'; fi
    printf '%s%s[%s]%s %s\n' "$ts" "$c0" "$tag" "$c1" "$*" >&"$fd"
}
info() { _log 1 $'\033[1;34m' 信息 "$@"; }
ok()   { _log 1 $'\033[1;32m' 完成 "$@"; }
warn() { _log 1 $'\033[1;33m' 注意 "$@"; }
err()  { _log 2 $'\033[1;31m' 错误 "$@"; }
die()  { err "$*"; exit 1; }

title() { printf '\n============================================================\n  %s\n============================================================\n' "$*"; }
rule()  { printf '%s\n' "------------------------------------------------------------"; }

has()          { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行，例如：sudo mine"; }
pause_enter()  { read -r -p $'\n按回车继续...' _ || true; }

# ---- 校验 -------------------------------------------------------------------
valid_worker()  { [[ $1 =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]]; }
valid_yesno()   { [[ $1 == yes || $1 == no ]]; }
valid_coin()    { [[ $1 == prl || $1 == qtc ]]; }
valid_uint()    { [[ $1 =~ ^[0-9]+$ ]]; }
valid_pos_int() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 )); }
valid_decimal() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
valid_gpu_ids() { [[ $1 == all || $1 =~ ^[0-9]+(,[0-9]+)*$ ]]; }          # all = 全部显卡
valid_interval(){ [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 60 )); }
valid_pool_list(){ [[ $1 =~ ^[a-z0-9.-]+:[0-9]{1,5}(,[a-z0-9.-]+:[0-9]{1,5})*$ ]]; }
valid_api_number() { [[ $1 =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][-+]?[0-9]+)?$ ]]; }

# ---- 交互输入（只在 mine set ... 里用，安装过程不提问）------------------------
ask() {  # ask <变量名> <提示> [默认值] [校验函数] [错误提示]
    local __v=$1 __p=$2 __d=${3:-} __chk=${4:-} __msg=${5:-输入无效，请重试。} __a
    while true; do
        if [[ -n $__d ]]; then
            read -r -p "$__p [$__d]: " __a || die "输入被中断"
            __a=${__a:-$__d}
        else
            read -r -p "$__p: " __a || die "输入被中断"
        fi
        __a=${__a//$'\r'/}
        __a=${__a#"${__a%%[![:space:]]*}"}
        __a=${__a%"${__a##*[![:space:]]}"}
        if [[ -z $__chk ]] || "$__chk" "$__a"; then
            printf -v "$__v" '%s' "$__a"
            return 0
        fi
        warn "$__msg"
    done
}

ask_yn() {  # ask_yn <变量名> <提示> <默认 yes|no>
    local __a __hint="y/N"
    [[ $3 == yes ]] && __hint="Y/n"
    while true; do
        read -r -p "$2 [$__hint]: " __a || die "输入被中断"
        case ${__a,,} in
            "")       printf -v "$1" '%s' "$3"; return 0 ;;
            y|yes|是) printf -v "$1" '%s' yes;  return 0 ;;
            n|no|否)  printf -v "$1" '%s' no;   return 0 ;;
            *)        warn "请输入 y 或 n。" ;;
        esac
    done
}

# ---- 文件读写 ---------------------------------------------------------------
atomic_write() {  # atomic_write <文件> [权限]   内容来自 stdin
    local f=$1 mode=${2:-0600} tmp
    tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$f"
}

# 安全读取 KEY="VALUE" 文件：不 source、不执行；只认指定的 KEY
kv_load() {  # kv_load <文件> <KEY>...
    local file=$1 line k v re='^([A-Z][A-Z0-9_]*)="([^"]*)"$'
    shift
    [[ -f $file ]] || return 0
    local -A want=()
    for k in "$@"; do want[$k]=1; done
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $line =~ $re ]]; then
            k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
            if [[ -n ${want[$k]:-} ]]; then printf -v "$k" '%s' "$v"; fi
        fi
    done < "$file"
}

kv_set() {  # kv_set <文件> <KEY> <VALUE>
    local f=$1 k=$2 v=$3 tmp
    [[ $v != *'"'* && $v != *$'\n'* ]] || return 1
    tmp=$(mktemp "${f}.tmp.XXXXXX") || return 1
    if ! K="$k" V="$v" awk '
        index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=\"" ENVIRON["V"] "\""; found=1; next }
        { print }
        END { if (!found) print ENVIRON["K"] "=\"" ENVIRON["V"] "\"" }
    ' "$f" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod 0600 "$tmp"
    mv -f "$tmp" "$f"
}
__FILE__

cat > "$T/lib/20-config.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 20-config.sh —— 配置：默认值 / 读取 / 校验 / 写入 / 旧版迁移
# 唯一配置文件：/etc/mine/mine.conf （KEY="VALUE"，安全读取，不会被 source 执行）
# ============================================================================

CFG_KEYS=(
    WORKER CPU_ENABLED CPU_THREADS
    GPU_ENABLED GPU_COIN GPU_IDS GPU_POWER_LIMIT
    XMR_POOLS PRL_POOLS QTC_POOLS
    PRL_HASHRATE QTC_HASHRATE
    CHECK_INTERVAL ADVANTAGE_PERCENT MIN_DAILY_USD CONFIRM_COUNT MIN_HOLD_SECONDS
)

declare -A CFG_CHECK=(
    [WORKER]=valid_worker        [CPU_ENABLED]=valid_yesno     [CPU_THREADS]=valid_uint
    [GPU_ENABLED]=valid_yesno    [GPU_COIN]=valid_coin         [GPU_IDS]=valid_gpu_ids
    [GPU_POWER_LIMIT]=valid_uint
    [XMR_POOLS]=valid_pool_list  [PRL_POOLS]=valid_pool_list   [QTC_POOLS]=valid_pool_list
    [PRL_HASHRATE]=valid_hashrate [QTC_HASHRATE]=valid_hashrate
    [CHECK_INTERVAL]=valid_interval  [ADVANTAGE_PERCENT]=valid_decimal
    [MIN_DAILY_USD]=valid_decimal    [CONFIRM_COUNT]=valid_pos_int
    [MIN_HOLD_SECONDS]=valid_uint
)

# 默认矿工名：MINE_WORKER 环境变量 > zd + 4 位随机数（和旧版 wwww.sh 一样）
default_worker() {
    local w=${MINE_WORKER:-}
    if [[ -n $w ]] && valid_worker "$w"; then printf '%s' "$w"; return 0; fi
    printf 'zd%04d' $((RANDOM % 10000))
}

cfg_defaults() {
    WORKER=$(default_worker)
    CPU_ENABLED=yes
    CPU_THREADS=0                                   # 0 = 交给 SRBMiner 自动决定
    GPU_ENABLED=no; GPU_COIN=$DEF_GPU_COIN; GPU_IDS=all; GPU_POWER_LIMIT=0
    XMR_POOLS="xmr.${KRX_DOMAIN}:${XMR_PORT}"
    PRL_POOLS="prl.${KRX_DOMAIN}:${PRL_PORT}"
    QTC_POOLS="qtc.${KRX_DOMAIN}:${QTC_PORT}"
    PRL_HASHRATE=$DEF_PRL_HASHRATE; QTC_HASHRATE=$DEF_QTC_HASHRATE
    cfg_reset_strategy_vars
    local k
    for k in "${CFG_KEYS[@]}"; do printf -v "FB_$k" '%s' "${!k}"; done
}

cfg_reset_strategy_vars() {
    CHECK_INTERVAL=$STRAT_CHECK_INTERVAL
    ADVANTAGE_PERCENT=$STRAT_ADVANTAGE_PERCENT
    MIN_DAILY_USD=$STRAT_MIN_DAILY_USD
    CONFIRM_COUNT=$STRAT_CONFIRM_COUNT
    MIN_HOLD_SECONDS=$STRAT_MIN_HOLD_SECONDS
}

cfg_sanitize() {
    local k v def chk
    for k in "${CFG_KEYS[@]}"; do
        v=${!k//[[:space:]]/}
        [[ $k == WORKER || $k == *_HASHRATE ]] || v=${v,,}
        [[ $k == *_HASHRATE ]] && v=${v^^}
        chk=${CFG_CHECK[$k]}
        if "$chk" "$v"; then
            printf -v "$k" '%s' "$v"
        else
            def="FB_$k"
            warn "配置项 $k 的值 [${!k}] 无效，已使用默认值 [${!def}]。"
            printf -v "$k" '%s' "${!def}"
        fi
    done
}

cfg_load() {
    cfg_defaults
    kv_load "$CONF_FILE" "${CFG_KEYS[@]}"
    cfg_sanitize
}

cfg_exists() { [[ -f $CONF_FILE ]]; }

cfg_save_all() {
    mkdir -p "$CONF_DIR"; chmod 0700 "$CONF_DIR"
    atomic_write "$CONF_FILE" 0600 <<EOF_CFG
# mine 配置文件 —— 由 mine 命令管理（手改后执行 mine restart 生效）
# 钱包最终为：${WALLET_BASE}.<WORKER>

WORKER="${WORKER}"

# CPU 挖 XMR（CPU_THREADS: 0 = 自动）
CPU_ENABLED="${CPU_ENABLED}"
CPU_THREADS="${CPU_THREADS}"

# GPU 挖 PRL / QTC（GPU_IDS: all = 全部显卡；GPU_POWER_LIMIT: 0 = 不限制，否则为瓦数，仅 NVIDIA）
GPU_ENABLED="${GPU_ENABLED}"
GPU_COIN="${GPU_COIN}"
GPU_IDS="${GPU_IDS}"
GPU_POWER_LIMIT="${GPU_POWER_LIMIT}"

# Kryptex 节点（直连；按延迟排序，启动时用第一个能连上的。mine pool 重新测速）
XMR_POOLS="${XMR_POOLS}"
PRL_POOLS="${PRL_POOLS}"
QTC_POOLS="${QTC_POOLS}"

# 自动切换用的算力：数字 + 单位，例如 100TH、1200MH
PRL_HASHRATE="${PRL_HASHRATE}"
QTC_HASHRATE="${QTC_HASHRATE}"

# 自动切换策略：检查间隔(秒) / 优势(%) / 最低日收益(USD) / 连续确认次数 / 最短驻留(秒)
CHECK_INTERVAL="${CHECK_INTERVAL}"
ADVANTAGE_PERCENT="${ADVANTAGE_PERCENT}"
MIN_DAILY_USD="${MIN_DAILY_USD}"
CONFIRM_COUNT="${CONFIRM_COUNT}"
MIN_HOLD_SECONDS="${MIN_HOLD_SECONDS}"
EOF_CFG
}

cfg_set() {  # cfg_set <KEY> <VALUE>
    local k=$1 v=$2 chk=${CFG_CHECK[$1]:-}
    [[ -n $chk ]] || die "未知配置项：$k"
    "$chk" "$v" || die "配置项 $k 的值无效：$v"
    cfg_exists || cfg_save_all
    kv_set "$CONF_FILE" "$k" "$v" || die "写入配置失败：$k"
    printf -v "$k" '%s' "$v"
}

# 静默部署：没有配置 → 用默认值 + 自动检测 GPU + 迁移旧版 + 节点测速；有配置 → 保留
cfg_init() {
    mkdir -p "$CONF_DIR" "$STATE_DIR"; chmod 0700 "$CONF_DIR" "$STATE_DIR"
    if cfg_exists; then
        cfg_load
        if ! grep -q '^XMR_POOLS=' "$CONF_FILE"; then
            info "已有配置里没有 Kryptex 直连节点（可能是局域网矿池版本），现在测速..."
            pools_rank_all
        fi
        cfg_save_all                   # 统一成新格式（旧版的局域网端口等项会被去掉）
        ok "沿用已有配置：矿工 ${WALLET_BASE}.${WORKER}"
        return 0
    fi

    cfg_defaults
    if gpu_detect; then GPU_ENABLED=yes; fi
    if cfg_migrate_wwww; then ok "已沿用旧版 wwww.sh 的矿工名。"; fi
    pools_rank_all
    if [[ $GPU_ENABLED == yes ]]; then pick_best_coin; fi
    cfg_sanitize
    cfg_save_all
    ok "已生成默认配置：矿工 ${WALLET_BASE}.${WORKER}"
}

# 旧版 wwww.sh（/root/aaa）：沿用矿工名和当前 GPU 币种，避免收益账户里多出一台新矿机
cfg_migrate_wwww() {
    local w="" m=""
    [[ -f $OLD_APP_DIR/run-miner.sh ]] || return 1
    if [[ -z ${MINE_WORKER:-} ]]; then
        w=$(sed -n 's/^WORKER="\([^"]*\)"$/\1/p' "$OLD_APP_DIR/run-miner.sh" | head -n1 || true)
        if [[ -n $w ]] && valid_worker "$w"; then WORKER=$w; fi
    fi
    if [[ -f $OLD_APP_DIR/gpu-mode ]]; then
        m=$(tr -d '[:space:]' < "$OLD_APP_DIR/gpu-mode" || true); m=${m,,}
        if valid_coin "$m"; then GPU_COIN=$m; fi
    fi
    return 0
}

cfg_show() {
    cfg_load
    local algo; [[ $GPU_COIN == prl ]] && algo=pearlhash || algo=quantus
    title "当前配置"
    printf '钱包：        %s.%s\n' "$WALLET_BASE" "$WORKER"
    printf 'CPU 挖 XMR：  %s  (%s)\n' "$CPU_ENABLED" "$([[ $CPU_THREADS == 0 ]] && echo 自动线程 || echo "${CPU_THREADS} 线程")"
    printf 'GPU 挖矿：    %s  币种 %s (%s)  显卡 %s\n' "$GPU_ENABLED" "${GPU_COIN^^}" "$algo" "$GPU_IDS"
    printf 'GPU 功耗：    %s\n' "$([[ $GPU_POWER_LIMIT == 0 ]] && echo 不限制 || echo "${GPU_POWER_LIMIT} W")"
    printf 'XMR 节点：    %s\n' "${XMR_POOLS//,/  }"
    printf 'PRL 节点：    %s\n' "${PRL_POOLS//,/  }"
    printf 'QTC 节点：    %s\n' "${QTC_POOLS//,/  }"
    printf '收益算力：    PRL %s | QTC %s\n' "$(hr_pretty "$PRL_HASHRATE")" "$(hr_pretty "$QTC_HASHRATE")"
    printf '网络：        全部直连（不使用代理）\n'
    printf '配置文件：    %s\n' "$CONF_FILE"
}
__FILE__

cat > "$T/lib/30-net.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 30-net.sh —— 网络：全部直连；Kryptex 节点测速 / 选择
# ============================================================================

net_curl() {
    curl -fsSL --connect-timeout 10 --max-time "${NET_MAX_TIME:-20}" \
        --retry 2 --retry-delay 2 "$@"
}

net_download() {  # net_download <URL> <保存路径>（支持断点续传）
    local url=$1 out=$2 rc=0
    curl -fL -C - --retry 10 --retry-delay 3 --retry-max-time 0 \
        --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
        -o "$out" "$url" || rc=$?
    if (( rc == 33 )); then
        rm -f "$out"
        curl -fL --retry 10 --retry-delay 3 --retry-max-time 0 \
            --connect-timeout 15 --speed-limit 1024 --speed-time 30 \
            -o "$out" "$url" || return 1
        return 0
    fi
    return "$rc"
}

# TCP 建连耗时（毫秒）；连不上返回 1
tcp_ms() {  # tcp_ms <主机> <端口>
    local s e
    s=$(date +%s%N)
    if timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
        e=$(date +%s%N)
        printf '%s\n' $(( (e - s) / 1000000 ))
    else
        return 1
    fi
}

tcp_test() {  # tcp_test <主机:端口>
    local ms
    if ms=$(tcp_ms "${1%:*}" "${1##*:}"); then
        printf '  TCP  %-34s 可连接  %s ms\n' "$1" "$ms"
    else
        printf '  TCP  %-34s 连接失败\n' "$1"
        return 1
    fi
}

# 列出某个币的全部 Kryptex 节点
pool_nodes() {  # pool_nodes <xmr|prl|qtc>
    local coin=$1 port r
    case $coin in
        xmr) port=$XMR_PORT ;; prl) port=$PRL_PORT ;; qtc) port=$QTC_PORT ;;
        *) return 1 ;;
    esac
    printf '%s.%s:%s\n' "$coin" "$KRX_DOMAIN" "$port"
    for r in $KRX_REGIONS; do printf '%s-%s.%s:%s\n' "$coin" "$r" "$KRX_DOMAIN" "$port"; done
}

# 并发测速，输出最快的 3 个（逗号分隔）；全部失败时返回主节点
pools_rank() {  # pools_rank <xmr|prl|qtc>
    local coin=$1 d node ms out i=0
    d=$(mktemp -d)
    while IFS= read -r node; do
        (
            if ms=$(tcp_ms "${node%:*}" "${node##*:}"); then
                printf '%s %s\n' "$ms" "$node"
            else
                printf '999999 %s\n' "$node"
            fi > "$d/$i"
        ) &
        i=$((i + 1))
    done < <(pool_nodes "$coin")
    wait
    sort -n "$d"/* | while read -r ms node; do
        if (( ms < 999999 )); then printf '  %-4s %-32s %6s ms\n' "${coin^^}" "$node" "$ms"
        else printf '  %-4s %-32s   失败\n' "${coin^^}" "$node"; fi
    done >&2
    out=$(sort -n "$d"/* | awk '$1 < 999999 { print $2 }' | head -n 3 | paste -sd, -)
    rm -rf "$d"
    [[ -n $out ]] || out=$(pool_nodes "$coin" | head -n 1)
    printf '%s' "$out"
}

pools_rank_all() {
    info "Kryptex 节点测速（直连）..."
    XMR_POOLS=$(pools_rank xmr)
    PRL_POOLS=$(pools_rank prl)
    QTC_POOLS=$(pools_rank qtc)
    ok "XMR：${XMR_POOLS}"
    ok "PRL：${PRL_POOLS}"
    ok "QTC：${QTC_POOLS}"
}

# 从排好序的列表里取第一个当前能连上的；都连不上就用第一个（矿机自己会重试）
pool_pick_live() {  # pool_pick_live <a:1,b:2,...>
    local p; local -a arr
    IFS=',' read -r -a arr <<< "$1"
    for p in "${arr[@]}"; do
        if tcp_ms "${p%:*}" "${p##*:}" >/dev/null; then printf '%s' "$p"; return 0; fi
    done
    printf '%s' "${arr[0]}"
}

# 网络自检：三个外部接口（直连）+ 当前节点
net_test() {
    cfg_load
    title "网络测试（全部直连，不走代理）"
    local -a tests=(
        "GitHub|https://api.github.com/repos/${GH_REPO}/releases/latest"
        "Kryptex|${KRYPTEX_API}/prl?hashrate=1000000000000"
        "CoinGecko|${CG_URL}?ids=${CG_PRL_ID}&vs_currencies=usd"
    )
    local t name url code bad=0 p
    for t in "${tests[@]}"; do
        name=${t%%|*}; url=${t#*|}
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || true)
        if [[ $code == 200 ]]; then printf '  %-12s HTTP %s  正常\n' "$name" "$code"
        else printf '  %-12s HTTP %s  异常\n' "$name" "${code:-000}"; bad=1; fi
    done
    echo
    echo "Kryptex 节点（配置中的顺序）："
    for p in ${XMR_POOLS//,/ } ${PRL_POOLS//,/ } ${QTC_POOLS//,/ }; do tcp_test "$p" || bad=1; done
    return "$bad"
}
__FILE__

cat > "$T/lib/40-system.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 40-system.sh —— 系统：时区 / 依赖 / systemd / 旧版清理 / 诊断 / 卸载
# ============================================================================

sys_set_timezone() {
    local cur
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")
    if [[ $cur == "$TZ_CN" ]]; then
        ok "系统时区已是 ${TZ_CN}（北京时间）。"
    else
        if [[ ! -e /usr/share/zoneinfo/$TZ_CN ]]; then
            info "缺少 tzdata，正在安装..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata >/dev/null 2>&1 || true
        fi
        if ! timedatectl set-timezone "$TZ_CN" 2>/dev/null; then
            ln -sf "/usr/share/zoneinfo/$TZ_CN" /etc/localtime
            echo "$TZ_CN" > /etc/timezone
        fi
        ok "系统时区已改为 ${TZ_CN}：$(date '+%F %T %Z')"
    fi
    timedatectl set-ntp true >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$AUTO_SERVICE" 2>/dev/null; then
        systemctl restart "$AUTO_SERVICE" || true
    fi
}

sys_install_deps() {
    has systemctl || die "当前系统没有 systemctl，不是标准 Ubuntu Server（systemd）环境。"
    local c; for c in awk sed journalctl timeout; do has "$c" || die "系统缺少 $c。"; done
    local -a need=()
    has curl  || need+=(curl)
    has jq    || need+=(jq)
    has flock || need+=(util-linux)
    has tar   || need+=(tar)
    if (( ${#need[@]} > 0 )); then
        has apt-get || die "缺少依赖：${need[*]}，且系统没有 apt-get 无法自动安装。"
        info "安装依赖：${need[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ca-certificates "${need[@]}"
    fi
}

svc_write_units() {
    cat > "$MINER_UNIT" <<EOF_U1
[Unit]
Description=SRBMiner-MULTI Mining Service (Kryptex)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${MINER_DIR}
ExecStart=${CMD_LINK} _run
Restart=always
RestartSec=8
TimeoutStopSec=30
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_U1

    cat > "$AUTO_UNIT" <<EOF_U2
[Unit]
Description=Kryptex PRL/QTC Profit Auto Switch
After=network-online.target ${MINER_SERVICE}
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${CMD_LINK} _autoswitch-daemon
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_U2
    chmod 0644 "$MINER_UNIT" "$AUTO_UNIT"
    systemctl daemon-reload
}

# 停掉旧版 wwww.sh 的服务（kryptex-miner.service），避免两个矿机抢显卡
sys_cleanup_legacy() {
    rm -f "$OLD_RUNNER" "$OLD_AUTO_LINK"
    if [[ -f /etc/systemd/system/$OLD_SERVICE ]]; then
        systemctl stop "$OLD_SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$OLD_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$OLD_SERVICE"
        systemctl daemon-reload
        ok "已停用旧版服务 ${OLD_SERVICE}（旧目录 ${OLD_APP_DIR} 保留未删，确认无用可自行删除）。"
    fi
}

# qtc / prl 快捷命令（兼容旧版习惯）：等同于 mine coin qtc / mine coin prl
sys_install_shortcuts() {
    local s
    for s in $SHORTCUTS; do
        rm -f "$s"
        printf '#!/bin/sh\nexec %s coin %s\n' "$CMD_LINK" "${s##*/}" > "$s"
        chmod 0755 "$s"
    done
}

sys_doctor() {
    cfg_load
    title "mine 诊断"
    printf '系统：%s   架构：%s\n' "$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")" "$(uname -m)"
    printf '时间：%s  （时区 %s）\n' "$(date '+%F %T %Z')" "$(timedatectl show -p Timezone --value 2>/dev/null || echo ?)"
    [[ $(uname -m) == x86_64 ]] || warn "不是 x86_64，SRBMiner 很可能无法运行。"
    echo
    if [[ -x $MINER_BIN ]]; then ok "矿机已安装：$(miner_version_tag)"; else err "矿机未安装：$MINER_BIN（执行 mine update）"; fi
    systemctl is-enabled --quiet "$MINER_SERVICE" 2>/dev/null && ok "矿机开机自启：开" || warn "矿机开机自启：关"
    systemctl is-active  --quiet "$MINER_SERVICE" 2>/dev/null && ok "矿机运行中" || warn "矿机未运行"
    systemctl is-active  --quiet "$AUTO_SERVICE"  2>/dev/null && ok "自动切换运行中" || warn "自动切换未运行"
    if [[ -f $RUN_POOLS ]]; then echo; echo "矿机当前连接的节点："; sed 's/^/  /' "$RUN_POOLS"; fi
    echo
    net_test || true
    echo
    if gpu_available; then gpu_print || true
    elif gpu_detect; then info "检测到非 NVIDIA 显卡（AMD/Intel），功耗功能不可用，挖矿正常。"
    else warn "没有检测到显卡（或驱动未装好）"; fi
}

uninstall_all() {
    warn "将卸载：矿机 + 自动切换 + mine/qtc/prl 命令。不会动显卡驱动，也不会还原时区。"
    local a purge s
    read -r -p "确认卸载？输入 YES 继续： " a || true
    [[ $a == YES ]] || { info "已取消。"; return 0; }

    systemctl stop "$AUTO_SERVICE" "$MINER_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$AUTO_SERVICE" "$MINER_SERVICE" >/dev/null 2>&1 || true
    gpu_reset_power
    rm -f "$MINER_UNIT" "$AUTO_UNIT" "$LOCK_DAEMON" "$LOCK_CHECK" "$RUN_POOLS"
    systemctl daemon-reload || true
    rm -rf "$MINER_DIR" "$STATE_DIR"

    read -r -p "是否连配置一起删除？输入 y 删除，直接回车保留： " purge || true
    if [[ ${purge,,} == y || ${purge,,} == yes ]]; then rm -rf "$CONF_DIR"; ok "配置已删除。"; else ok "配置已保留：$CONF_DIR"; fi
    for s in $SHORTCUTS; do rm -f "$s"; done
    rm -f "$CMD_LINK"
    rm -rf "$APP_DIR"
    ok "卸载完成。"
}
__FILE__

cat > "$T/lib/50-gpu.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 50-gpu.sh —— GPU 检测 / NVIDIA 编号校验 / 功耗限制
# ============================================================================

gpu_available() { has nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }      # NVIDIA 可用

# 是否有任意可挖矿的显卡（NVIDIA / AMD / Intel Arc）
gpu_detect() {
    gpu_available && return 0
    [[ -e /dev/kfd ]] && return 0
    has lspci && lspci 2>/dev/null | grep -Eiq '(vga|3d|display).*(nvidia|amd|ati|radeon|arc)'
}

gpu_all_ids() {
    gpu_available || return 1
    nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | tr -d ' ' | paste -sd, - || true
}

# GPU_IDS 转成具体编号（all → 全部 NVIDIA 卡）
gpu_resolve_ids() {
    if [[ $1 == all ]]; then gpu_all_ids; else printf '%s' "$1"; fi
}

gpu_valid_selection() {
    [[ $1 == all ]] && return 0
    valid_gpu_ids "$1" || return 1
    local all id; local -a arr
    all=$(gpu_all_ids || true)
    [[ -n $all ]] || return 1
    IFS=',' read -r -a arr <<< "$1"
    for id in "${arr[@]}"; do
        [[ ",$all," == *",$id,"* ]] || return 1
    done
}

_gpu_power_field() {  # _gpu_power_field <id> <min|max>
    local v
    v=$(nvidia-smi -i "$1" --query-gpu="power.${2}_limit" --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
    if ! [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        v=$(nvidia-smi -i "$1" -q -d POWER 2>/dev/null | awk -F: -v k="${2^} Power Limit" 'index($0,k){gsub(/[^0-9.]/,"",$2); print $2; exit}' || true)
    fi
    [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] || v=0
    awk -v v="$v" 'BEGIN{printf "%d", v+0.5}'
}

gpu_check_power() {  # gpu_check_power <瓦数> <GPU 编号列表|all>
    local limit=$1 ids id lo hi bad=0; local -a arr
    ids=$(gpu_resolve_ids "$2") || { err "读不到 NVIDIA 显卡，功耗限制只支持 NVIDIA。"; return 1; }
    IFS=',' read -r -a arr <<< "$ids"
    for id in "${arr[@]}"; do
        lo=$(_gpu_power_field "$id" min); hi=$(_gpu_power_field "$id" max)
        if (( hi <= 0 )); then err "读不到 GPU ${id} 的最大功耗。"; bad=1; continue; fi
        if (( limit < lo || limit > hi )); then err "GPU ${id} 允许功耗 ${lo}-${hi} W，你填的是 ${limit} W。"; bad=1; fi
    done
    return "$bad"
}

gpu_apply_power() {  # gpu_apply_power <瓦数> <GPU 编号列表|all>
    local limit=$1 ids id; local -a arr
    (( limit > 0 )) || return 0
    gpu_available || { warn "不是 NVIDIA 显卡，忽略功耗限制。"; return 0; }
    gpu_check_power "$limit" "$2" || return 1
    ids=$(gpu_resolve_ids "$2")
    IFS=',' read -r -a arr <<< "$ids"
    for id in "${arr[@]}"; do
        nvidia-smi -i "$id" -pl "$limit" >/dev/null 2>&1 || { err "无法把 GPU ${id} 限制到 ${limit} W（云主机可能禁止修改功耗）。"; return 1; }
    done
}

gpu_reset_power() {
    gpu_available || return 0
    local ids id d; local -a arr
    ids=$(gpu_all_ids) || return 0
    IFS=',' read -r -a arr <<< "$ids"
    for id in "${arr[@]}"; do
        d=$(nvidia-smi -i "$id" --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | awk '{print int($1+0.5)}' || true)
        if [[ $d =~ ^[0-9]+$ ]] && (( d > 0 )); then nvidia-smi -i "$id" -pl "$d" >/dev/null 2>&1 || true; fi
    done
}

gpu_print() {
    gpu_available || { warn "没有可用的 NVIDIA GPU（或 nvidia-smi 不工作）。"; return 1; }
    title "NVIDIA GPU"
    nvidia-smi --query-gpu=index,name,memory.total,power.min_limit,power.max_limit,power.limit,temperature.gpu --format=csv,noheader
}
__FILE__

cat > "$T/lib/55-ask.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 55-ask.sh —— 交互提问（安装时不会用到，只在 mine set ... 里用）
# ============================================================================

ask_worker() {
    ask "$1" "矿工名（不要输入前面的点）" "${2:-$WORKER}" valid_worker "只允许字母/数字/._-，且不能以 . 开头。"
}

_valid_threads() { valid_uint "$1" && (( 10#$1 <= $(nproc 2>/dev/null || echo 1) )); }
ask_cpu_threads() {
    local max; max=$(nproc 2>/dev/null || echo 1)
    echo "CPU 可用逻辑线程：${max}（0 = 自动）"
    ask "$1" "XMR 线程数" "${2:-0}" _valid_threads "请输入 0-${max} 之间的整数。"
}

ask_gpu_ids() {
    local all
    if ! all=$(gpu_all_ids) || [[ -z $all ]]; then
        info "非 NVIDIA 显卡，使用全部显卡。"; printf -v "$1" '%s' all; return 0
    fi
    echo "检测到 NVIDIA GPU：${all}（填 all 或 0 或 0,1）"
    ask "$1" "使用哪些 GPU" "${2:-all}" gpu_valid_selection "GPU 编号无效，当前可用：${all}"
}

_valid_coin_ci() { [[ ${1,,} == prl || ${1,,} == qtc ]]; }
ask_coin() {
    local __c
    ask __c "GPU 挖什么币？(PRL/QTC)" "${2:-prl}" _valid_coin_ci "请输入 PRL 或 QTC。"
    printf -v "$1" '%s' "${__c,,}"
}

_ASK_POWER_IDS=""
_valid_power() { valid_uint "$1" && { [[ $1 == 0 ]] || gpu_check_power "$1" "$_ASK_POWER_IDS"; }; }
ask_power() {  # ask_power <变量> <当前值> <GPU 编号>
    _ASK_POWER_IDS=$3
    echo "功耗直接输入瓦数，例如 280；0 = 不限制（仅 NVIDIA）。"
    ask "$1" "GPU 功耗限制 W" "${2:-0}" _valid_power "请输入整数瓦数（0 = 不限制）。"
}
__FILE__

cat > "$T/lib/60-miner.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 60-miner.sh —— SRBMiner：下载(GitHub 最新版，直连) / 启动参数 / 服务控制 / 日志
# ============================================================================

miner_version_tag() { if [[ -f $MINER_VERSION_FILE ]]; then cat "$MINER_VERSION_FILE"; else echo "未知"; fi; }

# 输出：<tag> <Linux 压缩包 URL>
miner_latest() {
    local json tag="" url="" loc q='"[^"]+"'
    if json=$(net_curl -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null); then
        tag=$(grep -oE "\"tag_name\"[[:space:]]*:[[:space:]]*${q}" <<< "$json" | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/' || true)
        url=$(grep -oE "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*Linux\.tar\.gz\"" <<< "$json" | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/' || true)
    fi
    if [[ -z $tag || -z $url ]]; then
        loc=$(net_curl -o /dev/null -w '%{url_effective}' "https://github.com/${GH_REPO}/releases/latest" 2>/dev/null) || return 1
        tag=${loc##*/}
        [[ $tag =~ ^[0-9]+([.][0-9]+)+$ ]] || return 1
        url="https://github.com/${GH_REPO}/releases/download/${tag}/SRBMiner-Multi-${tag//./-}-Linux.tar.gz"
    fi
    printf '%s %s\n' "$tag" "$url"
}

miner_install() {  # miner_install [--force]
    local force=${1:-} out tag url part tmp src
    mkdir -p "$MINER_DIR"
    info "向 GitHub 查询 SRBMiner 最新版（直连）..."
    out=$(miner_latest) || { err "查询 GitHub 最新版失败，请检查网络：mine net"; return 1; }
    read -r tag url <<< "$out"

    if [[ -x $MINER_BIN && $(miner_version_tag) == "$tag" && $force != --force ]]; then
        ok "SRBMiner 已是最新版 ${tag}。"
        return 0
    fi

    info "下载 SRBMiner-MULTI ${tag}（当前：$([[ -x $MINER_BIN ]] && miner_version_tag || echo 未安装)）"
    part="${MINER_DIR}/.dl-${tag}.tar.gz.part"
    find "$MINER_DIR" -maxdepth 1 -name '.dl-*' ! -name ".dl-${tag}.*" -delete 2>/dev/null || true
    if ! net_download "$url" "$part"; then
        warn "下载未完成，断点文件已保留；网络恢复后执行 mine update 会自动续传。"
        return 1
    fi

    tmp=$(mktemp -d "${MINER_DIR}/.extract.XXXXXX")
    if ! tar -xzf "$part" -C "$tmp"; then
        rm -rf "$tmp" "$part"; err "压缩包损坏，已删除，请重新执行 mine update。"; return 1
    fi
    src=$(find "$tmp" -type f -name SRBMiner-MULTI | head -n1 || true)
    if [[ -z $src ]]; then rm -rf "$tmp" "$part"; err "压缩包里没有找到 SRBMiner-MULTI。"; return 1; fi
    if has file && [[ $(file -b "$src") != *"ELF 64-bit"* ]]; then
        rm -rf "$tmp" "$part"; err "下载内容不是 Linux x86_64 可执行程序。"; return 1
    fi

    if [[ -x $MINER_BIN ]]; then cp -a "$MINER_BIN" "${MINER_BIN}.bak"; fi
    cp -a --remove-destination "$(dirname "$src")/." "$MINER_DIR/"
    chmod 0755 "$MINER_BIN"
    echo "$tag" > "$MINER_VERSION_FILE"
    rm -rf "$tmp" "$part"
    ok "SRBMiner-MULTI ${tag} 安装完成。"
}

miner_update() {
    local before after
    before=$(miner_version_tag)
    miner_install "${1:-}" || return 1
    after=$(miner_version_tag)
    if [[ $before != "$after" ]]; then miner_restart_if_running; fi
}

# ---- 启动参数 ----------------------------------------------------------------
# 选出本次要用的节点（每个币取第一个能连上的）
CUR_XMR_POOL=""; CUR_GPU_POOL=""
miner_select_pools() {
    CUR_XMR_POOL=""; CUR_GPU_POOL=""
    if [[ $CPU_ENABLED == yes ]]; then CUR_XMR_POOL=$(pool_pick_live "$XMR_POOLS"); fi
    if [[ $GPU_ENABLED == yes ]]; then
        if [[ $GPU_COIN == prl ]]; then CUR_GPU_POOL=$(pool_pick_live "$PRL_POOLS")
        else CUR_GPU_POOL=$(pool_pick_live "$QTC_POOLS"); fi
    fi
}

# 顺序有意义：混合 CPU/GPU 时先写 CPU 再写 GPU
miner_build_args() {  # miner_build_args <数组变量名>
    local -n _args=$1
    local wallet="${WALLET_BASE}.${WORKER}" algo=""
    _args=()
    if [[ $CPU_ENABLED == yes ]]; then
        _args+=(--algorithm-cpu randomx --pool "$CUR_XMR_POOL" --wallet "$wallet")
        if [[ $CPU_THREADS != 0 ]]; then _args+=(--cpu-threads "$CPU_THREADS"); fi
    else
        _args+=(--disable-cpu)
    fi
    if [[ $GPU_ENABLED == yes ]]; then
        [[ $GPU_COIN == prl ]] && algo=pearlhash || algo=quantus
        _args+=(--algorithm-gpu "$algo" --pool "$CUR_GPU_POOL" --wallet "$wallet")
        if [[ $GPU_IDS != all ]]; then _args+=(--gpu-id "$GPU_IDS"); fi
    else
        _args+=(--disable-gpu)
    fi
}

miner_show_cmd() {
    cfg_load
    miner_select_pools
    local -a a; miner_build_args a
    echo "实际 SRBMiner 命令（GPU 功耗由 nvidia-smi 在启动前设置）："
    printf '%q ' "$MINER_BIN" "${a[@]}"; echo
}

# systemd 入口（mine _run）：校验 → 选节点 → 设功耗 → exec 矿机
miner_run() {
    cfg_load
    [[ -x $MINER_BIN ]] || die "找不到矿机：$MINER_BIN（执行 mine update）"
    [[ $CPU_ENABLED == yes || $GPU_ENABLED == yes ]] || die "CPU 和 GPU 都关闭了，没有任何挖矿任务。"

    if [[ $GPU_ENABLED == yes ]] && has nvidia-smi; then
        local i
        for ((i = 0; i < 60; i++)); do gpu_available && break; sleep 2; done      # 开机后等驱动就绪
        gpu_available || die "等待 NVIDIA 驱动超时，GPU 挖矿未启动（mine doctor）。"
        gpu_valid_selection "$GPU_IDS" || die "GPU_IDS=${GPU_IDS} 不存在，当前 GPU：$(gpu_all_ids)"
        gpu_apply_power "$GPU_POWER_LIMIT" "$GPU_IDS" || die "功耗限制设置失败。"
    fi

    miner_select_pools
    {
        if [[ -n $CUR_XMR_POOL ]]; then echo "XMR $CUR_XMR_POOL"; fi
        if [[ -n $CUR_GPU_POOL ]]; then echo "${GPU_COIN^^} $CUR_GPU_POOL"; fi
    } | atomic_write "$RUN_POOLS" 0644

    local -a args; miner_build_args args
    info "================ 矿机开工 ================"
    info "矿工：${WALLET_BASE}.${WORKER}   SRBMiner $(miner_version_tag)"
    if [[ -n $CUR_XMR_POOL ]]; then info "CPU：XMR  ${CUR_XMR_POOL}"; fi
    if [[ -n $CUR_GPU_POOL ]]; then info "GPU：${GPU_COIN^^}  ${CUR_GPU_POOL}"; fi
    exec "$MINER_BIN" "${args[@]}"
}

# ---- 服务控制 ----------------------------------------------------------------
miner_active() { systemctl is-active --quiet "$MINER_SERVICE"; }

miner_start() {
    [[ -x $MINER_BIN ]] || die "矿机未安装，先执行：mine update"
    systemctl daemon-reload
    systemctl enable "$MINER_SERVICE" >/dev/null 2>&1
    systemctl restart "$MINER_SERVICE"
    sleep 3
    miner_active && ok "矿机已启动（并已开机自启）。" || { err "矿机没有正常启动，请看：mine log / mine doctor"; return 1; }
}

miner_stop() {
    systemctl stop "$MINER_SERVICE" || true
    gpu_reset_power
    ok "矿机已停止，GPU 功耗已恢复默认。"
}

miner_restart() {
    systemctl daemon-reload
    systemctl restart "$MINER_SERVICE"
    local i
    for ((i = 0; i < 15; i++)); do
        miner_active && { ok "矿机已重启。"; return 0; }
        sleep 1
    done
    err "重启后矿机未运行，请看：mine log / mine doctor"
    return 1
}

miner_restart_if_running() {
    if miner_active; then miner_restart; else info "矿机当前没在运行，参数已保存，下次启动生效。"; fi
}

miner_autostart() {
    if [[ ${1:-} == on ]]; then systemctl enable "$MINER_SERVICE" >/dev/null 2>&1; ok "已开启矿机开机自启。"
    else systemctl disable "$MINER_SERVICE" >/dev/null 2>&1 || true; ok "已关闭矿机开机自启（不会停止当前矿机）。"; fi
}

miner_status() {
    cfg_load
    title "矿机状态"
    printf '矿工：%s.%s\n' "$WALLET_BASE" "$WORKER"
    printf '版本：%s   运行：%s   开机自启：%s   自动切换：%s\n' "$(miner_version_tag)" \
        "$(miner_active && echo 运行中 || echo 已停止)" \
        "$(systemctl is-enabled --quiet "$MINER_SERVICE" 2>/dev/null && echo 开 || echo 关)" \
        "$(systemctl is-active --quiet "$AUTO_SERVICE" 2>/dev/null && echo 运行中 || echo 未运行)"
    printf '当前挖：%s%s\n' "$([[ $CPU_ENABLED == yes ]] && echo "CPU:XMR  " || true)" \
        "$([[ $GPU_ENABLED == yes ]] && echo "GPU:${GPU_COIN^^}" || true)"
    if [[ -f $RUN_POOLS ]]; then printf '节点：%s\n' "$(paste -sd'|' "$RUN_POOLS" | sed 's/|/   /g')"; fi
    rule
    journalctl -u "$MINER_SERVICE" -n 8 --no-pager -o cat 2>/dev/null || true
    if gpu_available; then
        rule
        nvidia-smi --query-gpu=index,name,utilization.gpu,power.draw,temperature.gpu --format=csv,noheader || true
    fi
}

miner_logs()        { journalctl -u "$MINER_SERVICE" -n "${1:-120}" --no-pager -o cat; }
miner_logs_follow() { journalctl -u "$MINER_SERVICE" -f -o cat || true; }
miner_version()     { [[ -x $MINER_BIN ]] || die "矿机未安装。"; echo "mine 记录版本：$(miner_version_tag)"; timeout 10 "$MINER_BIN" --version 2>&1 || true; }
__FILE__

cat > "$T/lib/65-settings.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 65-settings.sh —— 设置项：读配置 → 提问 → 写配置 → 如在运行则重启生效
# ============================================================================

set_worker() {
    cfg_load
    local w=${1:-}
    if [[ -z $w ]]; then ask_worker w "$WORKER"; fi
    valid_worker "$w" || die "矿工名只允许字母/数字/._-，且不能以 . 开头。"
    cfg_set WORKER "$w"
    ok "矿工名已改为 ${WALLET_BASE}.${w}"
    miner_restart_if_running
}

set_cpu() {
    cfg_load
    local on th=$CPU_THREADS
    ask_yn on "开启 CPU 挖 XMR？" "$CPU_ENABLED"
    if [[ $on == yes ]]; then ask_cpu_threads th "$CPU_THREADS"; fi
    cfg_set CPU_ENABLED "$on"; cfg_set CPU_THREADS "$th"
    miner_restart_if_running
}

set_gpu() {
    cfg_load
    local on ids=$GPU_IDS coin=$GPU_COIN pw=$GPU_POWER_LIMIT
    ask_yn on "开启 GPU 挖矿？" "$GPU_ENABLED"
    if [[ $on == yes ]]; then
        ask_gpu_ids ids "$GPU_IDS"
        ask_coin coin "$GPU_COIN"
        if gpu_available; then ask_power pw "$GPU_POWER_LIMIT" "$ids"; else pw=0; fi
    fi
    cfg_set GPU_ENABLED "$on"; cfg_set GPU_IDS "$ids"; cfg_set GPU_COIN "$coin"; cfg_set GPU_POWER_LIMIT "$pw"
    miner_restart_if_running
}

# mine coin（交互）/ mine coin prl|qtc / mine prl / mine qtc / prl / qtc
set_coin() {
    cfg_load
    [[ $GPU_ENABLED == yes ]] || die "GPU 当前是关闭的，先执行 mine set gpu 开启。"
    local c=${1:-}
    if [[ -z $c ]]; then ask_coin c "$GPU_COIN"; fi
    c=${c,,}
    valid_coin "$c" || die "币种只能是 prl 或 qtc。"
    if [[ $c == "$GPU_COIN" ]]; then info "当前已经是 ${c^^}，无需切换。"; return 0; fi
    cfg_set GPU_COIN "$c"
    ok "GPU 已切到 ${c^^}。"
    if systemctl is-active --quiet "$AUTO_SERVICE" 2>/dev/null; then
        warn "自动切换正在运行，之后仍会按收益判断是否切回；想固定 ${c^^} 请执行：mine auto stop"
    fi
    miner_restart_if_running
}

set_power() {
    cfg_load
    [[ $GPU_ENABLED == yes ]] || die "GPU 当前是关闭的。"
    gpu_available || die "功耗限制只支持 NVIDIA（nvidia-smi 不可用）。"
    local pw; ask_power pw "$GPU_POWER_LIMIT" "$GPU_IDS"
    cfg_set GPU_POWER_LIMIT "$pw"
    miner_restart_if_running
}

# 重新测速 Kryptex 节点
set_pool() {
    cfg_load
    pools_rank_all
    cfg_set XMR_POOLS "$XMR_POOLS"; cfg_set PRL_POOLS "$PRL_POOLS"; cfg_set QTC_POOLS "$QTC_POOLS"
    miner_restart_if_running
}

# 交互式全部重设（可选；安装时不会弹出）
setup_wizard() {
    cfg_load
    title "重新配置（每项直接回车 = 使用方括号里的当前值）"
    local w on th=$CPU_THREADS gon=$GPU_ENABLED ids=$GPU_IDS coin=$GPU_COIN pw=$GPU_POWER_LIMIT
    ask_worker w "$WORKER"
    ask_yn on "开启 CPU 挖 XMR？" "$CPU_ENABLED"
    if [[ $on == yes ]]; then ask_cpu_threads th "$CPU_THREADS"; fi
    ask_yn gon "开启 GPU 挖矿？" "$GPU_ENABLED"
    if [[ $gon == yes ]]; then
        ask_gpu_ids ids "$GPU_IDS"
        ask_coin coin "$GPU_COIN"
        if gpu_available; then ask_power pw "$GPU_POWER_LIMIT" "$ids"; else pw=0; fi
    fi
    cfg_set WORKER "$w"; cfg_set CPU_ENABLED "$on"; cfg_set CPU_THREADS "$th"
    cfg_set GPU_ENABLED "$gon"; cfg_set GPU_IDS "$ids"; cfg_set GPU_COIN "$coin"; cfg_set GPU_POWER_LIMIT "$pw"
    echo
    hr_configure
    ok "配置已保存。"
}

set_cmd() {  # mine set <worker|cpu|gpu|coin|power|pool|hashrate|all>
    case ${1:-} in
        worker) shift; set_worker "${1:-}" ;;
        cpu)    set_cpu ;;
        gpu)    set_gpu ;;
        coin)   shift; set_coin "${1:-}" ;;
        power)  set_power ;;
        pool|pools) set_pool ;;
        hashrate|hr) shift; hr_cmd "$@" ;;
        all)    setup_wizard; miner_restart_if_running ;;
        *)      die "用法：mine set <worker|cpu|gpu|coin|power|pool|hashrate|all>" ;;
    esac
}
__FILE__

cat > "$T/lib/70-hashrate.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 70-hashrate.sh —— 算力输入的解析与换算（100TH、1200MH、1.5PH ...）
# ============================================================================

hr_normalize() {  # hr_normalize <输入> [默认单位字母]
    local up num pre h re='^([0-9]+(\.[0-9]+)?)([KMGTPE]?)(H?)$'
    up=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    up=${up%/S}
    if [[ $up == *HS ]]; then up=${up%S}; fi
    [[ $up =~ $re ]] || return 1
    num=${BASH_REMATCH[1]}; pre=${BASH_REMATCH[3]}; h=${BASH_REMATCH[4]}
    if [[ -z $pre && -z $h ]]; then
        pre=${2:-}
        [[ -n $pre ]] || return 1
    fi
    local out="${num}${pre}H"
    hr_to_hs "$out" >/dev/null || return 1
    printf '%s' "$out"
}

hr_to_hs() {  # hr_to_hs 100TH → 100000000000000
    local re='^([0-9]+(\.[0-9]+)?)([KMGTPE]?)H$' e
    [[ $1 =~ $re ]] || return 1
    case ${BASH_REMATCH[3]} in
        K) e=3 ;; M) e=6 ;; G) e=9 ;; T) e=12 ;; P) e=15 ;; E) e=18 ;; *) e=0 ;;
    esac
    awk -v n="${BASH_REMATCH[1]}" -v e="$e" 'BEGIN { x = n * (10 ^ e); if (x <= 0 || x >= 9.22e18) exit 1; printf "%.0f", x }'
}

valid_hashrate() { hr_to_hs "$1" >/dev/null 2>&1; }

hr_pretty() {
    local re='^([0-9]+(\.[0-9]+)?)([KMGTPE]?)H$'
    if [[ $1 =~ $re ]]; then printf '%s %sH/s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"; else printf '%s' "$1"; fi
}

_hr_prefix() { local re='^[0-9.]+([KMGTPE]?)H$'; [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}" || true; }

_hr_ask_one() {  # _hr_ask_one <PRL|QTC> <配置键> <当前值>
    local name=$1 key=$2 cur=$3 in norm
    while true; do
        read -r -p "${name} 算力（如 100TH、1200MH；回车保持 $(hr_pretty "$cur")）: " in || die "输入被中断"
        in=${in//$'\r'/}
        if [[ -z ${in//[[:space:]]/} ]]; then info "${name} 算力保持 $(hr_pretty "$cur")。"; return 0; fi
        if norm=$(hr_normalize "$in" "$(_hr_prefix "$cur")"); then
            cfg_set "$key" "$norm"
            ok "${name} 算力 = $(hr_pretty "$norm") = $(hr_to_hs "$norm") H/s"
            return 0
        fi
        warn "格式不对。示例：100TH / 100 TH/s / 1.5PH / 1200MH"
    done
}

hr_configure() {
    cfg_load
    echo "【自动切换用的算力】填你这台机器在 SRBMiner 日志里看到的实际算力（单位 H/KH/MH/GH/TH/PH）。"
    _hr_ask_one PRL PRL_HASHRATE "$PRL_HASHRATE"
    _hr_ask_one QTC QTC_HASHRATE "$QTC_HASHRATE"
    rm -f "$CACHE_FILE"
}

# mine hashrate            交互
# mine hashrate prl 100TH  直接设置
hr_cmd() {
    if (( $# == 0 )); then hr_configure; return; fi
    (( $# == 2 )) || die "用法：mine hashrate [prl|qtc <算力，如 100TH>]"
    cfg_load
    local coin=${1,,} norm key cur
    valid_coin "$coin" || die "币种只能是 prl 或 qtc。"
    if [[ $coin == prl ]]; then key=PRL_HASHRATE; cur=$PRL_HASHRATE; else key=QTC_HASHRATE; cur=$QTC_HASHRATE; fi
    norm=$(hr_normalize "$2" "$(_hr_prefix "$cur")") || die "算力格式不对，示例：100TH、1200MH"
    cfg_set "$key" "$norm"
    rm -f "$CACHE_FILE"
    ok "${coin^^} 算力 = $(hr_pretty "$norm") = $(hr_to_hs "$norm") H/s（自动切换下一轮生效）"
}
__FILE__

cat > "$T/lib/80-market.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 80-market.sh —— 收益：Kryptex 日产币量（10 分钟缓存） × CoinGecko 币价（全部直连）
# ============================================================================

# 输出（TAB 分隔）：<PRL日产币量> <QTC日产币量> <来源说明>
kryptex_daily_coins() {
    local prl_hs qtc_hs now ts c_p c_q prl_coin qtc_coin
    prl_hs=$(hr_to_hs "$PRL_HASHRATE") || return 1
    qtc_hs=$(hr_to_hs "$QTC_HASHRATE") || return 1
    now=$(date +%s)

    if [[ -f $CACHE_FILE ]]; then
        read -r ts c_p c_q prl_coin qtc_coin < "$CACHE_FILE" || true
        if [[ ${ts:-} =~ ^[0-9]+$ ]] && (( now >= ts && now - ts < KRYPTEX_CACHE_TTL )) \
           && [[ ${c_p:-} == "$prl_hs" && ${c_q:-} == "$qtc_hs" ]] \
           && valid_api_number "${prl_coin:-}" && valid_api_number "${qtc_coin:-}"; then
            printf '%s\t%s\t缓存(%ss前)\n' "$prl_coin" "$qtc_coin" "$((now - ts))"
            return 0
        fi
    fi

    prl_coin=$(net_curl -H 'Accept: application/json' "${KRYPTEX_API}/prl?hashrate=${prl_hs}") || { err "Kryptex PRL 日产币量获取失败。"; return 1; }
    qtc_coin=$(net_curl -H 'Accept: application/json' "${KRYPTEX_API}/qtc?hashrate=${qtc_hs}") || { err "Kryptex QTC 日产币量获取失败。"; return 1; }
    prl_coin=${prl_coin//[[:space:]]/}; qtc_coin=${qtc_coin//[[:space:]]/}
    valid_api_number "$prl_coin" || { err "PRL 日产币量异常：[$prl_coin]"; return 1; }
    valid_api_number "$qtc_coin" || { err "QTC 日产币量异常：[$qtc_coin]"; return 1; }

    mkdir -p "$STATE_DIR"
    printf '%s %s %s %s %s\n' "$now" "$prl_hs" "$qtc_hs" "$prl_coin" "$qtc_coin" | atomic_write "$CACHE_FILE" 0600
    printf '%s\t%s\t实时\n' "$prl_coin" "$qtc_coin"
}

price_fetch() {  # 输出：<PRL价格> TAB <QTC价格>
    local body
    body=$(net_curl -H 'Accept: application/json' "${CG_URL}?ids=${CG_PRL_ID},${CG_QTC_ID}&vs_currencies=usd") || return 1
    jq -er --arg p "$CG_PRL_ID" --arg q "$CG_QTC_ID" '
        [.[$p].usd, .[$q].usd] | select(all(.[]; type == "number" and . > 0)) | @tsv
    ' <<< "$body"
}

# 输出（TAB）：PRL日收益 QTC日收益 PRL小时 QTC小时 PRL币价 QTC币价 Kryptex来源
revenue_get() {
    local coins prices prl_coin qtc_coin src prl_price qtc_price
    coins=$(kryptex_daily_coins) || return 1
    IFS=$'\t' read -r prl_coin qtc_coin src <<< "$coins"
    prices=$(price_fetch) || { err "CoinGecko 币价获取失败。"; return 1; }
    IFS=$'\t' read -r prl_price qtc_price <<< "$prices"
    valid_api_number "$prl_price" && valid_api_number "$qtc_price" || { err "币价数据异常：[$prl_price] [$qtc_price]"; return 1; }

    awk -v pc="$prl_coin" -v pp="$prl_price" -v qc="$qtc_coin" -v qp="$qtc_price" -v src="$src" 'BEGIN {
        pd = pc * pp; qd = qc * qp
        if (pd < 0 || qd < 0) exit 1
        printf "%.8f\t%.8f\t%.8f\t%.8f\t%s\t%s\t%s\n", pd, qd, pd / 24, qd / 24, pp, qp, src
    }' || { err "收益计算失败。"; return 1; }
}

as_show_revenue() {
    cfg_load
    local data prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src best
    data=$(revenue_get) || { err "收益/币价获取失败（mine net 检查网络）。"; return 1; }
    IFS=$'\t' read -r prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src <<< "$data"
    best=$(awk -v a="$prl_hour" -v b="$qtc_hour" 'BEGIN{print (a>b)?"PRL":((b>a)?"QTC":"相同")}')
    title "实时收益（Kryptex 产币 × CoinGecko 币价）"
    printf 'PRL ：%s USD/h   %s USD/day   币价 $%s   算力 %s\n' "$prl_hour" "$prl_day" "$prl_price" "$(hr_pretty "$PRL_HASHRATE")"
    printf 'QTC ：%s USD/h   %s USD/day   币价 $%s   算力 %s\n' "$qtc_hour" "$qtc_day" "$qtc_price" "$(hr_pretty "$QTC_HASHRATE")"
    printf '收益更高：%s     当前 GPU：%s     Kryptex 数据：%s\n' "$best" "${GPU_COIN^^}" "$src"
}

# 首次安装：先请求 Kryptex + CoinGecko 算一次收益，GPU 默认挖收益最高的币。
# 接口失败时保留当前值（旧版 wwww.sh 的币种，否则 PRL），之后由自动切换接管。
pick_best_coin() {
    local data prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src
    info "请求 Kryptex / CoinGecko 计算收益，选择 GPU 默认币种..."
    if ! data=$(revenue_get); then
        warn "收益数据获取失败，GPU 先挖 ${GPU_COIN^^}，自动切换稍后会按收益重新判断。"
        return 0
    fi
    IFS=$'\t' read -r prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src <<< "$data"
    GPU_COIN=$(awk -v a="$prl_day" -v b="$qtc_day" 'BEGIN { print (b > a) ? "qtc" : "prl" }')
    info "PRL ≈ ${prl_day} USD/day   QTC ≈ ${qtc_day} USD/day（算力 PRL $(hr_pretty "$PRL_HASHRATE") / QTC $(hr_pretty "$QTC_HASHRATE")）"
    ok "GPU 默认挖收益更高的：${GPU_COIN^^}"
}

as_show_prices() {
    local p
    p=$(price_fetch) || { err "币价获取失败，请执行 mine net 检查网络。"; return 1; }
    ok "PRL(${CG_PRL_ID}) = \$${p%%$'\t'*}    QTC(${CG_QTC_ID}) = \$${p##*$'\t'}"
}
__FILE__

cat > "$T/lib/85-autoswitch.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 85-autoswitch.sh —— GPU 在 PRL / QTC 之间按收益自动切换 + 节点健康检查
# 切换条件（缺一不可）：
#   ① 候选币日收益 ≥ MIN_DAILY_USD
#   ② 候选币小时收益 ≥ 当前币 × (1 + ADVANTAGE_PERCENT%)
#   ③ 连续 CONFIRM_COUNT 轮都满足（取数失败计数清零）
#   ④ 距离上次自动切换 ≥ MIN_HOLD_SECONDS
# ============================================================================

as_state_load() {
    LAST_COIN=""; LAST_SWITCH_EPOCH=0; PENDING_COIN=""; PENDING_COUNT=0
    mkdir -p "$STATE_DIR"
    kv_load "$STATE_FILE" LAST_COIN LAST_SWITCH_EPOCH PENDING_COIN PENDING_COUNT
    [[ $LAST_SWITCH_EPOCH =~ ^[0-9]+$ ]] || LAST_SWITCH_EPOCH=0
    [[ $PENDING_COUNT =~ ^[0-9]+$ ]]     || PENDING_COUNT=0
    valid_coin "$LAST_COIN"    || LAST_COIN=""
    valid_coin "$PENDING_COIN" || PENDING_COIN=""
}

as_state_save() {
    atomic_write "$STATE_FILE" 0600 <<EOF_ST
LAST_COIN="${LAST_COIN}"
LAST_SWITCH_EPOCH="${LAST_SWITCH_EPOCH}"
PENDING_COIN="${PENDING_COIN}"
PENDING_COUNT="${PENDING_COUNT}"
EOF_ST
}

as_clear_pending() { PENDING_COIN=""; PENDING_COUNT=0; as_state_save; }

_num_ge()   { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
_threshold(){ awk -v c="$1" -v p="$ADVANTAGE_PERCENT" 'BEGIN { printf "%.8f", c * (1 + p / 100) }'; }
_adv_pct()  { awk -v c="$1" -v n="$2" 'BEGIN { if (c <= 0) printf "999999.00"; else printf "%.2f", (n / c - 1) * 100 }'; }
_min()      { awk -v s="$1" 'BEGIN { printf "%g", s / 60 }'; }

as_check_impl() {
    cfg_load
    as_state_load

    if [[ $GPU_ENABLED != yes ]]; then info "GPU 没有开启，自动切换本轮不工作。"; return 0; fi
    local current=$GPU_COIN

    if [[ $LAST_COIN != "$current" ]]; then
        LAST_COIN=$current; PENDING_COIN=""; PENDING_COUNT=0; as_state_save
        info "当前 GPU 币种为 ${current^^}，已同步状态。"
    fi
    if ! miner_active; then info "矿机当前未运行，本轮不切换，也不会替你启动矿机。"; return 0; fi

    local data prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src
    if ! data=$(revenue_get); then
        err "收益/币价获取失败，本轮跳过；连续确认计数清零。"
        as_clear_pending; return 1
    fi
    IFS=$'\t' read -r prl_day qtc_day prl_hour qtc_hour prl_price qtc_price src <<< "$data"

    local cur_name cand cand_name cur_hour cand_hour cand_day
    if [[ $current == prl ]]; then
        cur_name=PRL; cand=qtc; cand_name=QTC; cur_hour=$prl_hour; cand_hour=$qtc_hour; cand_day=$qtc_day
    else
        cur_name=QTC; cand=prl; cand_name=PRL; cur_hour=$qtc_hour; cand_hour=$prl_hour; cand_day=$prl_day
    fi
    local adv; adv=$(_adv_pct "$cur_hour" "$cand_hour")
    info "PRL ${prl_hour}/h (${prl_day}/day, \$${prl_price}) | QTC ${qtc_hour}/h (${qtc_day}/day, \$${qtc_price}) | 当前 ${cur_name}，${cand_name} 优势 ${adv}% | Kryptex ${src}"

    if ! _num_ge "$cand_day" "$MIN_DAILY_USD"; then
        as_clear_pending; info "${cand_name} 日收益 ${cand_day} < ${MIN_DAILY_USD} USD，保持 ${cur_name}。"; return 0
    fi
    local th; th=$(_threshold "$cur_hour")
    if ! _num_ge "$cand_hour" "$th"; then
        as_clear_pending; info "${cand_name} 未达到 ${cur_name} + ${ADVANTAGE_PERCENT}%（需 ≥ ${th} USD/h），保持 ${cur_name}。"; return 0
    fi
    if [[ $PENDING_COIN == "$cand" ]]; then PENDING_COUNT=$((PENDING_COUNT + 1)); else PENDING_COIN=$cand; PENDING_COUNT=1; fi
    as_state_save
    if (( PENDING_COUNT < CONFIRM_COUNT )); then
        info "${cand_name} 连续确认 ${PENDING_COUNT}/${CONFIRM_COUNT}，暂不切换。"; return 0
    fi
    local now held; now=$(date +%s)
    if (( LAST_SWITCH_EPOCH <= 0 )); then held=999999999; else held=$((now - LAST_SWITCH_EPOCH)); fi
    if (( held < MIN_HOLD_SECONDS )); then
        info "条件已满足，但仍在最短驻留期：${held}s / ${MIN_HOLD_SECONDS}s，暂不切换。"; return 0
    fi

    info "全部条件满足，切换：${cur_name} → ${cand_name}（优势 ${adv}%）"
    cfg_set GPU_COIN "$cand"
    if miner_restart; then
        LAST_COIN=$cand; LAST_SWITCH_EPOCH=$now; PENDING_COIN=""; PENDING_COUNT=0; as_state_save
        ok "自动切换成功：GPU 现在挖 ${cand_name}。"
    else
        cfg_set GPU_COIN "$current"
        as_clear_pending
        miner_restart || true
        warn "切到 ${cand_name} 失败，已恢复 ${cur_name}。请执行 mine log 检查。"
        return 1
    fi
}

as_check_once() {
    (
        LOG_TS=1
        flock -n 8 || { warn "已有另一轮检查正在进行，本次跳过。"; exit 0; }
        as_check_impl
    ) 8> "$LOCK_CHECK"
}

# 矿机正在用的节点连续 POOL_FAIL_LIMIT 轮连不上 → 重启矿机（启动时会自动挑下一个能连上的节点）
POOL_FAILS=0
as_pool_health() {
    miner_active || { POOL_FAILS=0; return 0; }
    [[ -f $RUN_POOLS ]] || return 0
    local kind p bad=0
    while read -r kind p; do
        [[ -n ${p:-} ]] || continue
        if ! tcp_ms "${p%:*}" "${p##*:}" >/dev/null; then warn "${kind} 节点 ${p} 连接失败。"; bad=1; fi
    done < "$RUN_POOLS"
    if (( bad )); then POOL_FAILS=$((POOL_FAILS + 1)); else POOL_FAILS=0; fi
    if (( POOL_FAILS >= POOL_FAIL_LIMIT )); then
        warn "节点连续 ${POOL_FAILS} 轮不通，重启矿机换节点。"
        POOL_FAILS=0
        miner_restart || true
    fi
}

as_daemon() {
    LOG_TS=1
    cfg_load
    mkdir -p "$STATE_DIR"
    exec 9> "$LOCK_DAEMON"
    flock -n 9 || die "自动切换后台已经在运行，拒绝重复启动。"
    info "自动切换启动：每 $(_min "$CHECK_INTERVAL") 分钟 | 优势 ${ADVANTAGE_PERCENT}% | 日收益 ≥ \$${MIN_DAILY_USD} | 连续 ${CONFIRM_COUNT} 次 | 最短驻留 $(_min "$MIN_HOLD_SECONDS") 分钟"
    info "算力：PRL $(hr_pretty "$PRL_HASHRATE") | QTC $(hr_pretty "$QTC_HASHRATE") | 网络直连 | Kryptex 缓存 ${KRYPTEX_CACHE_TTL}s"
    sleep 60                                   # 给矿机一点启动时间
    while true; do
        as_check_once || warn "本轮检查异常，下一轮继续。"
        as_pool_health || true
        cfg_load
        sleep "$CHECK_INTERVAL"
    done
}

as_active() { systemctl is-active --quiet "$AUTO_SERVICE"; }

as_install() {
    mkdir -p "$STATE_DIR"
    systemctl enable "$AUTO_SERVICE" >/dev/null 2>&1
    systemctl restart "$AUTO_SERVICE"
    ok "自动切换已启动（开机自启）。"
}
as_start()   { systemctl enable "$AUTO_SERVICE" >/dev/null 2>&1; systemctl start "$AUTO_SERVICE"; ok "自动切换已启动（开机自启）。"; }
as_stop()    { systemctl stop "$AUTO_SERVICE" || true; systemctl disable "$AUTO_SERVICE" >/dev/null 2>&1 || true; ok "自动切换已停止，GPU 固定在当前币种（mine auto start 恢复）。"; }
as_restart() { systemctl restart "$AUTO_SERVICE"; ok "自动切换已重启。"; }
as_logs()    { journalctl -u "$AUTO_SERVICE" -n "${1:-120}" --no-pager -o cat; }
as_logs_follow() { journalctl -u "$AUTO_SERVICE" -f -o cat || true; }

as_status() {
    cfg_load
    title "自动切换状态"
    printf '服务：%s   开机自启：%s\n' "$(as_active && echo 运行中 || echo 未运行)" "$(systemctl is-enabled --quiet "$AUTO_SERVICE" 2>/dev/null && echo 开 || echo 关)"
    printf '算力：PRL %s | QTC %s\n' "$(hr_pretty "$PRL_HASHRATE")" "$(hr_pretty "$QTC_HASHRATE")"
    printf '策略：每 %s 分钟 | 优势 %s%% | 日收益 ≥ $%s | 连续 %s 次 | 最短驻留 %s 分钟\n' \
        "$(_min "$CHECK_INTERVAL")" "$ADVANTAGE_PERCENT" "$MIN_DAILY_USD" "$CONFIRM_COUNT" "$(_min "$MIN_HOLD_SECONDS")"
    printf '当前：GPU %s / %s\n' "$GPU_IDS" "${GPU_COIN^^}"
    rule
    journalctl -u "$AUTO_SERVICE" -n 5 --no-pager -o cat 2>/dev/null || true
}

_valid_minutes_1() { valid_decimal "$1" && awk -v m="$1" 'BEGIN { exit !(m >= 1) }'; }

as_strategy() {
    cfg_load
    title "自动切换策略（回车 = 保持方括号里的当前值）"
    local iv adv min cnt hold
    ask iv   "检查间隔（分钟，≥1）"      "$(_min "$CHECK_INTERVAL")"   _valid_minutes_1 "请输入不小于 1 的数字。"
    ask adv  "切换优势（%）"              "$ADVANTAGE_PERCENT"          valid_decimal    "请输入数字。"
    ask min  "候选币最低日收益（USD）"    "$MIN_DAILY_USD"              valid_decimal    "请输入数字。"
    ask cnt  "连续确认次数"               "$CONFIRM_COUNT"              valid_pos_int    "请输入 ≥1 的整数。"
    ask hold "最短驻留（分钟，0=不限）"   "$(_min "$MIN_HOLD_SECONDS")" valid_decimal    "请输入数字。"
    cfg_set CHECK_INTERVAL "$(awk -v m="$iv" 'BEGIN { printf "%d", m * 60 + 0.5 }')"
    cfg_set ADVANTAGE_PERCENT "$adv"
    cfg_set MIN_DAILY_USD "$min"
    cfg_set CONFIRM_COUNT "$cnt"
    cfg_set MIN_HOLD_SECONDS "$(awk -v m="$hold" 'BEGIN { printf "%d", m * 60 + 0.5 }')"
    ok "策略已保存，后台下一轮自动生效。"
}

as_strategy_reset() {
    cfg_load
    cfg_reset_strategy_vars
    local k
    for k in CHECK_INTERVAL ADVANTAGE_PERCENT MIN_DAILY_USD CONFIRM_COUNT MIN_HOLD_SECONDS; do cfg_set "$k" "${!k}"; done
    ok "已恢复推荐策略：5 分钟 / 4% / \$0.20/day / 连续 3 次 / 最短驻留 20 分钟。"
}
__FILE__

cat > "$T/lib/90-menu.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 90-menu.sh —— 交互菜单（每项都调用 mine <子命令>，在独立进程执行）
# ============================================================================

_run() { "$SELF" "$@" || true; pause_enter; }
_run_nopause() { "$SELF" "$@" || true; }

_menu_header() {
    cfg_load
    local miner auto
    miner_active && miner="运行中" || miner="已停止"
    as_active && auto="运行中" || auto="未运行"
    clear || true
    echo "============================================================"
    printf '  mine 控制台                     北京时间 %s\n' "$(date '+%F %T')"
    echo "============================================================"
    printf ' 矿工 %s.%s\n' "$WALLET_BASE" "$WORKER"
    printf ' GPU  %s / %s / 卡 %s      CPU  %s / XMR\n' "$GPU_ENABLED" "${GPU_COIN^^}" "$GPU_IDS" "$CPU_ENABLED"
    printf ' 矿机 %s (%s)      自动切换 %s\n' "$miner" "$(miner_version_tag)" "$auto"
    printf ' 算力 PRL %s | QTC %s\n' "$(hr_pretty "$PRL_HASHRATE")" "$(hr_pretty "$QTC_HASHRATE")"
    rule
}

menu_main() {
    local c
    trap ':' INT
    while true; do
        _menu_header
        cat <<'EOF_M'
 【常用】
   1) 矿机状态                  2) 实时日志
   3) 重启矿机                  4) 手动切换 GPU 币种 (PRL/QTC)
   5) 设置算力（如 100TH）      6) 当前收益对比
   7) 自动切换管理  ▶
 【设置】
   8) CPU 设置                  9) GPU 设置
  10) GPU 功耗                 11) 矿工名
  12) Kryptex 节点重新测速
 【启停】
  13) 启动矿机                 14) 停止矿机
  15) 开机自启 开              16) 开机自启 关
 【维护】
  17) 更新矿机（GitHub 最新版） 18) 网络测试
  19) 诊断                     20) 查看配置 / 实际命令
  21) 全部重新配置             22) 卸载
   0) 退出
EOF_M
        rule
        read -r -p "请输入编号： " c || exit 0
        case $c in
            1)  _run status ;;
            2)  _run_nopause logf ;;
            3)  _run restart ;;
            4)  _run coin ;;
            5)  _run hashrate ;;
            6)  _run rev ;;
            7)  menu_auto ;;
            8)  _run set cpu ;;
            9)  _run set gpu ;;
            10) _run set power ;;
            11) _run set worker ;;
            12) _run pool ;;
            13) _run start ;;
            14) _run stop ;;
            15) _run autostart on ;;
            16) _run autostart off ;;
            17) _run update ;;
            18) _run net ;;
            19) _run doctor ;;
            20) "$SELF" cfg || true; "$SELF" cmd || true; pause_enter ;;
            21) _run set all ;;
            22) "$SELF" uninstall || true; [[ -x $CMD_LINK ]] || exit 0; pause_enter ;;
            0|q|Q) exit 0 ;;
            *)  warn "没有这个选项。"; sleep 1 ;;
        esac
    done
}

menu_auto() {
    local c
    while true; do
        clear || true
        "$SELF" auto status || true
        cat <<'EOF_A'

   1) 当前收益（实时）          2) 立即检查一次
   3) 设置算力                  4) 修改策略
   5) 恢复推荐策略              6) 查看日志
   7) 实时日志                  8) 启动自动切换
   9) 停止自动切换（固定币种） 10) 重启自动切换
   0) 返回上一级
EOF_A
        rule
        read -r -p "请输入编号： " c || exit 0
        case $c in
            1)  _run rev ;;
            2)  _run auto once ;;
            3)  _run hashrate ;;
            4)  _run auto strategy ;;
            5)  _run auto reset ;;
            6)  _run auto log ;;
            7)  _run_nopause auto logf ;;
            8)  _run auto start ;;
            9)  _run auto stop ;;
            10) _run auto restart ;;
            0|q|Q) return 0 ;;
            *)  warn "没有这个选项。"; sleep 1 ;;
        esac
    done
}
__FILE__

cat > "$T/lib/95-cli.sh" <<'__FILE__'
# shellcheck shell=bash
# ============================================================================
# 95-cli.sh —— 安装流程 / 帮助 / 子命令分发
# ============================================================================

usage() {
    cat <<'EOF_USAGE'
mine —— SRBMiner + Kryptex（直连）  CPU:XMR  GPU:PRL/QTC 按收益自动切换

【最常用】
  mine                      交互菜单
  mine status               矿机状态          mine logf        实时日志
  mine restart              重启矿机          mine start|stop  启动 / 停止
  mine rev                  当前 PRL / QTC 收益对比
  mine hashrate prl 300TH   设置算力（自动切换按它算收益；不带参数 = 交互）
  mine coin prl|qtc         手动切换（也可直接输入 prl / qtc）

【自动切换】 mine auto <子命令>
  status  once  strategy  reset  start  stop  restart  log  logf
  （mine auto stop = 固定当前币种，不再自动切）

【设置】 mine set <worker|cpu|gpu|coin|power|pool|hashrate|all>
  mine set worker rig01     改矿工名
  mine pool                 Kryptex 节点重新测速

【维护】
  mine update [--force]     更新矿机到 GitHub 最新版
  mine net                  网络测试（GitHub / Kryptex / CoinGecko / 节点）
  mine doctor               一键诊断          mine cfg / cmd / gpu / ver
  mine autostart on|off     矿机开机自启
  mine install              重新静默部署（不覆盖已有配置）
  mine uninstall            卸载

调试：MINE_DEBUG=1 mine <命令>
EOF_USAGE
}

# 静默部署：全部默认值，不提问；可反复执行
cmd_install() {
    title "mine 静默部署（直连 Kryptex，可重复运行，不覆盖已有配置）"
    sys_set_timezone
    sys_install_deps
    cfg_init
    sys_cleanup_legacy
    miner_install "${1:-}" || warn "矿机下载失败：网络恢复后执行 mine update 重试（其余部署继续）。"
    svc_write_units
    sys_install_shortcuts
    touch "$CONF_DONE"
    if [[ -x $MINER_BIN ]]; then miner_start || true; fi
    as_install || warn "自动切换启动失败，矿机不受影响，稍后执行 mine auto restart。"

    cfg_load
    title "🎉 安装完成，矿机已开工"
    printf '  矿工：     %s.%s\n' "$WALLET_BASE" "$WORKER"
    printf '  CPU：      %s\n' "$([[ $CPU_ENABLED == yes ]] && echo "XMR  (${XMR_POOLS%%,*})" || echo 关闭)"
    printf '  GPU：      %s\n' "$([[ $GPU_ENABLED == yes ]] && echo "${GPU_COIN^^}（自动切换 PRL/QTC 已开启）" || echo "未检测到显卡，已关闭（装好驱动后 mine set gpu）")"
    printf '  SRBMiner： %s\n' "$(miner_version_tag)"
    echo
    echo "  mine            交互菜单          mine status   状态"
    echo "  mine logf       实时日志          mine rev      收益对比"
    echo "  mine hashrate prl 300TH / mine hashrate qtc 1500MH   填真实算力，切换更准"
    echo "  mine --help     全部命令"
}

auto_cmd() {
    local sub=${1:-}; shift || true
    case $sub in
        "")             menu_auto ;;
        status)         as_status ;;
        once)           as_check_once ;;
        strategy)       as_strategy ;;
        reset)          as_strategy_reset ;;
        start|on|enable)   as_start ;;
        stop|off|disable)  as_stop ;;
        restart)        as_restart ;;
        log|logs)       as_logs "${1:-120}" ;;
        logf)           as_logs_follow ;;
        *)              die "未知的自动切换命令：$sub（mine --help 查看）" ;;
    esac
}

main() {
    local cmd=${1:-}; shift || true
    case $cmd in -h|--help|help) usage; return 0 ;; esac
    require_root

    case $cmd in
        "")
            if cfg_exists && [[ -f $CONF_DONE ]]; then menu_main; else cmd_install; fi ;;
        install)                    cmd_install "$@" ;;
        status|st)                  miner_status ;;
        log|logs)                   miner_logs "${1:-120}" ;;
        logf|follow)                miner_logs_follow ;;
        start)                      cfg_load; miner_start ;;
        stop)                       miner_stop ;;
        restart)                    cfg_load; miner_restart ;;
        coin)                       set_coin "${1:-}" ;;
        prl|qtc|PRL|QTC)            set_coin "$cmd" ;;
        hashrate|hr)                hr_cmd "$@" ;;
        rev|revenue)                as_show_revenue ;;
        price)                      as_show_prices ;;
        auto|autoswitch)            auto_cmd "$@" ;;
        set)                        set_cmd "$@" ;;
        pool|pools)                 set_pool ;;
        update)                     miner_update "${1:-}" ;;
        net|proxy)                  net_test ;;
        tz)                         sys_set_timezone ;;
        doctor|check)               sys_doctor ;;
        cfg|config)                 cfg_show ;;
        cmd)                        miner_show_cmd ;;
        gpu|gpus)                   gpu_print ;;
        ver|version)                miner_version ;;
        autostart)                  miner_autostart "${1:-}" ;;
        menu)                       menu_main ;;
        uninstall|remove)           uninstall_all ;;
        _run)                       miner_run ;;
        _autoswitch-daemon)         as_daemon ;;
        *)  err "未知命令：$cmd"; usage; return 1 ;;
    esac
}
__FILE__

bash "$T/install.sh" "$@"
