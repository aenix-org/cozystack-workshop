## 12. Phase 1. Exporting the image out of vSphere

**Steps 1–3.** The virtual machine's disk sits in a format that VMware understands, and it won't
travel anywhere on its own. We need to turn it into a format for KVM and put it somewhere the cluster
can pick it up from.

Three steps: set up storage, bring up a temporary machine with the tools, convert.
