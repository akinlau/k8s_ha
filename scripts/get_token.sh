#!/bin/bash 
########################################
# @Author: akinlau 
# @Date: 2019-03-04 15:14:42 
# @Last Modified by:   akinlau 
# @Last Modified time: 2019-03-04 15:14:42 
# @Website: http://www.akinlau.com 
# @Description: gen dashboard login token
########################################
kubectl -n kube-system describe secret "$(kubectl get secret -n kube-system|grep dashboard-admin-token|awk '{print $1}')" | grep token: |awk '{print $NF}'