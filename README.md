# testwebserver — 웹 서비스 가용성 데모 (IaC / RAPA 2차)

vSphere / VMware Workstation 위에 **손으로 클론해 둔 리눅스 VM** 안에서,
저장소를 clone 하고 **역할 인자와 함께 스크립트 하나**를 실행하면 그 역할로 세팅된다.

> "환경을 코드로 재현한다(IaC)" 를 보여주는 발표용 데모.
> **VM 생성 자동화는 범위 밖** — 이 스크립트는 *이미 존재하는 VM 안에서* 도는 것만 담당한다.
> Docker/컨테이너, Terraform/govc/pyvmomi, 무거운 앱(Flask/Django)은 **의도적으로 쓰지 않는다.**

---

## 이 데모가 증명하는 가용성 2축

| | 대조군 (victim) | 이중화 서비스 (web×3 + lb×2) |
|---|---|---|
| 구조 | apache 1대, LB 없음 | HAProxy(이중화) 뒤에 web 3대 |
| **공격받으면** | 그대로 죽음 → 서비스 다운 | lb 의 `timeout http-request` 가 막음 → 유지 |
| **한 대가 죽으면** | 서비스 전체 다운 | 나머지가 계속 서비스 → **무중단(HA)** |

### 장애 단위별 대처 (현업 매핑)
가용성은 "무엇이 죽었나"에 따라 대처 계층이 다르다. 이 데모는 세 계층을 모두 보여준다.

| 장애 단위 | 감지 | 복구 | 이 데모에서 |
|---|---|---|---|
| 프로세스만 죽음(호스트 생존) | 로컬 감독자 | 그 자리 재시작 | systemd `Restart=`(nginx/haproxy) |
| 백엔드가 트래픽 못 받음 | LB 헬스체크 | 트래픽에서 제외(failover) | HAProxy `check` → DOWN → 나머지로 |
| 호스트(VM)째 죽음 | 외부(피어/오케스트레이터) | 다른 노드로 승계/재배치 | keepalived VIP 가 lb2 로 이동 |

> K8s 로 치면 liveness(재시작) / readiness(트래픽 제외) / node NotReady(재배치) 에 각각 대응.
> 현업: 프로세스=systemd·kubelet·docker restart / 트래픽제외=LB·readiness / 호스트=vSphere HA·ASG·K8s 재스케줄.

---

## 5~7대 구성도

```
                              VIP 10.0.0.100  (서비스 대표주소, 클라이언트/attacker 는 여기로)
                                    │
                 keepalived (active/standby)
              ┌───────────────┴───────────────┐
     ┌──────────────────┐            ┌──────────────────┐
     │ lb1 (HAProxy)     │            │ lb2 (HAProxy)     │
     │ MASTER 10.0.0.21  │            │ BACKUP 10.0.0.22  │
     └───────┬──────────┘            └────────┬─────────┘
             └──────────────┬──────────────────┘
                            │ roundrobin + 헬스체크
          ┌─────────────────┼─────────────────┐
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ web1 (nginx) │  │ web2 (nginx) │  │ web3 (nginx) │
   │  10.0.0.11   │  │  10.0.0.12   │  │  10.0.0.13   │   각 페이지: hostname/IP/MAC + 서버색
   └──────────────┘  └──────────────┘  └──────────────┘

   ┌──────────────┐            ┌────────────────────────┐
   │ victim       │◄──(공격)── │ attacker 10.0.0.41      │
   │ apache2 단독 │            │ slowhttptest / ab(설치만)│
   │  10.0.0.31   │            └────────────────────────┘
   └──────────────┘   ← 로드밸런서 없는 대조군
```

| 역할       | 패키지                        | 설명                                                             |
|-----------|-------------------------------|-----------------------------------------------------------------|
| `web`     | nginx                         | 응답 페이지에 hostname/IP/MAC + hostname 해시색 표시. 부팅마다 갱신 |
| `lb`      | haproxy (+keepalived 선택)     | L7 roundrobin + 헬스체크 + stats(:8404) + Slowloris timeout, VIP 이중화 |
| `victim`  | apache2                       | 로드밸런서 없는 대조군. `WEAK=1` 로 데모용 취약 모드              |
| `attacker`| slowhttptest, apache2-utils   | 공격/부하 도구 **설치만** (공격 실행은 수동)                     |

