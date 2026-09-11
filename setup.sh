#!/usr/bin/env bash
#
# setup.sh - 진입점(dispatcher). 첫 인자로 역할을 받아 roles/<역할>.sh 를 실행한다.
#
# 사용법:
#   sudo ./setup.sh web
#   sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb
#   sudo ./setup.sh victim
#   sudo ./setup.sh attacker
#
# 이 스크립트는 "이미 존재하는 VM 안에서" 도는 것만 담당한다.
# VM/하이퍼바이저 생성 자동화는 범위 밖.
set -euo pipefail

ROLE="${1:-}"
shift || true   # 나머지 인자는 역할 스크립트로 전달(lb 백엔드 IP 등)

# 스크립트가 놓인 실제 위치(심링크/상대경로와 무관하게)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$SCRIPT_DIR"

usage() {
  cat <<USAGE
사용법: sudo ./setup.sh <role>

  web       nginx. 응답 페이지에 hostname/IP/MAC 표시
  lb        HAProxy(L7). web들 roundrobin + 헬스체크 + stats(:8404) + Slowloris timeout
            [선택] VIP 를 주면 keepalived 이중화(lb 2대 active/standby)
  victim    apache2 단독(로드밸런서 없는 대조군). WEAK=1 이면 데모용 취약 모드
  attacker  slowhttptest, apache2-utils(ab) 설치만
  monitor   Prometheus + Grafana (관측 스택). 수집 대상은 HAPROXY_TARGETS/NODE_TARGETS 로
  node-exporter  node_exporter(:9100) 설치. 감시 대상 VM(web/lb/victim)에서 실행

예:
  sudo ./setup.sh web
  sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb
  # lb 이중화(VIP=서비스 대표주소):
  sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" VIP=10.0.0.100 LB_ROLE=master PEER=10.0.0.22 ./setup.sh lb
  sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" VIP=10.0.0.100 LB_ROLE=backup PEER=10.0.0.21 ./setup.sh lb
  sudo ./setup.sh victim            # 정상
  sudo WEAK=1 ./setup.sh victim     # 데모용 취약(Slowloris 로 확실히 다운)
  sudo ./setup.sh attacker
  # 관측: 감시 대상 각 VM에서 node-exporter, monitor VM 에서 스택
  sudo ./setup.sh node-exporter
  sudo HAPROXY_TARGETS="10.0.0.180 10.0.0.181" NODE_TARGETS="10.0.0.180 10.0.0.181 10.0.0.182 10.0.0.183 10.0.0.184 10.0.0.185" PROBE_VIP="http://10.0.0.190/" PROBE_VICTIM="http://10.0.0.185/" ./setup.sh monitor
USAGE
}

case "$ROLE" in
  web|lb|victim|attacker|monitor|node-exporter) ;;
  ""|-h|--help|help)
    usage
    [ -z "$ROLE" ] && exit 1 || exit 0
    ;;
  *)
    echo "[ERROR] 알 수 없는 역할: '$ROLE'" >&2
    usage
    exit 1
    ;;
esac

# root 권한 확인 (네 역할 모두 패키지 설치가 필요하므로 root 요구)
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 이 스크립트는 root 권한이 필요합니다. sudo 로 실행하세요." >&2
  echo "        예: sudo ./setup.sh $ROLE" >&2
  exit 1
fi

echo "=============================================="
echo " RAPA web availability demo :: role = $ROLE"
echo " repo dir = $REPO_DIR"
echo "=============================================="

# apt 인덱스 1회 갱신 (멱등: 재실행해도 문제 없음)
export DEBIAN_FRONTEND=noninteractive
echo "[*] apt-get update ..."
apt-get update -qq

# 해당 역할 스크립트로 위임
ROLE_SCRIPT="$REPO_DIR/roles/${ROLE}.sh"
if [ ! -f "$ROLE_SCRIPT" ]; then
  echo "[ERROR] 역할 스크립트를 찾을 수 없습니다: $ROLE_SCRIPT" >&2
  exit 1
fi

bash "$ROLE_SCRIPT" "$@"

echo
echo "[OK] role '$ROLE' 세팅 완료."
