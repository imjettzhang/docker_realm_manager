#!/bin/bash

DOCKER_IMAGE="custom/realm"
CONFIG_DIR="/etc/realm"
CONTAINER_NAME="realm-manager"
CONFIG_FILE="$CONFIG_DIR/config.json"

# 日志函数
log_success() {
  echo -e "\e[32m$1\e[0m"
}

log_warning() {
  echo -e "\e[33m$1\e[0m"
}

log_error() {
  echo -e "\e[31m$1\e[0m"
}

# 检查端口是否合法
is_valid_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 检查IPv4地址是否合法
is_valid_ipv4() {
  local ip=$1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    local -a ip_parts=($ip)
    [[ ${ip_parts[0]} -le 255 && ${ip_parts[1]} -le 255 && ${ip_parts[2]} -le 255 && ${ip_parts[3]} -le 255 ]]
    return $?
  fi
  return 1
}

# 检查IPv6地址是否合法
is_valid_ipv6() {
  local ip=$1
  # 更精确的IPv6格式检查，支持各种IPv6格式
  # 完整格式: 2404:c140:1f00:1e::10a0
  # 压缩格式: ::1, ::ffff:192.168.1.1
  # 混合格式等
  if [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || \
     [[ $ip =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
     [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,6}:([0-9a-fA-F]{0,4}:){0,5}[0-9a-fA-F]{0,4}$ ]] || \
     [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}:$ ]] || \
     [[ $ip == "::" ]]; then
    return 0
  fi
  return 1
}

