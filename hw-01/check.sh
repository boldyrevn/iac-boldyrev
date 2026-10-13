#!/usr/bin/env bash
set -uo pipefail

PREFIX=boldyrev-04
APP_PORT=8012
VM_COUNT="${1:-${VM_COUNT:-3}}"

RESULT=0

echo "==> проверка балансировщика"
if yc load-balancer network-load-balancer get --name "$PREFIX-lb" >/dev/null 2>&1; then
  LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json \
    | jq -r '.listeners[0].address')

  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 "http://$LB_IP" || true)

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "✓ балансировщик отвечает: 200"
  else
    echo "✗ балансировщик не отвечает: $HTTP_CODE"
    RESULT=1
  fi
else
  echo "✗ балансировщик $PREFIX-lb не найден"
  RESULT=1
fi

echo "==> проверка распределения запросов"
if [[ -n "${LB_IP:-}" ]]; then
  RESPONSES=""

  for ((i=0; i<20; i++)); do
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 \
      "http://$LB_IP" || true)

    if [[ -n "$RESPONSE" ]]; then
      RESPONSES+="$RESPONSE"$'\n'
    fi
  done

  MACHINES=$(printf '%s' "$RESPONSES" \
    | sed '/^$/d' \
    | sed 's/^.* on //' \
    | sort -u)

  MACHINE_COUNT=$(printf '%s\n' "$MACHINES" \
    | sed '/^$/d' \
    | wc -l)

  if (( MACHINE_COUNT == VM_COUNT )); then
    echo "✓ ответили все $VM_COUNT машины: $(echo "$MACHINES" | tr '\n' ' ')"
  else
    echo "✗ ответили $MACHINE_COUNT из $VM_COUNT машин: $(echo "$MACHINES" | tr '\n' ' ')"
    RESULT=1
  fi
else
  echo "✗ распределение проверить невозможно: балансировщик недоступен"
  RESULT=1
fi

echo "==> проверка сервера приложения"
if yc compute instance get --name "$PREFIX-web-1" >/dev/null 2>&1 &&
   yc compute instance get --name "$PREFIX-app" >/dev/null 2>&1; then

  WEB_IP=$(yc compute instance get --name "$PREFIX-web-1" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

  APP_IP=$(yc compute instance get --name "$PREFIX-app" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')

  APP_CODE=$(ssh \
    -i ~/.ssh/id_ed25519 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "student@$WEB_IP" \
    "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://$APP_IP:$APP_PORT" \
    2>/dev/null || true)

  if [[ "$APP_CODE" == "200" ]]; then
    echo "✓ сервер приложения доступен с web-1: 200"
  else
    echo "✗ сервер приложения недоступен с web-1"
    RESULT=1
  fi
else
  echo "✗ web-1 или сервер приложения не найден"
  RESULT=1
fi

exit "$RESULT"
