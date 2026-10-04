#!/usr/bin/env bash
set -euo pipefail

PREFIX=boldyrev-04
ZONE_A=ru-central1-d
ZONE_B=ru-central1-b
CIDR_A=10.14.1.0/24
CIDR_B=10.14.2.0/24
APP_PORT=8012
GREETING=devlab
VM_COUNT="${1:-${VM_COUNT:-3}}"
BOOT_SIZE=15
ENV_NAME=stage
IMAGE_FAMILY=ubuntu-2404-lts

if [[ $# -gt 1 || ! "$VM_COUNT" =~ ^(0|[1-9][0-9]*)$ ]] || (( VM_COUNT < 2 )); then
  echo "Использование: $0 [число_веб_серверов>=2]" >&2
  exit 2
fi

LABELS="env=$ENV_NAME,owner=$PREFIX"

TEMP_DIR=$(mktemp -d "$PWD/.cloud-init.XXXXXXXX")
CLOUD_INIT="$TEMP_DIR/cloud-init.yaml"
trap 'rm -f "$CLOUD_INIT"; rmdir "$TEMP_DIR"' EXIT

SSH_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")

echo "==> файл настройки из шаблона"
APP_PORT="$APP_PORT" \
GREETING="$GREETING" \
SSH_KEY="$SSH_KEY" \
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < hw-01/cloud-init.tpl.yaml > "$CLOUD_INIT"

echo "==> сеть"
if yc vpc network get --name "$PREFIX-net" >/dev/null 2>&1; then
  echo "Сеть $PREFIX-net уже существует, пропускаю"
else
  yc vpc network create \
    --name "$PREFIX-net" \
    --labels "$LABELS"
fi

echo "==> NAT-шлюз"
if yc vpc gateway get --name "$PREFIX-nat" >/dev/null 2>&1; then
  echo "NAT-шлюз $PREFIX-nat уже существует, пропускаю"
else
  yc vpc gateway create \
    --name "$PREFIX-nat" \
    --labels "$LABELS"
fi

GW_ID=$(yc vpc gateway get --name "$PREFIX-nat" --format json | jq -r '.id')

echo "==> таблица маршрутизации"
if yc vpc route-table get --name "$PREFIX-rt" >/dev/null 2>&1; then
  echo "Таблица $PREFIX-rt уже существует, пропускаю"
else
  yc vpc route-table create \
    --name "$PREFIX-rt" \
    --network-name "$PREFIX-net" \
    --labels "$LABELS" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID"
fi

echo "==> подсеть A"
if yc vpc subnet get --name "$PREFIX-subnet-a" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-a уже существует, пропускаю"
else
  yc vpc subnet create \
    --name "$PREFIX-subnet-a" \
    --network-name "$PREFIX-net" \
    --zone "$ZONE_A" \
    --range "$CIDR_A" \
    --labels "$LABELS"
fi

yc vpc subnet update \
  --name "$PREFIX-subnet-a" \
  --route-table-name "$PREFIX-rt" \
  >/dev/null

echo "==> подсеть B"
if yc vpc subnet get --name "$PREFIX-subnet-b" >/dev/null 2>&1; then
  echo "Подсеть $PREFIX-subnet-b уже существует, пропускаю"
else
  yc vpc subnet create \
    --name "$PREFIX-subnet-b" \
    --network-name "$PREFIX-net" \
    --zone "$ZONE_B" \
    --range "$CIDR_B" \
    --labels "$LABELS"
fi

echo "==> веб-серверы"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for ((i=1; i<=VM_COUNT; i++)); do
  NAME="$PREFIX-web-$i"

  if yc compute instance get --name "$NAME" >/dev/null 2>&1; then
    echo "ВМ $NAME уже существует, пропускаю"
    continue
  fi

  idx=$(( (i - 1) % 2 ))

  yc compute instance create \
    --name "$NAME" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --labels "$LABELS" \
    --create-boot-disk \
      "image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE,auto-delete=true" \
    --network-interface \
      "subnet-name=${SUBNETS[$idx]},nat-ip-version=ipv4" \
    --hostname "$NAME" \
    --metadata-from-file "user-data=$CLOUD_INIT"
done

echo "==> сервер приложения"
if yc compute instance get --name "$PREFIX-app" >/dev/null 2>&1; then
  echo "ВМ $PREFIX-app уже существует, пропускаю"
else
  yc compute instance create \
    --name "$PREFIX-app" \
    --zone "$ZONE_A" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --labels "$LABELS" \
    --create-boot-disk \
      "image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE" \
    --network-interface "subnet-name=$PREFIX-subnet-a" \
    --hostname "$PREFIX-app" \
    --metadata-from-file "user-data=$CLOUD_INIT"
fi

echo "==> целевая группа"
if yc load-balancer target-group get --name "$PREFIX-tg" >/dev/null 2>&1; then
  echo "Целевая группа $PREFIX-tg уже существует, пропускаю"
else
  TARGETS=""

  for i in $(seq 1 "$VM_COUNT"); do
    idx=$(( (i - 1) % 2 ))

    IP=$(yc compute instance get --name "$PREFIX-web-$i" --format json \
      | jq -r '.network_interfaces[0].primary_v4_address.address')

    TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
  done

  yc load-balancer target-group create \
    --name "$PREFIX-tg" \
    --labels "$LABELS" \
    $TARGETS
fi

echo "==> балансировщик"
if yc load-balancer network-load-balancer get --name "$PREFIX-lb" >/dev/null 2>&1; then
  echo "Балансировщик $PREFIX-lb уже существует, пропускаю"
else
  TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json \
    | jq -r '.id')

  yc load-balancer network-load-balancer create \
    --name "$PREFIX-lb" \
    --labels "$LABELS" \
    --region-id ru-central1 \
    --listener \
      "name=http,port=80,target-port=$APP_PORT,external-ip-version=ipv4" \
    --target-group \
      "target-group-id=$TG_ID,healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port=$APP_PORT,healthcheck-http-path=/"
fi

echo "==> стенд создан: $VM_COUNT веб-серверов"