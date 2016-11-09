#!/bin/bash

set -e -x

source /etc/profile.d/chruby.sh
chruby 2.1

export BUNDLE_GEMFILE="${PWD}/bosh-src/Gemfile"

bundle install --local

bosh() {
  bundle exec bosh -n -t "${BOSH_DIRECTOR_ADDRESS}" "$@"
}

# login
bosh login "${BOSH_DIRECTOR_USERNAME}" "${BOSH_DIRECTOR_PASSWORD}"

cleanup() {
  bosh cleanup --all
}
trap cleanup EXIT

# bosh upload stemcell
pushd stemcell
  bosh upload stemcell ./*.tgz
popd

# bosh upload release (syslog)
pushd syslog-release
  bosh upload release ./*.tgz
popd

env_attr() {
  local json=$1
  echo $json | jq --raw-output --arg attribute $2 '.[$attribute]'
}

metadata=$(cat environment/metadata)
network=$(env_attr "${metadata}" "network1")

: ${STEMCELL_TEST_VLAN:=$(                          env_attr "${network}" "vCenterVLAN")}
: ${STEMCELL_TEST_CIDR:=$(                          env_attr "${network}" "vCenterCIDR")}
: ${STEMCELL_TEST_RESERVED_RANGE:=$(                env_attr "${network}" "reservedRange")}
: ${STEMCELL_TEST_GATEWAY:=$(                       env_attr "${network}" "vCenterGateway")}

#Build Cloud config
cat > "./cloud-config.yml" <<EOF
azs:
- name: z1
  cloud_properties:
    datacenters:
    - name: ${BOSH_VSPHERE_VCENTER_DC}
      clusters:
        - ${BOSH_VSPHERE_VCENTER_CLUSTER}: {}

vm_types:
- name: default
  cloud_properties:
    ram: 2048
    cpu: 1
    disk: 5120

networks:
- name: default
  type: manual
  subnets:
  - range: ${STEMCELL_TEST_CIDR}
    reserved: [${STEMCELL_TEST_RESERVED_RANGE}]
    gateway: ${STEMCELL_TEST_GATEWAY}
    az: z1
    cloud_properties:
      name: ${STEMCELL_TEST_VLAN}

compilation:
  workers: 2
  reuse_compilation_vms: true
  az: z1
  vm_type: default
  network: default
EOF

bosh update cloud-config ./cloud-config.yml

# build manifest
cat > "./deployment.yml" <<EOF
---
name: bosh-stemcell-smoke-tests
director_uuid: $(bosh status --uuid)

releases:
- name: syslog
  version: $(cat syslog-release/version)

stemcells:
- alias: default
  os: ubuntu-trusty
  version: $(cat stemcell/version)

update:
  canaries: 1
  max_in_flight: 10
  canary_watch_time: 1000-30000
  update_watch_time: 1000-30000

instance_groups:
- name: syslog_storer
  stemcell: default
  vm_type: default
  instances: 1
  networks:
  - {name: default}
  azs: [z1]
  jobs:
  - name: syslog_storer
    release: syslog
    properties:
      syslog:
        transport: tcp
        port: 514
- name: syslog_forwarder
  stemcell: default
  vm_type: default
  azs: [z1]
  instances: 1
  networks:
  - {name: default}
  jobs:
  - name: syslog_forwarder
    release: syslog
    properties:
        forward_files: true
    consumes:
      syslog_storer: { from: syslog_storer }
EOF

cleanup() {
  bosh delete deployment bosh-stemcell-smoke-tests
  bosh cleanup --all
}

bosh -d ./deployment.yml deploy

DOWNLOAD_DESTINATION=`mktemp -d /tmp/syslog_test-$(date +%d%m%y-%H%M%S)-XXXXX`
LOGFILE=/var/vcap/sys/log/deep/path/deepfile.log

bosh -d ./deployment.yml ssh syslog_forwarder 0 "echo c1oudc0w | sudo -S mkdir -p /var/vcap/sys/log/deep/path && sudo touch ${LOGFILE} && echo 'test-deep-blackbox-msg' | sudo tee -a ${LOGFILE}"
sleep 20
bosh -d ./deployment.yml scp --download syslog_storer 0 /var/vcap/store/syslog_storer/syslog.log ${DOWNLOAD_DESTINATION}

LOGS_FROM_BB_FORWARDER=`cat ${DOWNLOAD_DESTINATION}/syslog.log.syslog_storer.* | grep 'test-deep-blackbox-msg' | xargs`

if [ -n "${LOGS_FROM_BB_FORWARDER}" ]; then
    # there are logs from the forwarder
    echo succeeded getting messages forwarded from BlackBox
else
    # there are no logs from the forwarder
    echo was not able to get message forwarded from BlackBox

    exit 1
fi