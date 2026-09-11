#!/usr/bin/env bash
#
# roles/victim.sh - 로드밸런서 없는 단일 웹서버 (대조군)
#   web 백엔드와 "완전히 동일한 nginx + 동일한 약화(lib 공유)"를 쓴다.
#   유일한 차이는 "앞에 HAProxy 가 없다"는 것 뿐 → 공정한 비교.
#     sudo ./setup.sh victim              # 정상
#     sudo WEAK=1 ./setup.sh victim       # 약화 (web 들도 똑같이 WEAK=1 로 맞춰서 비교)
#     sudo WEAK=1 NGINX_MAXCONN=64 ./setup.sh victim
# root 필요.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib-nginx-weak.sh
source "$REPO_DIR/roles/lib-nginx-weak.sh"
DOCROOT="/var/www/html"

# --- 0) 예전 apache2 가 깔려 있으면 :80 충돌 방지로 정지 ---
if dpkg -s apache2 >/dev/null 2>&1; then
  echo "[*] apache2 감지 → 정지/비활성 (nginx 로 통일)"
  systemctl stop apache2 2>/dev/null || true
  systemctl disable apache2 >/dev/null 2>&1 || true
fi

# --- 1) nginx 설치 (멱등) ---
if dpkg -s nginx >/dev/null 2>&1; then
  echo "[=] nginx 이미 설치됨 - skip"
else
  echo "[*] nginx 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi

# --- 2) 대조군 표시용 정적 페이지 (서버는 web 과 동일, 페이지만 라벨) ---
cat > "$DOCROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="ko"><head><meta charset="utf-8"><title>victim (no LB)</title>
<style>body{font-family:system-ui,sans-serif;background:#450a0a;color:#fee2e2;
display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center}
.c{background:#7f1d1d;padding:2rem 3rem;border-radius:16px;text-align:center}
h1{margin:0 0 .5rem}</style></head>
<body><div class="c"><h1>VICTIM · no load balancer</h1>
<p>web 백엔드와 동일한 nginx. 차이는 "앞에 LB 가 없다"는 것뿐.</p></div></body></html>
HTML

# --- 3) web 과 동일한 약화/복구 적용 (공유 lib) ---
apply_nginx_weak
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# --- 4) 방화벽(ufw) 활성 시 80/tcp 개방 ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 80/tcp 개방"
fi

# --- 5) 자체 검증 ---
echo
echo "----- 자체 검증 (victim) -----"
echo "모드: $([ "${WEAK:-0}" = "1" ] && echo "WEAK(worker_connections ${NGINX_MAXCONN:-64})" || echo 정상) / server=nginx (web 과 동일)"
if curl -sI --max-time 5 localhost | head -n1 | grep -q "200"; then
  curl -sI --max-time 5 localhost | head -n1
  echo "[OK] nginx 응답 정상 (200)"
else
  echo "[FAIL] nginx 응답 없음" >&2
  exit 1
fi
