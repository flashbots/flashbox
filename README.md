# flashbox :zap: :package:

flashbox is an opinionated Confidential VM (CVM) base image designed to run podman pod payloads. It provides a simple way to deploy containerized applications in a secure environment.

## Quick Start

1. Deploy the flashbox VM image
   - [Bare Metal non-TDX](#bare-metal-non-tdx)
   - [Bare Metal TDX](#bare-metal-tdx)
   - [Azure Deployment](#azure-deployment)
   - [GCP Deployment](#gcp-deployment)

2. Provision and start your containers:

```bash
# Upload pod configuration and environment variables
curl -X POST -F "pod.yaml=@pod.yaml" -F "env=@env" http://flashbox:24070/upload

# Start the containers
curl -X POST http://flashbox:24070/start
```

## Pod Configuration

### Docker Compose Users

If you're coming from Docker Compose, you can convert your existing configurations to podman pod format. The pod configuration format is similar to Kubernetes manifests (YAML manifests).

To convert a Docker Compose file to a podman pod configuration:
```bash
podman-compose generate-k8s docker-compose.yml > pod.yaml
```

See the [official documentation on differences between Docker Compose and Podman](https://docs.podman.io/en/latest/markdown/podman-compose.1.html) for more details on migration.

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
        - name: DB_HOST
          value: "localhost"
        - name: API_PORT
          value: "3000"
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

## Deployment Options

### Bare Metal non-TDX
[TO BE FILLED: Bare metal non-TDX deployment instructions]

### Bare Metal TDX
[TO BE FILLED: Bare metal TDX deployment instructions]

### Azure Deployment
[TO BE FILLED: Azure deployment instructions]

### GCP Deployment
[TO BE FILLED: GCP deployment instructions]

## Security Considerations

- flashbox runs in a Confidential VM environment, providing enhanced security for your workloads
- Configuration variables can be separated from pod configurations using the env file
- The env file contents are not included in the attestation flow, providing flexibility for deployment-specific configurations

## API Endpoints

- `POST http://flashbox:24070/upload`: Upload pod configuration and environment files
- `POST http://flashbox:24070/start`: Start the configured containers

## Contributing

[TO BE FILLED: Contributing guidelines]

## License

[TO BE FILLED: License information]
