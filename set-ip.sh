#!/bin/bash

set -e

INTERFACE="ens34"
GATEWAY="192.168.0.1"
PREFIX="24"

case "$1" in
  lb1)
    IP="192.168.0.180"
    ;;
  lb2)
    IP="192.168.0.181"
    ;;
  web1)
    IP="192.168.0.182"
    ;;
  web2)
    IP="192.168.0.183"
    ;;
  web3)
    IP="192.168.0.184"
    ;;
  victim)
    IP="192.168.0.185"
    ;;
  attacker)
    IP="192.168.0.186"
    ;;
  *)
    echo "사용법: sudo $0 {lb1|lb2|web1|web2|web3|victim|attacker}"
    exit 1
    ;;
esac

echo "=============================="
echo " Server    : $1"
echo " Interface : $INTERFACE"
echo " IP        : $IP/$PREFIX"
echo " Gateway   : $GATEWAY"
echo "=============================="

# 인터페이스 존재 확인
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "ERROR: $INTERFACE 인터페이스가 없습니다."
    echo
    ip -br link
    exit 1
fi

# 기존 설정 백업
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    cp /etc/netplan/50-cloud-init.yaml \
       /etc/netplan/50-cloud-init.yaml.bak
fi

cat > /etc/netplan/50-cloud-init.yaml <<EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $IP/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
EOF

chmod 600 /etc/netplan/50-cloud-init.yaml

echo
echo "[1/3] Netplan 문법 검사"
netplan generate

echo "[2/3] 네트워크 설정 적용"
netplan apply

echo "[3/3] 현재 네트워크"
ip -br addr show "$INTERFACE"

echo
echo "Routing Table"
ip route
