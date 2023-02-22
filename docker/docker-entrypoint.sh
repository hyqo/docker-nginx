#!/usr/bin/env bash

ACME_CONFIG=/.acme.config
NGINX_VHOST=/etc/nginx/conf.d/vhost.conf

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "" >$NGINX_VHOST

find "$ACME_CONFIG" -name '*.env' -type f -print0 | while read -rd $'\0' file; do
  dir=${file%/*}
  basename=${file##*/}
  domainId=${basename%.env}

  vhostProdFilename="$dir/$domainId.conf"
  vhostDevFilename="$dir/$domainId.dev.conf"

  if [[ "$APP_ENV" == "dev" && -f "$vhostDevFilename" ]]; then
    vhostFilename="$vhostDevFilename"
  elif [ -f "$vhostProdFilename" ]; then
    vhostFilename="$vhostProdFilename"
  else
    break
  fi

  set -a
  # shellcheck disable=SC1090
  # shellcheck disable=SC2086
  . $file
  set +a

  DOMAIN_LIST=$(echo "$DOMAINS" | tr -s ' ')

  if [ -z "$DOMAIN_LIST" ]; then
    echo "Empty env var DOMAINS"
    exit 1
  fi

  # shellcheck disable=SC2116
  SSL=$(echo \
    "ssl_certificate /etc/nginx/ssl/app/$domainId.fullchain.pem;" \
    "ssl_certificate_key /etc/nginx/ssl/app/$domainId.key.pem;" \
    "ssl_trusted_certificate /etc/nginx/ssl/app/$domainId.cert.pem;")

  # shellcheck disable=SC2116
  SERVER_80=$(echo \
    "listen 80;" \
    "listen [::]:80;" \
    "server_name %DOMAINS:$domainId%;" \
    "return 301 https://\$server_name\$request_uri;")

  # shellcheck disable=SC2116
  SERVER_443=$(echo \
    "listen 443 ssl http2;" \
    "listen [::]:443 ssl http2;" \
    "server_name %DOMAINS:$domainId%;" \
    "%SSL:$domainId%")

  # shellcheck disable=SC2086
  VHOST=$(<$vhostFilename)

  VHOST="${VHOST//%SERVER:$domainId:80%/$SERVER_80}"
  VHOST="${VHOST//%SERVER:$domainId:443%/$SERVER_443}"
  VHOST="${VHOST//%DOMAINS:$domainId%/$DOMAINS}"
  VHOST="${VHOST//%SSL:$domainId%/$SSL}"

  VHOST+=$'\n'

  echo "$VHOST" >>$NGINX_VHOST

  IFS=' '
  read -ra list <<<"$DOMAIN_LIST"

  ACME_DOMAIN_OPTION=""

  for i in "${!list[@]}"; do
    ACME_DOMAIN_OPTION+="-d ${list[$i]}"

    if [[ $i == 0 ]]; then
      ACME_DOMAIN_OPTION+=" --dns dns_cf"
    fi

    ACME_DOMAIN_OPTION+=" "
  done

  echo "Issue the cert for $domainId: $DOMAINS with options $ACME_DOMAIN_OPTION"

  # shellcheck disable=SC2086
  /root/.acme.sh/acme.sh --issue \
    $ACME_DOMAIN_OPTION \
    --renew-hook "nginx -s reload"

  # shellcheck disable=SC2086
  /root/.acme.sh/acme.sh --install-cert $ACME_DOMAIN_OPTION \
    --fullchain-file /etc/nginx/ssl/app/$domainId.fullchain.pem \
    --cert-file /etc/nginx/ssl/app/$domainId.cert.pem \
    --key-file /etc/nginx/ssl/app/$domainId.key.pem
done

openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -subj "/C=CA/ST=QC/O=Company Inc/CN=example.com" \
  -out /etc/nginx/ssl/default/cert.pem \
  -keyout /etc/nginx/ssl/default/key.pem

echo "Start cron"
crond

echo "Start nginx"
nginx -g "daemon off;"
