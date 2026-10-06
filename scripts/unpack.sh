#!/bin/bash
set -e
cd work
rm -rf base coloros coloros_raw base_imgs base_dl coloros_zip
mkdir -p base coloros coloros_raw

# ============================================================
# 工具函数
# ============================================================

# Android sparse 魔数: 0x3aff26ed -> 小端字节 ed26ff3a
is_sparse() {
  [ "$(dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "ed26ff3a" ]
}

# sparse -> raw；raw 原样复制
to_raw() {
  local in="$1" out="$2"
  if is_sparse "$in"; then
    simg2img "$in" "$out"
  else
    cp "$in" "$out"
  fi
}

# 文件系统类型: erofs / ext4 / unknown
fs_type() {
  local m1 m2
  m1=$(dd if="$1" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  m2=$(dd if="$1" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$m1" = "e2e1f5e0" ]; then echo erofs
  elif [ "$m2" = "53ef" ]; then echo ext4
  else echo unknown; fi
}

# 解包一个分区镜像到目录（目录名 = 分区名，与后续脚本约定一致）
extract_partition() {
  local img="$1" dest="$2"
  local raw="${img%.img}.raw"
  echo ">>> 解包 $(basename "$img") -> $dest"
  to_raw "$img" "$raw"
  local t; t=$(fs_type "$raw")
  rm -rf "$dest"; mkdir -p "$dest"
  case "$t" in
    erofs)
      fsck.erofs --extract="$(realpath "$dest")" "$raw" > /dev/null 2>&1 || true
      ;;
    ext4)
      debugfs -R "rdump / $(realpath "$dest")" "$raw" > /dev/null 2>&1 || true
      ;;
    *)
      echo "!!! 未知文件系统类型: $img"; return 1 ;;
  esac
  rm -f "$raw"
  if [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "!!! 解包失败: $img (类型 $t)"; return 1
  fi
}

# 归一化槽位后缀: system_a.img -> system.img（保留 _a 内容，删除 _a/_b 冗余）
normalize_slots() {
  local dir="$1" f base
  for f in "$dir"/*_a.img; do
    [ -f "$f" ] || continue
    base="${f%_a.img}"
    [ -f "$base.img" ] || cp "$f" "$base.img"
  done
  rm -f "$dir"/*_a.img "$dir"/*_b.img
}

# 把 super.img 拆成单分区镜像（若存在 lpunpack）
try_unpack_super() {
  local img="$1" out="$2"
  to_raw "$img" "$img.raw"
  if command -v lpunpack > /dev/null 2>&1; then
    lpunpack "$img.raw" "$out" 2>/dev/null || { echo "!!! lpunpack 失败: $img"; return 1; }
    normalize_slots "$out"
  else
    echo "!!! lpunpack 不可用，无法拆解 super.img: $img"; return 1
  fi
}

BASE_PARTS="system vendor"
# 底包只提取 system（build.prop）和 vendor（etc/group|passwd），省磁盘
COLOROS_PARTS="system system_ext vendor product odm my_product my_stock my_heytap my_carrier my_bigball my_region my_manifest my_engineering system_dlkm vendor_dlkm"

# ============================================================
# 底包
# ============================================================
echo ">>> 解包底包"
mkdir -p base_dl
if unzip -o ../download/base.zip -d base_dl > /dev/null 2>&1; then
  echo "    base.zip: zip 格式"
else
  echo "    base.zip: tar.gz 格式"
  tar -xzf ../download/base.zip -C base_dl
fi

if [ -f base_dl/payload.bin ]; then
  payload-dumper-go -o base_imgs base_dl/payload.bin > /dev/null
  rm -f base_dl/payload.bin ../download/base.zip
  # OTA payload 里出现 super.img 的情况（少见）
  if [ -f base_imgs/super.img ]; then
    try_unpack_super base_imgs/super.img base_imgs || true
    rm -f base_imgs/super.img base_imgs/super.img.raw
  fi
elif [ -f base_dl/super.img ]; then
  mkdir -p base_imgs
  cp base_dl/super.img base_imgs/
  try_unpack_super base_imgs/super.img base_imgs || true
elif ls base_dl/*.img > /dev/null 2>&1; then
  mkdir -p base_imgs
  cp base_dl/*.img base_imgs/
else
  echo "!!! 底包中找不到 payload.bin / super.img / *.img"; exit 1
fi

normalize_slots base_imgs
for p in $BASE_PARTS; do
  [ -f "base_imgs/$p.img" ] && extract_partition "base_imgs/$p.img" "base/$p" || true
done
# 保留 boot 相关镜像（analyze-kernel.sh 用 boot.img 提取内核配置）
for f in boot.img vendor_boot.img dtbo.img vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
  [ -f "base_imgs/$f" ] && cp "base_imgs/$f" base/
done
rm -rf base_imgs base_dl
echo ">>> 磁盘占用:"
df -h / | tail -1

# ============================================================
# ColorOS
# ============================================================
echo ">>> 解包 ColorOS"
first_7z=$(ls ../download/*image-logical.7z.001 2>/dev/null | head -1 || true)
if [ -n "$first_7z" ]; then
  # oneplus_archive 多卷 logical.7z：内部为 <分区>.img
  echo "    输入: 多卷 7z ($(basename "$first_7z"))"
  7z x -y -ocoloros_raw "$first_7z" > /dev/null
  rm -f ../download/*image-logical.7z.*
elif [ -f ../download/coloros.zip ]; then
  unzip -o ../download/coloros.zip -d coloros_zip > /dev/null
  if [ -f coloros_zip/payload.bin ]; then
    payload-dumper-go -o coloros_raw coloros_zip/payload.bin > /dev/null
  elif [ -f coloros_zip/super.img ]; then
    try_unpack_super coloros_zip/super.img coloros_raw || true
  else
    cp coloros_zip/*.img coloros_raw/ 2>/dev/null || true
  fi
elif ls ../download/*.7z > /dev/null 2>&1; then
  echo "    输入: 单文件 7z"
  7z x -y -ocoloros_raw ../download/*.7z > /dev/null
else
  echo "!!! 找不到 ColorOS 输入（多卷 7z / coloros.zip / *.7z）"; exit 1
fi

normalize_slots coloros_raw
for p in $COLOROS_PARTS; do
  if [ -f "coloros_raw/$p.img" ]; then
    extract_partition "coloros_raw/$p.img" "coloros/$p"
    rm -f "coloros_raw/$p.img"
  fi
done
rm -rf coloros_raw coloros_zip

echo ">>> base 目录:"
ls base/
echo ">>> coloros 目录:"
ls coloros/