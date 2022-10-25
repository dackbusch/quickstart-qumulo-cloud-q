#!/bin/bash -xe

cd /root
region="${Region}"
s3_region="${BucketRegion}"
stkname="${TopStackName}"
q_stkname="${QStackName}"
sc_secrets_arn="${SideCarSecretsArn}"
cluster_secrets_arn="${ClusterSecretsArn}"
software_secrets_arn="${SoftwareSecretsArn}"
protection="${TermProtection}"
qqh="./qq --host ${Node1IP}"
node_ips="${NodeIPs}"
instance_ids="${InstanceIDs}"
float_ips="${FloatIPs}"
def_password="${ClusterPwd}"
cmk="${CMK}"
req_imdsv2="${RequireIMDSv2}"
s3bkt="${BucketName}"
s3pfx="${KeyPrefix}"
serverIP=$(hostname -I | xargs)
token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
this_ec2=$(curl -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/instance-id)
sc_prov="NO"
cmk_prov="NO"
mod_FIPs="NO"
bkt_pfx="$s3bkt/$s3pfx""scripts/"
req_ver="${QClusterVersion}"
nodes_down="${MaxNodesDown}"
mod_overness="${ModOverness}"
num_azs="${NumberAZs}"
f_tput="${FlashTput}"
f_iops="${FlashIops}"                

if [[ ! -e "functions-v6.sh" ]]; then
  aws s3 cp --region $s3_region s3://$bkt_pfx"functions-v6.sh" ./functions-v6.sh
fi
source functions-v6.sh

if [ $(chkurl "google.com"; echo $?) -eq 1 ]; then
  ssmput "last-run-status" "$region" "$stkname" "BOOTED. Internet UP."
else
  ssmput "last-run-status" "$region" "$stkname" "BOOTED. Internet DOWN. VPC Endpoints required."
fi

if [ $(chkurl "trends.qumulo.com"; echo $?) -eq 1 ]; then
  ssmput "last-run-status" "$region" "$stkname" "Trends UP for software."
  no_inet="false"
else
  ssmput "last-run-status" "$region" "$stkname" "Trends DOWN for software."
  no_inet="true"
fi

ssmput "last-run-status" "$region" "$stkname" "Installing jq, nginx, aws cliv2, python3.8 and reading secrets"

if yum list installed "jq" >/dev/null 2>&1; then
  echo "jq exists"
else
  yum install -y jq
fi

if yum list installed "wget" >/dev/null 2>&1; then
  echo "wget exists"
else
  yum install -y wget
fi          

if yum list installed "awscli" >/dev/null 2>&1; then
  aws s3 cp --region $s3_region s3://$s3bkt/$s3pfx"upgrade/awscliv2.zip" ./awscliv2.zip      
  #curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  yum remove -y awscli
  unzip -q awscliv2.zip
  ./aws/install
  ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/sbin/aws   
  ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/bin/aws                        
else
  echo "aws cli v2 exists"
fi

if yum list installed "python38.x86_64" >/dev/null 2>&1; then
  echo "python 3.8 exists"
else
  amazon-linux-extras install python3.8
  rm -f /usr/bin/python3
  ln -s python3.8 /usr/bin/python3  
fi

if yum list installed "nginx.x86_64" >/dev/null 2>&1; then
  echo "nginx exists"
else
  amazon-linux-extras install nginx1
fi
systemctl start nginx

sc_username=$(getsecret "username" "$sc_secrets_arn" "$region" "false")
sc_password=$(getsecret "password" "$sc_secrets_arn" "$region" "false")
admin_password=$(getsecret "password" "$cluster_secrets_arn" "$region" "false")
software_password=$(getsecret "password" "$software_secrets_arn" "$region" "true")

IFS=', ' read -r -a newIDs <<< "$instance_ids"
term_state=$(ssmget "termination-protection" "$region" "$stkname")

if [ "$term_state" != "$protection" ]; then
  ssmput "last-run-status" "$region" "$stkname" "Updating Termination Protection. Enabled=$protection"
  stackprotect "$protection" "$region" "$stkname"

  for m in "${!newIDs[@]}"; do
    ec2protect "$protection" "$region" "${newIDs[m]}"
  done

  ec2protect "$protection" "$region" "$this_ec2"
  ssmput "termination-protection" "$region" "$stkname" "$protection"
fi

