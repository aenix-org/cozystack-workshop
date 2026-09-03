## 13. A closer look: what's inside 01-bucket.yaml

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: my-images
  namespace: tenant-workshopXX
spec:
  users:
    app: {}
```

`apiVersion: apps.cozystack.io/v1alpha1` — which set of types this object is drawn from.
`apps.cozystack.io` is the Cozystack catalog itself: everything listed there is something you can
order. It's not "Kubernetes knows how to do buckets on its own" — the platform added them.

`kind: Bucket` — what exactly you're ordering. The file doesn't describe *how* to stand up the
storage: it says "I want a bucket," and the platform does everything else itself. The whole catalog
works this way — you write down what you need, not a sequence of steps.

`metadata.name: my-images` — the name of the order. You'll use it to find the order in the dashboard
and in commands. This name is internal; the platform will generate its own real bucket name in S3,
long and unique — you'll see it later in the `bucketName` parameter.

`namespace: tenant-workshopXX` — your slice of the platform. **The only place you need to change by
hand:** substitute your own number for `XX`. A namespace is a partition inside the cluster: objects
with the same name in different namespaces don't interfere with each other and don't see each other.
The closest analogy is a separate Resource Pool with its own access rights, only stricter.

`users: app: {}` — creates an S3 user named `app`. The empty curly braces mean "default settings":
the platform will come up with an access key and a secret key for it on its own and put them into a
separate Secret object, which you'll open in the dashboard. You don't invent any passwords or type
them in anywhere.

Notice what's **not** in the file: size, address, ports, certificate, the nodes it will all be placed
on. The platform determines all of that itself. That's exactly the difference between "ordering from
the catalog" and "setting it up by hand."