> 예시 IP 는 전부 **더미**다. 실제 IP·VIP·암호는 파일에 넣지 않고 **실행 인자/환경변수로만** 준다.
> lb 이중화까지 하면 VM 은 web3 + lb2 + victim + attacker = **7대**. 이중화가 필요 없으면 lb 1대로 축소 가능.

---

## 실행 방식

각 VM 은 공개 저장소를 clone 해서 자기 역할 스크립트를 실행한다. (공개 저장소라 토큰 없이 clone 된다.)

```bash
git clone https://github.com/juniqu-e/testwebserver.git
cd testwebserver

# web VM (web1 / web2 / web3 — 동일 스크립트 공용)
sudo ./setup.sh web

# lb VM (단일)
sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb

# lb VM (이중화: VIP 를 서비스 대표주소로, keepalived active/standby)
#   lb1(MASTER):
sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" VIP=10.0.0.100 LB_ROLE=master PEER=10.0.0.22 ./setup.sh lb
#   lb2(BACKUP):
sudo WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" VIP=10.0.0.100 LB_ROLE=backup PEER=10.0.0.21 ./setup.sh lb

# victim VM
sudo ./setup.sh victim            # 정상(방어 살아있음)
sudo WEAK=1 ./setup.sh victim     # 데모용 취약(reqtimeout off + prefork + 워커 25) → Slowloris 로 확실히 다운

# attacker VM
sudo ./setup.sh attacker
```

lb 이중화 옵션(환경변수): `VIP`(필수, 서비스 대표주소) · `LB_ROLE`(master|backup) · `PEER`(상대 lb IP, 권장) ·
`VRID`(기본 51, 두 lb 동일) · `VRRP_PASS`(선택, 값은 파일에 넣지 말고 실행 시에만).

- 모든 스크립트는 `set -euo pipefail`, **root 필요**(패키지 설치).
- **멱등성**: 두 번 실행해도 깨지지 않는다. 이미 설치돼 있으면 건너뛴다. victim 은 `WEAK` 유무로 취약↔정상 왕복 가능.
- 방화벽(ufw)이 켜져 있으면 필요한 포트만 자동 개방(web/victim 80, lb 80·8404, HA 는 PEER 를 통째 허용해 VRRP 통과).

---

## 검증 명령

각 스크립트는 설치 후 **자체 검증**을 출력한다. 수동 확인은 아래처럼:

```bash
# web: hostname/IP/MAC 이 페이지에 찍혔는지
curl -s localhost | grep MAC
systemctl status rapa-web-index.service     # 부팅 재생성 서비스

# lb: roundrobin 순환 (hostname 이 번갈아 나오면 정상)
for i in $(seq 1 6); do curl -s http://10.0.0.100/ | grep HOSTNAME; done
#   stats 페이지:  http://<lb-ip>:8404/stats
haproxy -c -f /etc/haproxy/haproxy.cfg       # 설정 문법 검증

# HA: 지금 이 lb 가 VIP 를 들고 있나
ip -4 addr show | grep 10.0.0.100
systemctl status keepalived

# victim
curl -sI http://10.0.0.31/ | head -n1
```

---

## 발표 데모 순서

각 화면은 **?refresh=1** 을 붙여 열면 1초마다 자동 새로고침돼(서버색이 바뀌는 걸 자동으로 보여줌):
`http://10.0.0.100/?refresh=1`

1. **정상 순환(로드밸런싱)**
   `for i in $(seq 1 6); do curl -s http://10.0.0.100/ | grep HOSTNAME; done`
   → web1/web2/web3 이 roundrobin. 브라우저로 `?refresh=1` 열면 **화면색(보라/주황/초록)** 이 번갈아 → 뒷자리에서도 서버 교체가 보임. `:8404/stats` 3대 모두 **UP**.

2. **attacker → victim 공격 → 죽음 (대조군)**
   ```bash
   # victim 을 데모용 취약으로 세팅해 두면 확실히 다운됨
   #   (victim VM 에서)  sudo WEAK=1 ./setup.sh victim
   slowhttptest -c 500 -H -i 10 -r 200 -t GET -u http://10.0.0.31/ -x 24 -p 3
   ```
   다른 창 `curl http://10.0.0.31/` → 타임아웃. 단일 apache2 는 워커 고갈로 **응답 불능(다운)**.

