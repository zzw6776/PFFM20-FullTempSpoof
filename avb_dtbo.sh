#!/system/bin/sh

# AVB-aware DTBO container helpers.
#
# The signed vbmeta blob is copied byte-for-byte from the baseline image. The
# DT table is rebuilt separately, vbmeta is moved to the next DT page boundary,
# and a new (unsigned) AVB footer is emitted at the end of the original
# partition-sized image. This intentionally preserves structurally valid AVB
# metadata; an unlocked bootloader is still required because the signed hash
# descriptor continues to describe the unmodified baseline DTBO.

AVB_ERROR=""
AVB_FLASH_STATUS=""

avb_fail() {
    AVB_ERROR="$*"
    return 1
}

avb_is_uint() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

avb_is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
        *) return 0 ;;
    esac
}

avb_file_size() {
    stat -c '%s' "$1" 2>/dev/null
}

avb_sha256() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

avb_hex_at() {
    od -An -tx1 -v -j "$2" -N "$3" "$1" 2>/dev/null | tr -d '[:space:]'
}

avb_read_be32() {
    local value
    set -- $(od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null)
    [ "$#" -eq 4 ] || return 1
    value=$(( (($1 * 256 + $2) * 256 + $3) * 256 + $4 ))
    printf '%s\n' "$value"
}

avb_read_be64() {
    local value byte
    set -- $(od -An -tu1 -j "$2" -N 8 "$1" 2>/dev/null)
    [ "$#" -eq 8 ] || return 1
    # Shell arithmetic is signed. Android partition offsets must fit int64_t.
    [ "$1" -lt 128 ] || return 1
    value=0
    for byte in "$@"; do
        value=$((value * 256 + byte))
    done
    printf '%s\n' "$value"
}

avb_read_le32() {
    local value
    set -- $(od -An -tu1 -j "$2" -N 4 "$1" 2>/dev/null)
    [ "$#" -eq 4 ] || return 1
    value=$(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))
    printf '%s\n' "$value"
}

avb_range_fits() {
    local offset="$1"
    local length="$2"
    local limit="$3"
    avb_is_uint "$offset" && avb_is_uint "$length" && avb_is_uint "$limit" || return 1
    [ "$offset" -le "$limit" ] || return 1
    [ "$length" -le "$((limit - offset))" ]
}

avb_is_power_of_two() {
    local value="$1"
    avb_is_uint "$value" || return 1
    [ "$value" -gt 0 ] || return 1
    [ $((value & (value - 1))) -eq 0 ]
}

avb_validate_vbmeta_header() {
    local image="$1"
    local vbmeta_offset="$2"
    local vbmeta_size="$3"
    local auth_size aux_size
    local hash_offset hash_size signature_offset signature_size
    local key_offset key_size key_meta_offset key_meta_size
    local descriptors_offset descriptors_size

    [ "$(avb_hex_at "$image" "$vbmeta_offset" 4)" = "41564230" ] || {
        avb_fail "vbmeta magic AVB0 不存在"
        return 1
    }
    [ "$vbmeta_size" -ge 256 ] || {
        avb_fail "vbmeta 小于 256 字节头部"
        return 1
    }

    auth_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 12))")" || {
        avb_fail "无法读取 vbmeta authentication block 大小"
        return 1
    }
    aux_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 20))")" || {
        avb_fail "无法读取 vbmeta auxiliary block 大小"
        return 1
    }
    [ "$auth_size" -le "$((vbmeta_size - 256))" ] || {
        avb_fail "vbmeta authentication block 越界"
        return 1
    }
    [ "$aux_size" -eq "$((vbmeta_size - 256 - auth_size))" ] || {
        avb_fail "vbmeta 总大小与头部不一致"
        return 1
    }

    hash_offset="$(avb_read_be64 "$image" "$((vbmeta_offset + 32))")" || return 1
    hash_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 40))")" || return 1
    signature_offset="$(avb_read_be64 "$image" "$((vbmeta_offset + 48))")" || return 1
    signature_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 56))")" || return 1
    key_offset="$(avb_read_be64 "$image" "$((vbmeta_offset + 64))")" || return 1
    key_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 72))")" || return 1
    key_meta_offset="$(avb_read_be64 "$image" "$((vbmeta_offset + 80))")" || return 1
    key_meta_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 88))")" || return 1
    descriptors_offset="$(avb_read_be64 "$image" "$((vbmeta_offset + 96))")" || return 1
    descriptors_size="$(avb_read_be64 "$image" "$((vbmeta_offset + 104))")" || return 1

    avb_range_fits "$hash_offset" "$hash_size" "$auth_size" || {
        avb_fail "vbmeta hash 区域越界"
        return 1
    }
    avb_range_fits "$signature_offset" "$signature_size" "$auth_size" || {
        avb_fail "vbmeta signature 区域越界"
        return 1
    }
    avb_range_fits "$key_offset" "$key_size" "$aux_size" || {
        avb_fail "vbmeta public key 区域越界"
        return 1
    }
    avb_range_fits "$key_meta_offset" "$key_meta_size" "$aux_size" || {
        avb_fail "vbmeta public key metadata 区域越界"
        return 1
    }
    avb_range_fits "$descriptors_offset" "$descriptors_size" "$aux_size" || {
        avb_fail "vbmeta descriptors 区域越界"
        return 1
    }
    return 0
}

