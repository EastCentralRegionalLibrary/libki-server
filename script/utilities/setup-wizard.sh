#!/bin/bash
# Libki Server setup wizard.
#
#   setup-wizard.sh [--docker|--native] [--plain] [--no-start] [--no-nginx]
#
# docker : writes docker/.env (generated DB passwords, admin user, timezone,
#          port), optionally installs and configures nginx as the TLS reverse
#          proxy (existing certificate, Let's Encrypt, or plain HTTP), and
#          optionally runs `docker compose up -d`. The container listens on
#          127.0.0.1 only, so nginx is the way in from the network.
# native : for a checkout/install that already has Perl deps and MariaDB/MySQL:
#          writes the DB settings into libki_local.conf, migrates the
#          database and creates the admin user. (install.sh does all of this
#          plus package/user/service setup on a fresh Debian/Ubuntu box.)
#
# Uses whiptail when available and attached to a terminal, plain prompts
# otherwise (or with --plain).

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=""
PLAIN=0
NOSTART=0
NONGINX=0
for a in "$@"; do
  case "$a" in
    --docker) MODE=docker ;;
    --native) MODE=native ;;
    --plain) PLAIN=1 ;;
    --no-start) NOSTART=1 ;;
    --no-nginx) NONGINX=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (try --help)" >&2; exit 1 ;;
  esac
done

WT=0
if [ "$PLAIN" = 0 ] && [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then WT=1; fi

die() { echo "ERROR: $*" >&2; exit 1; }

# ask VAR "Label" "default" [validator-regex] [error message]
ask() {
  local var=$1 label=$2 def=${3-} re=${4-} err=${5-Invalid value.} ans
  while true; do
    if [ "$WT" = 1 ]; then
      ans=$(whiptail --title "Libki setup" --inputbox "$label" 10 70 "$def" 3>&1 1>&2 2>&3) || exit 1
    else
      read -r -p "$label${def:+ [$def]}: " ans || exit 1
    fi
    ans=${ans:-$def}
    if [ -z "$re" ] || [[ $ans =~ $re ]]; then printf -v "$var" '%s' "$ans"; return; fi
    echo "$err" >&2
  done
}

# askpw VAR "Label"  (asks twice, rejects empty/mismatch)
askpw() {
  local var=$1 label=$2 p1 p2
  while true; do
    if [ "$WT" = 1 ]; then
      p1=$(whiptail --title "Libki setup" --passwordbox "$label" 10 70 3>&1 1>&2 2>&3) || exit 1
      p2=$(whiptail --title "Libki setup" --passwordbox "$label (again)" 10 70 3>&1 1>&2 2>&3) || exit 1
    else
      read -r -s -p "$label: " p1 || exit 1; echo
      read -r -s -p "$label (again): " p2 || exit 1; echo
    fi
    if [ -z "$p1" ]; then echo "Password cannot be empty." >&2
    elif [ "$p1" != "$p2" ]; then echo "Passwords did not match." >&2
    else printf -v "$var" '%s' "$p1"; return; fi
  done
}

# yesno "Question" -> 0 for yes (default no)
yesno() {
  if [ "$WT" = 1 ]; then whiptail --title "Libki setup" --defaultno --yesno "$1" 10 70; return; fi
  local a; read -r -p "$1 [y/N]: " a || return 1
  [[ $a =~ ^[Yy] ]]
}

gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

default_tz() {
  local tz=""
  [ -r /etc/timezone ] && tz=$(cat /etc/timezone)
  [ -z "$tz" ] && command -v timedatectl >/dev/null 2>&1 && tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  echo "${tz:-America/New_York}"
}

check_tz() {
  [ -d /usr/share/zoneinfo ] || return 0
  [ -e "/usr/share/zoneinfo/$1" ]
}

ask_tz() {
  local d; d=$(default_tz)
  while true; do
    ask TZ_ANS "Timezone (see https://metacpan.org/pod/DateTime::TimeZone::Catalog)" "$d" '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$' "Not a timezone name."
    check_tz "$TZ_ANS" && return
    echo "Unknown timezone: $TZ_ANS" >&2
  done
}

NAME_RE='^[^[:space:]]+$'

# ---- nginx (docker mode) ----

# nginx_server_block DOMAIN PORT CERT KEY [PUBLIC_SCHEME]
# CERT empty => plain HTTP block. PUBLIC_SCHEME is what X-Request-Base advertises;
# it defaults from CERT, but Let's Encrypt starts as HTTP and becomes https.
nginx_server_block() {
  local d=$1 p=$2 cert=$3 key=$4 scheme=http l80="listen 80;" l443="listen 443 ssl http2;"
  [ -n "$cert" ] && scheme=https
  [ -n "${5-}" ] && scheme=$5
  # Only listen on IPv6 where the host has it, or nginx -t fails.
  if [ -s /proc/net/if_inet6 ]; then
    l80="$l80
    listen [::]:80;"
    l443="$l443
    listen [::]:443 ssl http2;"
  fi
  local loc
  loc=$(cat <<EOF
    client_max_body_size 100m;   # print jobs are uploaded through the server

    location / {
        proxy_pass http://127.0.0.1:$p;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Libki builds absolute links from this header
        proxy_set_header X-Request-Base "$scheme://$d";
    }
EOF
)
  if [ -n "$cert" ]; then
    cat <<EOF
server {
    $l80
    server_name $d;
    return 301 https://\$host\$request_uri;
}

server {
    $l443
    server_name $d;

    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;

$loc
}
EOF
  else
    cat <<EOF
server {
    $l80
    server_name $d;

$loc
}
EOF
  fi
}

# Verify a certificate/key pair before nginx ever sees them.
check_cert_pair() {
  local cert=$1 key=$2 d=$3 a b
  [ -r "$cert" ] || { echo "Cannot read certificate: $cert" >&2; return 1; }
  [ -r "$key" ]  || { echo "Cannot read private key: $key" >&2; return 1; }
  openssl x509 -in "$cert" -noout 2>/dev/null || { echo "Not a PEM certificate: $cert (convert .pfx/.der first)" >&2; return 1; }
  a=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256)
  b=$(openssl pkey -in "$key" -pubout 2>/dev/null </dev/null | openssl sha256)
  [ "$a" = "$b" ] || { echo "The private key does not match the certificate (or the key is passphrase-protected; nginx cannot prompt for one)." >&2; return 1; }
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || echo "WARNING: this certificate has expired." >&2
  openssl x509 -in "$cert" -noout -checkhost "$d" 2>/dev/null | grep -q 'does match' ||
    echo "WARNING: the certificate does not list $d; browsers will show a name mismatch." >&2
  if [ "$(grep -c 'BEGIN CERTIFICATE' "$cert")" -lt 2 ]; then
    echo "NOTE: $cert holds only one certificate. Some clients need the full chain (leaf + intermediates)." >&2
  fi
  return 0
}

