#!/usr/bin/env bash
#
# roles/node-exporter.sh - Prometheus node_exporter 설치 (CPU/RAM/디스크 지표)
#   감시 대상 VM(web/lb/victim)에서 실행한다. :9100/metrics 로 노출.
#   sudo ./setup.sh node-exporter
# root 필요.
set -euo pipefail

# 설치 (멱등) — Ubuntu universe 패키지
if dpkg -s prometheus-node-exporter >/dev/null 2>&1; then
  echo "[=] prometheus-node-exporter 이미 설치됨 - skip"
else
  echo "[*] prometheus-node-exporter 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-node-exporter
fi

systemctl enable prometheus-node-exporter >/dev/null 2>&1 || true
systemctl restart prometheus-node-exporter

# 방화벽: monitor 가 9100 을 긁어야 하므로 개방
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 9100/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 9100/tcp 개방"
fi

echo
echo "----- 자체 검증 (node-exporter) -----"
if curl -s --max-time 5 http://localhost:9100/metrics | grep -q '^node_'; then
  echo "[OK] node_exporter 지표 노출 중 (http://<this-ip>:9100/metrics)"
else
  echo "[FAIL] 9100/metrics 응답 없음" >&2
  exit 1
fi
