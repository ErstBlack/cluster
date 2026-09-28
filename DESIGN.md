# Design

This design is still being developed and researched, and requirements are still being gathered. Anything here may change, at any level. It records the decisions made so far. It describes concepts, not tools, so it stays true when a tool is replaced. Known gaps are tracked in GitHub issues, not here. Testing strategy is out of scope.

## Purpose

The system turns independent machines at an edge site into one cluster that runs containers and virtual machines. Each run lasts 24 to 48 hours. The goal is fully air-gapped sites, and each site stands alone. A site has anywhere from 3 to 100+ nodes, a mix of physical and virtual, and each node starts on its own with no orchestrator. The workloads may be ours, other vendors', or both. That is not yet known. A central manager for many sites may be explored once standalone sites are complete.

## Principles

- Each part has as few responsibilities as possible, ideally one. Side effects are kept to a minimum or removed.
- A layer hides how it works and offers one interface to the layer above. It reaches only the layers next to it. Breaking this needs a stated reason.
- The Kubernetes API is a hard line. Anything above it sees only the API. Exceptions are made case by case, where a benefit is shown.
- Logging, health, trust and secrets, and time cut across every part. Their implementation is open, but the design keeps them cheap to add.

## Runs

- Each run forms a fresh cluster from the nodes that are powered on. Nothing about the cluster survives shutdown.
- The size of a site, and whether it grows or shrinks, changes only between runs. So do upgrades.
- A run's workloads are declared in the data delivered when it starts, and the cluster applies them. Nobody needs to log in.
- If changes during a run are allowed later, they will come through a UI this project provides, sitting above the Kubernetes API.

## Nodes

- Every node boots the same image. Any node can take any role, and no node has a fixed one.
- Minimum hardware: x86_64, UEFI with Secure Boot, hardware virtualization, and 16 GB of RAM. 32 GB is typical. Virtual nodes need nested virtualization. A TPM is not required.
- Other hardware, such as accelerators, extra disks or more capacity, varies. A node reports what it has, and workloads ask for what they need.
- The image holds the OS, the platform software and preloaded public images. It holds no secrets and no site data, and nothing writes to it during a run.
- To upgrade a node, it is re-imaged between runs, never patched. A separate imaging step writes the image to the node's local disk, and the node boots from that disk. Booting over the network from a site server may be considered later, together with storage.

## Data protection

- Data loaded onto a node and data written during a run are encrypted.
- A node's scratch space is encrypted with a random key held only in memory, so powering off makes it unreadable.
- Data that must outlive a run leaves the node before shutdown. How it leaves is deferred.

## Cluster formation

- The nodes elect roles among themselves. Up to 3 become control-plane nodes, and one of those bootstraps the cluster.
- Control-plane nodes also run workloads. A fixed share of their CPU and RAM is reserved for the control plane and the system. At large sites, an operator can dedicate some nodes to control-plane work only.
- The control plane is fixed at formation. Nodes that arrive later join as workers. A lost control-plane node is not replaced, and losing the control plane ends the run. A repair mechanism may be added later.

## Stable endpoint

- The control-plane nodes hold one stable address, and other nodes join through it.
- Only the elected control-plane nodes take part in moving that address between them.

## Admission

- In scope: a device on the site network that has no secret. It must not be able to join, influence the election, or gain anything by taking the stable address.
- Each run has a new shared site secret, delivered with the site config. It authenticates both the election and the join. Worker nodes and control-plane nodes get separate credentials.
- A node sends its credential only to an endpoint that proves it holds the run's certificate authority.
- Not in scope yet: an attacker who holds a copy of the site config. If that attacker comes into scope, hardware identity per machine is the candidate defence.
- Network links are not authenticated for now.

## Config delivery

- Every node at a site gets the same config, which holds only the values that apply to the whole site. Each node works out the rest at boot.
- Time: if the site config names a time source, nodes follow it. Otherwise the elected bootstrap node serves time for the run.

## Workloads and platform services

- Containers run as cluster workloads. VMs run through a VM add-on on the same API.
- Compose files are an input format that is converted when delivered. They are never run as-is on a node. A translation for Docker-specific assumptions may come later.
- The platform services are the cluster, the VM add-on, and whatever applies the declared workloads. There is no third-party management UI.

## Non-goals

- Sites with fewer than 3 nodes.
- A cluster that persists across runs.
- Patching nodes in place.
- Running workloads on a node outside the cluster.
- CPU architectures other than x86_64.
- A central manager for many sites, for now.

## Deferred and open

- Storage, including whether a site needs distributed storage and what it would provide.
- Networking.
- Loading data onto nodes when a run starts and off them when it ends.
- Where container images, charts and VM images come from for each run.
- Restarting a failed node's VMs on another node.
- The list of responsibilities (#30), then the layer layout (#31).