avb_parse_dtbo_image() {
    local image="$1"
    local image_size footer_offset footer_magic footer_reserved
    local version_major version_minor original_size vbmeta_offset vbmeta_size
    local dt_magic dt_total_size dt_page_size

    [ -f "$image" ] || {
        avb_fail "镜像不存在: $image"
        return 1
    }
    image_size="$(avb_file_size "$image")" || {
        avb_fail "无法读取镜像大小: $image"
        return 1
    }
    avb_is_uint "$image_size" && [ "$image_size" -gt 320 ] || {
        avb_fail "镜像大小无效: $image_size"
        return 1
    }
    footer_offset=$((image_size - 64))
    footer_magic="$(avb_hex_at "$image" "$footer_offset" 4)"
    [ "$footer_magic" = "41564266" ] || {
        avb_fail "镜像末尾没有 AVBf footer"
        return 1
    }
    footer_reserved="$(avb_hex_at "$image" "$((footer_offset + 36))" 28)"
    case "$footer_reserved" in
        ""|*[!0]*)
            avb_fail "AVB footer reserved 字段不是全零"
            return 1
            ;;
    esac

    version_major="$(avb_read_be32 "$image" "$((footer_offset + 4))")" || return 1
    version_minor="$(avb_read_be32 "$image" "$((footer_offset + 8))")" || return 1
    [ "$version_major" -eq 1 ] && [ "$version_minor" -eq 0 ] || {
        avb_fail "仅支持 AVB footer 1.0，当前为 ${version_major}.${version_minor}"
        return 1
    }
    original_size="$(avb_read_be64 "$image" "$((footer_offset + 12))")" || return 1
    vbmeta_offset="$(avb_read_be64 "$image" "$((footer_offset + 20))")" || return 1
    vbmeta_size="$(avb_read_be64 "$image" "$((footer_offset + 28))")" || return 1

    [ "$original_size" -gt 32 ] || {
        avb_fail "AVB original_image_size 无效"
        return 1
    }
    [ "$original_size" -le "$vbmeta_offset" ] || {
        avb_fail "AVB original image 与 vbmeta 重叠"
        return 1
    }
    avb_range_fits "$vbmeta_offset" "$vbmeta_size" "$footer_offset" || {
        avb_fail "AVB vbmeta 区域越界"
        return 1
    }

    dt_magic="$(avb_hex_at "$image" 0 4)"
    [ "$dt_magic" = "d7b7ab1e" ] || {
        avb_fail "镜像开头不是 DT table"
        return 1
    }
    dt_total_size="$(avb_read_be32 "$image" 4)" || return 1
    [ "$dt_total_size" -eq "$original_size" ] || {
        avb_fail "DT table total_size($dt_total_size) 与 AVB original_image_size($original_size) 不一致"
        return 1
    }
    dt_page_size="$(avb_read_be32 "$image" 24)" || return 1
    avb_is_power_of_two "$dt_page_size" || {
        avb_fail "DT page_size 无效: $dt_page_size"
        return 1
    }
    [ $((vbmeta_offset % dt_page_size)) -eq 0 ] || {
        avb_fail "vbmeta_offset 未按 DT page_size 对齐"
        return 1
    }
    avb_validate_vbmeta_header "$image" "$vbmeta_offset" "$vbmeta_size" || return 1

    AVB_IMAGE_SIZE="$image_size"
    AVB_FOOTER_OFFSET="$footer_offset"
    AVB_VERSION_MAJOR="$version_major"
    AVB_VERSION_MINOR="$version_minor"
    AVB_ORIGINAL_IMAGE_SIZE="$original_size"
    AVB_VBMETA_OFFSET="$vbmeta_offset"
    AVB_VBMETA_SIZE="$vbmeta_size"
    AVB_DT_PAGE_SIZE="$dt_page_size"
    return 0
}

