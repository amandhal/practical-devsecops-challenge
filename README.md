# Practical DevSecOps Challenge README

## Overview

This repository provisions a small Docker Swarm lab on AWS using Terraform and demonstrates secure multi-host container communication across nodes. The environment consists of one **bastion** host in a public subnet, one **swarm manager** in a private subnet, and one **swarm worker** in a different private subnet, with private egress provided through a NAT gateway.

The design focuses on four goals:

- Provision infrastructure with Infrastructure as Code (Terraform).
- Secure Docker remote access with TLS so the Docker client on the bastion can manage the swarm manager safely.
- Demonstrate encrypted overlay networking across nodes.
- Use Docker Swarm service discovery so containers can reach services by DNS name.

## Architecture

### Nodes

- **Bastion host**: Publicly reachable administration jump host. It has only the Docker CLI installed and is used to run swarm and service commands remotely.
- **Node A - Swarm Manager**: Private EC2 instance running Docker Engine and acting as the swarm manager.
- **Node B - Swarm Worker**: Private EC2 instance running Docker Engine and joining the swarm as a worker.

### Network layout

- Bastion is placed in a public subnet.
- Manager and worker are placed in separate private subnets.
- Private nodes use a NAT gateway for outbound internet access.
- Security groups and subnet isolation should restrict access to only required ports between trusted hosts.

## Security model

This setup uses Docker Engine over TLS so the bastion can talk to the manager securely. Docker documents that remote engine access with TLS relies on a CA and signed client/server certificates, and secure remote access typically listens on TCP 2376 with TLS verification enabled.[1][2]

Recommended security controls for this challenge:

- Use mutual TLS for Docker client-to-daemon communication.
- Copy only the required client files to the bastion: `ca.pem`, `cert.pem`, and `key.pem`.
- Keep the Docker daemon on the manager restricted to trusted sources only.
- Do not expose swarm data-plane ports to the public internet.
- Limit SSH access to the bastion only; use AWS SSM where possible for private nodes.
- Protect private keys with strict filesystem permissions.
- Rotate certificates and destroy lab infrastructure after testing.

Docker Swarm requires specific ports between nodes: TCP 2377 for cluster management, TCP/UDP 7946 for node discovery, and UDP 4789 for overlay traffic. When encrypted overlay networks are used, IP protocol 50 (IPSec ESP) must also be allowed between swarm nodes.[3]

## Prerequisites

Before running the deployment, ensure the following are available:

- AWS credentials with permissions to create VPC, subnets, route tables, NAT gateway, EC2 instances, IAM/SSM resources, and security groups.
- Terraform installed locally.
- An SSH key pair for bastion access, if your Terraform code uses SSH.
- AWS Systems Manager Session Manager access for logging into private instances.
- A clone of this repository.

## Deployment steps

### 1. Clone the repository

```bash
git clone https://github.com/amandhal/practical-devsecops-challenge.git
cd practical-devsecops-challenge
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Apply the infrastructure

```bash
terraform apply -auto-approve
```

After apply completes, the EC2 instances and networking should be created. The manager user data installs Docker Engine and prepares TLS assets; the worker installs Docker Engine; the bastion installs the Docker CLI.

## Access the machines

Use AWS SSM to access the swarm manager and swarm worker. Use SSH to access the bastion if that is how the instance is configured.

Examples:

```bash
aws ssm start-session --target <manager-instance-id>
aws ssm start-session --target <worker-instance-id>
ssh -i <key.pem> ec2-user@<bastion-public-ip>
```

## Copy Docker TLS client certificates to bastion

The bastion needs the Docker client certificates generated on the swarm manager so it can manage the remote Docker daemon securely.

Copy these files from the manager:

- `/etc/docker/certs/ca.pem`
- `/etc/docker/certs/cert.pem`
- `/etc/docker/keys/key.pem`

Place them on the bastion under `~/.docker/`:

```bash
mkdir -p ~/.docker
chmod 700 ~/.docker
```

After copying:

```bash
chmod 644 ~/.docker/ca.pem ~/.docker/cert.pem
chmod 600 ~/.docker/key.pem
```

Add the manager hostname mapping on the bastion:

```bash
sudo vim /etc/hosts
```

Add an entry like:

```text
<swarm-manager-private-ip> swarm-manager
```

Set Docker client environment variables on the bastion:

```bash
export DOCKER_HOST=tcp://swarm-manager:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=$HOME/.docker
```

Verify remote connectivity:

```bash
docker version
docker info
```

## Initialize the swarm

Run the following on the manager node:

```bash
docker swarm init --advertise-addr <swarm-manager-private-ip>
```

Docker documents that swarm mode must be enabled before creating swarm-scoped overlay networks.[1][3]

The command prints a join token for workers. Copy the full worker join command.

## Join the worker node

Log in to the worker node and run the join command printed by the manager, for example:

```bash
docker swarm join \
  --token <worker-join-token> \
  <swarm-manager-private-ip>:2377
