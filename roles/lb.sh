#!/usr/bin/env bash
#
# roles/lb.sh - HAProxy L7 로드밸런서
#   web 백엔드 roundrobin 분산 + 헬스체크 + stats(:8404)
#   Slowloris 방어용 timeout http-request 포함
#
# 백엔드 IP 는 스크립트에 박지 않는다. 환경변수 또는 인자로 받는다:
#   sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb
#   sudo ./setup.sh lb 10.0.0.11 10.0.0.12 10.0.0.13
# timeout 값(데모용)도 조정 가능:
#   sudo TIMEOUT_HTTPREQUEST=5s WEB_BACKENDS="..." ./setup.sh lb   # 방어 ON(기본)
#   sudo TIMEOUT_HTTPREQUEST=1h WEB_BACKENDS="..." ./setup.sh lb   # 방어 사실상 OFF(취약 시연)
#
# [선택] lb 이중화(keepalived VIP) - VIP 를 주면 활성화된다. IP 는 하드코딩하지 않는다.
#   lb1: sudo WEB_BACKENDS="..." VIP=10.0.0.100 LB_ROLE=master PEER=10.0.0.22 ./setup.sh lb
#   lb2: sudo WEB_BACKENDS="..." VIP=10.0.0.100 LB_ROLE=backup PEER=10.0.0.21 ./setup.sh lb
#   VIP        가상 IP(서비스 대표주소). 클라이언트/attacker 는 이 IP 를 친다.
#   LB_ROLE    master|backup (기본 master). master 가 평상시 VIP 보유.
#   PEER       상대 lb 의 실제 IP(권장) -> unicast VRRP + ufw 통과에 사용.
#   VRID       virtual_router_id (기본 51, 두 lb 동일해야 함).
#   VRRP_PASS  VRRP 인증 암호(선택). 공개 저장소이므로 값은 파일에 넣지 말고 실행 시 환경변수로만.
# root 필요.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TMPL="$REPO_DIR/templates/haproxy.cfg.tmpl"
CFG="/etc/haproxy/haproxy.cfg"
TIMEOUT_HTTPREQUEST="${TIMEOUT_HTTPREQUEST:-5s}"

# HA(keepalived) 파라미터 - VIP 가 있으면 이중화 모드
VIP="${VIP:-}"
LB_ROLE="${LB_ROLE:-master}"
PEER="${PEER:-}"
VRID="${VRID:-51}"
VRRP_PASS="${VRRP_PASS:-}"

# 백엔드 목록: 환경변수 WEB_BACKENDS 우선, 없으면 위치 인자
BACKENDS="${WEB_BACKENDS:-$*}"
if [ -z "${BACKENDS// /}" ]; then
  echo "[ERROR] 백엔드 web IP 가 없습니다. IP 를 스크립트에 박지 않습니다." >&2
  echo "        예: sudo WEB_BACKENDS=\"10.0.0.11 10.0.0.12\" ./setup.sh lb" >&2
  exit 1
fi

# --- 1) HAProxy 설치 (멱등) ---
if dpkg -s haproxy >/dev/null 2>&1; then
  echo "[=] haproxy 이미 설치됨 - skip"
else
  echo "[*] haproxy 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq haproxy
fi

# --- 2) 백엔드 server 라인 생성 ---
SERVER_LINES=""
i=0
for ip in $BACKENDS; do
  i=$((i+1))
  SERVER_LINES+="    server web${i} ${ip}:80 check inter 2s fall 3 rise 2"$'\n'
done
echo "[*] 백엔드 ${i} 대:"
printf '%s' "$SERVER_LINES" | sed 's/^/      /'

# --- 3) 템플릿 -> 설정 렌더링 (자리표시자 치환) ---
TMP_CFG="$(mktemp)"
# timeout 치환
sed "s#@@TIMEOUT_HTTPREQUEST@@#${TIMEOUT_HTTPREQUEST}#g" "$TMPL" > "$TMP_CFG"
# 마커 줄(# @@WEB_BACKENDS@@)을 생성한 server 라인들로 교체
awk -v repl="$SERVER_LINES" '
  /# @@WEB_BACKENDS@@/ { printf "%s", repl; next }
  { print }
' "$TMP_CFG" > "${TMP_CFG}.2"
mv "${TMP_CFG}.2" "$TMP_CFG"

# --- 4) 문법 검증 후에만 반영 ---
echo "[*] haproxy -c 로 설정 검증 ..."
if ! haproxy -c -f "$TMP_CFG"; then
  echo "[ERROR] HAProxy 설정 검증 실패. 반영하지 않음." >&2
  rm -f "$TMP_CFG"
  exit 1
fi
install -m 0644 "$TMP_CFG" "$CFG"
rm -f "$TMP_CFG"

systemctl enable haproxy >/dev/null 2>&1 || true
systemctl reload haproxy 2>/dev/null || systemctl restart haproxy
echo "[*] haproxy 반영됨 (timeout http-request = ${TIMEOUT_HTTPREQUEST})"

# --- 5) 방화벽(ufw) 활성 시 80, 8404 개방 ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp   >/dev/null 2>&1 || true
  ufw allow 8404/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 80/tcp, 8404/tcp 개방"
fi

