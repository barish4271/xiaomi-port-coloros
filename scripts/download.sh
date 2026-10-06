#!/bin/bash
set -e
BASE_URL=$1
COLOROS_URL=$2
mkdir -p work/download
cd work/download

dl() {
  aria2c -x16 -s16 --file-allocation=none --console-log-level=warn --summary-interval=30 "$1" -o "$2"
}

echo ">>> 下载底包"
dl "$BASE_URL" base.zip

echo ">>> 下载 ColorOS 包"
# 支持三种输入：
#  A) GitHub release 多卷 7z（如 oneplus_archive 的 *-image-logical.7z.001）——自动枚举并下载全部卷
#  B) 单文件 .7z
#  C) 普通 zip（官方 OTA，含 payload.bin）
download_release_parts() {
  local url="$1"
  # https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
  if [[ ! "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?]+) ]]; then
    return 1
  fi
  local owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" tag="${BASH_REMATCH[3]}" file="${BASH_REMATCH[4]}"
  local prefix="${file%.7z.001}"          # 去掉卷号
  echo "    release: owner=$owner repo=$repo tag=$tag"
  echo "    asset 前缀: $prefix"

  local names
  names=$(curl -s "https://api.github.com/repos/$owner/$repo/releases/tags/$tag" \
          | jq -r --arg p "$prefix" '.assets[].name | select(startswith($p))' | sort -V)
  if [ -z "$names" ]; then
    echo "!!! GitHub API 没有匹配到资产，回退为直接下载"
    return 1
  fi
  echo "    卷列表:"; echo "$names" | sed 's/^/      /'
  local n
  for n in $names; do
    dl "https://github.com/$owner/$repo/releases/download/$tag/$n" "$n"
  done
  return 0
}

if [[ "$COLOROS_URL" == *.7z.001* ]]; then
  download_release_parts "$COLOROS_URL" || {
    echo "!!! 枚举卷失败，只下载传入的单链接"
    dl "$COLOROS_URL" "$(basename "${COLOROS_URL%%\?*}")"
  }
elif [[ "$COLOROS_URL" == *.7z* ]]; then
  dl "$COLOROS_URL" "$(basename "${COLOROS_URL%%\?*}")"
else
  dl "$COLOROS_URL" coloros.zip
fi

ls -lh