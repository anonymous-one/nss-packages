#!/bin/sh
# shellcheck disable=3014
#
# Helper script which uses ethtool to disable (most)
# interface offloads, if possible.
#
# Reference:
# https://forum.openwrt.org/t/how-to-make-ethtool-setting-persistent-on-br-lan/6433/14
#
. /lib/functions.sh

log() {
  local status="$1"
  local feature="$2"
  local interface="$3"

  if [ $status -eq 0 ]; then
    logger "[ethtool] $feature: disabled on $interface"
  fi

  if [ $status -eq 1 ]; then
    logger -s "[ethtool] $feature: failed to disable on $interface"
  fi

  if [ $status -gt 1 ]; then
    logger "[ethtool] $feature: no changes performed on $interface"
  fi
}

interface_is_virtual() {
  local interface="$1"
  [ -d /sys/devices/virtual/net/"$interface"/ ] || return 1
  return 0
}

get_base_interface() {
  local interface="$1"
  echo "$interface" | grep -Eo '^[a-z]*[0-9]*' 2> /dev/null || return 1
  return 0
}

disable_offloads() {
  local interface="$1"
  local features
  local cmd

  # Check if we can change features
  if ethtool -k $interface 1> /dev/null 2> /dev/null; then

    # Filter whitespaces
    # Get only enabled/not fixed features
    # Filter features that are only changeable by global keyword
    # Filter empty lines
    # Cut to First column
    features=$(ethtool -k "$interface" | awk '{$1=$1;print}' \
      | grep -E '^.+: on$' \
      | grep -v -E '^tx-checksum-.+$' \
      | grep -v -E '^tx-scatter-gather.+$' \
      | grep -v -E '^tx-tcp.+segmentation.+$' \
      | grep -v -E '^tx-udp-fragmentation$' \
      | grep -v -E '^tx-generic-segmentation$' \
      | grep -v -E '^rx-gro$' \
      | grep -v -E '^$' \
      | cut -d: -f1)

    # Replace feature name by global keyword
    echo $features
    features=$(echo "$features" | sed -e s/rx-checksumming/rx/ \
      -e s/tx-checksumming/tx/ \
      -e s/scatter-gather/sg/ \
      -e s/tcp-segmentation-offload/tso/ \
      -e s/udp-fragmentation-offload/ufo/ \
      -e s/generic-segmentation-offload/gso/ \
      -e s/generic-receive-offload/gro/ \
      -e s/large-receive-offload/lro/ \
      -e s/rx-vlan-offload/rxvlan/ \
      -e s/tx-vlan-offload/txvlan/ \
      -e s/ntuple-filters/ntuple/ \
      -e s/receive-hashing/rxhash/)

    # Check if we can disable anything
    if [ -z "$features" ]; then
      logger "[ethtool] Offloads            : no changes performed on $interface"
      return 0
    fi

    # Construct ethtool command line
    cmd="-K $interface"

    for feature in $features; do
      cmd="$cmd $feature off"
    done

    # Try to disable offloads
    ethtool $cmd 1> /dev/null 2> /dev/null
    log $? "Offloads" "$interface"

  else
    log $? "Offloads" "$interface"
  fi
}

disable_gro() {
  local interface="$1"
  local cmd

  # Construct ethtool command line
  cmd="-K $interface gro off"

  # Try to disable flow control
  ethtool $cmd 1> /dev/null 2> /dev/null
  log $? "Generic Receive Offload" "$interface"
}

disable_flow_control() {
  local interface="$1"
  local cmd

  # Check if we can change settings
  if ethtool -a $interface 1> /dev/null 2> /dev/null; then

    # Construct ethtool command line
    cmd="-A $interface autoneg off tx off rx off"

    # Try to disable flow control
    ethtool $cmd 1> /dev/null 2> /dev/null
    log $? "Flow Control" "$interface"

  else
    log $? "Flow Control" "$interface"
  fi
}

disable_interrupt_moderation() {
  local interface="$1"
  local features
  local cmd

  # Check if we can change settings
  if ethtool -c $interface 1> /dev/null 2> /dev/null; then
    # Construct ethtool command line
    cmd="-C $interface adaptive-tx off adaptive-rx off"

    # Try to disable adaptive interrupt moderation
    ethtool $cmd 1> /dev/null 2> /dev/null
    log $? "Adaptive Interrupt Moderation" "$interface"

    features=$(ethtool -c $interface | awk '{$1=$1;print}' \
      | grep -v -E '^.+: 0$|Adaptive|Coalesce' \
      | grep -v -E '^$' \
      | cut -d: -f1)

    # Check if we can disable anything
    if [ -z "$features" ]; then
      logger "[ethtool] Interrupt Moderation: no changes performed on $interface"
      return 0
    fi

    # Construct ethtool command line
    cmd="-C $interface"

    for feature in $features; do
      cmd="$cmd $feature 0"
    done

    # Try to disable interrupt Moderation
    ethtool $cmd 1> /dev/null 2> /dev/null
    log $? "Interrupt Moderation" "$interface"

  else
    log $? "Interrupt Moderation" "$interface"
  fi
}

parse_opt() {
  local cfg="$1"

  config_get_bool enable_bridge_filtering "$cfg" enable_bridge_filtering 0
  config_get_bool disable_offloads "$cfg" disable_offloads 0
  config_get_bool disable_flow_control "$cfg" disable_flow_control 0
  config_get_bool disable_interrupt_moderation "$cfg" disable_interrupt_moderation 0
  config_get_bool disable_gro "$cfg" disable_gro 0
}

disable_offload() {
  config_load ecm
  config_foreach parse_opt general

  [ -z $1 ] && interface=$(echo /sys/class/net/*) || interface=$*

  for i in $interface; do
    i=${i##*/}

    # Skip Loopback
    if [ $i == lo ]; then
      continue
    fi

    if [ "$disable_gro" -eq 1 ]; then
      disable_gro "$i"
    fi

    if [ "$disable_offloads" -eq 1 ]; then
      disable_offloads "$i"
    fi

    if [ "$disable_flow_control" -eq 1 ]; then
      disable_flow_control "$i"
    fi

    if [ "$disable_interrupt_moderation" -eq 1 ]; then
      disable_interrupt_moderation "$i"
    fi
  done
}
