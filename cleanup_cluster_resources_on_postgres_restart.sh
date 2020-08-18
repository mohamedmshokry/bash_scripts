#!/bin/bash

#################################################################################################
#Script Name	: Check remote service and take action based on service status or parameters                                                                                       
#Description	: Check postgresel.service startup time and take action based on recent restarts
#                 Check if there is failed or stopped resources in the cluster to do a cleanup                              
#Args           : None                                                   
#Author       	: Mohamed Shokry                                                
#Email         	: mohamed.magdyshokry@gmail.com                                          
#################################################################################################

# Global paramters description
##############################
# PIDFILE						: Bash process PID file location
# SERVICE_HOST_IP				: systemd service host IP address
# SERVICE_HOST_USER				: remote host linux user that has privillages to check and take action on the service
# SERVICE_HOST_PASSWORD			: remote host linux password
# SCRIPT_LOG_PATH				: absolute path to script logs
# SERVICE_UPTIME 				: service uptime from systemd ActiveEnterTimestamp parameters
# SERVICE_UPTIME_EPOCH 			: service uptime in epoch format
# CURRENT_DATE_EPOCH 			: current date in epoch format
# SERVICE_UPTIME_DIFF_EPOCH 	: CURRENT_DATE_EPOCH - SERVICE_UPTIME_EPOCH
# SERVICE_UPTIME_COMPARE_SECONDS: service uptime checking last start time in seconds, used to determine if service is restarted in last # of seconds
# ACTION_LOOP_TIME_SECONDS		: time to wait before taking the action again
# ACTION_RETRIES				: number of times to retry an action based on service status
# SERVICE_STATUS				: service status, initialized with 0 and will be populated with the right value after calling get_service_uptime function
# SERVICE_RESTARTED				: service restart flag, value 1 means service has been restarted
# SERVICE_STOPPED				: service stop flag, value 1 means service has been stopped
# FAULTED_CLUSTER_RESOURCES		: Faulted cluster resources flag, value is set after checking using functon "check_cluster_resources_state"

PIDFILE="/home/comptel/script.pid"
SERVICE_HOST_IP=172.16.121.126
SERVICE_HOST_USER=root
SERVICE_HOST_PASSWORD="P@ssw0rd"
SCRIPT_LOG_PATH=/var/log/service_based_action.log
SERVICE_UPTIME=0
SERVICE_UPTIME_EPOCH=0
CURRENT_DATE_EPOCH=$(date +%s)
SERVICE_UPTIME_DIFF_EPOCH=0
SERVICE_UPTIME_COMPARE_SECONDS=300
ACTION_LOOP_TIME_SECONDS=900
ACTION_RETRIES=6
SERVICE_NAME=postgresql.service
SERVICE_STATUS=0
SERVICE_RESTARTED=0
SERVICE_STOPPED=0
FAULTED_CLUSTER_RESOURCES=0




# Function to take an action on regular interval
# determined by the variables "ACTION_RETRIES" and "ACTION_LOOP_TIME_SECONDS"
# Below action is to do pacemaker resource cleanup
action() {
	for ((retries=1; retries<=$ACTION_RETRIES; retries++));
	do
		echo "$(date) $(hostname) [INFO] cleanup up cluster resources retry no# $retries" >> $SCRIPT_LOG_PATH;
		pcs resource cleanup 												  >> $SCRIPT_LOG_PATH;
		pcs status 															  >> $SCRIPT_LOG_PATH;
		check_cluster_resources_state
		if [ "FAULTED_CLUSTER_RESOURCES" -eq "1" ]; then
			break
		fi
		sleep $ACTION_LOOP_TIME_SECONDS;
	done
}

check_cluster_resources_state() {
	STOPPED_CLUSTER_RESOURCES=$(pcs resource show | grep -E 'Stopped|FAILED')
	if [ -z "$STOPPED_CLUSTER_RESOURCES" ]; then
		echo "$(date) $(hostname) [INFO] Cluster resources are running"				>> $SCRIPT_LOG_PATH
	else
		echo "$(date) $(hostname) [ERROR] The below cluster resources are faulted"	>> $SCRIPT_LOG_PATH
		echo "$STOPPED_CLUSTER_RESOURCES"								>> $SCRIPT_LOG_PATH
		FAULTED_CLUSTER_RESOURCES=1
	fi
}

# Function to print common messages for expected issues to happen when checking a service
# Below example is for postgresql.service running in a pacemaker cluster
service_errors() {
	echo -e "$(date) $(hostname) [ERROR] Can't get $SERVICE_NAME status, check the below: " 												>> $SCRIPT_LOG_PATH
	echo -e "$(date) $(hostname) [ERROR] 1- sshpass rpm, should be installed" 																>> $SCRIPT_LOG_PATH
	echo -e "$(date) $(hostname) [ERROR] 2- root credentials may have been changed" 														>> $SCRIPT_LOG_PATH
	echo -e "$(date) $(hostname) [ERROR] 3- SSH ECDSA key fingerprint of $SERVICE_NAME target host is not saved in /root/.ssh/known_hosts" 	>> $SCRIPT_LOG_PATH
	echo -e "$(date) $(hostname) [ERROR] 4- $SERVICE_NAME is the right name of the service" 												>> $SCRIPT_LOG_PATH
	echo -e "$(date) $(hostname) [ERROR] 5- Service Host IP may have been changed or VIP cluster resource is in FAILED state" 				>> $SCRIPT_LOG_PATH

}

