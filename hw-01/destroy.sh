#!/usr/bin/env bash
set -euo pipefail

PREFIX=boldyrev-04
ENV_NAME=stage

delete_labeled() {
  yc "$@" list --format json \
    | jq -r --arg owner "$PREFIX" --arg env "$ENV_NAME" \
      '.[] | select(.labels.owner == $owner and .labels.env == $env) | .name' \
    | while read -r name; do
        [[ -n "$name" ]] && yc "$@" delete "$name"
      done
}

echo "==> балансировщики"
delete_labeled load-balancer network-load-balancer

echo "==> целевые группы"
delete_labeled load-balancer target-group

echo "==> виртуальные машины"
delete_labeled compute instance

echo "==> отвязка таблицы маршрутизации"
yc vpc subnet list --format json \
  | jq -r --arg owner "$PREFIX" --arg env "$ENV_NAME" \
    '.[] | select(.labels.owner == $owner and .labels.env == $env and .route_table_id != null) | .name' \
  | while read -r name; do
      [[ -n "$name" ]] && yc vpc subnet update "$name" --disassociate-route-table
    done

echo "==> подсети"
delete_labeled vpc subnet

echo "==> таблицы маршрутизации"
delete_labeled vpc route-table

echo "==> NAT-шлюзы"
delete_labeled vpc gateway

echo "==> сети"
delete_labeled vpc network

echo "==> ресурсы owner=$PREFIX, env=$ENV_NAME удалены"