```

Back on the manager or from the bastion via remote Docker, verify the cluster:

```bash
docker node ls
```

## Create the encrypted overlay network

From the bastion, create an encrypted attachable overlay network:

```bash
docker network create \
  --opt encrypted \
  --driver overlay \
  --attachable \
  practical-devsecops-challenge
```

Docker states that multi-host connectivity requires swarm mode and an overlay network. It also documents `--attachable` for allowing manually started containers to join the overlay network in addition to swarm services.[1] The `--opt encrypted` option enables encrypted overlay traffic.[4][3]

## Deploy example services

### Deploy nginx on Node A (manager)

```bash
docker service create \
  --name nginx \
  --network practical-devsecops-challenge \
  --constraint 'node.hostname==<manager-hostname>' \
  nginx
```

### Deploy httpd on Node B (worker)

```bash
docker service create \
  --name httpd \
  --network practical-devsecops-challenge \
  --constraint 'node.hostname==<worker-hostname>' \
  httpd
```

Check service placement:

```bash
docker service ls
docker service ps nginx
docker service ps httpd
```

## Demonstrate service discovery and cross-node communication

Docker Swarm provides service discovery through an embedded DNS system, and services on the same swarm network can resolve each other by service name.[5][1]

Launch a temporary debugging container on the same overlay network:

```bash
docker run --rm -it \
  --network practical-devsecops-challenge \
  nicolaka/netshoot bash
```

Inside the container, test DNS-based access:

```bash
curl nginx
curl httpd
```

Expected result:

- `curl nginx` reaches the nginx service on the manager node.
- `curl httpd` reaches the httpd service on the worker node.
- Name resolution works without hardcoding container IP addresses because Swarm service discovery resolves service names on the overlay network.[5][1]

You can also inspect the network and services:

```bash
docker network inspect practical-devsecops-challenge
docker service inspect nginx
docker service inspect httpd
```

## Validation checklist

Use this checklist during the demo:

- Terraform creates bastion, manager, worker, VPC, subnets, and NAT successfully.
- Bastion can reach the Docker daemon on the manager only through TLS.
- Worker joins the swarm successfully.
- Overlay network is created with encryption enabled.
- `nginx` is scheduled on the manager.
- `httpd` is scheduled on the worker.
- A test container on the overlay network can resolve and curl both `nginx` and `httpd` by DNS name.

## Hardening recommendations

This challenge works as a lab, but these extra controls improve production safety:

- Restrict port 2376 to the bastion security group only.
- Restrict ports 2377, 7946 TCP/UDP, 4789 UDP, and ESP to manager/worker security groups only.[3]
- Prefer private DNS or Route 53 private hosted zones instead of editing `/etc/hosts` manually.
- Store certificates in AWS Secrets Manager or SSM Parameter Store instead of copying them manually where possible.
- Enable CloudWatch logging, VPC Flow Logs, and AWS CloudTrail for auditing.
- Use IAM least privilege for EC2 and SSM roles.
- Patch AMIs regularly and pin package versions in user data.
- Consider using `docker context` on the bastion to manage the TLS endpoint more cleanly.

Example `docker context` command:

```bash
docker context create swarm-manager-tls \
  --docker "host=tcp://swarm-manager:2376,ca=$HOME/.docker/ca.pem,cert=$HOME/.docker/cert.pem,key=$HOME/.docker/key.pem"
docker context use swarm-manager-tls
```

## Troubleshooting

### TLS connection fails from bastion

Check:

- `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, and `DOCKER_CERT_PATH` are set correctly.
- `ca.pem`, `cert.pem`, and `key.pem` are valid and readable.
- The manager daemon is listening on TCP 2376 with TLS enabled.
- The manager certificate SAN/CN matches the hostname or IP used by the bastion.

### Worker cannot join swarm

Check:

- Manager private IP is reachable from the worker.
- TCP 2377 is allowed between private subnets.
- The join token is current.
- Docker Engine is running on both nodes.

### Services cannot communicate across nodes

Check:

- TCP/UDP 7946 and UDP 4789 are open between swarm nodes.[3]
- IP protocol 50 is allowed when using `--opt encrypted`.[3]
- Both services are attached to the same overlay network.
- The service tasks are in `Running` state.

### DNS name does not resolve

Check:

- The test container is attached to `practical-devsecops-challenge`.
- Use service names (`nginx`, `httpd`) instead of container IDs.
- Confirm the services were created successfully and attached to the overlay network.

## Cleanup

Destroy the lab when finished:

```bash
terraform destroy -auto-approve
```

This removes the AWS infrastructure and helps reduce cost and exposure.
