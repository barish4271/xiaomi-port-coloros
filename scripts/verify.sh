#!/bin/bash
set -e
cd work
VERIFY_DIR="verify"
mkdir -p "$VERIFY_DIR"

# 文件系统魔数检查（不挂载：CI 无 loop 设备权限，且 sparse 不能直接挂载）
check_img() {
  local img="$1"
  local name; name=$(basename "$img")
  local m1 m2 sparse
  sparse=$(dd if="$img" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$sparse" = "ed26ff3a" ]; then
    echo "  ✓ $name (android sparse)"
    return 0
  fi
  m1=$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  m2=$(dd if="$img" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$m1" = "e2e1f5e0" ]; then
    echo "  ✓ $name (erofs raw)"
  elif [ "$m2" = "53ef" ]; then
    echo "  ✓ $name (ext4 raw)"
  else
    echo "  ✗ $name 格式异常" | tee -a "$VERIFY_DIR/errors.log"
  fi
}

for img in output/*.img; do
  [ -f "$img" ] || continue
  case "$(basename "$img")" in vbmeta-*) continue ;; esac
  check_img "$img"
done

if command -v lpdump > /dev/null 2>&1; then
  sup=$(ls output/*super.img 2>/dev/null | head -1 || true)
  if [ -n "$sup" ]; then
    simg2img "$sup" "$VERIFY_DIR/super.raw.img" && lpdump "$VERIFY_DIR/super.raw.img" > "$VERIFY_DIR/super_table.txt" 2>&1 || true
  fi
fi

# 解包出的目录不应为空
for d in coloros/*/; do
  name=$(basename "$d")
  case "$name" in merged_my|output|META-INF) continue ;; esac
  if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
    echo "  ✗ coloros/$name 为空" | tee -a "$VERIFY_DIR/errors.log"
  fi
done

echo ">>> 验证完成"