reload_nginx() {
  nginx -t || return 1
  if pgrep -x nginx >/dev/null 2>&1; then nginx -s reload
  else systemctl enable --now nginx 2>/dev/null || service nginx start 2>/dev/null || nginx
  fi
}

# setup_nginx PORT
setup_nginx() {
  local port=$1 domain mode cert="" key="" email="" conf sample="$ROOT/docker/nginx-libki.conf"
  ask domain "Public host name for this server (DNS must point here)" "" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' "Not a valid host name."
  if [ "$WT" = 1 ]; then
    mode=$(whiptail --title "Libki setup" --menu "TLS certificate" 14 70 3 \
      existing "I already have a certificate and key" \
      letsencrypt "Get a free Let's Encrypt certificate (certbot)" \
      http "No TLS (plain HTTP)" 3>&1 1>&2 2>&3) || exit 1
  else
    echo "1) existing    - I already have a certificate and key"
    echo "2) letsencrypt - get a free Let's Encrypt certificate (certbot)"
    echo "3) http        - no TLS (plain HTTP)"
    local c; read -r -p "Choose 1, 2 or 3: " c || exit 1
    case "$c" in 1) mode=existing ;; 2) mode=letsencrypt ;; 3) mode=http ;; *) die "Choose 1, 2 or 3." ;; esac
  fi

  case "$mode" in
    existing)
      while true; do
        ask cert "Path to the certificate (PEM, full chain)" "" '^/.+' "Use an absolute path."
        ask key  "Path to the private key (PEM, no passphrase)" "" '^/.+' "Use an absolute path."
        check_cert_pair "$cert" "$key" "$domain" && break
      done ;;
    letsencrypt)
      ask email "Email address for Let's Encrypt expiry notices" "" '^[^@[:space:]]+@[^@[:space:]]+$' "Not an email address." ;;
  esac

  local pubscheme=""
  [ "$mode" = letsencrypt ] && pubscheme=https

  # Without root and apt we cannot install anything: leave a ready-to-use file instead.
  if [ "$(id -u)" != 0 ] || ! command -v apt-get >/dev/null 2>&1; then
    nginx_server_block "$domain" "$port" "$cert" "$key" "$pubscheme" > "$sample"
    echo "Not root, or not a Debian/Ubuntu host: wrote $sample instead." >&2
    echo "Install nginx yourself, put that file in its sites/conf.d directory, then reload nginx." >&2
    [ "$mode" = letsencrypt ] && echo "Then run: certbot --nginx -d $domain --redirect" >&2
    return 0
  fi

  if ! command -v nginx >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx || die "Could not install nginx."
  fi
  if [ "$mode" = letsencrypt ] && ! command -v certbot >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx || die "Could not install certbot."
  fi

  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  conf=/etc/nginx/sites-available/libki
  [ -e "$conf" ] && cp -p "$conf" "$conf.bak.$(date +%s)"
  nginx_server_block "$domain" "$port" "$cert" "$key" "$pubscheme" > "$conf"
  ln -sfn "$conf" /etc/nginx/sites-enabled/libki
  if ! reload_nginx; then
    rm -f /etc/nginx/sites-enabled/libki
    die "nginx rejected the generated configuration ($conf). The site was not enabled."
  fi

  if [ "$mode" = letsencrypt ]; then
    if certbot --nginx -d "$domain" -m "$email" --agree-tos --no-eff-email --redirect --non-interactive; then
      PUBLIC_URL="https://$domain"
    else
      echo "WARNING: certbot failed (is DNS pointing here, and port 80 reachable?). The site is up on plain HTTP." >&2
      echo "         Fix it, then run: certbot --nginx -d $domain --redirect" >&2
      PUBLIC_URL="http://$domain"
    fi
  elif [ "$mode" = existing ]; then PUBLIC_URL="https://$domain"
  else PUBLIC_URL="http://$domain"; fi
  echo "nginx is serving $PUBLIC_URL (config: $conf)."
  echo "Open ports 80 and 443 in your firewall; keep $port closed (the container listens on 127.0.0.1 only)."
}

