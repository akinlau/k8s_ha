#!/bin/bash 
########################################
# @Author: akinlau 
# @Date: 2019-02-21 10:03:33 
# @Last Modified by:   akinlau 
# @Last Modified time: 2019-02-21 10:03:33 
# @Website: http://www.akinlau.com 
# @Description: install kubernetes 1.13.3 cluster
########################################
#!/bin/bash

cd ~/
 
# 创建集群信息文件
echo """
CP0_IP=192.168.19.16
CP1_IP=192.168.19.17
CP2_IP=192.168.19.18
VIP=192.168.19.21
NET_IF=ens33
CIDR=10.244.0.0/16
""" > ./cluster-info

function check_parm()
{
  if [ "${2}" == "" ]; then
    echo -n "${1}"
    return 1
  else
    return 0
  fi
}

if [ -f ./cluster-info ]; then
	source ./cluster-info 
fi

check_parm "Enter the IP address of master1: " ${CP0_IP} 
if [ $? -eq 1 ]; then
	read CP0_IP
fi
check_parm "Enter the IP address of master2: " ${CP1_IP}
if [ $? -eq 1 ]; then
	read CP1_IP
fi
check_parm "Enter the IP address of master3: " ${CP2_IP}
if [ $? -eq 1 ]; then
	read CP2_IP
fi
check_parm "Enter the VIP: " ${VIP}
if [ $? -eq 1 ]; then
	read VIP
fi
check_parm "Enter the Net Interface: " ${NET_IF}
if [ $? -eq 1 ]; then
	read NET_IF
fi
check_parm "Enter the cluster CIDR: " ${CIDR}
if [ $? -eq 1 ]; then
	read CIDR
fi

echo """
cluster-info:
  master-01:        ${CP0_IP}
  master-02:        ${CP1_IP}
  master-02:        ${CP2_IP}
  VIP:              ${VIP}
  Net Interface:    ${NET_IF}
  CIDR:             ${CIDR}
"""
echo -n 'Please print "yes" to continue or "no" to cancel: '
read AGREE
while [ "${AGREE}" != "yes" ]; do
	if [ "${AGREE}" == "no" ]; then
		exit 0;
	else
		echo -n 'Please print "yes" to continue or "no" to cancel: '
		read AGREE
	fi
done

IPS=(${CP0_IP} ${CP1_IP} ${CP2_IP})

mkdir -p ~/k8s/tls

PRIORITY=(100 50 30)
STATE=("MASTER" "BACKUP" "BACKUP")
HEALTH_CHECK=""
for index in 0 1 2; do
  HEALTH_CHECK=${HEALTH_CHECK}"""
    real_server ${IPS[$index]} 6443 {
        weight 1
        SSL_GET {
            url {
              path /healthz
              status_code 200
            }
            connect_timeout 3
            nb_get_retry 3
            delay_before_retry 3
        }
    }
"""
done

for index in 0 1 2; do
  ip=${IPS[${index}]}
  echo """
global_defs {
   router_id LVS_KUBE_MASTER
}

vrrp_instance VI_k8s_master {
    state ${STATE[${index}]}
    interface ${NET_IF}
    virtual_router_id 85
    priority ${PRIORITY[${index}]}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass UYtV9CFA
    }
    virtual_ipaddress {
        ${VIP}
    }
}

virtual_server ${VIP} 6443 {
    delay_loop 6
    lb_kind DR
    protocol TCP

${HEALTH_CHECK}
}
""" > ~/k8s/keepalived-${index}.conf
  scp ~/k8s/keepalived-${index}.conf ${ip}:/etc/keepalived/keepalived.conf

  ssh ${ip} "
    systemctl stop keepalived
    systemctl enable keepalived
    systemctl start keepalived
    kubeadm reset -f
    iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
    ipvsadm --clear
    rm -rf /etc/kubernetes/pki/"
done

echo """
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: v1.13.3
controlPlaneEndpoint: "${VIP}:6443"
apiServer:
  certSANs:
  - ${CP0_IP}
  - ${CP1_IP}
  - ${CP2_IP}
  - ${VIP}
networking:
  # This CIDR is a Calico default. Substitute or remove for your CNI provider.
  podSubnet: ${CIDR}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
""" > /etc/kubernetes/kubeadm-config.yaml

kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf ${HOME}/.kube/config

