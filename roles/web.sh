#!/usr/bin/env bash
#
# roles/web.sh - nginx 웹 노드 (web1/web2/web3 공용)
# 응답 페이지에 그 서버의 hostname / IP / MAC 을 표시한다.
# index.html 은 "부팅 때마다" 현재값으로 재생성된다(systemd oneshot).
# root 필요 (setup.sh 에서 검증됨).
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib-nginx-weak.sh
source "$REPO_DIR/roles/lib-nginx-weak.sh"
TMPL_SRC="$REPO_DIR/templates/index.html.tmpl"
STATE_DIR="/etc/rapa-demo"
TMPL_DST="$STATE_DIR/index.html.tmpl"
DOCROOT="/var/www/html"
GEN_BIN="/usr/local/bin/rapa-gen-index.sh"
UNIT="/etc/systemd/system/rapa-web-index.service"

# --- 1) nginx 설치 (멱등) ---
if dpkg -s nginx >/dev/null 2>&1; then
  echo "[=] nginx 이미 설치됨 - skip"
else
  echo "[*] nginx 설치 ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
fi

# --- 2) 템플릿을 저장소와 무관한 안정 위치로 복사 ---
install -d -m 0755 "$STATE_DIR"
install -m 0644 "$TMPL_SRC" "$TMPL_DST"

# --- 3) index 생성 스크립트 배치 (부팅 시/수동 실행 공용) ---
#     기본 인터페이스는 자동 감지한다. 인터페이스 이름을 하드코딩하지 않는다.
cat > "$GEN_BIN" <<'GEN'
#!/usr/bin/env bash
# 현재 hostname/IP/MAC 을 읽어 index.html 을 재생성한다.
set -euo pipefail
TMPL="/etc/rapa-demo/index.html.tmpl"
OUT="/var/www/html/index.html"

# 기본(디폴트 라우트) 인터페이스 자동 감지 - 하드코딩 금지
IFACE="$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
  # 폴백: lo 가 아닌 첫 UP 인터페이스
  IFACE="$(ip -o link show up | awk -F': ' '$2!="lo"{print $2; exit}')"
fi

HOSTNAME_V="$(hostname)"
IP_V="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
IP_V="${IP_V:-unknown}"
if [ -n "${IFACE:-}" ] && [ -r "/sys/class/net/$IFACE/address" ]; then
  MAC_V="$(cat "/sys/class/net/$IFACE/address")"
else
  MAC_V="unknown"
fi

TMP="$(mktemp)"
sed -e "s/@@HOSTNAME@@/${HOSTNAME_V}/g" \
    -e "s/@@IP@@/${IP_V}/g" \
    -e "s/@@MAC@@/${MAC_V}/g" \
    "$TMPL" > "$TMP"
install -m 0644 "$TMP" "$OUT"
rm -f "$TMP"
echo "[gen] iface=$IFACE host=$HOSTNAME_V ip=$IP_V mac=$MAC_V -> $OUT"
GEN
chmod +x "$GEN_BIN"

# --- 4) 부팅마다 재생성하는 systemd oneshot 유닛 (멱등: 덮어쓰기) ---
cat > "$UNIT" <<UNITEOF
[Unit]
Description=RAPA demo - regenerate web index (hostname/IP/MAC) at boot
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$GEN_BIN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable rapa-web-index.service >/dev/null 2>&1 || true

# --- 5) 지금 즉시 1회 생성 + (동일)약화 적용 + nginx 기동 ---
"$GEN_BIN"
apply_nginx_weak        # WEAK=1 이면 web 백엔드도 victim 과 동일하게 약화
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# --- 6) 방화벽(ufw)이 활성화면 80/tcp 만 개방 ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  echo "[*] ufw: 80/tcp 개방"
fi

# --- 7) 자체 검증 ---
echo
echo "----- 자체 검증 (web) -----"
echo "\$ curl -s localhost | grep MAC"
if curl -s --max-time 5 localhost | grep MAC; then
  echo "[OK] index.html 에 MAC 표기 확인"
else
  echo "[FAIL] MAC 표기를 찾지 못함" >&2
  exit 1
fi
