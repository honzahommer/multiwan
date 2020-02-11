#!/usr/bin/env bash

PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

readonly __BASENAME="$(basename "$0" .sh)"

CONFIG="/etc/$__BASENAME.conf"

STARTUP=1
CHECK_INTERVAL=1
LOG_FACILITY=local6
LOG_PRIORITY=notice

declare -A WAN_IF
declare -A WAN_GW
declare -A WAN_TABLE
declare -A WAN_WEIGHT

declare -A WAN_IP # IP address of each WAN interface
declare -A LLS # Last link status. Defaults to down to force check of both on first run.
declare -A LPS # Last ping status.
declare -A CPS # Current ping status.
declare -A CLS # Change link status.
declare -A CNT # Count of consecutive status checks

while getopts ":c:" opt; do
  case ${opt} in
    c)
      CONFIG=$OPTARG
      ;;
    \? )
      >&2 echo "Invalid option: $OPTARG"
      exit 1
      ;;
    : )
      >&2 echo "Invalid option: $OPTARG requires an argument"
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

if [ ! -f "$CONFIG" ]; then
  >&2 echo "$CONFIG: no such file"
  exit 1
fi

# shellcheck source=/dev/null
. "$CONFIG"

for v in WAN_IF WAN_TABLE WAN_GW WAN_WEIGHT; do
  for i in 1 2; do
    var="${v}${i}"
    val="${!var}"

    if [ -n "$val" ]; then
      eval "${v}[$i]=$val"
    fi
  done
done

for i in "${!WAN_IF[@]}"; do
  WAN_IP[$i]="$(ip addr show "${WAN_IF[$i]}" 2> /dev/null | awk '$1 == "inet" { gsub(/\/.*/, "", $2); print $2 }')"

  if [ -z "${WAN_IF[$i]}" ] || [ -z "${WAN_TABLE[$i]}" ] || [ -z "${WAN_GW[$i]}" ] || [ -z "${WAN_IP[$i]}" ]; then
    unset "WAN_IF[$i]"
    continue
  fi

  LLS[$i]=1
  LPS[$i]=1
  CPS[$i]=1
  CLS[$i]=1
  CNT[$i]=0

  if [ -z "${WAN_WEIGHT[$i]}" ]; then
    WAN_WEIGHT[$i]=1
  fi
done

now() {
  date +"%a %b %d %T %Y"
}

log() {
  if [ -n "$LOG_FILE" ]; then
    echo -e "$(now): $__BASENAME: $*" | tee -a "$LOG_FILE" 1>&2
  else
    logger -p "$LOG_FACILITY.$LOG_PRIORITY" -t "${__BASENAME}[$$]" -s "$@"
  fi
}

link_status() {
  case $1 in
    0)
      echo "Up" ;;
    1)
      echo "Down" ;;
    *)
      echo "Unknown" ;;
  esac
}

# check_link $IP $TIMEOUT
check_link() {
  ping -W "$2" -I "$1" -c 1 "$PING_TARGET" > /dev/null 2>&1
  RETVAL=$?
  if [ $RETVAL -ne 0 ] ; then
    STATE=1
  else
    STATE=0
  fi

  link_status $STATE

  return $STATE
}

while : ; do
  for i in "${!WAN_IF[@]}"; do
    check_link "${WAN_IP[$i]}" "$PING_TIMEOUT"
    CPS[$i]=$?

    if [[ ${LPS[$i]} -ne ${CPS[$i]} ]] ; then
      log "Ping state changed for ${WAN_TABLE[$i]} from $(link_status ${LPS[$i]}) to $(link_status ${CPS[$i]})"
      CNT[$i]=1
    else
      if [[ ${LPS[$i]} -ne ${LLS[$i]} ]] ; then
        CNT[$i]=$((CNT[i]+1))
      fi
    fi

    if [[ ${CNT[$i]} -ge $SUCCESS_COUNT || (${LLS[$i]} -eq 0 && ${CNT[$i]} -ge $FAILURE_COUNT) ]]; then
      CLS[$i]=0
      CNT[$i]=0

      if [[ ${LLS[$i]} -eq 1 ]] ; then
        LLS[$i]=0
      else
        LLS[$i]=1
      fi
      log "Link state for ${WAN_TABLE[$i]} is $(link_status ${LLS[$i]})"
    else
      CLS[$i]=1
    fi

    LPS[$i]=${CPS[$i]}
  done

  for i in "${!CLS[@]}"; do
    if [[ ${CLS[$i]} -eq 0 ]]; then
      COMMAND=("ip route replace default scope global")

      if [[ $STARTUP -eq 1 ]] ; then
        STARTUP=0
        CHECK_INTERVAL=15
      fi

      for j in "${!LLS[@]}"; do
        if [[ ${LLS[$j]} -eq 0 ]]; then
          COMMAND+=("nexthop via ${WAN_GW[$j]} dev ${WAN_IF[$j]} weight ${WAN_WEIGHT[$j]}")
        fi
      done

      if [[ ${#COMMAND[@]} -gt 1 ]]; then
        eval "${COMMAND[@]}"

        if [ -n "$ON_CHANGE" ]; then
          log "Run 'ON_CHANGE' command"
          eval "$ON_CHANGE" 2>/dev/null || true
        fi
      fi

      break
    fi
  done

  sleep $CHECK_INTERVAL
done