3. **같은 공격을 서비스 VIP 로 → 버팀**
   ```bash
   slowhttptest -c 500 -H -i 10 -r 200 -t GET -u http://10.0.0.100/ -x 24 -p 3
   ```
   `curl http://10.0.0.100/` 는 계속 응답. HAProxy `timeout http-request` 가 느린 헤더 커넥션을 끊어 백엔드를 보호.

4. **lb timeout 적용 전/후 비교**
   ```bash
   # (취약) 방어 사실상 OFF
   sudo TIMEOUT_HTTPREQUEST=1h WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb   # → 3번 공격 재현 시 흔들림
   # (방어) 기본값 복구
   sudo TIMEOUT_HTTPREQUEST=5s WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb   # → 다시 버팀
   ```
   > `timeout http-request` 한 줄이 방어의 핵심임을 같은 공격으로 대비.

5. **백엔드 1대 장애 → failover (웹 티어 이중화)**
   ```bash
   # (a) 깔끔한 시연: web1 정지
   #     (web1 VM 에서)  sudo systemctl stop nginx
   # (b) 공격으로: attacker 가 web1 을 직접 (nginx 는 slowloris 저항이 있어 (a) 가 더 확실)
   ```
   `:8404/stats` 에서 web1 **DOWN**(빨강), `curl http://10.0.0.100/` 반복 시 web2/web3 로만 → 서비스 무중단. web1 복구(`start nginx`) 시 헬스체크 통과해 자동 복귀.

6. **lb 호스트째 장애 → VIP failover (로드밸런서 이중화)**
   ```bash
   # 현재 VIP 를 든 MASTER(lb1) 를 정지 (호스트 다운 모사)
   #   (lb1 VM 에서)  sudo systemctl stop keepalived    # 또는 VM 전원 off
   ```
   `ip addr | grep 10.0.0.100` 로 확인 → VIP 가 **lb2 로 이동**. 그동안 `curl http://10.0.0.100/` 는 계속 응답(서비스 대표주소 무중단). lb1 복구 시 우선순위대로 VIP 회수.

7. **(옵션) HTTP Flood → 사양 낮춘 victim OOM**
   victim VM 을 RAM 512MB~1GB / 1 vCPU 로 낮춘 뒤:
   ```bash
   for i in 1 2 3 4; do ab -n 100000 -c 300 -k http://10.0.0.31/ & done
   ```
   저사양 + prefork 대량 fork → 스왑/OOM 으로 박스 먹통. 같은 부하를 VIP 로 주면 3대 분산으로 안정 → 처리량/실패율 비교.

### 복구(정상화)
```bash
# victim 원상복구(방어 다시 켜기)
sudo ./setup.sh victim
# lb 기본 방어값 복구
sudo TIMEOUT_HTTPREQUEST=5s WEB_BACKENDS="10.0.0.11 10.0.0.12 10.0.0.13" ./setup.sh lb
# 정지했던 서비스 재기동
sudo systemctl start nginx        # web
sudo systemctl start keepalived   # lb
```

---

## 저장소 구조

```
testwebserver/
├── setup.sh               # 진입점. 첫 인자로 역할: web|lb|victim|attacker
├── roles/
│   ├── web.sh
│   ├── lb.sh              # HAProxy + (선택) keepalived VIP 이중화
│   ├── victim.sh          # apache2 단독. WEAK=1 데모 취약 모드
│   └── attacker.sh
├── templates/
│   ├── haproxy.cfg.tmpl   # 백엔드 IP·timeout 은 실행 시 주입
│   ├── keepalived.conf.tmpl  # VIP/역할/인터페이스는 실행 시 주입
│   └── index.html.tmpl    # hostname/IP/MAC 자리표시자 + 해시색
├── README.md
└── .gitignore
```

## 주의 (공개 저장소)

- 실제 IP·비밀번호·SSH 키·토큰·`VRRP_PASS` 를 **파일에 넣지 않는다.** 전부 실행 인자/환경변수로만.
- 예시 IP(`10.0.0.x`)·VIP(`10.0.0.100`)는 더미다.
- `.gitignore` 로 `*.key` / `*.pem` / `.env` 등을 제외한다.
- **공격 명령은 네 소유의 격리된 랩망 안에서만.** 공용 인터넷/클라우드 공유망으로 플러드를 보내지 말 것(타인 인프라 영향). 랩망은 NAT/host-only 처럼 외부와 끊어진 세그먼트로 둔다.
