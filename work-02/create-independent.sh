#!/usr/bin/env bash
set -euo pipefail

# Вариант 04: значения по умолчанию.
PREFIX=boldyrev-04
ZONE_A=ru-central1-d
ZONE_B=ru-central1-b
CIDR_A=10.14.1.0/24
CIDR_B=10.14.2.0/24
APP_PORT=8012
GREETING=devlab
VM_COUNT="${1:-3}"
DISK_SIZE="${2:-20}"
BOOT_SIZE=15
IMAGE_FAMILY=ubuntu-2404-lts

if [[ $# -gt 2 || ! "$VM_COUNT" =~ ^(0|[1-9][0-9]*)$ || ! "$DISK_SIZE" =~ ^(0|[1-9][0-9]*)$ ]] ||
   (( VM_COUNT < 2 || DISK_SIZE < 1 )); then
  echo "Использование: $0 [число_машин>=2] [размер_диска_ГБ>=1]" >&2
  exit 2
fi

TEMP_DIR=$(mktemp -d "$PWD/.cloud-init.XXXXXXXX")
CLOUD_INIT="$TEMP_DIR/cloud-init.yaml"
trap 'rm -f "$CLOUD_INIT"; rmdir "$TEMP_DIR"' EXIT
SSH_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
export APP_PORT GREETING SSH_KEY

echo "==> файл настройки из шаблона"
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < work-02/cloud-init-independent.tpl.yaml > "$CLOUD_INIT"

echo "==> сеть и подсети"
yc vpc network create --name "$PREFIX-net"
yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
  --zone "$ZONE_A" --range "$CIDR_A"
yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
  --zone "$ZONE_B" --range "$CIDR_B"

echo "==> дополнительный диск"
yc compute disk create --name "$PREFIX-data" --zone "$ZONE_A" \
  --size "$DISK_SIZE" --type network-hdd

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")

for ((i=1; i<=VM_COUNT; i++)); do
  idx=$(( (i - 1) % 2 ))
  instance_args=(
    --name "$PREFIX-app-$i"
    --zone "${ZONES[$idx]}"
    --platform standard-v3
    --cores=2 --core-fraction=20 --memory=2
    --preemptible
    --create-boot-disk "image-folder-id=standard-images,image-family=$IMAGE_FAMILY,type=network-hdd,size=$BOOT_SIZE"
    --network-interface "subnet-name=${SUBNETS[$idx]},nat-ip-version=ipv4"
    --hostname "$PREFIX-app-$i"
    --metadata-from-file "user-data=$CLOUD_INIT"
  )
  if (( i == 1 )); then
    instance_args+=(--attach-disk "disk-name=$PREFIX-data,device-name=data")
  fi
  yc compute instance create "${instance_args[@]}"
done

echo "==> целевая группа"

# собираем список машин: имя подсети и внутренний адрес каждой
TARGETS=""
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS="$TARGETS --target subnet-name=${SUBNETS[$idx]},address=$IP"
done

yc load-balancer target-group create --name "$PREFIX-tg" $TARGETS

echo "==> балансировщик"
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -er '.id')
yc load-balancer network-load-balancer create \
  --name "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener "name=http,port=80,target-port=$APP_PORT,external-ip-version=ipv4" \
  --target-group "target-group-id=$TG_ID,healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port=$APP_PORT,healthcheck-http-path=/"

echo "==> стенд создан: $VM_COUNT ВМ, диск ${DISK_SIZE} ГБ"