# 检查域名是否合法
is_valid_domain() {
  local domain=$1
  [[ $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# 验证目标地址
validate_target_address() {
  local addr=$1
  if is_valid_ipv4 "$addr"; then
    return 0
  elif is_valid_ipv6 "$addr"; then
    return 0
  elif is_valid_domain "$addr"; then
    return 0
  else
    return 1
  fi
}

# 格式化目标地址（IPv6 自动加方括号）
format_target_address() {
  local addr=$1
  local port=$2
  
  if is_valid_ipv6 "$addr"; then
    # IPv6 地址需要用方括号包围
    echo "[$addr]:$port"
  else
    # IPv4 地址或域名直接使用
    echo "$addr:$port"
  fi
}

print_menu() {
  echo "========= Docker Realm 转发管理脚本 ========="
  echo "1. 安装 Docker Realm"
  echo "2. 创建转发规则"
  echo "3. 查看转发规则"
  echo "4. 删除转发规则"
  echo "5. 重启 Realm 容器"
  echo "6. 实时查看日志"
  echo "7. 卸载 Realm"
  echo "8. 退出"
  echo "==========================================="
}

# 添加防火墙规则
add_firewall_rule() {
  local port=$1
  local protocol=$2
  
  # 检查是否安装了 ufw
  if command -v ufw &>/dev/null; then
    # 检查 ufw 是否处于活动状态
    if ufw status | grep -q "Status: active"; then
      if [[ $protocol == "tcp" || $protocol == "both" ]]; then
        if ! ufw status | grep -q "$port/tcp"; then
          ufw allow $port/tcp &>/dev/null
          log_success "UFW 防火墙规则已添加：允许 TCP 端口 $port"
        else
          log_warning "TCP 端口 $port 已在 UFW 中开放，无需重复添加"
        fi
      fi
      if [[ $protocol == "udp" || $protocol == "both" ]]; then
        if ! ufw status | grep -q "$port/udp"; then
          ufw allow $port/udp &>/dev/null
          log_success "UFW 防火墙规则已添加：允许 UDP 端口 $port"
        else
          log_warning "UDP 端口 $port 已在 UFW 中开放，无需重复添加"
        fi
      fi
    else
      log_warning "检测到 UFW 但未启用，跳过防火墙配置"
    fi
  else
    log_warning "未检测到 UFW 防火墙，跳过防火墙配置（假设默认放行）"
  fi
}

# 删除防火墙规则
delete_firewall_rule() {
  local port=$1
  local protocol=$2
  
  # 检查是否安装了 ufw
  if command -v ufw &>/dev/null; then
    # 检查 ufw 是否处于活动状态
    if ufw status | grep -q "Status: active"; then
      if [[ $protocol == "tcp" || $protocol == "both" ]]; then
        if ufw status | grep -q "$port/tcp"; then
          ufw delete allow $port/tcp &>/dev/null
          log_success "UFW 防火墙规则已删除：移除 TCP 端口 $port"
        else
          log_warning "TCP 端口 $port 未在 UFW 中开放，无需删除"
        fi
      fi
      if [[ $protocol == "udp" || $protocol == "both" ]]; then
        if ufw status | grep -q "$port/udp"; then
          ufw delete allow $port/udp &>/dev/null
          log_success "UFW 防火墙规则已删除：移除 UDP 端口 $port"
        else
          log_warning "UDP 端口 $port 未在 UFW 中开放，无需删除"
        fi
      fi
    else
      log_warning "检测到 UFW 但未启用，跳过防火墙配置"
    fi
  else
    log_warning "未检测到 UFW 防火墙，跳过防火墙配置"
  fi
}

# 检查和安装 jq 工具
check_and_install_jq() {
  if ! command -v jq &>/dev/null; then
    log_warning "jq 工具未安装，正在尝试安装..."
    
    # 尝试使用包管理器安装
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y jq
    elif command -v yum &>/dev/null; then
      yum install -y jq
    elif command -v dnf &>/dev/null; then
      dnf install -y jq
    else
      # 手动下载安装
      local jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
      if curl -L "$jq_url" -o /tmp/jq && chmod +x /tmp/jq; then
        mv /tmp/jq /usr/local/bin/jq
        log_success "jq 工具安装成功"
      else
        log_error "jq 工具安装失败，无法继续操作"
        return 1
      fi
    fi
    
    if command -v jq &>/dev/null; then
      log_success "jq 工具安装成功"
    else
      log_error "jq 工具安装失败，无法继续操作"
      return 1
    fi
  fi
  return 0
}

install_docker_and_realm() {
  echo ">>> 安装 Docker..."
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
    systemctl start docker
    systemctl enable docker
  else
    log_success "Docker 已安装"
  fi

  # 检查是否已存在 Realm 容器
  if docker ps -a | grep -q $CONTAINER_NAME; then
    log_warning "检测到已存在的 Realm 容器！"
    
    while true; do
      read -p "是否确认覆盖安装？这将清空所有转发规则 (y/n): " confirm
      case $confirm in
        [Yy]|[Yy][Ee][Ss])
          echo ">>> 正在卸载现有 Realm..."
          docker stop $CONTAINER_NAME 2>/dev/null
          docker rm $CONTAINER_NAME 2>/dev/null
          log_success "现有容器已删除"
          break
          ;;
        [Nn]|[Nn][Oo])
          log_warning "安装已取消"
          return 0
          ;;
        *)
          log_error "请输入 y 或 n"
          ;;
      esac
    done
  fi

  mkdir -p $CONFIG_DIR
  
  # 创建基础 JSON 配置文件
  cat > $CONFIG_FILE << 'EOF'
{
  "network": {
    "use_udp": true,
    "zero_copy": true,
    "tcp_timeout": 300,
    "udp_timeout": 30
  },
  "dns": {
    "mode": "ipv4_and_ipv6",
    "protocol": "tcp_and_udp",
    "nameservers": ["1.1.1.1:53", "8.8.8.8:53"],
    "min_ttl": 600,
    "max_ttl": 3600,
    "cache_size": 64
  },
  "endpoints": []
}
EOF

  # 创建 Dockerfile
  cat > /tmp/realm_dockerfile << 'EOL'
FROM debian:latest

# 安装必要的包
RUN apt-get update && apt-get install -y \
    wget \
    tar \
    && rm -rf /var/lib/apt/lists/*

# 工作目录
WORKDIR /app

# 下载和安装 realm
RUN wget -P /etc/realm https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-gnu.tar.gz \
    && tar -zxf /etc/realm/realm-x86_64-unknown-linux-gnu.tar.gz -C /etc/realm \
    && chmod +x /etc/realm/realm \
    && mv /etc/realm/realm /usr/local/bin/ \
    && rm -f /etc/realm/realm-x86_64-unknown-linux-gnu.tar.gz

# 配置文件目录
VOLUME /etc/realm

# 启动命令
CMD ["realm", "-c", "/etc/realm/config.json"]
EOL

  # 构建并运行 Realm 容器
  echo ">>> 构建 Realm 镜像..."
  docker build -f /tmp/realm_dockerfile -t $DOCKER_IMAGE /tmp/
  rm -f /tmp/realm_dockerfile
  
  echo ">>> 启动 Realm 容器..."
  docker run -d \
    --name $CONTAINER_NAME \
    --restart always \
    --network host \
    -v $CONFIG_FILE:/etc/realm/config.json \
    $DOCKER_IMAGE

  if docker ps | grep -q $CONTAINER_NAME; then
    log_success "Realm 已安装并运行！"
  else
    log_error "Realm 容器启动失败，请检查日志："
    docker logs --tail 10 $CONTAINER_NAME
  fi
}

create_rule() {
  echo ">>> 添加转发规则"
  
  # 检查并安装 jq
  if ! check_and_install_jq; then
    log_error "无法安装 jq 工具，操作中止"
    return 1
  fi
  
  # 验证本地端口
  while true; do
    read -p "输入本地监听端口: " listen_port
    if ! is_valid_port "$listen_port"; then
      log_error "无效的端口号！请输入 1-65535 之间的数字"
    else
      break
    fi
  done
  
  # 验证目标地址
  while true; do
    read -p "输入目标地址 (IPv4, IPv6 或域名): " target_addr
    if validate_target_address "$target_addr"; then
      break
    else
      log_error "无效的目标地址！请输入正确的 IPv4、IPv6 地址或域名"
    fi
  done
  
  # 验证目标端口
  while true; do
    read -p "输入目标端口: " target_port
    if ! is_valid_port "$target_port"; then
      log_error "无效的端口号！请输入 1-65535 之间的数字"
    else
      break
    fi
  done

  # 显示格式化后的目标地址确认
  local formatted_target=$(format_target_address "$target_addr" "$target_port")
  echo ""
  echo ">>> 转发配置确认："
  echo "本地端口: $listen_port"
  echo "目标地址: $formatted_target"
  if is_valid_ipv6 "$target_addr"; then
    log_success "检测到 IPv6 地址，已自动添加方括号格式"
  fi
  echo ""

  echo "请选择协议："
  echo "1: TCP"
  echo "2: UDP"
  echo "3: TCP + UDP"
  read -p "请输入 (1/2/3): " protocol_choice

  # 备份现有配置
  cp $CONFIG_FILE $CONFIG_FILE.bak

  # 添加新规则到 JSON 配置
  add_endpoint_to_json() {
    local protocol=$1
    local listen_addr="[::]:$listen_port"
    
    # 使用 IPv6 双栈监听地址，自动处理 IPv4 和 IPv6 流量
    jq --arg listen "$listen_addr" \
       --arg remote "$formatted_target" \
       --arg protocol "$protocol" \
       '.endpoints += [{
         "listen": $listen,
         "remote": $remote,
         "protocol": $protocol
       }]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  }

  case $protocol_choice in
    1) 
      # TCP 转发配置
      add_endpoint_to_json "tcp"
      add_firewall_rule "$listen_port" "tcp"
      ;;
    2)
      # UDP 转发配置
      add_endpoint_to_json "udp"
      add_firewall_rule "$listen_port" "udp"
      ;;
    3)
      # TCP + UDP 转发配置
      add_endpoint_to_json "tcp"
      add_endpoint_to_json "udp"
      add_firewall_rule "$listen_port" "both"
      ;;
    *)
      log_error "无效的选择！"
      return 1
      ;;
  esac

  docker restart $CONTAINER_NAME
  sleep 2

  local proto=""
  case $protocol_choice in
    1) proto="TCP" ;;
    2) proto="UDP" ;;
    3) proto="TCP + UDP" ;;
  esac
  
  # 重新获取格式化的目标地址用于显示
  local display_target=$(format_target_address "$target_addr" "$target_port")
  
  if netstat -tunlp | grep -q ":$listen_port.*realm"; then
    log_success "转发规则已添加并生效！"
    echo ">>> 转发详情:"
    echo "本地端口: $listen_port (IPv4 + IPv6) -> 目标: $display_target"
    echo "协议: $proto"
    echo "监听地址: 0.0.0.0:$listen_port 和 [::]:$listen_port"
  else
    log_warning "转发规则已添加，但端口未正常监听，请检查日志："
    docker logs --tail 10 $CONTAINER_NAME
  fi
}

view_rules() {
  # 直接使用简洁的列表格式显示规则
  if ! list_rules_for_deletion; then
    return 1
  fi
}

# 列出当前所有转发规则并返回规则数组
list_rules_for_deletion() {
  echo ">>> 当前转发规则列表："
  
  if ! [ -f "$CONFIG_FILE" ]; then
    log_warning "配置文件不存在"
    return 1
  fi
  
  # 使用 jq 精确提取信息，并将端点信息存储到数组中
  local endpoints=$(jq -r '.endpoints[] | "\(.listen) (\(.protocol)) -> \(.remote)"' "$CONFIG_FILE" 2>/dev/null)
  
  if [ -z "$endpoints" ]; then
    log_warning "未找到任何转发规则"
    return 1
  fi
  
  # 清空全局数组
  unset rule_endpoints
  declare -g -a rule_endpoints
  
  local rule_count=0
  while IFS= read -r line; do
    rule_count=$((rule_count + 1))
    echo "$rule_count. $line (IPv4 + IPv6 双栈)"
    
    # 存储完整的端点信息
    rule_endpoints[$rule_count]="$line"
  done <<< "$endpoints"
  
  # 返回规则数量
  echo "$rule_count" > /tmp/rule_count
  return 0
}

delete_rule() {
  echo ">>> 删除转发规则"
  
  # 检查并安装 jq
  if ! check_and_install_jq; then
    log_error "无法安装 jq 工具，操作中止"
    return 1
  fi
  
  # 显示当前规则
  if ! list_rules_for_deletion; then
    return 1
  fi
  
  # 获取规则数量
  local rule_count=$(cat /tmp/rule_count 2>/dev/null || echo "0")
  rm -f /tmp/rule_count
  
  if [ "$rule_count" -eq 0 ]; then
    log_error "没有可删除的规则"
    return 1
  fi
  
  echo ""
  while true; do
    read -p "请输入要删除的规则编号 (1-$rule_count): " rule_number
    
    if [[ "$rule_number" =~ ^[0-9]+$ ]] && [ "$rule_number" -ge 1 ] && [ "$rule_number" -le "$rule_count" ]; then
      break
    else
      log_error "无效的编号！请输入 1 到 $rule_count 之间的数字"
    fi
  done

  # 获取选中的规则信息
  local port="${rule_ports[$rule_number]}"
  local protocol="${rule_protocols[$rule_number]}"
  local remote_addr="${rule_remotes[$rule_number]}"
  
  if [ -z "$port" ] || [ -z "$protocol" ] || [ -z "$remote_addr" ]; then
    log_error "无法获取选中的规则信息"
    return 1
  fi
  
  echo ">>> 准备删除规则: 端口 $port ($protocol) -> $remote_addr (IPv4 + IPv6)"

  # 备份配置文件
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"

  # 使用 jq 精确删除规则 - 同时删除 IPv4 和 IPv6 规则
  log_success "使用 jq 工具删除 IPv4 和 IPv6 规则..."
  
  # 构建 IPv4 和 IPv6 监听地址
  local listen_addr_v4="0.0.0.0:$port"
  local listen_addr_v6="[::]:$port"
  
  # 删除 IPv4 和 IPv6 端点
  jq --arg listen_v4 "$listen_addr_v4" \
     --arg listen_v6 "$listen_addr_v6" \
     --arg protocol "$protocol" \
     --arg remote "$remote_addr" \
     '.endpoints |= map(select(not((.listen == $listen_v4 or .listen == $listen_v6) and .protocol == $protocol and .remote == $remote)))' \
     "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  
  # 检查删除结果
  local remaining_rules=$(jq -e --arg listen_v4 "$listen_addr_v4" --arg listen_v6 "$listen_addr_v6" --arg protocol "$protocol" --arg remote "$remote_addr" \
    '.endpoints[] | select((.listen == $listen_v4 or .listen == $listen_v6) and .protocol == $protocol and .remote == $remote)' \
    "$CONFIG_FILE" 2>/dev/null | wc -l)
  
  if [ "$remaining_rules" -eq 0 ]; then
    log_success "成功删除规则: 端口 $port ($protocol) -> $remote_addr (IPv4 + IPv6)"
    
    # 检查是否还有相同端口的其他协议规则
    if ! jq -e --arg port ":$port" '.endpoints[] | select(.listen | endswith($port))' "$CONFIG_FILE" &>/dev/null; then
      # 如果没有其他规则使用该端口，删除防火墙规则
      delete_firewall_rule "$port" "both"
    else
      # 如果还有其他协议的规则，只删除对应协议的防火墙规则
      delete_firewall_rule "$port" "$protocol"
    fi
  else
    log_error "删除失败，恢复备份文件..."
    # 恢复备份文件
    latest_backup=$(ls -t "$CONFIG_FILE.bak."* | head -1)
    cp "$latest_backup" "$CONFIG_FILE"
    return 1
  fi

  # 重启 Realm 容器以使配置生效
  echo ">>> 重启 Realm 容器..."
  docker restart $CONTAINER_NAME
  sleep 2

  # 验证删除结果
  if docker ps | grep -q $CONTAINER_NAME; then
    log_success "Realm 容器重启成功！"
    if [ "$protocol" = "tcp" ]; then
      if ! netstat -tunlp | grep -q ":$port.*realm.*tcp"; then
        log_success "TCP 端口 $port 已停止监听，删除成功！"
      else
        log_warning "TCP 端口 $port 仍在监听，请检查配置"
      fi
    else
      if ! netstat -tunlp | grep -q ":$port.*realm.*udp"; then
        log_success "UDP 端口 $port 已停止监听，删除成功！"
      else
        log_warning "UDP 端口 $port 仍在监听，请检查配置"
      fi
    fi
  else
    log_error "Realm 容器启动失败，请检查配置："
    docker logs --tail 10 $CONTAINER_NAME
  fi
}

restart_container() {
  docker restart $CONTAINER_NAME
  sleep 2
  if docker ps | grep -q $CONTAINER_NAME; then
    log_success "Realm 容器已重启！"
    echo ">>> 当前端口监听状态："
    netstat -tunlp | grep "realm" || echo "未检测到 Realm 监听的端口"
  else
    log_error "Realm 容器启动失败，请检查配置："
    docker logs --tail 10 $CONTAINER_NAME
  fi
}

view_container_logs() {
  echo ">>> 实时查看 Realm 容器日志 (按 Ctrl+C 退出)"
  
  # 检查容器是否存在
  if ! docker ps -a | grep -q $CONTAINER_NAME; then
    log_error "Realm 容器不存在！请先安装 Realm"
    return 1
  fi
  
  # 直接进入实时日志模式
  docker logs --tail 20 -f $CONTAINER_NAME
}

uninstall_realm() {
  if docker ps -a | grep -q $CONTAINER_NAME; then
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
    rm -rf $CONFIG_DIR
    log_success "Realm 已卸载！"
  else
    log_warning "Realm 未安装！"
  fi
}

# 主循环
while true; do
  print_menu
  read -p "请选择操作: " choice
  case $choice in
    1) install_docker_and_realm ;;
    2) create_rule ;;
    3) view_rules ;;
    4) delete_rule ;;
    5) restart_container ;;
    6) view_container_logs ;;
    7) uninstall_realm ;;
    8)
      echo "退出脚本！"
      exit 0
      ;;
    *)
      log_error "无效的选择！"
      ;;
  esac
done