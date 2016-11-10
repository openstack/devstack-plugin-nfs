#

XTRACE=$(set +o | grep xtrace)
set +o xtrace

NFS_EXPORT_DIR=${NFS_EXPORT_DIR:-/srv/nfs1}
STACK_NFS_CONF=${STACK_NFS_CONF:-/etc/exports.d/stack_nfs.exports}
NFS_SHARES_CONF=${NFS_SHARES_CONF:-/etc/cinder/nfs-shares.conf}
NFS_SECURE_FILE_PERMISSIONS=${NFS_SECURE_FILE_PERMISSIONS:-False}
NFS_SECURE_FILE_OPERATIONS=${NFS_SECURE_FILE_OPERATIONS:-False}

if is_ubuntu; then
    NFS_SERVICE=nfs-kernel-server
else
    NFS_SERVICE=nfs-server
fi

function install_nfs {
    if is_ubuntu; then
        install_package nfs-common
        install_package nfs-kernel-server
    elif is_fedora; then
        install_package nfs-utils
    elif is_suse; then
        install_package nfs-kernel-server
        install_package	nfs-client
    fi
}

function configure_nfs {
    sudo mkdir -p $NFS_EXPORT_DIR
    sudo chown $STACK_USER $NFS_EXPORT_DIR

    sudo mkdir -p /etc/exports.d

    cat <<EOF | sudo tee ${STACK_NFS_CONF}>/dev/null
$NFS_EXPORT_DIR	localhost(rw,no_root_squash)
EOF
}

function start_nfs {
    sudo service $NFS_SERVICE start
}

# is_nfs_enabled_for_service() - checks whether the OpenStack service
# specified as an argument is enabled with NFS as its storage backend.
function is_nfs_enabled_for_service {
    local config config_name enabled service
    enabled=1
    service=$1
    # Construct the global variable ENABLE_NFS_.* corresponding to a
    # $service.
    config_name=ENABLE_NFS_$(echo $service | \
                                    tr '[:lower:]' '[:upper:]' | tr '-' '_')
    config=$(eval echo "\$$config_name")

    if (is_service_enabled $service) && [[ $config == 'True' ]]; then
        enabled=0
    fi
    return $enabled
}

function configure_cinder_nfs {
    echo "localhost:${NFS_EXPORT_DIR}" > ${NFS_SHARES_CONF}
    iniset $CINDER_CONF nfs nfs_shares_config ${NFS_SHARES_CONF}
    iniset $CINDER_CONF nfs nas_secure_file_operations \
        ${NFS_SECURE_FILE_OPERATIONS}
    iniset $CINDER_CONF nfs nas_secure_file_permissions \
        ${NFS_SECURE_FILE_PERMISSIONS}

    # NFS snapshot support is currently opt-in only.
    iniset $CINDER_CONF nfs nfs_snapshot_support True

    # Point Cinder to the Nova service correctly
    # Cinder's defaults don't match what devstack sets up.
    iniset $CINDER_CONF DEFAULT nova_catalog_info compute:nova:publicURL
    iniset $CINDER_CONF DEFAULT nova_catalog_admin_info compute:nova:adminURL

}

# Configures tempest for running Cinder volume API tests with an NFS backend.
function configure_tempest_nfs {
    # The Cinder NFS backend doesn't yet support snapshot, backup or clone.
    iniset $TEMPEST_CONFIG volume-feature-enabled snapshot False
    iniset $TEMPEST_CONFIG volume-feature-enabled backup False
    iniset $TEMPEST_CONFIG volume-feature-enabled clone False
}


if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
    echo_summary "Installing NFS"
    install_nfs
    echo_summary "Configuring NFS"
    configure_nfs
    echo_summary "Initializing NFS"
    start_nfs
elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
    if is_nfs_enabled_for_service cinder; then
        configure_cinder_nfs
        sudo service $NFS_SERVICE restart
    fi
elif [[ "$1" == "stack" && "$2" == "test-config" ]]; then
    if is_nfs_enabled_for_service cinder; then
        configure_tempest_nfs
    fi
fi

if [[ "$1" == "unstack" ]]; then
    # Unmount any NFS shares mounted by Cinder
    find ${DATA_DIR}/cinder/mnt -mindepth 1 -maxdepth 1 -type d \
        | sudo xargs umount -l

    sudo rm -f ${STACK_NFS_CONF}

    # Reload to ensure (removed) config is reread, but don't
    # interfere with other NFS exports.
    sudo service $NFS_SERVICE reload
fi


$XTRACE
