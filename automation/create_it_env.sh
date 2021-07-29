#!/bin/bash -ex

CONTAINER_CMD=${CONTAINER_CMD:=podman}

EXEC_PATH=$(dirname "$(realpath "$0")")
PROJECT_ROOT=$(git rev-parse --show-toplevel)
EXPORTED_ARTIFACTS_DIR="$PROJECT_ROOT/exported-artifacts/"

OVN_CENTRAL_TRIPLEO_TAG="${CENTRAL_CONTAINER_TAG:-current-tripleo-rdo}"
OVN_CONTROLLER_TRIPLEO_TAG="${CONTROLLER_CONTAINER_TAG:-current-tripleo-rdo}"
OVN_CENTRAL_IMG="docker.io/tripleorocky/centos-binary-ovn-northd:$OVN_CENTRAL_TRIPLEO_TAG"
OVN_CONTROLLER_IMG="docker.io/tripleorocky/centos-binary-ovn-controller:$OVN_CONTROLLER_TRIPLEO_TAG"
OVIRT_PROVIDER_OVN_IMG="${PROVIDER_IMG:-quay.io/mdbarroso/ovirt_provider_ovn}"

OVN_CONTAINER_FILES="$PROJECT_ROOT/automation/containers"
OVN_NORTHD_FILES="${OVN_CONTAINER_FILES}/ovn-central"
OVN_CONTROLLER_FILES="${OVN_CONTAINER_FILES}/ovn-controller"

PROVIDER_PATH="$PROJECT_ROOT"/provider
CONTAINER_SRC_CODE_PATH="/ovirt-provider-ovn"

AUTOMATED_TEST_TARGET="${TEST_TARGET:-integration-tests}"

test -t 1 && USE_TTY="t"

function container_ip {
    ${CONTAINER_CMD} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1
}

function container_exec {
    ${CONTAINER_CMD} exec "-i$USE_TTY" "$1" /bin/bash -c "$2"
}

function destroy_env {
  mkdir -p "$EXPORTED_ARTIFACTS_DIR"
  collect_sys_info
  collect_ovn_data
  collect_provider_logs
  collect_journalctl_data
  if [ -n "$OVN_CENTRAL_ID" ]; then
     ${CONTAINER_CMD} rm -f "$OVN_CENTRAL_ID"
  fi
  if [ -n "$OVN_CONTROLLER_ID" ]; then
     ${CONTAINER_CMD} rm -f "$OVN_CONTROLLER_ID"
  fi
  if [ -n "$PROVIDER_ID" ]; then
     ${CONTAINER_CMD} rm -f "$PROVIDER_ID"
  fi
}

function create_ovn_containers {
  OVN_CENTRAL_ID="$(${CONTAINER_CMD} run --privileged -d -v ${OVN_NORTHD_FILES}/config.json:/var/lib/kolla/config_files/config.json -v ${OVN_NORTHD_FILES}/boot-northd.sh:/usr/bin/boot-northd -e "KOLLA_CONFIG_STRATEGY=COPY_ONCE" $OVN_CENTRAL_IMG)"
  OVN_CENTRAL_IP="$(container_ip $OVN_CENTRAL_ID)"

  OVN_CONTROLLER_ID="$(${CONTAINER_CMD} run --privileged -d -v ${OVN_CONTROLLER_FILES}/config.json:/var/lib/kolla/config_files/config.json -v ${OVN_CONTROLLER_FILES}/boot-controller.sh:/usr/bin/boot-controller -e KOLLA_CONFIG_STRATEGY=COPY_ONCE -e OVN_SB_IP=$OVN_CENTRAL_IP $OVN_CONTROLLER_IMG)"
  OVN_CONTROLLER_IP="$(container_ip $OVN_CONTROLLER_ID)"
  container_exec "$OVN_CONTROLLER_ID" "yum install -y dhclient --disablerepo='*' --enablerepo=base"
}