avb_validate_raw_dtbo() {
    local image="$1"
    local image_size magic total_size header_size entry_size entry_count entries_offset page_size
    local entries_end index entry_offset dt_size dt_offset dt_magic

    [ -f "$image" ] || {
        avb_fail "裸 DTBO 不存在: $image"
        return 1
    }
    image_size="$(avb_file_size "$image")" || return 1
    magic="$(avb_hex_at "$image" 0 4)"
    [ "$magic" = "d7b7ab1e" ] || {
        avb_fail "裸 DTBO 开头不是 DT table"
        return 1
    }
    total_size="$(avb_read_be32 "$image" 4)" || return 1
    header_size="$(avb_read_be32 "$image" 8)" || return 1
    entry_size="$(avb_read_be32 "$image" 12)" || return 1
    entry_count="$(avb_read_be32 "$image" 16)" || return 1
    entries_offset="$(avb_read_be32 "$image" 20)" || return 1
    page_size="$(avb_read_be32 "$image" 24)" || return 1

    [ "$total_size" -eq "$image_size" ] || {
        avb_fail "裸 DTBO 文件大小($image_size) 与 header total_size($total_size) 不一致"
        return 1
    }
    [ "$header_size" -ge 32 ] && [ "$header_size" -le "$image_size" ] || {
        avb_fail "DT table header_size 无效"
        return 1
    }
    [ "$entry_size" -ge 32 ] && [ "$entry_size" -le 4096 ] || {
        avb_fail "DT table entry_size 无效"
        return 1
    }
    [ "$entry_count" -gt 0 ] && [ "$entry_count" -le 4096 ] || {
        avb_fail "DT table entry_count 无效"
        return 1
    }
    [ "$entries_offset" -ge "$header_size" ] && [ "$entries_offset" -le "$image_size" ] || {
        avb_fail "DT table entries_offset 无效"
        return 1
    }
    [ "$((entry_count * entry_size))" -le "$((image_size - entries_offset))" ] || {
        avb_fail "DT table entries 区域越界"
        return 1
    }
    avb_is_power_of_two "$page_size" || {
        avb_fail "裸 DTBO page_size 无效: $page_size"
        return 1
    }

    entries_end=$((entries_offset + entry_count * entry_size))
    index=0
    while [ "$index" -lt "$entry_count" ]; do
        entry_offset=$((entries_offset + index * entry_size))
        dt_size="$(avb_read_be32 "$image" "$entry_offset")" || {
            avb_fail "无法读取 DT entry[$index] 大小"
            return 1
        }
        dt_offset="$(avb_read_be32 "$image" "$((entry_offset + 4))")" || {
            avb_fail "无法读取 DT entry[$index] 偏移"
            return 1
        }
        [ "$dt_size" -ge 40 ] || {
            avb_fail "DT entry[$index] 大小无效: $dt_size"
            return 1
        }
        [ "$dt_offset" -ge "$entries_end" ] || {
            avb_fail "DT entry[$index] 偏移落在 DT table 头部内: $dt_offset"
            return 1
        }
        avb_range_fits "$dt_offset" "$dt_size" "$image_size" || {
            avb_fail "DT entry[$index] 数据越界"
            return 1
        }
        dt_magic="$(avb_hex_at "$image" "$dt_offset" 4)"
        [ "$dt_magic" = "d00dfeed" ] || {
            avb_fail "DT entry[$index] 不是有效 FDT"
            return 1
        }
        index=$((index + 1))
    done

    AVB_RAW_SIZE="$image_size"
    AVB_RAW_PAGE_SIZE="$page_size"
    AVB_RAW_ENTRY_COUNT="$entry_count"
    return 0
}