if [ -z "$MODE" ]; then
  if [ "$WT" = 1 ]; then
    MODE=$(whiptail --title "Libki setup" --menu "How is this server run?" 14 70 2 \
      docker "Docker Compose (writes docker/.env)" \
      native "Existing native install (libki_local.conf + admin user)" 3>&1 1>&2 2>&3) || exit 1
  else
    echo "1) docker  - Docker Compose (writes docker/.env)"
    echo "2) native  - existing native install (libki_local.conf + admin user)"
    read -r -p "Choose 1 or 2: " c || exit 1
    case "$c" in 1) MODE=docker ;; 2) MODE=native ;; *) die "Choose 1 or 2." ;; esac
  fi
fi

if [ "$MODE" = docker ]; then
  ENVFILE="$ROOT/docker/.env"
  ask ADMIN_USER "Admin username" "admin" "$NAME_RE" "No spaces allowed."
  while true; do
    askpw ADMIN_PASS "Admin password"
    [[ $ADMIN_PASS != *"'"* ]] && break
    echo "Password may not contain a single quote (it is stored single-quoted in docker/.env)." >&2
  done
  ask INSTANCE "Instance name (leave empty for a normal single-library server)" "" '^[A-Za-z0-9_-]*$' "Letters, digits, - and _ only."
  ask_tz
  ask PORT "Port on this host" "3000" '^[0-9]+$' "Port must be a number."
  ask DBNAME "Database name" "libki" '^[A-Za-z0-9_]+$' "Letters, digits and _ only."
  ask DBUSER "Database user" "libki" '^[A-Za-z0-9_]+$' "Letters, digits and _ only."
  DBPASS=$(gen); DBROOT=$(gen)

  if [ -e "$ENVFILE" ]; then
    cp -p "$ENVFILE" "$ENVFILE.bak.$(date +%s)" || die "Could not back up existing $ENVFILE"
    echo "Existing .env backed up."
  fi
  # Existing database volumes keep their old passwords; warn if one is likely present.
  if command -v docker >/dev/null 2>&1 && docker volume ls -q 2>/dev/null | grep -q 'db_data$'; then
    echo "WARNING: a db_data volume already exists. MariaDB ignores new DB_* passwords for an" >&2
    echo "         initialised volume. Reuse the old .env values or remove the volume." >&2
  fi
  (
    umask 077
    {
      echo "LIBKI_ADMIN_USERNAME=$ADMIN_USER"
      echo "LIBKI_ADMIN_PASSWORD='$ADMIN_PASS'"
      echo "LIBKI_INSTANCE=$INSTANCE"
      echo "LIBKI_TZ=$TZ_ANS"
      echo "LIBKI_PORT=$PORT"
      echo "DB_NAME=$DBNAME"
      echo "DB_USER=$DBUSER"
      echo "DB_PASS=$DBPASS"
      echo "DB_ROOT_PASS=$DBROOT"
    } > "$ENVFILE"
  ) || die "Could not write $ENVFILE"
  echo "Wrote $ENVFILE (mode 600)."

  PUBLIC_URL=""
  if [ "$NONGINX" = 0 ] && yesno "Set up nginx as the public (TLS) front end on this host?"; then
    setup_nginx "$PORT"
  fi

  if [ "$NOSTART" = 0 ] && yesno "Run 'docker compose up -d' now?"; then
    (cd "$ROOT/docker" && docker compose up -d) || die "docker compose failed."
    echo "Started. Admin page: ${PUBLIC_URL:-http://127.0.0.1:$PORT}/administration"
  else
    echo "Start later with: cd $ROOT/docker && docker compose up -d"
  fi
  exit 0
