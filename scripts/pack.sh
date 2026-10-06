#!/bin/bash
set -e
cd work

PACK_MODE="${PACK_MODE:-super}"
SUPER_SIZE="${SUPER_SIZE:-8589934592}"
OUT=output
mkdir -p "$OUT"
KERNEL_HAS_EROFS="${KERNEL_HAS_EROFS:-true}"
KERNEL_HAS_EROFS_LZ4="${KERNEL_HAS_EROFS_LZ4:-true}"

# 命名参数
DEVICE="${CFG_DEVICE_MODEL:-${DEVICE_MODEL:-alioth}}"
SYSTEM_NAME="${CFG_DEVICE_SYSTEM_NAME:-${SYSTEM_NAME:-ColorOS}}"
ANDROID_VER="${ANDROID_VER:-16}"
ANDROID_TAG="A${ANDROID_VER}"
DATE_TAG=$(date +%y%m%d)

# 底包的 vbmeta（刷入时配 --disable-verity --disable-verification 使用）
[ -f base/vbmeta.img ] && cp base/vbmeta.img "$OUT/vbmeta-${DEVICE}.img" || true

pack_partitions() {
  cd coloros
  for dir in */; do
    name="${dir%/}"
    case "$name" in merged_my|output|META-INF) continue ;; esac
    [ -d "$name" ] || continue
    [ -f "$name.img" ] && continue
    echo ">>> 打包 $name"
    if [ "$KERNEL_HAS_EROFS" = "true" ]; then
      EROFS_ARGS=(-b 4096 -T 1230768000 --mount-point="/$name")
      [ "$KERNEL_HAS_EROFS_LZ4" = "true" ] && EROFS_ARGS+=(-zlz4)
      if mkfs.erofs "${EROFS_ARGS[@]}" "$name.img" "$name" 2>/dev/null; then
        continue
      fi
    fi
    # ext4 回退：mke2fs（make_ext4fs 在 Ubuntu 上不可用）
    SIZE_MB=$(($(du -sk "$name" | cut -f1) / 1024 + 128))
    mke2fs -F -q -t ext4 -b 4096 -d "$name" -E lazy_itable_init=0 "${SIZE_MB}M" "$name.img"
  done
  cd ..
}

build_super() {
  # 需要 lpmake（AOSP partition_tools，apt 里没有）
  if ! command -v lpmake > /dev/null 2>&1; then
    echo "!!! lpmake 不可用，跳过 super.img（请用 fastbootd 逐分区刷入 flash-fastbootd.sh）"
    return 0
  fi
  PARTITIONS=()
  for img in coloros/*.img; do
    name=$(basename "$img" .img)
    case "$name" in super|vbmeta|boot|dtbo) continue ;; esac
    PARTITIONS+=("$name")
  done
  LPM_ARGS=(
    --device-size="$SUPER_SIZE"
    --metadata-size=65536
    --metadata-slots=2
    --group=main:"$SUPER_SIZE"
    --output="$OUT/${DEVICE}-${SYSTEM_NAME}-${ANDROID_TAG}-${DATE_TAG}-super.img"
  )
  # VAB 设备需要槽位后缀：每个分区同时定义 _a 和 _b
  for p in "${PARTITIONS[@]}"; do
    LPM_ARGS+=(--partition="${p}_a:readonly:0:main")
    LPM_ARGS+=(--image="${p}_a=coloros/$p.img")
    LPM_ARGS+=(--partition="${p}_b:readonly:0:main")
    LPM_ARGS+=(--image="${p}_b=coloros/$p.img")
  done
  lpmake "${LPM_ARGS[@]}"
  echo ">>> super.img: $OUT/${DEVICE}-${SYSTEM_NAME}-${ANDROID_TAG}-${DATE_TAG}-super.img"
}

write_flash_script() {
  cat > "$OUT/flash-fastbootd.sh" << 'EOFF'
#!/bin/bash
# ColorOS port — fastbootd 逐分区刷入（VAB 设备）
# 用法: 手机进 bootloader 后 ./flash-fastbootd.sh
set -e
fastboot reboot fastboot
sleep 15
for p in system system_ext vendor product odm my_product my_stock my_heytap \
         my_carrier my_bigball my_region my_manifest my_engineering \
         system_dlkm vendor_dlkm; do
  [ -f "$p.img" ] || continue
  # sparse 头部 total_blocks(offset16,u32)*4096 = raw 分区大小
  size=$(python3 -c "import struct,sys;f=open('$p.img','rb');f.seek(16);print(struct.unpack('<I',f.read(4))[0]*4096)")
  echo ">>> $p (size=$size)"
  fastboot delete-logical-partition "${p}_a" 2>/dev/null || true
  fastboot delete-logical-partition "${p}_b" 2>/dev/null || true
  fastboot create-logical-partition "${p}_a" "$size" 2>/dev/null || true
  fastboot create-logical-partition "${p}_b" "$size" 2>/dev/null || true
  fastboot flash "${p}_a" "$p.img"
  fastboot flash "${p}_b" "$p.img"
done
if [ -f "vbmeta-*.img" ] || ls vbmeta-*.img > /dev/null 2>&1; then
  fastboot flash vbmeta vbmeta-*.img --disable-verity --disable-verification
fi
echo ">>> 完成。执行 fastboot reboot"
EOFF
  chmod +x "$OUT/flash-fastbootd.sh"
}

pack_partitions
write_flash_script

# 输出稀疏镜像（raw 太大，无法传 Release；fastbootd 直接吃 sparse）
for img in coloros/*.img; do
  name=$(basename "$img" .img)
  img2simg "$img" "$OUT/$name.img" 2>/dev/null || cp "$img" "$OUT/$name.img"
done

case "$PACK_MODE" in
  zip)   echo "!!! zip(卡刷) 模式对本目标不适用，改用 super/fastbootd 路径" ; build_super ;;
  super) build_super ;;
  both)  build_super ;;
esac

# 打包完成，释放 raw 镜像空间（输出为 sparse）
rm -f coloros/*.img coloros/*.raw 2>/dev/null || true
echo ">>> 磁盘占用:"
df -h / | tail -1

echo ">>> 输出目录:"
ls -lh "$OUT/"