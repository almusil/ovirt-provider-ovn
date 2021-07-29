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
OVN_CONTROLLER_FILES="${OVN_CONTAINER_FILES}/ovn-controller/"

PROVIDER_PATH="$PROJECT_ROOT"/provider
CONTAINER_SRC_CODE_PATH="/ovirt-provider-ovn"

AUTOMATED_TEST_TARGET="${TEST_TARGET:-integration-tests27}"

function container_ip {
    ${CONTAINER_CMD} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $1
}

function destroy_env {
  mkdir -p "$EXPORTED_ARTIFACTS_DIR"
  collect_sys_info
  if [ -n "$(filter_integration_test_containers)" ]; then
    collect_ovn_data
    collect_provider_logs
    collect_journalctl_data
    ${CONTAINER_CMD} rm -f $(filter_integration_test_containers)
  else
    echo "No containers to destroy; Bailing out."
    return 0
  fi
}

function filter_integration_test_containers {
  ${CONTAINER_CMD} ps -q --filter "label=purpose=ovirt_provider_ovn_integ_tests"
}

function create_ovn_containers {
  OVN_CENTRAL_ID="$(${CONTAINER_CMD} run --privileged -itd -v ${OVN_NORTHD_FILES}/config.json:/var/lib/kolla/config_files/config.json -v ${OVN_NORTHD_FILES}/boot-northd.sh:/usr/bin/boot-northd -e "KOLLA_CONFIG_STRATEGY=COPY_ONCE" --label purpose=ovirt_provider_ovn_integ_tests $OVN_CENTRAL_IMG)"
  OVN_CENTRAL_IP="$(container_ip $OVN_CENTRAL_ID)"

  OVN_CONTROLLER_ID="$(${CONTAINER_CMD} run --privileged -itd -v ${OVN_CONTROLLER_FILES}/config.json:/var/lib/kolla/config_files/config.json -v ${OVN_CONTROLLER_FILES}/boot-controller.sh:/usr/bin/boot-controller -e KOLLA_CONFIG_STRATEGY=COPY_ONCE -e OVN_SB_IP=$OVN_CENTRAL_IP --label purpose=ovirt_provider_ovn_integ_tests $OVN_CONTROLLER_IMG)"
  OVN_CONTROLLER_IP="$(container_ip $OVN_CONTROLLER_ID)"
  ${CONTAINER_CMD} exec -t "$OVN_CONTROLLER_ID" bash -c "
    yum install -y dhclient --disablerepo='*' --enablerepo=base
  "
}

function start_provider_container {
  kernel_version="$(uname -r)"
  PROVIDER_ID="$(
      ${CONTAINER_CMD} run --privileged -d \
          -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
	  -v $PROJECT_ROOT/:$CONTAINER_SRC_CODE_PATH \
	  -v /lib/modules/$kernel_version:/lib/modules/$kernel_version:ro \
	  -p 9696:9696 -p 35357:35357 \
	  -e OVN_NB_IP=$OVN_CENTRAL_IP \
	  -e PROVIDER_SRC_CODE=$CONTAINER_SRC_CODE_PATH \
        $OVIRT_PROVIDER_OVN_IMG
  )"
  create_rpms
  install_provider_on_container
}

function create_rpms {
  cleanup_past_builds
  ${CONTAINER_CMD} exec -t "$PROVIDER_ID" /bin/bash -c '
    touch /var/log/ovirt-provider-ovn.log
  '
  ${CONTAINER_CMD} exec -t "$PROVIDER_ID" /bin/bash -c '
    cd $PROVIDER_SRC_CODE && \
    make rpm
  '
}

function cleanup_past_builds {
  rm -f "$PROJECT_ROOT"/ovirt-provider-ovn-*.tar.gz
}

function install_provider_on_container {
  ${CONTAINER_CMD} exec -t "$PROVIDER_ID" /bin/bash -c '
    yum install -y --disablerepo=* \
	    ~/rpmbuild/RPMS/noarch/ovirt-provider-ovn-1.*.rpm && \
    sed -ie "s/PLACE_HOLDER/${OVN_NB_IP}/g" /etc/ovirt-provider-ovn/conf.d/10-integrationtest.conf && \
    modprobe openvswitch && \
    systemctl start ovirt-provider-ovn
  '
}

function activate_provider_traces {
  ${CONTAINER_CMD} exec -t "$PROVIDER_ID" /bin/bash -c '
    sed -i_backup 's/INFO/DEBUG/g' /etc/ovirt-provider-ovn/logger.conf
  '
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
    ${CONTAINER_CMD} exec "$PROVIDER_ID" /bin/bash -c 'journalctl -xe' \
	    > "$EXPORTED_ARTIFACTS_DIR"/journalctl.log
  fi
}

trap destroy_env EXIT
create_ovn_containers
start_provider_container
activate_provider_traces
if [ -n "$RUN_INTEG_TESTS" ]; then
  tox -e "$AUTOMATED_TEST_TARGET"
  destroy_env
fi
trap - EXIT
cleanup_past_builds