# --- 6) [선택] lb 이중화: keepalived VIP failover ---
if [ -n "$VIP" ]; then
  echo
  echo "[*] HA 모드: keepalived VIP=$VIP role=$LB_ROLE"

  # 역할 -> 상태/우선순위
  case "$LB_ROLE" in
    master|MASTER) STATE="MASTER"; PRIORITY=150 ;;
    backup|BACKUP) STATE="BACKUP"; PRIORITY=100 ;;
    *) echo "[ERROR] LB_ROLE 는 master|backup 이어야 합니다 (받은 값: $LB_ROLE)" >&2; exit 1 ;;
  esac

  # keepalived 설치 (멱등)
  if dpkg -s keepalived >/dev/null 2>&1; then
    echo "[=] keepalived 이미 설치됨 - skip"
  else
    echo "[*] keepalived 설치 ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq keepalived
  fi

  # 기본 인터페이스/자기 IP 자동 감지 (인터페이스명 하드코딩 금지)
  IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -z "${IFACE:-}" ] && IFACE="$(ip -o link show up | awk -F': ' '$2!="lo"{print $2; exit}')"
  MY_IP="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
  echo "[*] iface=$IFACE self=$MY_IP"

  # 인증 블록(선택) — 값은 실행 시 환경변수로만. 저장소에 남기지 않는다.
  if [ -n "$VRRP_PASS" ]; then
    AUTH_BLOCK=$'    authentication {\n        auth_type PASS\n        auth_pass '"$VRRP_PASS"$'\n    }'
  else
    AUTH_BLOCK=""
    echo "[!] VRRP_PASS 미지정 - 인증 없이 진행(격리된 랩망 전제)."
  fi

  # unicast 블록(권장) — PEER 를 주면 멀티캐스트 대신 유니캐스트로. 방화벽 통과에 유리.
  if [ -n "$PEER" ] && [ -n "${MY_IP:-}" ]; then
    UNICAST_BLOCK=$'    unicast_src_ip '"$MY_IP"$'\n    unicast_peer {\n        '"$PEER"$'\n    }'
  else
    UNICAST_BLOCK=""
    [ -z "$PEER" ] && echo "[!] PEER 미지정 - 멀티캐스트 VRRP 사용(ufw 가 막을 수 있음)."
  fi

  # 템플릿 렌더링: 단일값은 sed, 여러 줄 블록은 awk 로 마커 줄 치환
  TMP_KA="$(mktemp)"
  sed -e "s#@@STATE@@#${STATE}#g" \
      -e "s#@@INTERFACE@@#${IFACE}#g" \
      -e "s#@@VRID@@#${VRID}#g" \
      -e "s#@@PRIORITY@@#${PRIORITY}#g" \
      -e "s#@@VIP@@#${VIP}#g" \
      "$REPO_DIR/templates/keepalived.conf.tmpl" > "$TMP_KA"
  awk -v auth="$AUTH_BLOCK" -v uni="$UNICAST_BLOCK" '
    /# @@AUTH_BLOCK@@/    { if (auth != "") print auth; next }
    /# @@UNICAST_BLOCK@@/ { if (uni  != "") print uni;  next }
    { print }
  ' "$TMP_KA" > "${TMP_KA}.2"
  mv "${TMP_KA}.2" "$TMP_KA"

  install -d -m 0755 /etc/keepalived
  install -m 0640 "$TMP_KA" /etc/keepalived/keepalived.conf
  rm -f "$TMP_KA"

  systemctl enable keepalived >/dev/null 2>&1 || true
  systemctl restart keepalived

  # 방화벽: unicast 면 상대 lb 를 통째로 허용(VRRP=프로토콜 112 포함)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ -n "$PEER" ]; then
      ufw allow from "$PEER" >/dev/null 2>&1 || true
      echo "[*] ufw: peer $PEER 허용(VRRP)"
    else
      echo "[!] ufw 활성 + PEER 없음 -> VRRP 멀티캐스트가 막힐 수 있음. PEER 지정 권장."
    fi
  fi
  echo "[*] keepalived 반영됨. MASTER 가 VIP($VIP)를 보유하게 됩니다."
fi

# --- 7) 자체 검증: curl 반복으로 순환(roundrobin) 확인 ---
echo
echo "----- 자체 검증 (lb) -----"
echo "\$ curl 를 6회 반복 -> 응답 hostname 이 순환하는지 확인"
for n in $(seq 1 6); do
  line="$(curl -s --max-time 5 localhost | grep HOSTNAME || true)"
  host="$(printf '%s' "$line" | sed -n 's/.*class=\"v\">\([^<]*\)<.*/\1/p')"
  echo "  [$n] hostname=${host:-<no-response>}"
done
echo "stats 페이지: http://<lb-ip>:8404/stats"
echo "[OK] 위 목록에서 hostname 이 번갈아 나오면 roundrobin 정상"

if [ -n "$VIP" ]; then
  echo
  echo "----- 자체 검증 (HA / keepalived) -----"
  echo "\$ systemctl is-active keepalived -> $(systemctl is-active keepalived 2>/dev/null || echo inactive)"
  if ip -4 addr show | grep -qw "$VIP"; then
    echo "[OK] 이 노드가 현재 VIP($VIP)를 보유 중 (MASTER 로 동작)"
  else
    echo "[i] 이 노드는 지금 VIP 미보유 (BACKUP 대기 중이거나 MASTER 가 다른 노드)"
  fi
  echo "확인: 클라이언트/attacker 는 서비스 대표주소 VIP($VIP)로 접속. MASTER lb 정지 시 BACKUP 이 VIP 승계."
fi
