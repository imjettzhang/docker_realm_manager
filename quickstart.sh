#!/bin/bash
set -e

# 你所有脚本的文件名
files=(
    realm_docker_manager.sh
)

# 创建目标目录
mkdir -p docker_realm_manager/sh

# 下载所有脚本
for file in "${files[@]}"; do
    # echo "正在下载 $file ..."
    curl -fsSL -o "docker_realm_manager/sh/$file" "https://raw.githubusercontent.com/imjettzhang/docker_realm_manager/main/$file"
done

# 给所有脚本加执行权限
chmod +x docker_realm_manager/sh/*.sh

# 运行主程序
./docker_realm_manager/sh/realm_docker_manager.sh
