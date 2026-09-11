#!/usr/bin/env bash
#
# roles/monitor.sh - 관측 스택 (Prometheus + Grafana)
#   HAProxy(:8405/metrics) 와 각 노드 node_exporter(:9100) 를 수집해 대시보드로 보여준다.
#   IP 는 하드코딩하지 않는다. 수집 대상을 환경변수로 받는다:
#     sudo HAPROXY_TARGETS="10.0.0.180 10.0.0.181" \
#          NODE_TARGETS="10.0.0.180 10.0.0.181 10.0.0.182 10.0.0.183 10.0.0.184 10.0.0.185" \
#          ./setup.sh monitor
#   HAPROXY_TARGETS  lb 들 (포트 생략 시 :8405 자동)
#   NODE_TARGETS     node_exporter 대상 (포트 생략 시 :9100 자동)
# 접속: Grafana http://<monitor-ip>:3000  (기본 admin/admin, 최초 로그인 시 변경 요구)
#       Prometheus http://<monitor-ip>:9090
# root 필요.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HAPROXY_TARGETS="${HAPROXY_TARGETS:-}"
NODE_TARGETS="${NODE_TARGETS:-}"
PROBE_VIP="${PROBE_VIP:-}"           # VIP(로드밸런싱) URL   (예: http://10.0.0.190/)
PROBE_VICTIM="${PROBE_VICTIM:-}"     # victim(단일) URL      (예: http://10.0.0.185/)

if [ -z "${HAPROXY_TARGETS// /}" ]; then
  echo "[ERROR] HAPROXY_TARGETS 가 없습니다. IP 를 스크립트에 박지 않습니다." >&2
  echo "        예: sudo HAPROXY_TARGETS=\"10.0.0.180 10.0.0.181\" ./setup.sh monitor" >&2
  exit 1
fi

# 포트 자동 보정 후 'ip:port','ip:port' 문자열 생성
build_targets() {  # $1=목록  $2=기본포트
  local out="" t
  for t in $1; do
    case "$t" in *:*) : ;; *) t="${t}:$2" ;; esac
    out="${out:+$out,}'${t}'"
  done
  printf '%s' "$out"
}
HA_STR="$(build_targets "$HAPROXY_TARGETS" 8405)"
NODE_STR="$(build_targets "${NODE_TARGETS:-}" 9100)"
# 프로브 대상은 URL 이라 포트를 붙이지 않는다 (그대로 따옴표만)
VIP_STR="";    [ -n "${PROBE_VIP:-}" ]    && VIP_STR="'${PROBE_VIP}'"
VICTIM_STR=""; [ -n "${PROBE_VICTIM:-}" ] && VICTIM_STR="'${PROBE_VICTIM}'"
echo "[*] haproxy targets: $HA_STR"
echo "[*] node targets:    ${NODE_STR:-<none>}"
echo "[*] probe vip:       ${VIP_STR:-<none>}   victim: ${VICTIM_STR:-<none>}"

# --- 1) Prometheus 설치 (멱등, Ubuntu universe) ---
if dpkg -s prometheus >/dev/null 2>&1; then
  echo "[=] prometheus 이미 설치됨 - skip"
else
  echo "[*] prometheus 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus
fi

# --- 2) Grafana 설치 (멱등, 공식 apt 저장소) ---
if dpkg -s grafana >/dev/null 2>&1; then
  echo "[=] grafana 이미 설치됨 - skip"
else
  echo "[*] grafana 저장소 추가 + 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apt-transport-https software-properties-common wget gnupg
  install -d -m 0755 /etc/apt/keyrings
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
fi

# --- 2c) 가용성 프로브(blackbox_exporter) 설치 (PROBE_VIP/PROBE_VICTIM 있으면) ---
if [ -n "${PROBE_VIP:-}${PROBE_VICTIM:-}" ]; then
  if dpkg -s prometheus-blackbox-exporter >/dev/null 2>&1; then
    echo "[=] prometheus-blackbox-exporter 이미 설치됨 - skip"
  else
    echo "[*] prometheus-blackbox-exporter 설치 ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-blackbox-exporter
  fi
  systemctl enable prometheus-blackbox-exporter >/dev/null 2>&1 || true
  systemctl restart prometheus-blackbox-exporter
fi

# --- 3) Prometheus 설정 렌더링 ---
TMP="$(mktemp)"
sed -e "s#@@HAPROXY_TARGETS@@#${HA_STR}#g" \
    -e "s#@@NODE_TARGETS@@#${NODE_STR}#g" \
    -e "s#@@PROBE_VIP@@#${VIP_STR}#g" \
    -e "s#@@PROBE_VICTIM@@#${VICTIM_STR}#g" \
    "$REPO_DIR/templates/prometheus.yml.tmpl" > "$TMP"
install -m 0644 "$TMP" /etc/prometheus/prometheus.yml
rm -f "$TMP"
systemctl enable prometheus >/dev/null 2>&1 || true
systemctl restart prometheus

# --- 4) Grafana 프로비저닝 (데이터소스 + 대시보드 자동 등록) ---
install -d -m 0755 /etc/grafana/provisioning/datasources
install -d -m 0755 /etc/grafana/provisioning/dashboards
install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards 2>/dev/null || install -d -m 0755 /var/lib/grafana/dashboards
install -m 0644 "$REPO_DIR/templates/grafana-datasource.yaml"         /etc/grafana/provisioning/datasources/rapa.yaml
install -m 0644 "$REPO_DIR/templates/grafana-dashboard-provider.yaml" /etc/grafana/provisioning/dashboards/rapa.yaml
install -m 0644 "$REPO_DIR/templates/grafana-dashboard.json"          /var/lib/grafana/dashboards/rapa.json
chown -R grafana:grafana /var/lib/grafana/dashboards 2>/dev/null || true
systemctl enable grafana-server >/dev/null 2>&1 || true
systemctl restart grafana-server

# --- 5) 방화벽 ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 3000/tcp >/dev/null 2>&1 || true
  ufw allow 9090/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 3000/tcp(grafana), 9090/tcp(prometheus) 개방"
fi

# --- 6) 자체 검증 ---
echo
echo "----- 자체 검증 (monitor) -----"
sleep 3
P="$(curl -s --max-time 5 http://localhost:9090/-/ready || true)"
echo "Prometheus: ${P:-<no-response>}"
G="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:3000/api/health || true)"
echo "Grafana /api/health HTTP: ${G:-<no-response>}"
echo
echo "[OK] 접속: Grafana http://<monitor-ip>:3000  (기본 admin/admin) > Dashboards > RAPA > 'RAPA 웹 가용성 데모'"
echo "     Prometheus http://<monitor-ip>:9090/targets 에서 대상 UP 확인"
