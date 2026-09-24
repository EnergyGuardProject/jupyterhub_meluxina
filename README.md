# jupyterhub_meluxina

JupyterHub deployment for the EnergyGuard project. The Hub runs on **Kubernetes**
and starts each single-user server as a **Slurm job on MeluXina** through the
[SlurmRESTAPISpawner](https://github.com/EnergyGuardProject/slurmrestapispawner).

Users log in with **Keycloak** (OIDC). When a user starts a server, the Hub looks
up the user's email and asks the
[token-store service](https://github.com/EnergyGuardProject/keycloak_meluxina_map)
for the Slurm token, MeluXina project and service user of the user's team. The
token authenticates the Slurm job submission. The project sets the Slurm account
and the working directory. The service user is the Slurm username for the REST
requests. Users who do not belong to a team with a token cannot use the HPC.

## Login and spawn flow

1. The user clicks sign in and logs in with Keycloak.
2. The Hub reads the user's email from the encrypted OAuth `auth_state`. If no
   email is present, it uses the Hub username.
3. `pre_spawn_hook` calls `GET /users/{email}/token` on the token store with the
   `X-API-Key` header. The token store finds the user's team and returns its
   `slurm_token`, `meluxina_project_name` and `service_user`.
4. The Hub sets these values on the user's spawner.
   - `slurm_token` authenticates the job submission.
   - `account` is the MeluXina project name.
   - `slurm_user` is the team's service user.
   - `current_working_directory` is `/project/home/<project>/jovyan/work`.

   Users cannot change any of these in the spawn form.
5. The Hub submits the job to `slurmrestd`.

If the token store answers 400 or 404, or returns no token, project or service
user, the user sees a "no HPC access" page. If the token store cannot be reached
or returns another error, the user sees a message that the HPC token service is
unavailable. The check runs on every spawn, so changes to teams and tokens apply
at the next spawn.

Logging out of JupyterHub also ends the Keycloak session.

## Slurm job settings

| Setting | Value |
|---------|-------|
| `slurmrestd_url` | `https://slurm.cloud.lxp.lu` |
| `slurm_api_version` | `v0.0.44` |
| `partition` | `gpu` |
| `qos` | `default` |
| `time_limit` | `02:00:00` |
| `start_timeout` | `2400` seconds |

Users can adjust the job options in the spawn form. The job prologue loads the
`Python` module and creates a venv at `$HOME/test_restapi` with JupyterHub and
JupyterLab on the first run. It also expects a CA certificate at
`$HOME/certs/mkcert-ca.crt` in the service user's home directory.

## EnergyGuard kernel (`eg-default`)

The kernel reproduces the one in
[EnergyGuard-JupyterHub](https://github.com/epu-ntua/EnergyGuard-JupyterHub)'s
`Dockerfile.singleuser`, built as a venv on shared storage in place of a
container image. The `energyguard-sdk` and MLflow SSO layer is not installed.

There are two differences from the upstream image.

- **PyTorch comes from the MeluXina module**
  `PyTorch/2.9.1-foss-2025a-CUDA-12.8.0-whl`, which is built against the
  cluster's CUDA. Upstream pins `torch==2.10.0`, and 2.9.1 is the closest
  version available on MeluXina. A constraints file pins the module's torch
  version so that pip does not install a PyPI torch over it. `numpy` is not
  pinned, so it stays compatible with the module's torch.
- **`jupyterhub` is not pinned to 4.1.6**, because the Hub runs 5.x and the
  single-user server has to match it.

The job prologue builds the kernel and creates these files.

| Path | Purpose |
|------|---------|
| `$HOME/eg-kernel/` | Kernel venv with the PyTorch module, mlflow, pandas, scikit-learn and other packages |
| `$HOME/eg-kernel/bin/eg-kernel-launch` | Loads the PyTorch module and starts `ipykernel_launcher` |
| `$VENV/share/jupyter/kernels/eg-default/kernel.json` | Registers the kernel in JupyterLab |
| `$VENV/etc/jupyter/jupyter_server_config.py` | Sets `eg-default` as the default kernel |
| `$HOME/eg-kernel/.eg-complete-v${EG_VERSION}` | Marks a finished build. If it is missing, the next spawn builds the kernel again |

All members of a team run their jobs as the same Slurm service user, so the
kernel is built once per team. The first spawn for a team builds it and later
spawns reuse it. A team with a different `service_user` gets its own build. To
rebuild the kernel for all teams after changing packages, increase `EG_VERSION`
in `values.yaml`.

The build behaves as follows.

- The build needs at least 30 minutes of job time. If less time is left, the
  build is skipped and the server starts without the kernel. Start one spawn
  with a longer time limit to build it.
- If the build fails, the partial venv is removed and no stamp file is written,
  so the next spawn tries again. The server still starts.
- Only one build runs at a time, guarded by the lock directory
  `$HOME/.eg-kernel-build.lock`. A lock older than 60 minutes is removed. A
  spawn that finds a build in progress waits up to 5 minutes and then starts
  the server without the kernel.

To use a different PyTorch module, set `EG_TORCH_MODULE` in `values.yaml` to the
exact name shown by `module spider PyTorch` on a login node, and increase
`EG_VERSION`.

## Repository contents

| File | Purpose |
|------|---------|
| `values.yaml` | Helm values with the hub image, environment and all spawner and authenticator settings (`hub.extraConfig`) |
| `Dockerfile` | Custom `k8s-hub` image with the SlurmRESTAPISpawner (`keycloak_integration` branch) |
| `ingress.yaml` | Cilium Ingress with TLS for the public hostname |

## Secrets

`meluxina-secret.yaml` is not in the repository. Create it as a Kubernetes
`Secret` named `meluxina-credentials` in the `jupyterhub` namespace with these
keys under `stringData`.

| Key | Content |
|-----|---------|
| `compute-hub-base` | Public URL of the Hub. The Keycloak client redirect URIs must match it |
| `keycloak_base_url` | Keycloak base URL |
| `keycloak_realm` | Keycloak realm |
| `keycloak_client_id` | Keycloak client ID |
| `keycloak_client_secret` | Keycloak client secret |
| `token-store-url` | Base URL of the token-store service |
| `token-store-api-key` | API key for the token-store service |
| `jupyterhub-crypt-key` | Key that encrypts `auth_state`, for example from `openssl rand -hex 32` |

## Deploy

Build and push the Hub image.

```bash
docker build --no-cache --platform linux/amd64 \
  -t theopnt12/jupyterhub-meluxina:v4-amd64 .
docker push theopnt12/jupyterhub-meluxina:v4-amd64
```

Apply the secret and install the chart.

```bash
kubectl apply -n jupyterhub -f meluxina-secret.yaml
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub --create-namespace -f values.yaml
```

For public access, create the TLS secret `jupyter-cert` and apply the ingress.

```bash
kubectl create secret tls jupyter-cert -n jupyterhub \
  --cert=<hostname>.pem --key=<hostname>-key.pem
HOSTNAME=<hostname> envsubst < ingress.yaml | kubectl apply -f -
```
