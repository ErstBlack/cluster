# Design

This design is still being developed and researched, and requirements are still being gathered. Anything here may change, at any level. It records the decisions made so far. It describes concepts, not tools, so it stays true when a tool is replaced. Known gaps are tracked in GitHub issues, not here. Testing strategy is out of scope.

## Purpose

The system turns independent machines at an edge site into one cluster that runs containers and virtual machines. Each run lasts 24 to 48 hours. The goal is fully air-gapped sites, and each site stands alone. A site has anywhere from 3 to 100+ nodes, a mix of physical and virtual, and each node starts on its own with no orchestrator.

## Principles

- Each part has as few responsibilities as possible, ideally one. Side effects are kept to a minimum or removed.
- A layer hides how it works and offers one interface to the layer above. It reaches only the layers next to it. Breaking this needs a stated reason.
- The Kubernetes API is a hard line. Anything above it sees only the API. Exceptions are made case by case, where a benefit is shown.
- Logging, health, trust and secrets, and time cut across every part. The design keeps them cheap to add.

## Layers

These layers are a tentative starting point, not a fixed design. Layers may be added, merged or removed as the design develops.

Hardware is the floor. The disk image and the site config come from outside the layers, between runs.

1. Node: one machine on its own. It hides hardware differences, the OS, disk encryption and how the node finds its address. It runs on the hardware from the disk image. It offers a name, an address, encrypted scratch, hardware virtualization, and the site config in memory.
2. Cluster: formation (the election, the stable address and admission), Kubernetes, and the VM add-on. It hides roles, which node bootstraps, the stable address, join credentials, which Kubernetes distribution runs, and how VMs run. It meets the node layer at files on the node. It offers the Kubernetes API, including VM types, with the run's declared workloads stored as delivered and each node's hardware visible.
3. Platform services: whatever applies the declared workloads, and any UI for changes during a run. It hides how declarations become running workloads. It sees only the Kubernetes API.

- Each layer below the Kubernetes API reads its own part of the site config. Anything above the API gets its part through the API.
- Anything that needs direct access to a node belongs in the cluster layer.
- Parts inside a layer still meet at contracts, so each one stays replaceable.
- No layer reaches past its neighbour.

## Responsibilities

Each line is one part: what it does, then what it offers the layer above. Like the layers, this list is tentative. "Deferred and open" lists what has no owner yet.

### Node

- Run the OS from the disk image. Offers a running machine with hardware virtualization.
- Read the site config from where it was delivered. Offers the config at a known path in memory.
- Give itself a random name each boot. Offers the name.
- Give itself an address on the site network, which the site config names apart from the stable address. Offers the address.
- Encrypt scratch with a key held only in memory. Offers an encrypted path.

### Cluster

- Elect each node's role and the bootstrap node. Offers the role and bootstrap in a file.
- Hold the stable address among the control-plane nodes. Offers the address other nodes join through.
- Admit nodes. Turn the run's secret into separate credentials for the election, workers and control-plane nodes, and send one only to an endpoint that proves it holds the run's certificate authority. Offers the credentials to the election and to Kubernetes.
- Run Kubernetes on each node in its elected role. Offers the Kubernetes API.
- Run VMs through the VM add-on. Offers VM types in the API.
- Show each node's hardware in the API. Offers it on each node's entry.
- Store the run's declared workloads in the API as delivered, without reading them. Offers them to platform services.
- Keep the clocks in step, as Config delivery describes. Offers synced time on every node.

### Platform services

- Apply the run's declared workloads, retrying until the API accepts each one. Kubernetes keeps them running after that. Offers the running workloads.

## Runs

- Each run forms a fresh cluster from the nodes that are powered on. Nothing about the cluster survives shutdown.
- The size of a site, and whether it grows or shrinks, changes only between runs. So do upgrades.
- A run's workloads are declared in the data delivered when it starts, and the cluster applies them. Nobody needs to log in.