avb_write_byte() {
    local value="$1"
    local octal
    avb_is_uint "$value" && [ "$value" -le 255 ] || return 1
    octal="$(printf '%03o' "$value")" || return 1
    printf '%b' "\\$octal"
}

avb_write_be32() {
    local value="$1"
    local divisor=16777216
    local byte
    avb_is_uint "$value" || return 1
    while [ "$divisor" -gt 0 ]; do
        byte=$((value / divisor))
        value=$((value % divisor))
        avb_write_byte "$byte" || return 1
        divisor=$((divisor / 256))
    done
}

avb_write_be64() {
    local value="$1"
    avb_is_uint "$value" || return 1

    # Android's /system/bin/sh can evaluate arithmetic with a 32-bit range.
    # A 2^56 divisor therefore collapses to zero on affected builds and emits
    # no bytes at all. DTBO partition offsets are tiny by comparison, so keep
    # the supported range explicit and encode the high dword as zero.
    [ "$value" -le 2147483647 ] || return 1
    avb_write_be32 0 || return 1
    avb_write_be32 "$value" || return 1
}

avb_write_footer() {
    local footer="$1"
    local version_major="$2"
    local version_minor="$3"
    local original_size="$4"
    local vbmeta_offset="$5"
    local vbmeta_size="$6"

    : > "$footer" || {
        avb_fail "无法创建 footer 临时文件"
        return 1
    }
    printf 'AVBf' >> "$footer" || return 1
    avb_write_be32 "$version_major" >> "$footer" || return 1
    avb_write_be32 "$version_minor" >> "$footer" || return 1
    avb_write_be64 "$original_size" >> "$footer" || return 1
    avb_write_be64 "$vbmeta_offset" >> "$footer" || return 1
    avb_write_be64 "$vbmeta_size" >> "$footer" || return 1
    dd if=/dev/zero bs=28 count=1 status=none >> "$footer" 2>/dev/null || {
        avb_fail "无法写入 footer reserved 字段"
        return 1
    }
    local footer_size
    footer_size="$(avb_file_size "$footer")" || {
        avb_fail "无法读取 footer 临时文件大小"
        return 1
    }
    [ "$footer_size" -eq 64 ] || {
        avb_fail "footer 大小异常: $footer_size"
        return 1
    }
    return 0
}

avb_range_is_zero() {
    local image="$1"
    local offset="$2"
    local length="$3"
    [ "$length" -eq 0 ] && return 0
    cmp -s -n "$length" "$image" /dev/zero "$offset" 0
}

