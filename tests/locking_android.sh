#!/system/bin/sh

ROOT=${0%/*}
ROOT=${ROOT%/*}
BUSYBOX=${PFFM_BUSYBOX:-/data/adb/magisk/busybox}

if [ "${PFFM_BUSYBOX_SHELL:-0}" != 1 ]; then
    [ -x "$BUSYBOX" ] || exit 90
    PFFM_BUSYBOX="$BUSYBOX"
    PFFM_BUSYBOX_SHELL=1
    export PFFM_BUSYBOX PFFM_BUSYBOX_SHELL
    exec "$BUSYBOX" sh "$0" "$@"
fi

mode=${1:-main}
state=${2:-/data/local/tmp/pffm_lock_test}
name=${3:-worker}
export PFFM_STATE_DIR="$state"
MODDIR="$ROOT"
. "$ROOT/common.sh" || exit 91

case "$mode" in
    contend)
        if acquire_lock; then
            echo "$name=acquired"
            sleep 1
            release_lock
        else
            echo "$name=busy"
        fi
        exit 0
        ;;
    hold)
        acquire_lock || exit 92
        install_lock_signal_traps
        echo ready > "$state/holder.ready"
        sleep 30
        exit 0
        ;;
    term)
        acquire_lock || exit 93
        install_lock_signal_traps
        kill -TERM $$
        echo continued_after_term=1
        exit 94
        ;;
    hup)
        acquire_lock || exit 101
        install_lock_signal_traps
        kill -HUP $$
        echo continued_after_hup=1
        exit 102
        ;;
    app_term)
        acquire_lock || exit 95
        # App 的状态、准备、提交和导出命令统一使用 common.sh 的信号处理。
        install_lock_signal_traps
        kill -TERM $$
        echo app_continued_after_term=1
        exit 96
        ;;
    legacy_unlinked_hold)
        exec 7>"$state/lock" || exit 97
        "$BUSYBOX" flock -n 7 >/dev/null 2>&1 || exit 98
        legacy_start="$(process_start_time "$$")"
        [ -n "$legacy_start" ] || exit 99
        printf '%s\t%s\n' "$$" "$legacy_start" > "$state/lock.owner" || exit 100
        rm -f "$state/lock"
        echo ready > "$state/legacy-unlinked.ready"
        sleep 30
        exit 0
        ;;
    legacy_dir_delayed)
        : > "$state/legacy-dir-delayed.ready"
        while [ ! -e "$state/legacy-dir-delayed.go" ]; do
            sleep 0.02
        done
        if mkdir "$LEGACY_LOCK_PATH" 2>/dev/null; then
            echo delayed_old=acquired
        elif legacy_lock_owner_status "$LEGACY_LOCK_PATH"; then
            echo delayed_old=blocked
            exit 0
        else
            # 旧目录锁实现会把无法识别拥有者的路径当作陈旧锁删除后重建。
            rm -rf "$LEGACY_LOCK_PATH" 2>/dev/null
            if mkdir "$LEGACY_LOCK_PATH" 2>/dev/null; then
                echo delayed_old=acquired
            else
                echo delayed_old=blocked
                exit 0
            fi
        fi
        old_start="$(process_start_time "$$")"
        printf '%s\t%s\n' "$$" "$old_start" > "$LEGACY_LOCK_PATH/pid" 2>/dev/null
        sleep 1
        rm -rf "$LEGACY_LOCK_PATH" 2>/dev/null
        exit 0
        ;;
esac

rm -rf "$state"
mkdir -p "$state/lock" || exit 1
printf '999999\t1\n' > "$state/lock/pid" || exit 2

# 只有明确的启动边界才能清理上一启动遗留的目录锁。
PFFM_LEGACY_LOCK_BOOT_CLEANUP=1
acquire_lock || exit 29
release_lock || exit 30
PFFM_LEGACY_LOCK_BOOT_CLEANUP=0
export PFFM_LEGACY_LOCK_BOOT_CLEANUP

"$BUSYBOX" sh "$0" contend "$state" A > "$state/a.out" 2>&1 &
a_pid=$!
"$BUSYBOX" sh "$0" contend "$state" B > "$state/b.out" 2>&1 &
b_pid=$!
wait "$a_pid" || exit 3
wait "$b_pid" || exit 4
cat "$state/a.out" "$state/b.out"
[ "$(grep -c '=acquired$' "$state/a.out" "$state/b.out" 2>/dev/null | awk -F: '{n += $NF} END {print n+0}')" = 1 ] || exit 5
[ "$(grep -c '=busy$' "$state/a.out" "$state/b.out" 2>/dev/null | awk -F: '{n += $NF} END {print n+0}')" = 1 ] || exit 6
[ -f "$state/lock.v2" ] && [ ! -d "$state/lock.v2" ] || exit 7

# 模拟更旧进程在新版检查旧路径后、实际 mkdir 前暂停。新版持锁时，旧实现
# 即使执行“删除陈旧路径并重建”的完整分支，也必须看到活动 pid 并退出。
rm -rf "$state"
mkdir -p "$state" || exit 31
"$BUSYBOX" sh "$0" legacy_dir_delayed "$state" old > "$state/legacy-dir-delayed.out" 2>&1 &
legacy_dir_pid=$!
tries=0
while [ ! -e "$state/legacy-dir-delayed.ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
done
[ -e "$state/legacy-dir-delayed.ready" ] || exit 32
acquire_lock || exit 33
: > "$state/legacy-dir-delayed.go"
wait "$legacy_dir_pid" || exit 34
grep -q '^delayed_old=blocked$' "$state/legacy-dir-delayed.out" || exit 35
[ "$PFFM_LOCK_HELD" = 1 ] || exit 36
release_lock || exit 37
echo delayed_old_directory_lock_blocked=ok

# 新版进程若在发布 symlink 后被外部清理了隐藏目标，下一次获取必须能安全
# 删除已识别的悬空屏障，不能永久卡住所有入口。
rm -rf "$state"
mkdir -p "$state" || exit 39
"$BUSYBOX" ln -s .lock.v2-compat.999999 "$state/lock" || exit 40
acquire_lock || exit 41
release_lock || exit 42
echo dangling_compat_link_recovered=ok

rm -f "$state/holder.ready"
"$BUSYBOX" sh "$0" hold "$state" holder > "$state/holder.out" 2>&1 &
holder_pid=$!
tries=0
while [ ! -e "$state/holder.ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
done
[ -e "$state/holder.ready" ] || exit 8
kill -KILL "$holder_pid" 2>/dev/null || exit 9
wait "$holder_pid" 2>/dev/null
"$BUSYBOX" sh "$0" contend "$state" after_kill > "$state/after-kill.out" 2>&1 || exit 10
grep -q '^after_kill=acquired$' "$state/after-kill.out" || exit 11
echo kernel_release_after_kill=ok

"$BUSYBOX" sh "$0" term "$state" term > "$state/term.out" 2>&1
term_rc=$?
[ "$term_rc" -eq 143 ] || exit 12
! grep -q 'continued_after_term=1' "$state/term.out" || exit 13
echo term_exit_rc=$term_rc

"$BUSYBOX" sh "$0" hup "$state" hup > "$state/hup.out" 2>&1
hup_rc=$?
[ "$hup_rc" -eq 129 ] || exit 43
! grep -q 'continued_after_hup=1' "$state/hup.out" || exit 44
"$BUSYBOX" sh "$0" contend "$state" after_hup > "$state/after-hup.out" 2>&1 || exit 45
grep -q '^after_hup=acquired$' "$state/after-hup.out" || exit 46
echo hup_exit_rc=$hup_rc

"$BUSYBOX" sh "$0" app_term "$state" app > "$state/app-term.out" 2>&1
app_term_rc=$?
[ "$app_term_rc" -eq 143 ] || exit 14
! grep -q 'app_continued_after_term=1' "$state/app-term.out" || exit 15
echo app_term_exit_rc=$app_term_rc

# 上一版 flock 的路径若被更老进程删除，内核锁会留在不可见 inode 上；新版
# 必须通过独立 owner 文件识别该持锁者，不能直接创建 lock.v2。
rm -f "$state/legacy-unlinked.ready" "$state/lock.owner"
"$BUSYBOX" sh "$0" legacy_unlinked_hold "$state" legacy > "$state/legacy-unlinked.out" 2>&1 &
legacy_holder_pid=$!
tries=0
while [ ! -e "$state/legacy-unlinked.ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
done
[ -e "$state/legacy-unlinked.ready" ] || exit 16
"$BUSYBOX" sh "$0" contend "$state" legacy_contender > "$state/legacy-contender.out" 2>&1 || exit 17
grep -q '^legacy_contender=busy$' "$state/legacy-contender.out" || exit 18
kill -KILL "$legacy_holder_pid" 2>/dev/null || exit 19
wait "$legacy_holder_pid" 2>/dev/null
echo unlinked_legacy_flock_owner_blocked=ok

# 无 pid 的旧目录可能属于暂停在 mkdir 与写 pid 之间的旧进程；普通入口必须
# 拒绝执行，不能删除目录后在同一路径创建 flock 文件。
rm -rf "$state"
mkdir -p "$state/lock" || exit 20
"$BUSYBOX" sh "$0" contend "$state" ambiguous > "$state/ambiguous.out" 2>&1 || exit 21
grep -q '^ambiguous=busy$' "$state/ambiguous.out" || exit 22
[ ! -e "$state/lock.v2" ] || exit 23
echo ambiguous_legacy_dir_blocked=ok

# late_start 是明确的重启边界；此时旧进程不可能存活，才允许清理无 pid 目录。
PFFM_LEGACY_LOCK_BOOT_CLEANUP=1
export PFFM_LEGACY_LOCK_BOOT_CLEANUP
acquire_lock || exit 24
[ -f "$state/lock.v2" ] || exit 25
[ -L "$state/lock" ] || exit 38
"$BUSYBOX" sh "$0" contend "$state" third > "$state/third.out" 2>&1 || exit 26
grep -q '^third=busy$' "$state/third.out" || exit 27
release_lock || exit 28
echo boot_cleanup_replaced_legacy_dir_with_live_barrier=ok

echo LOCKING_ANDROID_OK
rm -rf "$state"