# Check ability to get postgresql service details and populate service parameters
get_service_uptime() {
	UPTIME=$(sshpass -p $SERVICE_HOST_PASSWORD ssh -qn $SERVICE_HOST_USER@$SERVICE_HOST_IP systemctl show $SERVICE_NAME --property=ActiveEnterTimestamp | cut -d"=" -f 2)
	if [ -z "$UPTIME" ]; then
		service_errors
	else
		SERVICE_UPTIME=$UPTIME
		SERVICE_STATUS=$(sshpass -p $SERVICE_HOST_PASSWORD ssh -qn $SERVICE_HOST_USER@$SERVICE_HOST_IP systemctl is-active $SERVICE_NAME)
		SERVICE_UPTIME_EPOCH=$(date -d "$SERVICE_UPTIME" +%s)
		SERVICE_UPTIME_DIFF_EPOCH=$(($CURRENT_DATE_EPOCH - $SERVICE_UPTIME_EPOCH))
	fi
}

# Function to enable tracing for every command and file descriptors in the script
script_debug_log() {
	set -o errexit
	set -o nounset
	set -o pipefail
	set -o xtrace
	exec 3>&1 4>&2
	trap 'exec 2>&4 1>&3' 0 1 2 3
	exec 1>$SCRIPT_LOG_PATH 2>&1
}

# Fnction to create a logrotate in /etc/logrotate.d/
# Create a logrotate file if not existing
create_logrotate_file() {
	if [[ -f /etc/logrotate.d/service_based_action ]]; then
		echo "$(date) $(hostname) [INFO] Checking logrotate file: logrotate file exists" 			>> $SCRIPT_LOG_PATH
		echo "$(date) $(hostname) [INFO] " $(cat /etc/logrotate.d/service_based_action) 			>> $SCRIPT_LOG_PATH
	else
		echo "$(date) $(hostname) [INFO] Checking logrotate file: logrotate file doesn't exists" 	>> $SCRIPT_LOG_PATH
		echo "$(date) $(hostname) [INFO] Checking logrotate file: creating logrotate file" 			>> $SCRIPT_LOG_PATH
		cat > /etc/logrotate.d/service_based_action << END
$SCRIPT_LOG_PATH
{
    daily
    missingok
    compress
    delaycompress
    dateext
    dateformat -%d%m%Y
    size 10M
    rotate 30
}
END
	fi
}

check_service_recent_restart() {
	# Check if service status variable was populated
	if [ -z $SERVICE_STATUS ]; then
		service_errors
	elif [[ $SERVICE_STATUS == "stopped" ]]; then
		SERVICE_STOPPED=1
	elif [[ $SERVICE_STATUS == "active" ]]; then
		echo "$(date) $(hostname) [INFO] DataRefinery PostgreSQL service is running" 									>> $SCRIPT_LOG_PATH
		# Logic to be done if service is in "running" state
		if [ -z $SERVICE_UPTIME_DIFF_EPOCH ]; then
			echo "$(date) $(hostname) [ERROR] Unable to calculate postgresql service uptime epoch difference" 			>>$SCRIPT_LOG_PATH
			service_errors
		# Populate variables if service was restarted recently (time determined by SERVICE_UPTIME_COMPARE_SECONDS)
		elif [ "$SERVICE_UPTIME_DIFF_EPOCH" -lt "$SERVICE_UPTIME_COMPARE_SECONDS" ]; then
			SERVICE_RESTARTED=1
		fi
	else
		echo "$(date) $(hostname) [ERROR] PostgreSQL service is not running, service may be stopped or not existing" 	>> $SCRIPT_LOG_PATH
	fi
}


# Function for Script lock manipulation to prevent parallel runs
scrip_pid_check() {
	if [ -s $PIDFILE ] && [ $(cat $PIDFILE) == $BASHPID ]; then
		exit 1
	else
		rm -rf $PIDFILE
		echo $BASHPID > $PIDFILE
fi
}


# Main Logic
#############

# Importing default profile initials
source /etc/profile
scrip_pid_check
get_service_uptime
create_logrotate_file
#script_debug_log
check_service_recent_restart
check_cluster_resources_state

if [ "$SERVICE_RESTARTED" -eq "1" ] || [ "$FAULTED_CLUSTER_RESOURCES" -eq "1" ]; then
 	action
fi

# Remove script lock
rm -rf $PIDFILE