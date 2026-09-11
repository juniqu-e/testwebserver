#!/usr/bin/env bash
# 공유 라이브러리: nginx 를 web 백엔드와 victim "양쪽에 똑같이" 약화/복구한다.
#   WEAK=1        worker_processes 1 + worker_connections NGINX_MAXCONN(기본 64) → 단일 노드는 공격에 죽음
#   WEAK 미지정   기본값(worker_processes auto, worker_connections 768)으로 복구
# 이 함수를 web.sh 와 victim.sh 가 공유해서, 두 쪽의 서버 조건이 100% 동일해진다.
# (유일한 차이는 "앞에 HAProxy 가 있냐" 뿐 → 공정한 비교)
apply_nginx_weak() {
  local conf="/etc/nginx/nginx.conf"
  local weak="${WEAK:-0}" maxc="${NGINX_MAXCONN:-64}"
  if [ "$weak" = "1" ]; then
    echo "[*] WEAK(동일 약화): worker_processes 1 + worker_connections ${maxc}"
    sed -i -E "s/^[[:space:]]*worker_processes[[:space:]]+.*/worker_processes 1;/" "$conf"
    sed -i -E "s/(worker_connections)[[:space:]]+[0-9]+;/\1 ${maxc};/" "$conf"
  else
    echo "[*] 정상 모드: worker_processes auto + worker_connections 768 (복구)"
    sed -i -E "s/^[[:space:]]*worker_processes[[:space:]]+.*/worker_processes auto;/" "$conf"
    sed -i -E "s/(worker_connections)[[:space:]]+[0-9]+;/\1 768;/" "$conf"
  fi
  nginx -t
}
