#!/bin/bash
# Libki Server setup wizard.
#
#   setup-wizard.sh [--docker|--native] [--plain] [--no-start]
#
# docker : writes docker/.env (generated DB passwords, admin user, timezone,
#          port) and optionally runs `docker compose up -d`.
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
for a in "$@"; do
  case "$a" in
    --docker) MODE=docker ;;
    --native) MODE=native ;;
    --plain) PLAIN=1 ;;
    --no-start) NOSTART=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

  if [ "$NOSTART" = 0 ] && yesno "Run 'docker compose up -d' now?"; then
    (cd "$ROOT/docker" && docker compose up -d) || die "docker compose failed."
    echo "Started. Admin page: http://localhost:$PORT/administration"
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
