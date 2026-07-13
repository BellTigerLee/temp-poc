# temp-child

This local-only repository uses a three-file direct-source layout:

- `README.md` documents the source boundary and publication status.
- `deploy/dev/configmap.yaml` is the stable source path for development deployment content.
- `smurfx/request.yaml` is an inert target request. It doesn't register, approve, or deploy anything.

The files are not currently published, fetchable by federation, registered, validated, approved, deployed, or proof of runtime health.

A future commit and push must publish the files before federation registration and integration can occur. Those steps are prerequisites for any later consumption or deployment.