function start_provider_container {
  kernel_version="$(uname -r)"
  PROVIDER_ID="$(
    ${CONTAINER_CMD} run --privileged -d \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
	  -v $PROJECT_ROOT/:$CONTAINER_SRC_CODE_PATH \
	  -v /lib/modules/$kernel_version:/lib/modules/$kernel_version:ro \
	  -p 9696:9696 -p 35357:35357 \
    $OVIRT_PROVIDER_OVN_IMG
  )"
  create_rpms
  install_provider_on_container
}

function create_rpms {
  cleanup_past_builds
  container_exec "$PROVIDER_ID" "touch /var/log/ovirt-provider-ovn.log"
  container_exec "$PROVIDER_ID" "
    cd $CONTAINER_SRC_CODE_PATH && \
    make rpm
  "
}

function cleanup_past_builds {
  rm -f "$PROJECT_ROOT"/ovirt-provider-ovn-*.tar.gz
}

function install_provider_on_container {
  container_exec "$PROVIDER_ID" "
    yum install -y --disablerepo=* \
	  ~/rpmbuild/RPMS/noarch/ovirt-provider-ovn-1.*.rpm && \
    sed -ie s/PLACE_HOLDER/${OVN_CENTRAL_IP}/g /etc/ovirt-provider-ovn/conf.d/10-integrationtest.conf && \
    modprobe openvswitch && \
    systemctl start ovirt-provider-ovn
  "
}

function activate_provider_traces {
  container_exec "$PROVIDER_ID" "sed -i_backup s/INFO/DEBUG/g /etc/ovirt-provider-ovn/logger.conf"
}

function collect_ovn_data {
  echo "Collecting data from OVN containers ..."
  if [ -n "$OVN_CENTRAL_ID" ]; then
    ${CONTAINER_CMD} cp "$OVN_CENTRAL_ID":/etc/openvswitch/ovnnb_db.db "$EXPORTED_ARTIFACTS_DIR"
    ${CONTAINER_CMD} cp "$OVN_CENTRAL_ID":/etc/openvswitch/ovnsb_db.db "$EXPORTED_ARTIFACTS_DIR"
    ${CONTAINER_CMD} cp "$OVN_CENTRAL_ID":/var/log/openvswitch/ovn-northd.log "$EXPORTED_ARTIFACTS_DIR"
  fi
  if [ -n "$OVN_CONTROLLER_ID" ]; then
    ${CONTAINER_CMD} cp "$OVN_CONTROLLER_ID":/var/log/openvswitch/ovn-controller.log "$EXPORTED_ARTIFACTS_DIR"
  fi
}

function collect_provider_logs {
  if [ -n "$PROVIDER_ID" ]; then
    ${CONTAINER_CMD} cp "$PROVIDER_ID":/var/log/ovirt-provider-ovn.log "$EXPORTED_ARTIFACTS_DIR"
  fi
}

function collect_sys_info {
    cp /etc/redhat-release $EXPORTED_ARTIFACTS_DIR
    uname -a > $EXPORTED_ARTIFACTS_DIR/kernel_info.txt
}

function collect_journalctl_data {
  if [ -n "$PROVIDER_ID" ]; then
    container_exec "$PROVIDER_ID" "journalctl -xe > /var/log/journalctl.log"
    ${CONTAINER_CMD} cp "$PROVIDER_ID":/var/log/journalctl.log "$EXPORTED_ARTIFACTS_DIR"
  fi
}

trap destroy_env EXIT
create_ovn_containers
start_provider_container
activate_provider_traces
if [ -n "$RUN_INTEG_TESTS" ]; then
  export PROVIDER_CONTAINER_ID=$PROVIDER_ID
  export CONTROLLER_CONTAINER_ID=$OVN_CONTROLLER_ID
  export CONTAINER_PLATFORM=$CONTAINER_CMD
  tox -e "$AUTOMATED_TEST_TARGET"
  destroy_env
fi
trap - EXIT
cleanup_past_builds