## Nodes

- Every node boots the same image. Any node can take any role, and no node has a fixed one.
- Minimum hardware: x86_64, UEFI with Secure Boot, hardware virtualization, and 16 GB of RAM. 32 GB is typical. Virtual nodes need nested virtualization. A TPM is not required.
- Other hardware, such as accelerators, extra disks or more capacity, varies. The cluster shows what each node has, and workloads ask for what they need.
- The image holds the OS, the platform software and preloaded public images. It holds no secrets and no site data, and nothing writes to it during a run.
- To upgrade a node, it is re-imaged between runs, never patched. A separate imaging step writes the image to the node's local disk, and the node boots from that disk.

## Data protection

- Data loaded onto a node and data written during a run are encrypted.
- A node's scratch space is encrypted with a random key held only in memory, so powering off makes it unreadable.
- Data that must outlive a run leaves the node before shutdown.

## Cluster formation

- The nodes elect roles among themselves. Up to 3 become control-plane nodes, and one of those bootstraps the cluster. If the bootstrap node dies before another server has joined, the others elect again without it.
- Control-plane nodes also run workloads. A fixed share of their CPU and RAM is reserved for the control plane and the system. At large sites, an operator can dedicate some nodes to control-plane work only.
- The control plane is fixed at formation. Nodes that arrive later join as workers. A node that reboots during a run joins again as a new worker, so a rebooted control-plane node counts as lost. A lost control-plane node is not replaced, and losing the control plane ends the run.

## Stable endpoint

- The control-plane nodes hold one stable address, and other nodes join through it.
- Only the elected control-plane nodes take part in moving that address between them.

## Admission

- In scope: a device on the site network that has no secret. It must not be able to join, influence the election, or gain anything by taking the stable address.
- Each run has a new shared site secret, delivered with the site config. It authenticates both the election and the join. Worker nodes and control-plane nodes get separate credentials.
- A node sends its credential only to an endpoint that proves it holds the run's certificate authority.

## Config delivery

- Every node at a site gets the same config, which holds only the values that apply to the whole site. Each node works out the rest at boot.
- Time: if the site config names a time source, nodes follow it. Otherwise the elected bootstrap node serves time for the run.

## Workloads and platform services

- Containers run as cluster workloads. VMs run through a VM add-on on the same API.
- Compose files are an input format that is converted between runs, when the site config is written. They are never run as-is on a node.
- The platform runs only the cluster, the VM add-on, and whatever applies the declared workloads. There is no third-party management UI.

## Non-goals

- Sites with fewer than 3 nodes.
- A cluster that persists across runs.
- Patching nodes in place.
- Running workloads on a node outside the cluster.
- CPU architectures other than x86_64.

## Deferred and open

Everything the design has not yet decided, does not yet know, or has not yet given an owner is listed here and nowhere else. Each item has an epic. Until logging, health, and trust and secrets have an owner, each layer handles its own share of them.

- Whether the workloads are ours, other vendors', or both (#99).
- Logging (#100).
- Health (#101).
- Trust and secrets (#102). Admission holds the cluster's share.
- Storage, including whether a site needs distributed storage and what it would provide. Booting nodes over the network from a site server would be considered with it (#103).
- Networking (#104).
- Loading data onto nodes when a run starts and off them when it ends, including how data that must outlive a run leaves (#105).
- Where container images, charts and VM images come from for each run (#106).
- Restarting a failed node's VMs on another node (#107).
- Repairing a lost control plane (#108).
- Changes during a run. If they are allowed, they come through a UI this project provides, above the Kubernetes API (#109).
- Translating Docker-specific assumptions in compose files (#110).
- Authenticating network links (#111).
- An attacker who holds a copy of the site config. Hardware identity per machine is the candidate defence (#112).
- A central manager for many sites, once standalone sites are complete (#113).
- The steps between runs, listed as responsibilities (#114).
