#!/bin/bash
# Script to assign roles to cluster nodes based on a definition in cluster.txt:
#
# - The environment is needed to find the root password of the machines
#   and to provide the environment in which to chef them
#
# - An install_type is needed; options are Hadoop, Kafka, Bootstrap or Basic
#
# - If no hostname is provided, all nodes will be attempted
#
# - if a nodename is provided, either by hostname or ip address, only
#   that node will be attempted
#
# - if a chef object is provided, e.g. role[ROLE-NAME] or
#   recipe[RECIPE-NAME], only nodes marked for that action are attempted
#
# - A node may be excluded by setting its action to SKIP
set -x
set -o errtrace
set -o errexit
set -o nounset

# We use eclamation point as a separator but it is a pain to use in strings with variables
# make it a variable to include in strings
BANG='!'
# Global Regular Expression for parsing parse_cluster_txt output
REGEX='(.*)!(.*)!(.*)'
# Knife administrative credentials
KNIFE_ADMIN="-u admin -k /etc/chef-server/admin.pem"

########################################################################
# install_machines -  Install a set of machines (will run chefit.sh if no node object for machine)
# Argument: $1 - a string of role!IP!FQDN pairs separated by white space
# Will install the machine with role $role in the order passed (left to right)
function install_machines {
  passwd=`sudo knife vault show os cobbler "root-password" --mode client | grep "root-password:" | awk ' {print $2}'`
  for h in $(sort <<< ${*// /\\n}); do
    [[ "$h" =~ $REGEX ]]
    local run_list="${BASH_REMATCH[1]}"
    local ip="${BASH_REMATCH[2]}"
    local fqdn="${BASH_REMATCH[3]}"
    if sudo knife node show $fqdn $KNIFE_ADMIN 2>/dev/null >/dev/null; then
      printf "Running chef for node $fqdn in $ENVIRONMENT run_list ${run_list}...\n"
      local SSHCMD="./nodessh.sh $ENVIRONMENT $ip"
      sudo knife node run_list set $fqdn "$run_list" $KNIFE_ADMIN
      $SSHCMD "chef-client -o '$run_list'" sudo
    else
      printf "About to bootstrap node $fqdn in $ENVIRONMENT run_list ${run_list}...\n"
      ./chefit.sh $ip $ENVIRONMENT
      sudo -E knife bootstrap -E $ENVIRONMENT -r "$run_list" $ip -x ubuntu ${passwd:+-P} $passwd $KNIFE_ADMIN --sudo <<< $passwd
    fi
  done
}

#############################################################################################
# parse cluster.txt 
# Argument: $1 - optional case insensitive match text (e.g. hostname, ipaddress, chef object)
# Returns: List of matching hosts (or all non-skipped hosts) one host per line with ! delimited fileds
# (Note: if you want to skip a machine, set its role to SKIP in cluster.txt)
function parse_cluster_txt {
  local match_text=${1-}
  local hosts=""
  while read host macaddr ipaddr iloipaddr cobbler_profile domain role; do
    shopt -s nocasematch
    if [[ -z "${match_text-}" || "$match_text" = "$host" || "$match_text" = "$ipaddr" || "$role" =~ $match_text ]] && \
       [[ ! "|$role" =~ '|SKIP' ]]; then
      hosts="$hosts ${role}${BANG}${ipaddr}${BANG}${host}.$domain"
    fi
    shopt -u nocasematch
  done < cluster.txt
  printf "$hosts"
}

##########################################
# Install Machine Stub
# Function to create basic machine representation (in parallel) if Chef does not
# already know about machine
# Runs: Chef role[Basic], Chef recipe[bcpc::default], recipe[bcpc::networking]
# Argument: $* - hosts are returned by parse_cluster_txt
function install_stub {
  printf "Creating stubs for nodes...\n"
  for h in $*; do
    [[ "$h" =~ $REGEX ]]
    local role="${BASH_REMATCH[1]}"
    local ip="${BASH_REMATCH[2]}"
    local fqdn="${BASH_REMATCH[3]}"
    sudo knife node show $fqdn $KNIFE_ADMIN 2>/dev/null >/dev/null ||  install_machines "role[Basic],recipe[bcpc::default],recipe[bcpc::networking]${BANG}${ip}${BANG}${fqdn}" &
  done
  wait
  # verify all nodes created knife node objects -- and thus installed
  local installed_hosts=$(sudo knife node list $KNIFE_ADMIN)
  for h in $*; do
    local fqdn="${BASH_REMATCH[3]}"
    egrep "(^| )$fqdn( |$)" <<< $installed_hosts || ( printf "Failed to create a node object for $fqdn\n" >&2; exit 1)
  done
}

########################################################################
# Perform Hadoop install
# Arguments: $* - hosts (as output from parse_cluster_txt)
# Method:
# * Installs stubs (create chef nodes and setup networking) for all machines in parallel
# * Set all headnode to admins
# * Assigns roles for headnodes
# * Installs headnodes sorted by role
# * Unsets all headnode from being admins
# * Installs worknodes in parallel
function hadoop_install {
  local hosts="$*"
  shopt -u nocasematch
  printf "Doing Hadoop style install...\n"
  # to prevent needing to re-chef headnodes the Hadoop code base assumes
  # all nodes and clients have been created and further that all roles
  # have been assigned before any node Chefing begins
  install_stub $(printf ${hosts// /\\n} | sort)

  printf "Assigning roles for headnodes...\n"
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    local role="${BASH_REMATCH[1]}"
    local ip="${BASH_REMATCH[2]}"
    local fqdn="${BASH_REMATCH[3]}"
    sudo knife node run_list add $fqdn "$role" $KNIFE_ADMIN &
  done

  # set the headnodes to admin for creating data bags
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": false\ns/false/true\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN || /bin/true
  done

  if printf ${hosts// /\\n} | grep -q "BCPC-Hadoop-Head"; then
    # Making sure that the run_list is updated in solr index and is available for search during chef-client run
    num_hosts=$(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | wc -l)
    while true; do
      printf "Waiting for Chef Solr to update\n"
      sleep 0.5
      roleCount=$(sudo knife search node "role:BCPC-Hadoop-Head-Namenode*" $KNIFE_ADMIN | grep '^Node Name:' | wc -l)
      rolesCount=$(sudo knife search node "roles:BCPC-Hadoop-Head-Namenode*" $KNIFE_ADMIN | grep '^Node Name:' | wc -l)
      if [[ $num_hosts -eq $rolesCount ]] || [[ $num_hosts -eq $roleCount ]]; then
        break
      fi
    done

    printf "Installing heads...\n"
    for cntr in {1..2}; do
      for m in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
        [[ "$m" =~ $REGEX ]]
        local fqdn="${BASH_REMATCH[3]}"
        # authenticate the node one by one
        vaults=$(sudo ./find_resources.rb $fqdn | tail -1)
        sudo ./node_auth.rb $vaults $fqdn
        install_machines $m
      done
   done
  fi

  # remove admin from the headnodes
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": true\ns/true/false\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN 
  done

  printf "Installing workers...\n"
  status_file=$(mktemp)
  function clean_up_status_file { 
    rm -f $status_file
  }
  trap clean_up_status_file EXIT
  for m in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Worker" | sort); do
    [[ "$m" =~ $REGEX ]]
    local fqdn="${BASH_REMATCH[3]}"
    # authenticate the node one by one
    vaults=$(sudo ./find_resources.rb $fqdn | tail -1)
    sudo ./node_auth.rb $vaults $fqdn
    install_machines $m &
  done
  wait
  failures=$(wc -l $status_file | sed 's/ .*//')
  if [[ $failures -ne 0 ]]; then
    printf "Install failed for machines:\n" > /dev/stderr
    cat $status_file > /dev/stderr
    exit 1
  fi
  clean_up_status_file
  trap - EXIT
}

###########################################################################
# Perform hadoop bootstrap install
# Arguments: $* - hosts (as output from parse_cluster_txt
# Installs BCPC-Hadoop-Head only
#
#
function bootstrap_install {
  local hosts="$*"
  shopt -u nocasematch
  printf "Doing bootstrap install...\n"
  # to prevent needing to re-chef headnodes the Hadoop code base assumes
  # all nodes and clients have been created and further that all roles
  # have been assigned before any node Chefing begins
  install_stub $(printf ${hosts// /\\n} | sort)

  printf "Assigning roles for headnodes...\n"
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    local role="role[BCPC-Hadoop-Head]"
    local ip="${BASH_REMATCH[2]}"
    local fqdn="${BASH_REMATCH[3]}"
    sudo knife node run_list add $fqdn "$role" $KNIFE_ADMIN &
  done

  # set the headnodes to admin for creating data bags
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": false\ns/false/true\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN || /bin/true
  done

  printf "Bootstrapping heads...\n"
  for c in {1..2}; do
    for m in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head"| sort); do
      [[ "$m" =~ $REGEX ]]
      local fqdn="${BASH_REMATCH[3]}"
      # authenticate the node one by one
      vaults=$(sudo ./find_resources.rb $fqdn | tail -1)
      sudo ./node_auth.rb $vaults $fqdn
      m=`echo $m|sed 's/^[^!]*!/role\[BCPC-Hadoop-Head\]!/'`
      install_machines $m
    done
  done

  # remove admin from the headnodes
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Hadoop-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": true\ns/true/false\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN
  done
}

########################################################################
# Perform Kafka install
# Arguments: $* - hosts (as output from parse_cluster_txt)
# Method:
# * Installs stubs (create chef nodes and setup networking) for all machines in parallel
# * Set all kafka headnode to admins
# * Assigns kafka roles for headnodes
# * Waits for solr index to get updated run list for search
# * Installs kafka zookeepeer headnodes sorted by role
# * Installs kafka server headnodes sorted by role
# * Unsets all headnode from being admins
function kafka_install {
  local hosts="$*"
  shopt -u nocasematch
  printf "Doing Kafka install...\n"

  install_stub $(printf ${hosts// /\\n} | sort)

  # set the headnodes to admin for creating data bags
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": false\ns/false/true\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN || /bin/true
  done

  # Setting run list for Kafka-Zookeeper and Kafka-Server head nodes that allows Solr to get updated
  # before chef-client runs and searches for nodes
  printf "Assigning roles for Kafka head nodes...\n"
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    local role="${BASH_REMATCH[1]}"
    local ip="${BASH_REMATCH[2]}"
    local fqdn="${BASH_REMATCH[3]}"
    sudo knife node run_list set $fqdn "$role" $KNIFE_ADMIN &
  done
 
  if printf ${hosts// /\\n} | grep -q "BCPC-Kafka-Head-Zookeeper"; then
    # Making sure that the run_list is updated in solr index and is available for search during chef-client run 
    num_hosts=$(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head-Zookeeper" | wc -l)
    while true; do
      printf "Waiting for Chef Solr to update\n"
      sleep 0.5
      [[ $num_hosts -eq $(sudo knife search node "role:BCPC-Kafka-Head-Zookeeper" $KNIFE_ADMIN | grep '^Node Name:' | wc -l) ]] && break
    done

    printf "Installing kafka zookeeper heads...\n"
    for m in $(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head-Zookeeper" | sort); do
      [[ "$m" =~ $REGEX ]]
      local fqdn="${BASH_REMATCH[3]}"
      # authenticate the node one by one
      vaults=$(sudo ./find_resources.rb $fqdn | tail -1)
      sudo ./node_auth.rb $vaults $fqdn
      install_machines $m
    done
  fi

  printf "Installing kafka server heads...\n"
  for m in $(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head-Server" | sort); do
    [[ "$m" =~ $REGEX ]]
    local fqdn="${BASH_REMATCH[3]}"
    # authenticate the node one by one
    vaults=$(sudo ./find_resources.rb $fqdn | tail -1)
    sudo ./node_auth.rb $vaults $fqdn
    install_machines $m
  done


  # remove admin from the headnodes
  for h in $(printf ${hosts// /\\n} | grep -i "BCPC-Kafka-Head" | sort); do
    [[ "$h" =~ $REGEX ]]
    printf "/\"admin\": true\ns/true/false\nw\nq\n" | EDITOR=ed sudo -E knife client edit "${BASH_REMATCH[3]}" $KNIFE_ADMIN
  done
}

############
# Main Below
#

if [[ "${#*}" -lt "2" ]]; then
  printf "Usage : $0 environment install_type (hostname)\n" > /dev/stderr
  exit 1
fi

ENVIRONMENT=$1
INSTALL_TYPE=$2
MATCHKEY=${3-}

shopt -s nocasematch
if [[ ! "$INSTALL_TYPE" =~ (|hadoop|kafka|bootstrap|basic) ]]; then
  printf "Error: Need install type of Hadoop, Kafka, Bootstrap or Basic\n" > /dev/stderr
  exit 1
fi
shopt -u nocasematch

if [[ ! -f "environments/$ENVIRONMENT.json" ]]; then
  printf "Error: Couldn't find '$ENVIRONMENT.json'. Did you forget to pass the environment as first param?\n" > /dev/stderr
  exit 1
fi

# Report which hosts were found
hosts="$(parse_cluster_txt $MATCHKEY)"
for h in $hosts; do
  [[ "$h" =~ $REGEX ]]
  role="${BASH_REMATCH[1]}"
  ip="${BASH_REMATCH[2]}"
  fqdn="${BASH_REMATCH[3]}"
  printf "%s\t-\t%s\n" $role $fqdn
done | sort 

if [[ -z "${hosts-}" ]]; then
  printf "Warning: No nodes found\n" > /dev/stderr
  exit 0
fi

shopt -s nocasematch
if [[ "$INSTALL_TYPE" = "Bootstrap" ]]; then
  bootstrap_install $hosts
elif [[ "$INSTALL_TYPE" = "Hadoop" ]]; then
  hadoop_install $hosts
elif [[ "$INSTALL_TYPE" = "Kafka" ]]; then
  kafka_install $hosts
elif [[ "$INSTALL_TYPE" = "Basic" ]]; then
  install_stub $(printf ${hosts// /\\n} | sort)
fi

printf "#### Install finished\n"
