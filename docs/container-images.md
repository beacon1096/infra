# NixOS OCI Container Images

This document explains how we build and run OCI (Docker/Kubernetes) container images directly from our NixOS modules. By using this approach, we can perfectly reuse our existing Nix configuration, `sops-nix` secret management, and systemd service definitions in a Kubernetes environment.

## 1. The "NixOS-in-a-container" Architecture

Instead of building a minimal Docker image with just a binary and a static config, we build an image that uses NixOS's `docker-image.nix` builder.

These images use `/sbin/init` (systemd) as their entrypoint. When the container starts:
1. `systemd` boots up inside the container.
2. It runs the normal NixOS activation scripts.
3. **`sops-nix` runs and decrypts secrets using an injected Age key.**
4. Services configured via Nix (like `sing-box`) start automatically with the fully rendered and decrypted configuration.

This ensures seamless reuse of the configuration defined in `modules/**/*.nix` without requiring separate Helm charts or manual config generation scripts.

---

## 2. Example: `k8s-sing-box-image`

The `k8s-sing-box-image` package defined in `flake.nix` is an example containing the `sing-box` proxy proxy and all its routing/domain rules.

### How to Build
To build the image (use `--builders` if you are on an ARM Mac like an M4, so the build runs on an x86_64 remote machine):

```bash
nix build .#packages.x86_64-linux.k8s-sing-box-image \
  --builders 'ssh://beacon@msi-claw x86_64-linux'
```

### Result
The output will be a `tar` archive linked at `./result`:
```text
result -> /nix/store/...-docker-layer-k8s-sing-box-image
```

### Importing the Image
Load the image archive into your container runtime:
- **Docker**: `docker load < result`
- **containerd / K8s (ctr)**: `ctr -n k8s.io image import result`

---

## 3. Automated CI/CD and Forgejo Registry

We use Forgejo Actions to automatically build and push the `sing-box` image to our internal registry.

### Registry Details
- **Registry Host**: `${SECRET_IMAGE_REGISTRY}`
- **Image Path**: `${SECRET_IMAGE_REGISTRY}/infrastructure/nix-fleet/sing-box`
- **Authentication**: Use your Forgejo credentials or an Access Token.

### CI Workflow
The workflow is defined in `.forgejo/workflows/build-and-push.yaml`. It triggers on pushes to the `main` branch and on new tags (`v*`).

### Pulling from K8s
In your Kubernetes deployment, reference the image from the registry:

```yaml
    image: ${SECRET_IMAGE_REGISTRY}/infrastructure/nix-fleet/sing-box:latest
```

Ensure you have a `imagePullSecret` configured if your registry is private:
```bash
kubectl create secret docker-registry forgejo-registry-secret \
  --docker-server=${SECRET_IMAGE_REGISTRY} \
  --docker-username=<username> \
  --docker-password=<token>
```

---

## 4. Running the Image in Kubernetes

To run these customized images in Kubernetes, you must mount a SOPS Age key so the container can decrypt its configuration upon boot.

### Step 1: Create a K8s Secret with the Age Key
Obtain your `age` secret key (the private key, e.g., `keys.txt`), and create a secret in your namespace:
```bash
kubectl create secret generic sops-age-key \
  --from-file=key.txt=/path/to/your/sops/keys.txt \
  -n your-namespace
```

### Step 2: Deploy the Pod
Below is an example Pod definition. Note the volume mounts and security context:
* Since `sing-box` requires creating a `tun` interface in the container, we grant `NET_ADMIN`.
* The Age key is mounted directly to `/var/lib/sops-nix/key.txt`, perfectly aligning with our custom `flake.nix` setup for this image.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sing-box-gateway
  labels:
    app: sing-box
spec:
  containers:
  - name: sing-box
    image: k8s-sing-box-image:latest # Modify as needed if pushed to a registry
    imagePullPolicy: IfNotPresent
    securityContext:
      capabilities:
        add: ["NET_ADMIN"] # Required for tun-in interface
    volumeMounts:
    - name: sops-age-key-volume
      mountPath: /var/lib/sops-nix
      readOnly: true
  volumes:
  - name: sops-age-key-volume
    secret:
      secretName: sops-age-key
```

### Logs
Because we configured `services.journald.console = "/dev/console";` in the build, systemd will stream the initialization logs and service logs straight out to standard output, making `kubectl logs sing-box-gateway` work correctly.

---

## 4. How to Create New Container Images

You can use the `k8s-sing-box-image` pattern in `flake.nix` to containerize another module in this repository, such as an nginx or custom backend image.

### Template for `flake.nix`

```nix
packages.x86_64-linux = {
  my-new-app-image = (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit inputs; };
    modules = [
      # 1. Include sops-nix for secrets decryption
      sops-nix.nixosModules.sops

      # 2. Include the specific NixOS module for the app
      ./modules/common/my-new-app.nix

      # 3. Use the docker-image builder and define container specifics
      "${nixpkgs}/nixos/modules/virtualisation/docker-image.nix"
      ({ pkgs, lib, ... }: {
        boot.isContainer = true;

        # Disable any global services you don't want running in this container
        services.tailscale.enable = lib.mkForce false;

        # Set the location for the injected sops key
        sops.age.sshKeyPaths = [ ];
        sops.age.keyFile = "/var/lib/sops-nix/key.txt";

        # Route systemd journal to Docker/K8s stdout
        services.journald.console = "/dev/console";
      })
    ];
  }).config.system.build.tarball;
};
```
