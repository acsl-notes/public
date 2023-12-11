# Deploy a k8s cluster for dev env on a PVE host
Dec 10, 2023

## Background
We are going to deploy a k8s cluster with 1 master and 2 workers on a PVE host for dev env. The spec of the PVE host is:
| Spec | Value |
| --- | --- |
| CPU | 48 cores in 2 sockets |
| Memory | 512 GB |
| Fast Storage | 4 TB SSD with LVM-Thin |
| Slow Storage | 16 TB HDD with ZFS |

We won't use all PVE resources for the k8s cluster. THe spec of the master and workers are:

| Spec | Master | Worker |
| --- | --- | --- |
| CPU | 2 cores | 16 cores |
| Memory | 8 GB | 128 GB |
| Fast Storage | 64 GB | 1 TB |
| Slow Storage | -- | 4 TB |

The host system is Ubuntu 20.04 (minimized), and the k8s version is 1.28.4.

## Networking
The subnet our k8s cluster will use is `10.0.0.0/16`. The IP addresses of k8s nodes are:

| Node | IP Address |
| --- | --- |
| master | 10.0.190.1 |
| worker1 | 10.0.190.11 |
| worker2 | 10.0.190.12 |

## VM Configuration
The Kubernetes requires the host MUST close the swap, so we will NOT configure swap space for the VMs.

## Initialize the host environment
After configuring the VMs, we need to initialize the host environment. The steps are:
1. Disable swap.
2. Configure the kernel modules `br_netfilter` and `overlay`.
3. Configure the kernel parameters to enable IP forwarding and bridge-nf-call-iptables.
4. Install the container runtime `containerd`.
5. Install the k8s components `kubeadm`, `kubelet` and `kubectl`.

I have written a script to do these steps here: [init-k8s-host.sh](./init-k8s-host.sh).

The script will process the steps above automatically, but you need to notice that:
`The script has only been tested on Ubuntu 20.04`, if you test it on other OS, please be careful, and let me know if you find any issues.

Before running the script, you may configure the proxy environment variables if you are behind a proxy:
```bash
export http_proxy=http://<proxy>:<port>
export https_proxy=http://<proxy>:<port>
```

Furthermore, a reboot is highly recommended after running the script.

## Configure the master node
After initializing the host environment, we can configure the master node.

First of all, the proxy environment variables should be configured for the services containerd and kubelet:
```bash
# My host is behind a proxy: 10.0.170.10:7890, you should change it to your own proxy.
# The default CNI CIDR for k8s is 10.96.0.0/12, and our service subnet is 10.77.0.0/16,
# so we should add them to the NO_PROXY list.
systemctl set-environment HTTP_PROXY=http://10.0.170.10:7890
systemctl set-environment HTTPS_PROXY=http://10.0.170.10:7890
systemctl set-environment NO_PROXY="localhost,10.0.0.0/16,10.96.0.0/12,10.77.0.0/16"
systemctl daemon-reload
systemctl restart containerd
systemctl restart kubelet
```

Then, we can initialize the master node:

```bash
# Our master node IP is 10.0.190.1, we should specify it as the control-plane-endpoint for the node may have multiple IPs.
kubeadm init --service-cidr=10.96.0.0/12 --pod-network-cidr=10.77.0.0/16 --control-plane-endpoint 10.0.190.1
```

After the initialization, we can configure the kubectl for the current user:
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
```

Then, we can install the CNI plugin `calico`:
```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

## Configure the worker nodes

