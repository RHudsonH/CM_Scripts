#!/bin/bash
################################################################################
## Script: sync_users.sh                                                      ##
## By: Hudson Hallenbeck                                                      ##
## Last Modified: 9 August 2022                                               ##
##                                                                            ##
## Description:                                                               ##
## This script should be run on a Bright Cluster Manager Headnode             ##
##                                                                            ##
## This script takes and Active Directory username, gathers information about ##
## the user and synchronizes that user with the local OpenLDAP server.        ##
##                                                                            ##
## Presently this script does not make any acutal changes. Once all of the    ##
## logic is working we'll begin by giving the user commands to run. Only      ##
## once that functionality is working well will we attempt to make actual     ##
## changes on the server.                                                     ##
##                                                                            ##
## To Do:                                                                     ##
## 1. Add dry run option.                                                     ##
## 2. Deal with the case that the AD user doesn't exist.                      ##
## 3. Make sure group name and gid are the ame from AD to OpenLDAP            ##
##                                                                            ##
## Caveats:                                                                   ##
## 1. This script does not test to see if a user is in OpenLDAP groups that   ##
##    they don't belong in. For instance if a user has been removed from a    ##
##    group in AD.                                                            ##
################################################################################

name=""             # Initialize the variable
safe_to_add=false   # Set initial value for sanity
verbosity=0         # No unecessary output by default

# A little useage help
help() {
  echo "Sync user to local OpenLDAP server based on AD details"
  echo
  echo "Synopsis: $0 -u <user_name> [-h|-v]"
  echo "Options:"
  echo "u     Username to be included in OpenLdap"
  echo "v     Prints a bunch of garbage you usually don't need."
  echo "      May be called more than once for increasing"
  echo "      amounts of garbage."
  echo "h     Display this message and exit"
}

# Print Help and die
error_out() {
  help
  exit 1
}

# Determine if a given user already exists in OpenLDAP
# Return Values:
#   0: The User does not exist in OpenLDAP
#   1: The Username exists in OpenLDAP but
#      has a different UID number.
#   2: The UID exists in OpenLDAP but has
#      a different Username.
#   3: The User exists in OpenLDAP with 
#      the same Username and UID nubmer.
user_in_openldap() {
  let retval=0
  # Get raw list of users
  cmsh_userslist=$(cat <(cmsh -c "user; list -f name:0,id:0"))

  # Create an array out of those users
  declare -A cmsh_existing_users
  while IFS= read -r line; do
    key=$(echo $line | awk '{print $1}')
    value=$(echo $line | awk '{print $2}')
    cmsh_existing_users[${key}]=${value}
  done <<< ${cmsh_userslist}

  if [[ "${!cmsh_existing_users[@]}" =~ "${user_name}" ]]; then
    let "retval+=1" # Turn on the 1s bit
  fi                                    

  if [[ "${cmsh_existing_users[@]}" =~ "${user_uid}" ]]; then
    let "retval+=2" # Turn on the 2s bit.
  fi                                    
  echo $retval
}

ldap_group_member_list() {
  group=$1
  member_list=$(cat <(cmsh -c "group; show $group" | grep Members | awk '{print $2}' | awk -F'[[,]' '{print $1 $2}'))
  echo ${member_list}
}

user_name_set() {
  # Ensure we have a user name
  if [ -z ${name} ]; then
    echo "Username to synchronize:"
    read name
    user_name_set  # Recursion is fun!
  fi
}

# Process command line arguments
while getopts ":dhu:v" option; do
  case ${option} in
    # Print Help and exit
    d)
      DRY_RUN=true
      ;;
    h)
      help
      exit
      ;;
    # Provide the username to be sychronized
    u)
      name=${OPTARG}
      ;;
    # Turn on verbosity
    v)
      let verbosity+=1
      ;;
    # Fail on missing argmuents
    :)
      echo "Error: -${OPTARG} requires an argument."
      error_out
      ;;
    # Unknown options
    *)
      error_out
      ;;
  esac
done

# if we didn't get a username, ask for one.
user_name_set

# Get the users info as presented in sss
info=`id ${name}`
#echo "raw: ${info}"

# Colate the info.
user_field=$(echo $info | cut -f1 -d " ")
primarygroup_field=$(echo $info | cut -f2 -d " ")
grouplist_field=$(echo $info | cut -f3- -d " " )

# Process the Users name and uid
user_info=$(echo ${user_field} | awk -F'[=()]' '{print $2,$3}')
user_name=$(echo ${user_info} | awk '{print $2}')
user_uid=$(echo ${user_info} | awk '{print $1}')

# Process the Users group and gid
primarygroup_info=$(echo ${primarygroup_field} | awk -F'[=()]' '{print $2,$3}')
primarygroup_name=$(echo ${primarygroup_info} | awk '{print $2}')
primarygroup_gid=$(echo ${primarygroup_info} | awk '{print $1}')


