# flashbox :zap: :package:

flashbox is an opinionated Confidential VM (CVM) base image built for podman pod payloads. With a focus on security balanced against TCB size, designed to give developers the simplest path to TDX VMs.

## Why flashbox?

One command, `./zap` - and you've got yourself a TDX box.

⚠️ **IMPORTANT**: This is an early development release and is not production-ready software. Use with caution.

## Quick Start

1. Download the latest VM image from the releases page

2. Deploy the flashbox VM:
```bash
# Local deployment (non-TDX)
./zap --mode normal

# Local deployment (TDX)
./zap --mode tdx

# Azure deployment
./zap azure myvm eastus

# GCP deployment
./zap gcp myvm us-east4
```

### Known Issues

- Azure deployments may encounter an issue with the `--security-type` parameter. See [Azure CLI Issue #29207](https://github.com/Azure/azure-cli/issues/29207#issuecomment-2479343290) for the workaround.

### Considerations

⚠️ **WARNING**: Debug releases come with SSH enabled and a root user without password. Always use the `--ssh-source-ip` option to restrict SSH access in cloud deployments.
⚠️ **IMPORTANT**: If you want to run TDX VMs on bare metal you need to first setup your host environment properly. For this, follow the instructions in the [canonical/tdx](https://github.com/canonical/tdx) repo.

3. Provision and start your containers:
```bash
# Upload pod configuration and environment variables
curl -X POST -F "pod.yaml=@pod.yaml" -F "env=@env" http://flashbox:24070/upload

# Start the containers
curl -X POST http://flashbox:24070/start
```

## Pod Configuration

### Docker Compose Migration

If you're coming from Docker Compose, you can convert your existing configurations:
```bash
podman-compose generate-k8s docker-compose.yml > pod.yaml
```

See the [official documentation on differences between Docker Compose and Podman](https://docs.podman.io/en/latest/markdown/podman-compose.1.html) for migration details.

### Example Configuration

Here's a basic example of a pod configuration:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  labels:
    app: my-app
spec:
  containers:
    - name: web-container
      image: nginx:latest
      env:
        - name: DATABASE_URL
          value: "${DATABASE_URL}"
      ports:
        - containerPort: 80
          hostPort: 8080
```
### Non-Attestable Variable Configuration

flashbox allows you to provision secrets and configuration variables that should remain outside the attestation flow. This is done through a separate `env` file that is processed independently of the pod configuration.

1. Create an `env` file with your variables:
```bash
DATABASE_URL=postgresql://localhost:5432/mydb
API_KEY=your-secret-key
```

2. Reference these variables in your pod configuration using the `${VARIABLE}` syntax:
```yaml
env:
  - name: DATABASE_URL
    value: "${DATABASE_URL}"
  - name: API_KEY
    value: "${API_KEY}"
```

Variables in the env file will be substituted into the pod configuration at runtime, keeping them separate from the attestation process. This is useful for both secrets and configuration that may vary between deployments.
