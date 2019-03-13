#!/bin/bash 
########################################
# @Author: akinlau 
# @Date: 2019-01-29 13:20:27 
# @Last Modified by:   akinlau 
# @Last Modified time: 2019-01-29 13:20:27 
# @Website: http://www.akinlau.com 
# @Description: create token for dashboard
########################################
KUBE_APISERVER="https://192.168.6.204:6443"
DASHBOARD_LOGIN_TOKEN=`kubectl -n kube-system describe secret "$(kubectl get secret -n kube-system|grep dashboard-admin-token|awk '{print $1}')" | grep token: |awk '{print $NF}'`

# 设置集群参数
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=/root/k8s/scripts/dashboard.kubeconfig

# 设置客户端认证参数，使用上面创建的 Token
kubectl config set-credentials dashboard_user \
  --token=${DASHBOARD_LOGIN_TOKEN} \
  --kubeconfig=/root/k8s/scripts/dashboard.kubeconfig

# 设置上下文参数
kubectl config set-context default \
  --cluster=kubernetes \
  --user=dashboard_user \
  --kubeconfig=/root/k8s/scripts/dashboard.kubeconfig

# 设置默认上下文
kubectl config use-context default --kubeconfig=/root/k8s/scripts/dashboard.kubeconfig