# Process the Groups list
grouplist_info=$(echo ${grouplist_field} | cut -f2 -d '=')

# Loop through the list of groups an tokenize them
declare -A grouplist
IFS=','
for group in $grouplist_info; do
  key=$(echo $group | awk -F'[()]' '{print $2}')   #' This comment just fixes the linter error
  value=$(echo $group | awk -F'[()]' '{print $1}') #' This comment just fixes the linter error
  if [[ ${key} == ${primarygroup_name} ]]; then
	  continue
  fi
  grouplist[${key}]=${value}
done
           

# Output the id data for visual confirmation.
if [ $verbosity -gt 0 ]; then
  echo "VERBOSITY: ${verbosity}"
  echo "User:"
  echo "  User Name = ${user_name}"
  echo "  User Id Number = ${user_uid}"
  echo "Primary Group:"
  echo "  Group Name: ${primarygroup_name}"
  echo "  Group Id Number: ${primarygroup_gid}"
  echo "Additional Groups:"
  for gi in "${!grouplist[@]}"; do
    echo "  $gi: ${grouplist[$gi]}"
  done
  echo ""
fi

# Now we start to query CMSH
user_exists=$(user_in_openldap)
case $user_exists in
  "0") # The user doesn't exist in OpenLDAP and should be added.
    safe_to_add=true
    ;; 
  "1") # The Username is found in OpenLDAP but has a different UID
    safe_to_add=false
    echo "ERROR: This username was found in OpenLDAP but has an unexpected UID. The user will need to be manually synced."
    exit 1
    ;;
  "2") # The UID is found in OpenLDAP but with a different UserName.
    safe_to_add=false
    echo "ERROR: This user's UID is already in use in OpenLDAP by a user with a different name. The user will need to be manually synced."
    exit 1 
    ;;
  "3") # The Username/UID combination is already present.
    safe_to_add=false
    ;;
  *)
    safe_to_add=false
    error_out
    ;;
esac

cmsh_groups=$(cat <(cmsh -q -c "group; list -f name:0,id:0"))

# Assign these groups to an array.
declare -A cmsh_existing_groups
while IFS= read -r line; do
  key=$(echo $line | awk '{print $1}')
  value=$(echo $line | awk '{print $2}')
  cmsh_existing_groups[${key}]=${value}
done <<< ${cmsh_groups}

# Compare AD groups to existing groups in OpenLDAP
declare -A add_groups
for ad_group in "${!grouplist[@]}"; do
  for ol_group in "${!cmsh_existing_groups[@]}"; do
    # User should be in this group. Are they already in it?
    if [ "$group_list[${ad_group}]" = "$cmsh_existing_groups[${ol_group}]" ]; then
      member_list=$(ldap_group_member_list "$ol_group")
      if [[ ! $member_list == *"$user_name" ]]; then
        # User is not already a member of this OpenLDAP Goup and should be added.
        if [ $verbosity -gt 0 ]; then
          echo "${user_name} should be added to $cmsh_existing_groups[${ol_group}]"
        fi
        add_groups+="$cmsh_existing_groups[$ol_group]"
      else
        if [ $verbosity -gt 0 ]; then
          echo "$user_name IS ALREADY IN $cmsh_existing_groups[${ol_group}]"
        fi
      fi
    fi
  done
done

# Output cmsh data for visual confirmation
if [ $verbosity -gt 0 ]; then
  echo ""
  echo "Existing Groups in OpenLDAP:"
  for gi in "${!cmsh_existing_groups[@]}"; do
    echo " $gi: ${cmsh_existing_groups[$gi]}"
  done
fi

if [ $safe_to_add = true  ]; then
  if [ $verbosity -gt 0 ]; then
    echo "To add this user to OpenLDAP issue the following command:"
  fi
  if [[ $DRY_RUN = true ]]; then
    echo "cmsh -c \"user; add ${user_name}; set id ${user_uid}; commit\""
  else
    cmsh -c "user; add ${user_name}; set id ${user_uid}; commit"
  fi
else
  echo "WARNING: This user is marked as unsafe to add."
  echo "This is most likely because the user already exists in OpenLDAP"
fi

for add_group in $add_groups; do
  add_group="$(echo $add_group | sed 's/\]//;s/\[//' )"  # This removes the [braces] from the value.
  if [ ! $add_group = "" ]; then
    if [ $verbosity -gt 0 ]; then
      echo "Looks like $user_name should be added to $add_group"
      echo "To make this happen issue the following command:"
    fi
    if [[ $DRY_RUN = true ]]; then
      echo "cmsh -q -c \"group; use ${add_group}; append members $user_name; commit\""
    else
      cmsh -q -c "group; use $add_group; append members $user_name; commit"
    fi
  fi
done