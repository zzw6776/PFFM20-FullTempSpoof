#!/system/bin/sh

PATCH_SYNC_FLAG="$STATE_DIR/pif-security-patch-sync.enabled"
PATCH_SYNC_APPLIED="$STATE_DIR/pif-security-patch-sync.applied"
PIF_MODULE_DIR=/data/adb/modules/playintegrityfix
PIF_CUSTOM_PROP="$PIF_MODULE_DIR/custom.pif.prop"
PIF_CUSTOM_JSON="$PIF_MODULE_DIR/custom.pif.json"
PIF_PROP="$PIF_MODULE_DIR/pif.prop"
PIF_JSON="$PIF_MODULE_DIR/pif.json"

active_pif_prop_file() {
    if [ -f "$PIF_CUSTOM_PROP" ]; then
        printf '%s\n' "$PIF_CUSTOM_PROP"
        return 0
    fi
    if [ -f "$PIF_CUSTOM_JSON" ]; then
        return 2
    fi
    if [ -f "$PIF_PROP" ]; then
        printf '%s\n' "$PIF_PROP"
        return 0
    fi
    if [ -f "$PIF_JSON" ]; then
        return 2
    fi
    return 1
}

prop_entry_count() {
    awk -F= -v wanted="$1" '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) count++
        }
        END { print count + 0 }
    ' "$2"
}

prop_entry_value() {
    awk -F= -v wanted="$1" '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key != wanted) next
            sub(/^[^=]*=/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$2"
}

valid_patch_date() {
    local value="$1" year month day month_number day_number max_day
    printf '%s\n' "$value" \
        | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' \
        || return 1

    year="${value%%-*}"
    month="${value#*-}"
    month="${month%%-*}"
    day="${value##*-}"
    month_number="${month#0}"
    day_number="${day#0}"
    case "$month_number" in
        1|3|5|7|8|10|12) max_day=31 ;;
        4|6|9|11) max_day=30 ;;
        2)
            max_day=28
            if [ $((year % 400)) -eq 0 ] \
                || { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; }; then
                max_day=29
            fi
            ;;
        *) return 1 ;;
    esac
    [ "$day_number" -le "$max_day" ]
}

set_patch_property() {
    local name="$1" patch="$2" actual
    if [ "$(resetprop "$name")" != "$patch" ]; then
        resetprop -n "$name" "$patch" >/dev/null 2>&1 || return 1
    fi
    actual="$(resetprop "$name")"
    [ "$actual" = "$patch" ] || return 1
}

sync_pif_security_patch() {
    local stage="$1" config_result config_file build_count property_count
    local build_patch property_patch

    if [ ! -e "$PATCH_SYNC_FLAG" ]; then
        rm -f "$PATCH_SYNC_APPLIED" 2>/dev/null
        log INFO "$stage PIF security patch sync disabled"
        return 0
    fi

    rm -f "$PATCH_SYNC_APPLIED" 2>/dev/null
    [ -f "$PIF_MODULE_DIR/module.prop" ] || {
        log ERROR "$stage PIF security patch sync enabled but Play Integrity Fork is missing"
        return 1
    }
    [ ! -e "$PIF_MODULE_DIR/disable" ] && [ ! -e "$PIF_MODULE_DIR/remove" ] || {
        log ERROR "$stage PIF security patch sync enabled but Play Integrity Fork is disabled"
        return 1
    }
    command -v resetprop >/dev/null 2>&1 || {
        log ERROR "$stage PIF security patch sync cannot find resetprop"
        return 1
    }

    config_file="$(active_pif_prop_file)"
    config_result=$?
    if [ "$config_result" -eq 2 ]; then
        log ERROR "$stage active Play Integrity Fork config is JSON; prop format is required"
        return 1
    fi
    if [ "$config_result" -ne 0 ] || [ -z "$config_file" ]; then
        log ERROR "$stage cannot find an active Play Integrity Fork config"
        return 1
    fi

    build_count="$(prop_entry_count SECURITY_PATCH "$config_file")"
    property_count="$(prop_entry_count '*.security_patch' "$config_file")"
    if [ "$build_count" -ne 1 ] || [ "$property_count" -ne 1 ]; then
        log ERROR "$stage PIF config must contain exactly one SECURITY_PATCH and *.security_patch"
        return 1
    fi

    build_patch="$(prop_entry_value SECURITY_PATCH "$config_file")"
    property_patch="$(prop_entry_value '*.security_patch' "$config_file")"
    if [ "$build_patch" != "$property_patch" ]; then
        log ERROR "$stage PIF patch mismatch build=$build_patch property=$property_patch"
        return 1
    fi
    valid_patch_date "$build_patch" || {
        log ERROR "$stage PIF security patch has invalid date format: $build_patch"
        return 1
    }

    set_patch_property ro.build.version.security_patch "$build_patch" || {
        log ERROR "$stage failed to set ro.build.version.security_patch"
        return 1
    }
    set_patch_property ro.vendor.build.security_patch "$build_patch" || {
        log ERROR "$stage failed to set ro.vendor.build.security_patch"
        return 1
    }

    printf '%s\n' "$build_patch" > "$PATCH_SYNC_APPLIED" || {
        log ERROR "$stage cannot persist applied PIF security patch"
        return 1
    }
    chown 0:0 "$PATCH_SYNC_APPLIED" 2>/dev/null
    chmod 0600 "$PATCH_SYNC_APPLIED" 2>/dev/null
    log INFO "$stage synchronized system and vendor security patch from $config_file: $build_patch"
    return 0
}
