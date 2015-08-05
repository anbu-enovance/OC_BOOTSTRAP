#!/bin/bash

export nova="nova --no-cache"
export OS_TENANT_NAME=safchain
export OS_USERNAME=safchain
export OS_PASSWORD=redhat123
export OS_AUTH_URL="https://identity.lab0.aub.cloudwatt.net/v2.0/"

TLD="occi."

unique_name()
{
     UUID=$( cat /proc/sys/kernel/random/uuid | cut -d '-' -f 1 )
     echo $1-$UUID
}

wait_for_controller()
{
    CONTROLLER=$1
    
    while true
    do
        echo Waiting for $CONTROLLER
	CONTROLLER_IP=$( nova --insecure show $CONTROLLER | grep "adm network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]' )
	curl http://$CONTROLLER_IP:8082 2>/dev/null 1>/dev/null && break
    done
}

spawn_controller()
{
    CONTROLLER_UUID=$( unique_name "controller" )
    
    nova --insecure boot --flavor m1.large --image 5db66a8a-3165-4606-982d-43e89846c16f --key-name safchain --nic net-id=c2abf4aa-3631-4d6d-a4ab-f54fed99bdfb --nic net-id=95b20e17-38c1-446e-b2b5-eecf6ced198f --user-data controller.yaml $CONTROLLER_UUID > /dev/null

    echo $CONTROLLER_UUID
}

get_adm_ip()
{
    NAME=$1
    nova --insecure show $NAME | grep "adm network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]'
}

get_usr_ip()
{
    NAME=$1
    nova --insecure show $NAME | grep "usr network" | awk -F '|' '{print $3}' | tr -d '[[:space:]]'
}

ssh_command()
{
    NAME=$1
    CMD=$2
    IP=$( get_adm_ip $NAME )
    ssh -oStrictHostKeyChecking=no $IP "$CMD"
}

register_dns()
{
    NODE_NAME=$1
    NODE_IP=$( get_usr_ip $NODE_NAME )

    # A
    ( echo update del $NODE_NAME.$TLD ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
    ( echo update add $NODE_NAME.$TLD 300 A $NODE_IP ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key

    # PTR
    PTR=$( echo $NODE_IP | awk 'BEGIN{FS="."}{print $4"."$3"."$2"."$1".in-addr.arpa"}' )
    ( echo update del $PTR ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
    ( echo update add $PTR 300 PTR $NODE_NAME.$TLD ; echo send ) | sudo nsupdate -v -l -k /etc/bind/rndc.key
}

get_post_install_config()
{
    CONFIG_IP=$( get_usr_ip $1 )
    CONTROLLER1_IP=$( get_usr_ip $1 )
    CONTROLLER2_IP=$( get_usr_ip $2 )

cat <<EOF

#--------------------------

RABBIT_IP=$CONFIG_IP
OPENSTACK_IP=$CONFIG_IP
SERVICE_HOST=$CONTROLLER1_IP
CONTROL_IP=$CONTROLLER1_IP
USE_DISCOVERY=True
CASSANDRA_IP=$CONFIG_IP
CASSANDRA_IP_LIST=$CONFIG_IP
DNS_IP_LIST=$CONFIG_IP
CONTROL_IP_LIST=("$CONTROLLER1_IP" "$CONTROLLER2_IP")
DISCOVERY_IP=$CONFIG_IP
ZOOKEEPER_IP_LIST=$CONFIG_IP
EOF
}

CONTROLLER1=$( spawn_controller )
CONTROLLER2=$( spawn_controller )

register_dns $CONTROLLER1
register_dns $CONTROLLER2


#CONTROLLER1=controller-e8df6de0
#CONTROLLER2=controller-1a4f0072

wait_for_controller $CONTROLLER1
wait_for_controller $CONTROLLER2
echo Controllers ready !

echo Updating controller configurations
POST_CONFIG=$( get_post_install_config $CONTROLLER1 $CONTROLLER1 $CONTROLLER2 )
echo -e $POST_CONFIG

ssh_command $CONTROLLER1 "echo -e \"$POST_CONFIG\" >> ~/contrail-installer/localrc"
ssh_command $CONTROLLER1 "cd ~/contrail-installer; ./contrail.sh configure; ./contrail.sh stop; contrail.sh restart"

POST_CONFIG=$( get_post_install_config $CONTROLLER1 $CONTROLLER2 $CONTROLLER1 )
echo -e $POST_CONFIG

ssh_command $CONTROLLER2 "echo -e \"$POST_CONFIG\" >> ~/contrail-installer/localrc"
ssh_command $CONTROLLER2 "cd ~/contrail-installer; ./contrail.sh configure; ./contrail.sh stop; contrail.sh restart"

echo Done
