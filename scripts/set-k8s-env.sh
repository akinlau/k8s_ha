#!/bin/bash 
########################################
# @Author: akinlau 
# @Date: 2019-02-21 10:55:42 
# @Last Modified by:   akinlau 
# @Last Modified time: 2019-02-21 10:55:42 
# @Website: http://www.akinlau.com 
# @Description: set k8s env
########################################
# 设置软件、脚本、镜像、配置文件存放的目录
baseDir=/root/k8s
# master和node节点ip列表
NODE_IPS=(192.168.19.16 192.168.19.17 192.168.19.18 192.168.19.19 192.168.19.20)
# 设置主机名，顺序要跟ip列表一致
HOSTS_NAME=(master1 master2 master3 node1 node2)
# 设置时间间隔用于升级内核后重启系统后继续完成后面的操作，请根据实际情况设置
interval=10
# 用户名
user="root"
# 密码
# 如果密码有特殊字符的话需要转义不然expect会报错，比如$符号，需要在$前面加个反斜杠\$
pw='xxxxxxx'

ins_expect(){
    # 安装expect用于后面做主机互信
    rpm -q expect &>/dev/null
    if [ $? -ne 0 ];then
        yum localinstall -y ${baseDir}/soft/expect/*
    fi
}

pushSshKey(){
    # 设置主机互信，这里只做单向的互信，比如在A机器上执行本脚本，那么A就可以免密码访问master1 master2 master3
    # 反过来集群机器不能免密码访问A服务器
    if [ ! -f ~/.ssh/id_rsa ];then
        ssh-keygen -t rsa -b 4096 -P '' -f /root/.ssh/id_rsa
    fi

    if [ ! -f ~/.ssh/authorized_keys ];then
        cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
    fi

    # 复制公钥到5台集群服务器上
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then
            # 测试主机是否已建立互信
            ssh -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no  ${user}@${ip} "date" &> /dev/null
            if [ $? -ne 0 ];then
            echo "复制公钥到${ip} ："
/usr/bin/expect <<-EOF
# 复制公钥
spawn ssh-copy-id ${user}@$ip
expect "yes/no" { send "yes\r" }
expect "*assword*" { send "${pw}\r" }
expect eof
EOF
            fi
        fi
    done
}

set_hostname(){
    for index in 0 1 2 3 4
    do
        ip=${NODE_IPS[${index}]}
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then
            echo "${ip} 修改主机名："
            ssh ${user}@${ip} "hostnamectl set-hostname ${HOSTS_NAME[${index}]}"
            ssh ${user}@${ip} "hostname"
        fi
    done
}

set_hosts(){
    # 生成IP到主机名的解析
    hosts="127.0.0.1 k8s.gcr.io quay.io gcr.io"
    for index in 0 1 2 3 4
    do
        hosts=${hosts}"""
${NODE_IPS[${index}]} ${HOSTS_NAME[${index}]}"""
    done


    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 $ip &>/dev/null
        if [ $? -eq 0 ];then
            echo "${ip} 修改hosts配置："
            # 这条ssh命令不稳定，有时可以，有时不行，有可能是使用了管道导致，暂时无解,所以换了下面那个命令
            #ssh  ${user}@${ip} "grep -Ev '${HOSTS_NAME[0]}|${HOSTS_NAME[1]}|${HOSTS_NAME[2]}|gcr.io' /tmp/hosts | tee /tmp/hosts"
            ssh  ${user}@${ip} "grep -Ev '${HOSTS_NAME[0]}|${HOSTS_NAME[1]}|${HOSTS_NAME[2]}|${HOSTS_NAME[3]}|${HOSTS_NAME[4]}|gcr.io' /etc/hosts > /tmp/hosts.$$;cat /tmp/hosts.$$ >  /etc/hosts;rm -f /tmp/hosts.$$"
            ssh ${user}@${ip} "echo '${hosts}' >> /etc/hosts"
            ssh ${user}@${ip} "cat /etc/hosts"
        fi
    done
}


set_sys(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
        echo "${ip} 开始设置系统参数："
        ssh -T ${user}@${ip} << EEOOFF
    # 关闭Selinux/firewalld
    systemctl status firewalld | grep inactive &>/dev/null
    if [ $? -ne 0 ];then
        systemctl stop firewalld
        systemctl disable firewalld
        echo "firewalld done!"
    else
        echo "firewalld stopped!"
    fi

    status="$(getenforce)"
    if [ "$status" != "Disabled" ];then
        setenforce 0
        sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
        echo "selinux done!"
    else
        echo "selinux stopped!"
    fi

    # 关闭交换分区
    grep swap /etc/fstab &>/dev/null
    if [ $? -eq 0 ];then
        swapoff -a
        yes | cp /etc/fstab /etc/fstab_bak
        cat /etc/fstab_bak |grep -v swap > /etc/fstab
        echo "swap done!"
    else
        echo "swap done!"
    fi

if [ ! -f /etc/sysctl.d/k8s.conf ];then
# 加载br_netfilte，不然下面执行sysctl时会报错
modprobe br_netfilter

# 设置网桥包经IPTables，core文件生成路径
cat > /etc/sysctl.d/k8s.conf << EOF
# https://github.com/moby/moby/issues/31208 
# ipvsadm -l --timout
# 修复ipvs模式下长连接timeout问题 小于900即可
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.ip_forward = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_synack_retries = 2
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.netfilter.nf_conntrack_max = 2310720
fs.inotify.max_user_watches=89100
fs.may_detach_mounts = 1
fs.file-max = 52706963
fs.nr_open = 52706963
net.bridge.bridge-nf-call-arptables = 1
vm.swappiness = 0
vm.overcommit_memory=1
vm.panic_on_oom=0
EOF

sysctl --system
echo "sysctl done!"
else
    echo "k8s.conf is exists!"
fi

    # 同步时间
    ntpdate -u ntp.api.bz
    echo "systime done!"
exit
EEOOFF
fi
done
}

self_exe(){
    grubby --default-kernel | grep 4.18 &>/dev/null
    if [ $? -ne 0 ];then
        grep set-k8s-env.sh /etc/rc.local &> /dev/null
        if [ $? -ne 0 ];then
            chmod +x /etc/rc.d/rc.local
            echo "echo yes | sh -x /root/k8s/scripts/set-k8s-env.sh >> /tmp/k8s.log" >> /etc/rc.local
        fi
    else
        grep set-k8s-env.sh /etc/rc.local &> /dev/null
        if [ $? -eq 0 ];then
            sed -i '/set-k8s-env.sh/d' /etc/rc.local
        fi
    fi
}

update_kernel(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then
            ssh ${user}@${ip} "grubby --default-kernel | grep 4.18 &>/dev/null"
            if [ $? -ne 0 ];then
                ssh ${user}@${ip} "test ! -d ${baseDir} && mkdir -p ${baseDir}"
                result=`ssh ${user}@${ip} "test ! -f ${baseDir}/soft/kernel/kernel-ml-4.18.16*.rpm && echo true"`
                if [ "${result}" == "true" ];then
                    ssh ${user}@${ip} "test ! -d ${baseDir}/soft && mkdir -p ${baseDir}/soft"
                    echo "${ip} 开始传输内核安装文件："
                    scp -r ${baseDir}/soft/kernel root@${ip}:${baseDir}/soft/
                fi
                echo "${ip} 开始更新内核:"
                ssh -T ${user}@${ip} << EEOOFF
                # ipvs依赖于nf_conntrack_ipv4内核模块,4.19包括之后内核里改名为nf_conntrack,但是kube-proxy的代码里没有加判断一直用的nf_conntrack_ipv4,所以这里安装4.18版的内核;
                yum localinstall -y ${baseDir}/soft/kernel/*.rpm
                # 将新内核设为默认grbu启动项
                grub2-set-default 0
                # 生成 grub 配置文件
                grub2-mkconfig -o /etc/grub2.cfg
                # 检查默认内核版本是否大于4.14，否则请调整默认启动参数
                grub2-editenv list
                # 检查启动的内核是否指向上面安装的内核
                grubby --default-kernel
                # docker官方的内核检查脚本建议(RHEL7/CentOS7: User namespaces disabled; add 'user_namespace.enable=1' to boot command line),使用下面命令开启
                # 可以用以下命令移除'user_namespace.enable=1'参数：
                # grubby --remove-args="user_namespace.enable=1" --update-kernel="$(grubby --default-kernel)"
                grubby --args="user_namespace.enable=1" --update-kernel="\$(grubby --default-kernel)"
                
                # 重启系统
                reboot
EEOOFF
            fi
        fi
    done
}

wait_conn(){
    ping -c1 ${ip} &>/dev/null
    while [ $? -ne 0 ]
    do
        echo "等待远程主机重启完成。。。。。。"
        sleep ${interval}
        ping -c1 ${ip} &>/dev/null
    done
}

enable_ipvs(){
    for index in 0 1 2
    do
        ip=${NODE_IPS[${index}]}
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
        echo "${ip} 启用ipvs模块："
        ssh -T ${user}@${ip} '
    # ipvs依赖于nf_conntrack_ipv4内核模块,4.19包括之后内核里改名为nf_conntrack,但是kube-proxy的代码里没有加判断一直用的nf_conntrack_ipv4,所以上面安装4.18版的内核;
    # grubby --default-kernel| grep 4.18 &>/dev/null
    # if [ $? -eq 0 ];then
        num=`lsmod | grep -c ip_vs`
        if [ $num -lt 4 ];then
            cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
# ipvs_modules="ip_vs ip_vs_lc ip_vs_wlc ip_vs_rr ip_vs_wrr ip_vs_lblc ip_vs_lblcr ip_vs_dh ip_vs_sh ip_vs_fo ip_vs_nq ip_vs_sed ip_vs_ftp nf_conntrack"
ipvs_modules="\$(ls /usr/lib/modules/\$(uname -r)/kernel/net/netfilter/ipvs|sed 's/\.ko.xz//')"
for kernel_module in \${ipvs_modules}; do
 /sbin/modinfo -F filename \${kernel_module} > /dev/null 2>&1
 if [ \$? -eq 0 ]; then
 /sbin/modprobe \${kernel_module}
 fi
done
EOF
            chmod 755 /etc/sysconfig/modules/ipvs.modules
            bash /etc/sysconfig/modules/ipvs.modules
            lsmod | grep ip_vs
        fi
    # fi'
        fi
    done
}

check_ethinfo(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then
            echo "${ip} 产品UUID:"
            ssh ${user}@${ip} "cat /sys/class/dmi/id/product_uuid"
            echo "${ip} MAC地址："
            ssh ${user}@${ip} "ip link|grep -A 1 ens160|grep link|awk '{print \$2}'"
        fi
    done
}

ins_ha(){
    for index in 0 1 2
    do
        ip=${NODE_IPS[${index}]}
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
            ssh ${user}@${ip} "test ! -d ${baseDir} && mkdir -p ${baseDir}"
            result=`ssh ${user}@${ip} "test ! -f ${baseDir}/soft/ha/keepalived*.rpm && echo true"`
            if [ "${result}" == "true" ];then
                ssh ${user}@${ip} "test ! -d ${baseDir}/soft && mkdir -p ${baseDir}/soft"
                echo "${ip} 开始传输keepalived安装文件："
                scp -r ${baseDir}/soft/ha ${user}@${ip}:${baseDir}/soft/
                echo "${ip} 开始安装keepalived："
                ssh -T ${user}@${ip} "yum localinstall -y ${baseDir}/soft/ha/*"
            else
                    result=`ssh ${user}@${ip} "rpm -q keepalived &>/dev/null && echo true"`
                    if [ "${result}" != "true" ];then
                        echo "${ip} 开始安装keepalived："
                        ssh -T ${user}@${ip} "yum localinstall -y ${baseDir}/soft/ha/*"
                    fi
            fi
        fi
    done
}

ins_docker(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
            ssh ${user}@${ip} "test ! -d ${baseDir} && mkdir -p ${baseDir}"
            result=`ssh ${user}@${ip} "test ! -f ${baseDir}/soft/docker/docker-ce-18*.rpm && echo true"`
            if [ "${result}" == "true" ];then
                echo "${ip} 开始安装docker："
                ssh ${user}@${ip} "test ! -d ${baseDir}/soft && mkdir -p ${baseDir}/soft"
                echo "${ip} 开始传输docker安装文件："
                scp -r ${baseDir}/soft/docker ${user}@${ip}:${baseDir}/soft/
                ssh -T ${user}@${ip} << EOF
                yum localinstall -y ${baseDir}/soft/docker/*
                # 编辑systemctl的Docker启动文件
                sed -i "13i ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT" /usr/lib/systemd/system/docker.service
                
                # 启动docker
                systemctl daemon-reload
                systemctl enable docker
                systemctl start docker
EOF

            else
                result=`ssh ${user}@${ip} "rpm -q docker-ce &>/dev/null && echo true"`
                if [ "${result}" != "true" ];then
                    echo "${ip} 开始安装docker："
                    ssh -T ${user}@${ip} << EOF
                    yum localinstall -y ${baseDir}/soft/docker/*
                    # 编辑systemctl的Docker启动文件
                    sed -i "13i ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT" /usr/lib/systemd/system/docker.service
                    
                    # 启动docker
                    systemctl daemon-reload
                    systemctl enable docker
                    systemctl start docker
EOF
                fi
            fi
        fi
    done
}

load_images(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
            ssh ${user}@${ip} "test ! -d ${baseDir} && mkdir -p ${baseDir}"
            result=`ssh ${user}@${ip} "test ! -f ${baseDir}/images/kube-apiserver*.tar && echo true"`
            if [ "${result}" == "true" ];then
                ssh ${user}@${ip} "test ! -d ${baseDir}/images && mkdir -p ${baseDir}/images"
                echo "${ip} 开始传输镜像："
                scp ${baseDir}/images/*.tar ${user}@${ip}:${baseDir}/images/
                echo "${ip} 开始导入镜像："
                # ssh ${user}@${ip} ls ${baseDir}/images/|while read line;do docker load -i ${baseDir}/images/${line};done
                ls ${baseDir}/images/|while read line;do ssh -n ${user}@${ip} docker load -i ${baseDir}/images/${line};done
            else
                imgs=` ssh ${user}@${ip} "docker images|wc -l"`
                if [ ${imgs} -lt 16 ];then
                    echo "${ip} 开始导入镜像："
                    # ssh ${user}@${ip} ls ${baseDir}/images/|while read line;do docker load -i ${baseDir}/images/${line};done
                    ls ${baseDir}/images/|while read line;do ssh -n ${user}@${ip} docker load -i ${baseDir}/images/${line};done
                fi
            fi
        fi
    done
}

ins_kubernetes(){
    for ip in "${NODE_IPS[@]}"
    do
        ping -c1 ${ip} &>/dev/null
        if [ $? -eq 0 ];then 
            ssh ${user}@${ip} "test ! -d ${baseDir} && mkdir -p ${baseDir}"
            result=`ssh ${user}@${ip} "test ! -f ${baseDir}/soft/kubernetes/kubeadm*.rpm && echo true"`
            if [ "${result}" == "true" ];then
                ssh ${user}@${ip} "test ! -d ${baseDir}/soft && mkdir -p ${baseDir}/soft"
                echo "${ip} 开始传输kubernetes安装文件："
                scp -r ${baseDir}/soft/kubernetes ${user}@${ip}:${baseDir}/soft/
                echo "${ip} 开始安装kubernetes："
                ssh -T ${user}@${ip} << EOF
                yum localinstall -y ${baseDir}/soft/kubernetes/*
                systemctl enable kubelet
                kubeadm version -o short
EOF
            else
                result=`ssh ${user}@${ip} "rpm -q kubeadm &>/dev/null && echo true"`
                if [ "${result}" != "true" ];then
                    echo "${ip} 开始安装kubernetes："
                    ssh -T ${user}@${ip} << EOF
                    yum localinstall -y ${baseDir}/soft/kubernetes/*
                    systemctl enable kubelet
                    kubeadm version -o short
EOF
                fi
            fi
        fi
    done
}

main(){
    ins_expect
    pushSshKey
    set_hostname
    set_hosts
    set_sys
    # self_exe
    # update_kernel
    # wait_conn
    enable_ipvs
    check_ethinfo
    ins_ha
    ins_docker
    load_images
    ins_kubernetes
}

echo -n """
注意: 
    更新完内核重启后需要再执行一次!!!
    更新完内核重启后需要再执行一次!!!
    更新完内核重启后需要再执行一次!!!
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


main