avb_verify_dtbo_image() {
    local source="$1"
    local raw="$2"
    local candidate="$3"
    local source_image_size source_footer_offset source_version_major source_version_minor
    local source_vbmeta_offset source_vbmeta_size source_page_size
    local raw_size raw_page_size expected_vbmeta_offset
    local candidate_image_size candidate_footer_offset candidate_version_major candidate_version_minor
    local candidate_original_size candidate_vbmeta_offset candidate_vbmeta_size candidate_page_size
    local leading_gap trailing_gap

    avb_parse_dtbo_image "$source" || return 1
    source_image_size="$AVB_IMAGE_SIZE"
    source_footer_offset="$AVB_FOOTER_OFFSET"
    source_version_major="$AVB_VERSION_MAJOR"
    source_version_minor="$AVB_VERSION_MINOR"
    source_vbmeta_offset="$AVB_VBMETA_OFFSET"
    source_vbmeta_size="$AVB_VBMETA_SIZE"
    source_page_size="$AVB_DT_PAGE_SIZE"

    avb_validate_raw_dtbo "$raw" || return 1
    raw_size="$AVB_RAW_SIZE"
    raw_page_size="$AVB_RAW_PAGE_SIZE"
    [ "$raw_page_size" -eq "$source_page_size" ] || {
        avb_fail "重打包 page_size($raw_page_size) 与原始值($source_page_size) 不一致"
        return 1
    }
    expected_vbmeta_offset=$(( ((raw_size + source_page_size - 1) / source_page_size) * source_page_size ))

    avb_parse_dtbo_image "$candidate" || return 1
    candidate_image_size="$AVB_IMAGE_SIZE"
    candidate_footer_offset="$AVB_FOOTER_OFFSET"
    candidate_version_major="$AVB_VERSION_MAJOR"
    candidate_version_minor="$AVB_VERSION_MINOR"
    candidate_original_size="$AVB_ORIGINAL_IMAGE_SIZE"
    candidate_vbmeta_offset="$AVB_VBMETA_OFFSET"
    candidate_vbmeta_size="$AVB_VBMETA_SIZE"
    candidate_page_size="$AVB_DT_PAGE_SIZE"

    [ "$candidate_image_size" -eq "$source_image_size" ] || {
        avb_fail "候选镜像不是原分区大小"
        return 1
    }
    [ "$candidate_footer_offset" -eq "$source_footer_offset" ] || return 1
    [ "$candidate_version_major" -eq "$source_version_major" ] && \
        [ "$candidate_version_minor" -eq "$source_version_minor" ] || {
        avb_fail "候选镜像 AVB footer 版本变化"
        return 1
    }
    [ "$candidate_original_size" -eq "$raw_size" ] || {
        avb_fail "候选 footer 没有记录新的 DT table 大小"
        return 1
    }
    [ "$candidate_vbmeta_offset" -eq "$expected_vbmeta_offset" ] || {
        avb_fail "候选 vbmeta_offset 不是新的安全对齐位置"
        return 1
    }
    [ "$candidate_vbmeta_size" -eq "$source_vbmeta_size" ] || {
        avb_fail "候选 vbmeta_size 与原始值不同"
        return 1
    }
    [ "$candidate_page_size" -eq "$source_page_size" ] || return 1
    avb_range_fits "$candidate_vbmeta_offset" "$candidate_vbmeta_size" "$candidate_footer_offset" || {
        avb_fail "候选 vbmeta 与 footer 重叠"
        return 1
    }

    cmp -s -n "$raw_size" "$raw" "$candidate" || {
        avb_fail "候选镜像前缀与裸 DTBO 不一致"
        return 1
    }
    cmp -s -n "$source_vbmeta_size" "$source" "$candidate" \
        "$source_vbmeta_offset" "$candidate_vbmeta_offset" || {
        avb_fail "签名 vbmeta 未被逐字节保留"
        return 1
    }

    leading_gap=$((candidate_vbmeta_offset - raw_size))
    trailing_gap=$((candidate_footer_offset - candidate_vbmeta_offset - candidate_vbmeta_size))
    avb_range_is_zero "$candidate" "$raw_size" "$leading_gap" || {
        avb_fail "DT table 与 vbmeta 之间不是全零填充"
        return 1
    }
    avb_range_is_zero "$candidate" "$((candidate_vbmeta_offset + candidate_vbmeta_size))" "$trailing_gap" || {
        avb_fail "vbmeta 与 footer 之间不是全零填充"
        return 1
    }

    AVB_BUILT_IMAGE_SIZE="$candidate_image_size"
    AVB_BUILT_RAW_SIZE="$raw_size"
    AVB_BUILT_VBMETA_OFFSET="$candidate_vbmeta_offset"
    AVB_BUILT_VBMETA_SIZE="$candidate_vbmeta_size"
    return 0
}

