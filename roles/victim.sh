#!/usr/bin/env bash
#
# roles/victim.sh - apache2 단독 웹서버 (로드밸런서 없는 대조군)
#   attacker 의 Slowloris 공격에 "먼저 죽는" 쪽을 보여주기 위한 노드.
#
# 기본은 "정직한" apache 다. Ubuntu apache2 는 mod_reqtimeout(느린 헤더 방어)가
# 기본 활성이라 이 상태로는 Slowloris 로 잘 안 죽는다.
#   sudo WEAK=1 ./setup.sh victim   # 데모용: reqtimeout 끄고 prefork + 워커 축소 -> 확실히 다운
#   sudo ./setup.sh victim          # 원상복구(방어 다시 켜고 event MPM 로 복귀)
# root 필요.
set -euo pipefail

DOCROOT="/var/www/html"
WEAK="${WEAK:-0}"
WEAK_CONF="/etc/apache2/conf-available/rapa-weak.conf"

# --- 1) apache2 설치 (멱등) ---
if dpkg -s apache2 >/dev/null 2>&1; then
  echo "[=] apache2 이미 설치됨 - skip"
else
  echo "[*] apache2 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2
fi

# --- 2) 대조군임을 알리는 정적 페이지 (멱등: 항상 동일 내용으로 덮어씀) ---
cat > "$DOCROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="ko"><head><meta charset="utf-8"><title>victim (no LB)</title>
<style>body{font-family:system-ui,sans-serif;background:#450a0a;color:#fee2e2;
display:flex;min-height:100vh;margin:0;align-items:center;justify-content:center}
.c{background:#7f1d1d;padding:2rem 3rem;border-radius:16px}</style></head>
<body><div class="c"><h1>VICTIM (apache2, no load balancer)</h1>
<p>로드밸런서 없는 대조군. Slowloris 공격에 취약.</p></div></body></html>
HTML

# --- 2b) 방어 모드 전환 (WEAK=1 데모용 취약 / 미지정 정상복구) ---
if [ "$WEAK" = "1" ]; then
  echo "[*] WEAK 모드: reqtimeout 비활성 + prefork + 워커 축소 (데모용 취약)"
  # 느린 헤더 방어(mod_reqtimeout) 끄기 -> Slowloris 에 노출
  a2dismod -q reqtimeout >/dev/null 2>&1 || true
  # event/worker MPM 끄고 prefork 로 (커넥션=프로세스 1:1 이라 슬롯 고갈이 쉬움)
  a2dismod -q mpm_event mpm_worker >/dev/null 2>&1 || true
  a2enmod  -q mpm_prefork >/dev/null 2>&1 || true
  # 워커 풀을 좁혀서 소수의 느린 커넥션만으로 슬롯이 다 차게 함
  cat > "$WEAK_CONF" <<'CONF'
# RAPA 데모용 취약 설정 (WEAK=1). 발표 시연 외에는 쓰지 말 것.
<IfModule mpm_prefork_module>
    StartServers        2
    MinSpareServers     2
    MaxSpareServers     5
    MaxRequestWorkers   25
    MaxConnectionsPerChild 0
</IfModule>
KeepAlive Off
CONF
  a2enconf -q rapa-weak >/dev/null 2>&1 || true
else
  # 정상 복구: 데모 취약 설정 제거, 방어/기본 MPM 되돌림
  a2disconf -q rapa-weak >/dev/null 2>&1 || true
  rm -f "$WEAK_CONF"
  a2enmod  -q reqtimeout >/dev/null 2>&1 || true
  if apache2ctl -M 2>/dev/null | grep -q mpm_prefork; then
    a2dismod -q mpm_prefork >/dev/null 2>&1 || true
    a2enmod  -q mpm_event   >/dev/null 2>&1 || true
  fi
fi

systemctl enable apache2 >/dev/null 2>&1 || true
# MPM 전환은 reload 로 안 되므로 restart
systemctl restart apache2

# --- 3) 방화벽(ufw) 활성 시 80/tcp 개방 ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 80/tcp 개방"
fi

# --- 4) 자체 검증 ---
echo
echo "----- 자체 검증 (victim) -----"
if [ "$WEAK" = "1" ]; then
  echo "모드: WEAK (취약) - MPM=$(apache2ctl -M 2>/dev/null | grep -o 'mpm_[a-z]*' | head -n1), reqtimeout $(apache2ctl -M 2>/dev/null | grep -q reqtimeout && echo ON || echo OFF)"
else
  echo "모드: 정상 - MPM=$(apache2ctl -M 2>/dev/null | grep -o 'mpm_[a-z]*' | head -n1), reqtimeout $(apache2ctl -M 2>/dev/null | grep -q reqtimeout && echo ON || echo OFF)"
fi
echo "\$ curl -sI localhost | head -n1"
if curl -sI --max-time 5 localhost | head -n1 | grep -q "200"; then
  curl -sI --max-time 5 localhost | head -n1
  echo "[OK] apache2 응답 정상 (200)"
else
  echo "[FAIL] apache2 응답 없음" >&2
  exit 1
fi