kubectl apply -f ~/k8s/calico/rbac.yaml
cat ~/k8s/calico/calico.yaml | sed "s#8.8.8.8#${CP0_IP}#g;s#10.244.0.0/16#${CIDR}#g" | kubectl apply -f -

# curl -fsSL https://raw.githubusercontent.com/Lentil1016/kubeadm-ha/1.13.0/calico/calico.yaml | sed "s!8.8.8.8!${CP0_IP}!g" | sed "s!10.244.0.0/16!${CIDR}!g" | kubectl apply -f -
# sed "s#8.8.8.8#${CP0_IP}#g;s#10.244.0.0/16#${CIDR}#g" ~/calico/calico.yaml | kubectl apply -f - 

JOIN_CMD="$(kubeadm token create --print-join-command)"

for index in 1 2; do
  ip=${IPS[${index}]}
  ssh $ip "mkdir -p /etc/kubernetes/pki/etcd; mkdir -p ~/.kube/"
  scp /etc/kubernetes/pki/ca.crt $ip:/etc/kubernetes/pki/ca.crt
  scp /etc/kubernetes/pki/ca.key $ip:/etc/kubernetes/pki/ca.key
  scp /etc/kubernetes/pki/sa.key $ip:/etc/kubernetes/pki/sa.key
  scp /etc/kubernetes/pki/sa.pub $ip:/etc/kubernetes/pki/sa.pub
  scp /etc/kubernetes/pki/front-proxy-ca.crt $ip:/etc/kubernetes/pki/front-proxy-ca.crt
  scp /etc/kubernetes/pki/front-proxy-ca.key $ip:/etc/kubernetes/pki/front-proxy-ca.key
  scp /etc/kubernetes/pki/etcd/ca.crt $ip:/etc/kubernetes/pki/etcd/ca.crt
  scp /etc/kubernetes/pki/etcd/ca.key $ip:/etc/kubernetes/pki/etcd/ca.key
  scp /etc/kubernetes/admin.conf $ip:/etc/kubernetes/admin.conf
  scp /etc/kubernetes/admin.conf $ip:~/.kube/config
  ssh ${ip} "sleep 5;${JOIN_CMD} --experimental-control-plane"
done

echo "Cluster create finished."

echo """
[req] 
distinguished_name = req_distinguished_name
prompt = yes

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_value               = CN

stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_value       = Guangdong

localityName                    = Locality Name (eg, city)
localityName_value              = Guangzhou

organizationName                = Organization Name (eg, company)
organizationName_value          = akinlau

organizationalUnitName          = Organizational Unit Name (eg, section)
organizationalUnitName_value    = sa Department

commonName                      = Common Name (eg, your name or your server\'s hostname)
commonName_value                = *.akinlau.com


emailAddress                    = Email Address
emailAddress_value              = akinlau@foxmail.com
""" > ~/k8s/tls/openssl.cnf
openssl req -newkey rsa:4096 -nodes -config ~/k8s/tls/openssl.cnf -days 3650 -x509 -out ~/k8s/tls/tls.crt -keyout ~/k8s/tls/tls.key
kubectl create -n kube-system secret tls ssl --cert ~/k8s/tls/tls.crt --key ~/k8s/tls/tls.key
kubectl apply -f ~/k8s/plugin/traefik.yaml
kubectl apply -f ~/k8s/plugin/metrics.yaml
kubectl apply -f ~/k8s/plugin/kubernetes-dashboard.yaml

echo "Plugin install finished."
echo "Waiting for all pods into 'Running' status. You can press 'Ctrl + c' to terminate this waiting any time you like."
POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
while [ "${POD_UNREADY}" != "" -o "${NODE_UNREADY}" != "" ]; do
  sleep 1
  POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
  NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
done

echo

kubectl get cs
kubectl get nodes
kubectl get pods -n kube-system

echo """
join command:
  `kubeadm token create --print-join-command`"""

echo """
Kubernetes dashboard is running at https://dashboard.akinlau.com
or https://192.168.19.20:6443/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy
Ingress is running at http://ingress.akinlau.com"""

echo """
dashboard token is:
`kubectl -n kube-system describe secret "$(kubectl get secret -n kube-system|grep dashboard-admin-token|awk '{print $1}')" | grep token: |awk '{print $NF}'`"""
