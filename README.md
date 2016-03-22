# Azure HPC Template

Deploys an HPC Cluster with head node and n compute nodes only suitable for slurm cloud bursting. The head node services are Linux Containers based on Docker.

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjordiblasco%2Fazure-hpc-cluster%2Fmaster%2Fazuredeploy.json" target="_blank">
   <img alt="Deploy to Azure" src="http://azuredeploy.net/deploybutton.png"/>
</a>
<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fjordiblasco%2Fazure-hpc-cluster%2Fmaster%2Fazuredeploy.json" target="_blank">
   <img src="http://armviz.io/visualizebutton.png"/>
</a>

1. Fill in the mandatory parameters.

2. Select an existing resource group or enter the name of a new resource group to create.

3. Select the resource group location.

4. Accept the terms and agreements.

5. Click Create.

## Accessing the cluster

Simply SSH to the master node using the DNS name _**dnsName**_._**location**_.cloudapp.azure.com, for example, my_cluster.westus.cloudapp.azure.com.

```
# ssh azureuser@my_cluster.westus.cloudapp.azure.com
```

You can log into the head node using the admin user and password specified. Once on the head node you can switch to the HPC user which will be responsible for the applications building. For security reasons the HPC user cannot login to the head node directly.
The users will stage-in and stage-out files through the data transfer service.

## Running workloads

### HPC Users

The users will submit the jobs in the local facility and some of them will be ofloaded to the cloud when required.

### Apps User
This is a special user that should be used to build and install new applications in the cloud.  This user has public key authentication configured across the cluster and can login to any node without a password. 

To switch to the HPC user.

```
azureuser@master:~> sudo su apps
azureuser's password:
apps@master:/home/apps>
```

### Shares

The master node doubles as a NFS server for the compute nodes and exports two shares, one for the HPC user home directory and one for a data disk.

The HPC users home directory is located in /share/home and is shared by all nodes across the cluster.

The master also exports a generic data share under /share/data.  This share is mounted under the same location on all compute nodes.  This share is backed by 16 disks configured as a RAID-0 volume.  You can expect much better IO from this share and it should be used for any shared data across the cluster.

### Running a SLURM job

To verify that SLURM is configured and running as expected you can execute the following.

```
apps@master:~> srun -N6 hostname
cloud4
cloud0
cloud2
cloud3
cloud5
cloud1
apps@master:~>
```

Replace '6' above with the number of compute nodes your cluster was configured with.  The output of the command should print out the hostname of each node.

### VM Sizes

#### Head Node

The master/head node only supports VM sizes that support up to 16 disks being attached, hence >= A4.

#### Compute Nodes

Compute nodes support any VM size.

### Applications