avb_build_dtbo_image() {
    local source="$1"
    local raw="$2"
    local output="$3"
    local source_image_size source_footer_offset source_version_major source_version_minor
    local source_vbmeta_offset source_vbmeta_size source_page_size
    local raw_size raw_page_size new_vbmeta_offset footer

    [ "$source" != "$raw" ] && [ "$source" != "$output" ] && [ "$raw" != "$output" ] || {
        avb_fail "源镜像、裸 DTBO 和输出路径必须互不相同"
        return 1
    }
    [ ! -e "$output" ] || {
        avb_fail "输出文件已存在，拒绝覆盖: $output"
        return 1
    }

    avb_parse_dtbo_image "$source" || return 1
    source_image_size="$AVB_IMAGE_SIZE"
    source_footer_offset="$AVB_FOOTER_OFFSET"
    source_version_major="$AVB_VERSION_MAJOR"
    source_version_minor="$AVB_VERSION_MINOR"
    source_vbmeta_offset="$AVB_VBMETA_OFFSET"
    source_vbmeta_size="$AVB_VBMETA_SIZE"
    source_page_size="$AVB_DT_PAGE_SIZE"

    avb_validate_raw_dtbo "$raw" || return 1
    raw_size="$AVB_RAW_SIZE"
    raw_page_size="$AVB_RAW_PAGE_SIZE"
    [ "$raw_page_size" -eq "$source_page_size" ] || {
        avb_fail "新旧 DT page_size 不一致"
        return 1
    }
    new_vbmeta_offset=$(( ((raw_size + source_page_size - 1) / source_page_size) * source_page_size ))
    avb_range_fits "$new_vbmeta_offset" "$source_vbmeta_size" "$source_footer_offset" || {
        avb_fail "修改后的 DT table 太大，会覆盖 vbmeta/footer"
        return 1
    }

    umask 077
    footer="${output}.footer.$$"
    rm -f "$footer"
    truncate -s "$source_image_size" "$output" || {
        avb_fail "无法创建分区大小的候选镜像"
        rm -f "$output" "$footer"
        return 1
    }
    dd if="$raw" of="$output" bs=1048576 conv=notrunc status=none 2>/dev/null || {
        avb_fail "写入裸 DTBO 失败"
        rm -f "$output" "$footer"
        return 1
    }
    dd if="$source" of="$output" bs=1 skip="$source_vbmeta_offset" \
        count="$source_vbmeta_size" seek="$new_vbmeta_offset" \
        conv=notrunc status=none 2>/dev/null || {
        avb_fail "复制原始签名 vbmeta 失败"
        rm -f "$output" "$footer"
        return 1
    }
    avb_write_footer "$footer" "$source_version_major" "$source_version_minor" \
        "$raw_size" "$new_vbmeta_offset" "$source_vbmeta_size" || {
        [ -n "$AVB_ERROR" ] || avb_fail "生成 AVB footer 失败"
        rm -f "$output" "$footer"
        return 1
    }
    dd if="$footer" of="$output" bs=1 seek="$source_footer_offset" \
        conv=notrunc,fsync status=none 2>/dev/null || {
        avb_fail "写入 AVB footer 失败"
        rm -f "$output" "$footer"
        return 1
    }
    rm -f "$footer"

    avb_verify_dtbo_image "$source" "$raw" "$output" || {
        rm -f "$output"
        return 1
    }
    return 0
}

avb_bootconfig_value() {
    # PJZ110 实机的 magisk 域可由 cat 打开 bootconfig，但 toybox/BusyBox awk
    # 直接 open() 会被拒绝；通过管道传递内容，不回退到可能被伪装的 getprop。
    cat /proc/bootconfig 2>/dev/null \
        | awk -v key="$1" '$1 == key {gsub(/"/, "", $3); print $3; exit}'
}

avb_require_unlocked_bootloader() {
    local verified_state device_state
    verified_state="$(avb_bootconfig_value androidboot.verifiedbootstate)"
    device_state="$(avb_bootconfig_value androidboot.vbmeta.device_state)"
    [ "$verified_state" = "orange" ] && [ "$device_state" = "unlocked" ] || {
        avb_fail "Bootconfig 未明确显示 orange + unlocked（当前: ${verified_state:-unknown}/${device_state:-unknown}）"
        return 1
    }
    return 0
}