ssmput "last-run-status" "$region" "$stkname" "Checking quorum state, boot status, and stack completion"
out_quorum=0
in_quorum=0
IFS=', ' read -r -a nodeIPs <<< "$node_ips"
for m in "${!nodeIPs[@]}"; do
  until [ $(chkurl "https://${nodeIPs[m]}" "NO"; echo $?) -eq 1 ]; do
    sleep 5
    echo "Waiting for ${nodeIPs[m]} to boot"
  done
  if [ $m -eq 0 ]; then
    getqq "${nodeIPs[m]}" "qq"
  fi

  quorum=$(./qq --host ${nodeIPs[m]} node_state_get)
  if [[ "$quorum" != *"ACTIVE"* ]]; then
    (( out_quorum = out_quorum + 1 ))
  else
    (( in_quorum = in_quorum + 1 ))
  fi
done

revision=$($qqh version | grep "revision_id")
cur_ver=${revision//[!0-9.]/}

ssmput "installed-version" "$region" "$stkname" "$cur_ver"

org_ver=$(ssmget "creation-version" "$region" "$stkname")

if [ "$org_ver" == "null" ]; then
  ssmput "creation-version" "$region" "$stkname" "$cur_ver"
  org_ver=$cur_ver
fi

if [ $out_quorum -eq ${#nodeIPs[@]} ] && [ $in_quorum -eq 0 ]; then
  ssmput "last-run-status" "$region" "$stkname" "All nodes out of quorum, NEW CLUSTER"

  new_cluster="true"

  aws s3 cp --region $s3_region s3://$bkt_pfx"stack-policy.json" ./stack_policy.json
  setstackpolicy "$region" "$q_stkname" "./stack_policy.json"

  imdsv2 "$req_imdsv2" "$region" "$this_ec2"
  for m in "${!newIDs[@]}"; do
    imdsv2 "$req_imdsv2" "$region" "${newIDs[m]}"
  done

  chk=$(vercomp $req_ver "4.2.1"; echo $?)
  chk1=$(vercomp $req_ver "4.2.2"; echo $?)
  if [ $chk -eq 0 ] || [ $chk1 -eq 0 ]; then
    ssmput "last-run-status" "$region" "$stkname" "Requested version $req_ver, but deploying 4.2.0. Upgrade to 4.2.3 or newer in the future."
    req_ver=4.2.0
  fi

  if [ "$cur_ver" != "$req_ver" ]; then
    new_ver=$req_ver
  fi

  IFS=', ' read -r -a upgradeIPs <<< "$node_ips"
  IFS=', ' read -r -a upgradeIDs <<< "$instance_ids"

elif [ $in_quorum -gt 3 ]; then
  ssmput "last-run-status" "$region" "$stkname" "4 or more nodes in quorum, checking for node additions & stack cleanup"
  new_cluster="false"
  sc_done=$(ssmget "sidecar-provisioned" "$region" "$stkname")
  if [ "$sc_done" != "YES" ] && [ ${SideCarProv} == "YES" ]; then
    sc_prov="YES"
  fi

  cmk_done=$(ssmget "cmk-policy-modified" "$region" "$stkname")
  if [ "$cmk_done" != "YES" ] && [ ${SideCarProv} == "YES" ]; then
    cmk_prov="YES"
  fi

  IFS=', ' read -r -a newIPs <<< "$node_ips"
  IFS=', ' read -r -a oldIPs <<< $(ssmget "node-ips" "$region" "$stkname")
  for m in "${!newIPs[@]}"; do
    if [[ ! "${oldIPs[@]}" =~ "${newIPs[m]}" ]]; then
      upgradeIPs+=(${newIPs[m]})
    fi
  done

  IFS=', ' read -r -a oldIDs <<< $(ssmget "instance-ids" "$region" "$stkname")
  for m in "${!newIDs[@]}"; do
    if [[ ! "${oldIDs[@]}" =~ "${newIDs[m]}" ]]; then
      upgradeIDs+=(${newIDs[m]})
      ec2protect "$protection" "$region" "${newIDs[m]}"
      imdsv2 "$req_imdsv2" "$region" "${newIDs[m]}"
    fi
  done

  if [[ ! -z "$float_ips" ]]; then
    IFS=', ' read -r -a newFIPs <<< "$float_ips"
    IFS=', ' read -r -a oldFIPs <<< $(ssmget "float-ips" "$region" "$stkname")
    if [ ${#oldFIPs[@]} -eq ${#newFIPs[@]} ]; then
      for m in "${!newFIPs[@]}"; do
        if [[ ! "${oldFIPs[@]}" =~ "${newFIPs[m]}" ]]; then
          mod_FIPs="YES"
          break
        fi
      done
    else
      mod_FIPs="YES"
    fi
  fi

  if [ ${#upgradeIPs[@]} -gt 0 ]; then
    revision=$(./qq --host ${upgradeIPs[0]} version | grep "revision_id")
    add_ver=${revision//[!0-9.]/}
    add_nodes="true"
    if [ "$cur_ver" != "$add_ver" ]; then
      new_ver=$cur_ver
      cur_ver=$add_ver
    fi
    setstackpolicy "$region" "$q_stkname" "./stack_policy.json"
  fi
fi

if [ -n "$new_ver" ]; then
  aws s3 cp --region $s3_region s3://$bkt_pfx"upgrade-order.txt" ./order.txt --quiet
  IFS=", " read -r -a order <<< $(cat ./order.txt)

  for ((n=0; n<${#order[@]}+1; n++)); do
    chk=$(vercomp $new_ver ${order[n]}; echo $?)
    case $chk in
      0)  upver+=(${order[n]}); break;;
      1)  upver+=($new_ver); break;;
      2)  chk2=$(vercomp ${order[n]} $org_ver; echo $?)
          if [ $chk2 -eq 2 ]; then
            if [ $n -eq ${#order[@]} ]; then
              upver+=($new_ver)
            else
              upver+=(${order[n]})
            fi
          fi;;
    esac
  done

  for n in ${!upver[@]}; do
    sw_file="qumulo_upgrade_cloud_${upver[n]}.qimg"
    f_path="s3://"$s3bkt"/"$s3pfx"upgrade/"$sw_file
    cd /usr/share/nginx/html
    if [ -e "$sw_file" ]; then
      echo "$sw_file already downloaded"
    elif [ "$no_inet" == "true" ]; then
      aws s3api head-object --region $s3_region --bucket $s3bkt --key $s3pfx"upgrade/"$sw_file || no_file="true"
      if [ "$no_file" == "true" ]; then
        ssmput "last-run-status" "$region" "$stkname" "Software upgrade required, no Internet or no object $f_path"
        exit
      else
        aws s3 cp --region $s3_region $f_path ./$sw_file --quiet
        ssmput "last-run-status" "$region" "$stkname" "Downloading $f_path"
      fi
    else
      ssmput "last-run-status" "$region" "$stkname" "Downloading $sw_file from Trends.qumulo.com"
      wget "https://trends.qumulo.com/data/download/$sw_file?access_code=$software_password" --output-document=$sw_file --quiet
    fi
    cd /root

    ssmput "last-run-status" "$region" "$stkname" "Upgrading unconfigured nodes to ${upver[n]}"

    upgrade_url=http://$serverIP/qumulo_upgrade_cloud_${upver[n]}.qimg

    chk=$(vercomp $cur_ver "4.1.4"; echo $?)
    chk1=$(vercomp $cur_ver "4.1.0.1"; echo $?)

    if [ $chk -eq 2 ]; then
      up_set=unconfigured_upgrade_config_set
      up_stat=unconfigured_upgrade_status
    else
      up_set=upgrade_config_set
      up_stat=upgrade_status
    fi

    for m in "${!upgradeIPs[@]}"; do
      if [ $m -eq 0 ] && ([ $chk -eq 2 ] || [ $chk1 -eq 1 ]); then
        getqq "${upgradeIPs[m]}" "qqu"
      fi
      ./qqu --host ${upgradeIPs[m]} $up_set --path "$upgrade_url" --target "prepare" &
    done

    for m in "${!upgradeIPs[@]}"; do
      until ./qqu --host ${upgradeIPs[m]} $up_stat --monitor | grep -q "UPGRADE_PREPARED"; do
        sleep 5
        echo "Waiting for Upgrade Prep ${upgradeIPs[m]}"
      done
      echo "Upgrade prepared ${upgradeIPs[m]}"
    done

    for m in "${!upgradeIPs[@]}"; do
      ./qqu --host ${upgradeIPs[m]} $up_set --path "$upgrade_url" --target "arm" &
    done
   
    for m in "${!upgradeIPs[@]}"; do
      while [ "${upver[n]}" != "$cur_ver" ]; do
        revision=$(./qqu --host ${upgradeIPs[m]} --timeout 5 version | grep "revision_id") || revision="rebooting"
        cur_ver=${revision//[!0-9.]/}
        sleep 5
      done
      echo "Node ${upgradeIPs[m]} upgraded to $cur_ver"
    done
    ssmput "installed-version" "$region" "$stkname" "$cur_ver"
    sleep 10
  done
fi

if [ "$new_cluster" == "true" ]; then
  ip_list="$node_ips"
  primary_list=${ip_list//,/ }

  getqq "${Node1IP}" "qq"

  ssmput "last-run-status" "$region" "$stkname" "Forming first quorum and configuring cluster"

  if [ "$num_azs" == "1" ]; then
    maxd=""
  else
    maxd="--max-node-failures $nodes_down"
  fi

  $qqh cluster_create --cluster-name ${QClusterName} --admin-password $def_password --accept-eula --host-instance-id $def_password $maxd --node-ips $primary_list

  until $qqh node_state_get | grep -q "ACTIVE"; do
    sleep 5
    echo "Waiting for Quorum"
  done
  echo "First Quorum formed"

  sc_prov="${SideCarProv}"
  cmk_prov="${SideCarProv}"
  
  cluster_id=$($qqh node_state_get | grep "cluster_id" | tr -d '",')
  uuid=${cluster_id//"cluster_id: "/}

  ssmput "uuid" "$region" "$stkname" "$uuid"
  ssmput "node-ips" "$region" "$stkname" "$node_ips"
  ssmput "creation-number-AZs" "$region" "$stkname" "$num_azs"
  ssmput "max-nodes-down" "$region" "$stkname" "$nodes_down"

  $qqh login -u admin -p $def_password
  $qqh audit_set_cloudwatch_config --enable --log-group-name /qumulo/$q_stkname --region $region
  if [[ ! -z "$float_ips" ]]; then
    $qqh network_mod_network --network-id 1 --floating-ip-ranges $float_ips
    ssmput "float-ips" "$region" "$stkname" "$float_ips"
  fi
  $qqh change_password -o $def_password -p $admin_password

elif [ "$add_nodes" == "true" ]; then
  ssmput "last-run-status" "$region" "$stkname" "Quorum already exists, adding nodes to cluster"

  $qqh login -u admin -p $admin_password

  if [[ ! -z "$float_ips" ]]; then
    delim=""
    halfFloatIPs=""
    for m in "${!newFIPs[@]}"; do
      if [ $m -lt 40 ]; then
        halfFloatIPs="$halfFloatIPs$delim${newFIPs[m]}"
        delim=", "
      fi
    done
    $qqh network_mod_network --network-id 1 --floating-ip-ranges $halfFloatIPs
  fi

  $qqh add_nodes --node-ips ${upgradeIPs[@]}
  until ./qq --host ${upgradeIPs[0]} node_state_get | grep -q "ACTIVE"; do
    sleep 5
    echo "Waiting for Quorum"
  done
  echo "Quorum formed"
  ssmput "node-ips" "$region" "$stkname" "$node_ips"
  if [[ ! -z "$float_ips" ]]; then
    $qqh network_mod_network --network-id 1 --floating-ip-ranges $float_ips
    ssmput "float-ips" "$region" "$stkname" "$float_ips"
  fi

  if [ "$mod_overness" == "YES" ]; then
    ssmput "last-run-status" "$region" "$stkname" "REQUIRED: manually increase protection for 2 node failure"
    ssmput "max-nodes-down" "$region" "$stkname" "$nodes_down"
  fi

elif [ "$mod_FIPs" == "YES" ]; then
  ssmput "last-run-status" "$region" "$stkname" "Quorum already exists, no nodes to add, modifying floating IPs"
  $qqh login -u admin -p $admin_password
  $qqh network_mod_network --network-id 1 --floating-ip-ranges $float_ips
  ssmput "float-ips" "$region" "$stkname" "$float_ips"
fi

if [ "$sc_prov" == "YES" ]; then
  ssmput "last-run-status" "$region" "$stkname" "Provisioning Sidecar info on Cluster"

  $qqh login -u admin -p $admin_password
  $qqh auth_add_user --name $sc_username --primary-group Guests -p "$sc_password"
  $qqh auth_create_role --role $sc_username --description "Qumulo Sidecar User for AWS"
  $qqh auth_modify_role --role $sc_username -G PRIVILEGE_ANALYTICS_READ
  $qqh auth_modify_role --role $sc_username -G PRIVILEGE_CLUSTER_READ
  $qqh auth_modify_role --role $sc_username -G PRIVILEGE_FS_ATTRIBUTES_READ
  $qqh auth_modify_role --role $sc_username -G PRIVILEGE_NETWORK_READ
  $qqh auth_assign_role --role $sc_username --trustee $sc_username

  ssmput "sidecar-provisioned" "$region" "$stkname" "YES"
fi

if [ "$cmk_prov" == "YES" ] && [ -n "$cmk" ]; then
  ssmput "last-run-status" "$region" "$stkname" "Applying CMK policy"
  aws s3 cp --region $s3_region s3://$bkt_pfx"cmk-policy-skeleton.json" ./add_policy.json
  modcmkpolicy "$cmk" "$region" "$stkname" "QSIDECARSTACK" "CloudQStack" "DiskRecoveryLambda"
  ssmput "cmk-policy-modified" "$region" "$stkname" "YES"
fi

ssmput "last-run-status" "$region" "$stkname" "Tagging EBS volumes & updating gp3 IOPS/Tput if applicable"
tagvols "newIDs" "$region" "$q_stkname" "$f_iops" "$f_tput"

ssmput "instance-ids" "$region" "$stkname" "$instance_ids"
ssmput "last-run-status" "$region" "$stkname" "Shutting down provisioning instance"