fi

# ---- native ----
CONF="$ROOT/libki_local.conf"
if [ ! -e "$CONF" ]; then
  [ -e "$ROOT/libki_local.conf.example" ] || die "libki_local.conf.example not found in $ROOT"
  cp "$ROOT/libki_local.conf.example" "$CONF"
fi

ask DBHOST "Database host" "localhost" '^[A-Za-z0-9._-]+$' "Invalid host."
ask DBNAME "Database name" "libki" '^[A-Za-z0-9_]+$' "Letters, digits and _ only."
ask DBUSER "Database user" "libki" '^[A-Za-z0-9_]+$' "Letters, digits and _ only."
while true; do
  askpw DBPASS "Database password"
  [[ $DBPASS != *'"'* && $DBPASS != *'\'* ]] && break
  echo 'Password may not contain " or \ (it is written inside quotes in libki_local.conf).' >&2
done
ask ADMIN_USER "Admin username" "admin" "$NAME_RE" "No spaces allowed."
askpw ADMIN_PASS "Admin password"

cp -p "$CONF" "$CONF.bak.$(date +%s)"
DSN="dbi:mysql:$DBNAME;host=$DBHOST" DBUSER="$DBUSER" DBPASS="$DBPASS" perl -0pi -e '
  s/^(\s*dsn\s+).*$/$1$ENV{DSN}/m;
  s/^(\s*user\s+).*$/$1$ENV{DBUSER}/m;
  s/^(\s*password\s+)"[^"\n]*"/$1"$ENV{DBPASS}"/m;
' "$CONF" || die "Could not edit $CONF"
chmod 600 "$CONF"
echo "Updated database settings in $CONF."

export PERL5LIB="$ROOT/lib${PERL5LIB:+:$PERL5LIB}"
perl "$ROOT/installer/update_db.pl" || die "Database update failed. Check the settings above and that the database exists."
perl "$ROOT/script/administration/create_user.pl" -u "$ADMIN_USER" -p "$ADMIN_PASS" -s || die "Creating the admin user failed."
echo "Done. Restart the service (service libki restart) to pick up the new settings."
