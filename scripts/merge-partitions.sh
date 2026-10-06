#!/bin/bash
set -e
cd work

mkdir -p coloros/merged_my
for p in my_product my_stock my_heytap my_carrier my_company my_preload; do
  [ -d "coloros/$p" ] && cp -a "coloros/$p/." coloros/merged_my/ 2>/dev/null || true
done

[ -d "base/system_ext" ] && [ ! -d "coloros/system_ext" ] && cp -a base/system_ext coloros/system_ext
# 注意：不把底包(A13)的 apex 拷进 ColorOS 16 —— 版本不匹配会导致 apexd 拒载/无法开机，
# ColorOS 自带 apex 打包在 system/system_ext 内部。

for f in group passwd; do
  [ -f "base/vendor/etc/$f" ] && cp -f "base/vendor/etc/$f" "coloros/vendor/etc/$f"
done