#!/bin/bash

# This script used to install and configure the Kubernetes Master on a new server.
# This script is tested on Ubuntu 22.04.

# Check if the script is running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check if swap is disabled
if [[ $(swapon --show) ]]; then
    echo "Swap is enabled. Kubernetes requires swap to be disabled."
    echo "This script will disable swap for you, please make sure you have enough RAM to run your applications."
    echo "Do you want to continue? (y/n)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
        echo "Disabling swap..."
        swapoff -a
        sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab
        echo "Swap disabled."
    else
        echo "Swap is not disabled. Exiting..."
        exit 1
    fi
fi

# Load overlay and br_netfilter kernel modules
echo "Loading overlay and br_netfilter kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Check if the br_netfilter module is loaded
if [[ ! $(lsmod | grep br_netfilter) ]]; then
    echo "br_netfilter module is not loaded. Exiting..."
    exit 1
fi

# Check if the overlay module is loaded
if [[ ! $(lsmod | grep overlay) ]]; then
    echo "overlay module is not loaded. Exiting..."
    exit 1
fi

# Configure kernel parameters
echo "Configuring kernel parameters..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Apply kernel parameters
echo "Applying kernel parameters..."
sysctl --system

# Check if the iptables rule is set
if [[ ! $(sysctl net.bridge.bridge-nf-call-iptables) ]]; then
    echo "net.bridge.bridge-nf-call-iptables is not set. Exiting..."
    exit 1
fi

# Check if the ip6tables rule is set
if [[ ! $(sysctl net.bridge.bridge-nf-call-ip6tables) ]]; then
    echo "net.bridge.bridge-nf-call-ip6tables is not set. Exiting..."
    exit 1
fi

# Check if the ip_forward rule is set
if [[ ! $(sysctl net.ipv4.ip_forward) ]]; then
    echo "net.ipv4.ip_forward is not set. Exiting..."
    exit 1
fi

# Install containerd
# https://github.com/containerd/containerd/blob/main/docs/getting-started.md
echo "Installing containerd..."

# We use 1.6.25 here
# You can find the latest version here:
#   https://github.com/containerd/containerd/releases
wget -O containerd.tar.gz https://github.com/containerd/containerd/releases/download/v1.6.25/containerd-1.6.25-linux-amd64.tar.gz
tar -xvz -C /usr/local -f containerd.tar.gz

# Download and apply service script
wget -O  /usr/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
systemctl daemon-reload
systemctl enable --now containerd

# Download and install runc
# https://github.com/opencontainers/runc/releases
wget  https://github.com/opencontainers/runc/releases/download/v1.1.10/runc.amd64
install -m  755 runc.amd64 /usr/local/sbin/runc

# Download and install CNI plugins
# https://github.com/containernetworking/plugins/releases
wget -O cni-plugins.tgz https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
mkdir -p /opt/cni/bin
tar -xzv -C /opt/cni/bin -f ./cni-plugins.tgz

# Generate default config
mkdir -p /etc/containerd
/usr/local/bin/containerd  config default  > /etc/containerd/config.toml

# Enable the systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Start containerd
systemctl restart containerd

# Check if containerd is running
if [[ ! $(systemctl is-active containerd) ]]; then
    echo "containerd start failed."
    echo "Please check the logs and try again."
    echo "    To check the logs run: journalctl -u containerd"
    echo "Exiting..."
    exit 1
fi

# Install crictl that is required for kubeadm
# https://github.com/kubernetes-sigs/cri-tools/releases/
echo "Installing crictl..."
wget -O crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz
tar -xzv -C /usr/local/bin -f crictl.tar.gz

# Install kubeadm, kubelet and kubectl
DOWNLOAD_DIR="/usr/local/bin"

RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
ARCH="amd64"
cd $DOWNLOAD_DIR
curl -L --remote-name-all https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/{kubeadm,kubelet}
chmod +x {kubeadm,kubelet}

RELEASE_VERSION="v0.16.2"
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service
mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Install kubectl
# https://kubernetes.io/docs/tasks/tools/#kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/bin/

systemctl enable --now kubelet

# Install Prerequirements for kubeadm init
apt install -y ethtool ebtables socat conntrack

echo "kubeadm is ready to use."
echo "Please run 'kubeadm init' to initialize the Kubernetes master."
echo "After that you can join the worker nodes using the command provided by kubeadm init."
echo ""
echo "kubeadm will pull the required images using the containerd runtime. If you are behind a proxy, you need to configure proxy for containerd:"
echo "    systemctl set-environment HTTP_PROXY=http://<proxy>:<port>"
echo "    systemctl set-environment HTTPS_PROXY=http://<proxy>:<port>"
echo "    systemctl set-environment NO_PROXY=localhost,<exclude_items>"
echo "    systemctl daemon-reload"
echo "    systemctl restart containerd"
echo "    systemctl restart kubelet"

echo ""
echo "--------"
echo ""
echo "The default CNI CIDR is 10.96.0.0/12, This subnet should be included in the exclude_items of NO_PROXY."
echo "To change the default CNI CIDR, please run 'kubeadm init --service-cidr=<CIDR>'"
echo "The POD CIDR (--pod-network-cidr) also should be included in the exclude_items of NO_PROXY."
echo ""
echo "For example:"
echo ""
echo "systemctl set-environment NO_PROXY=\"localhost,10.0.0.0/16,10.96.0.0/12,10.77.0.0/16\""
echo "systemctl daemon-reload"
echo "systemctl restart containerd"
echo "systemctl restart kubelet"
echo "kubeadm init --service-cidr=10.96.0.0/12 --pod-network-cidr=10.77.0.0/16"
echo ""
echo "--------"
echo ""
echo "To obtain the join command, please run 'kubeadm token create --print-join-command' on the master node."
echo "The node that joins the cluster may meet NotReady status. This is because the CNI plugin (Proxy) is not installed."
echo "To install the CNI plugin, here is an example about how to install Flannel:"
echo "    1. Download the Flannel YAML file:"
echo "        wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
echo "    2. Edit the YAML file and change the podSubnet to the CIDR you specified when running kubeadm init."
echo "        sed -i 's/10\.244\.0\.0\/16/<YOUR SUBNET CIDR>/g' kube-flannel.yml"
echo "    3. Apply the YAML file:"
echo "        kubectl apply -f kube-flannel.yml"
echo "The default CNI CIDR is 10.244.0.0/16, If your CNI CIDR is the same as the default one, you can skip step 2, or execute the following command directly:"
echo "    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
echo ""
echo "--------"
echo ""
echo "To check the status of the cluster, please run 'kubectl get nodes -o wide'"