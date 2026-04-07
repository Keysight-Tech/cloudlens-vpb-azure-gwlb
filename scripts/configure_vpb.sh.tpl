#!/bin/bash
set -e

echo "=== Installing dependencies ==="
sudo apt-get update -qq && sudo apt-get install -y sshpass expect 2>/dev/null || true

echo "=== Waiting for ${vpb_name} Docker container on port 2222 ==="
for i in $(seq 1 60); do
  if nc -z localhost 2222 2>/dev/null; then
    echo "${vpb_name} container port 2222 is open"
    break
  fi
  echo "Waiting for ${vpb_name} container... attempt $i/60"
  sleep 15
done
sleep 10

echo "=== Accepting EULA (${vpb_name}) ==="
expect -c "
  set timeout 60
  spawn sshpass -p ${cli_password} ssh -o StrictHostKeyChecking=no -p 2222 admin@localhost
  expect {
    \"Do you want to display the EULA\" { send \"n\r\"; exp_continue }
    \"Do you accept\" { send \"y\r\"; exp_continue }
    \"accept the EULA\" { send \"y\r\"; exp_continue }
    \"y/n\" { send \"y\r\"; exp_continue }
    \"Y/N\" { send \"y\r\"; exp_continue }
    \"CloudLensVPB#\" { send \"show version\r\" }
    \"#\" { send \"show version\r\" }
  }
  expect \"#\"
  send \"exit\r\"
  expect eof
"
sleep 5

echo "=== Configuring ${vpb_name} GWLB integration ==="

GWLB_IP="${gwlb_ip}"
TOOL_IP="${tool_ip}"
VLM_IP="${vlm_ip}"
LB_VIP="${lb_vip}"

expect -c "
  set timeout 30

  proc drain_pager {} {
    expect {
      -exact {--More--} { send \" \"; drain_pager }
      -re {CloudLensVPB[^#]*#} {}
      timeout {}
    }
  }

  spawn sshpass -p ${cli_password} ssh -o StrictHostKeyChecking=no -p 2222 admin@localhost
  expect \"#\"

  # License server
  send \"license server $VLM_IP type advanced\r\"
  expect \"#\"

  # VXLAN tunnels
  send \"vxlan-forwarding vxlan1 local-interface eth1 remote-ip $GWLB_IP vni 900 udp-port 10800\r\"
  expect \"#\"
  send \"vxlan-forwarding vxlan2 local-interface eth1 remote-ip $GWLB_IP vni 901 udp-port 10801\r\"
  expect \"#\"
  send \"vxlan-forwarding vxlan3 local-interface eth2 remote-ip $TOOL_IP vni 42 udp-port 4789\r\"
  expect \"#\"

  # eth1 — GWLB-facing interface
  send \"interface eth1\r\"
  expect \"#\"
  send \"ingress-mode ip\r\"
  expect \"#\"
  send \"arp\r\"
  expect \"#\"
  send \"icmp\r\"
  expect \"#\"
  send \"load-balancer-probe port 80\r\"
  expect \"#\"
  # Strip mode — required for DPDK VXLAN processing
  send \"ingress-filter vxlan port 10800\r\"
  expect \"#\"
  send \"ingress-filter vxlan port 10801\r\"
  expect \"#\"
  send \"end\r\"
  expect \"#\"

  # eth2 — tool-facing interface
  send \"interface eth2\r\"
  expect \"#\"
  send \"ingress-mode ip\r\"
  expect \"#\"
  send \"arp\r\"
  expect \"#\"
  send \"icmp\r\"
  expect \"#\"
  send \"end\r\"
  expect \"#\"

  # Direction-aware match rules using Standard LB VIP
  # GWLB intercepts BEFORE Standard LB DNAT:
  #   Inbound:  inner dst = LB VIP -> forward to Internal tunnel + mirror
  #   Outbound: inner src = LB VIP -> forward to External tunnel + mirror
  send \"match precedence 1 any ingress-port eth1 dip $LB_VIP/32 egress-port vxlan2 vxlan3\r\"
  expect \"#\"
  send \"match precedence 2 any ingress-port eth1 sip $LB_VIP/32 egress-port vxlan1 vxlan3\r\"
  expect \"#\"

  # Verify
  send \"show interface-status\r\"
  drain_pager
  send \"show tunnel-status\r\"
  drain_pager
  send \"show traffic-rule-packet-counters\r\"
  drain_pager

  send \"exit\r\"
  expect eof
"

echo "=== Bringing up physical NICs ==="
sudo ip link set enP48280s3 up 2>/dev/null || true
sudo ip link set enP29545s2 up 2>/dev/null || true

# Health probe responder (kernel path — GWLB probes don't reach DPDK)
echo "=== Starting health probe responder on port 80 ==="
sudo nohup python3 -c "import http.server; http.server.HTTPServer(('0.0.0.0', 80), http.server.SimpleHTTPRequestHandler).serve_forever()" > /dev/null 2>&1 &
sleep 2

echo "=== ${vpb_name} GWLB configuration complete ==="
