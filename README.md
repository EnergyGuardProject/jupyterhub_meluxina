# jupyterhub_meluxina

JupyterHub deployment for the EnergyGuard project, running on **Kubernetes** and
spawning single-user servers as **Slurm jobs on MeluXina** via the
[SlurmRESTAPISpawner](https://github.com/EnergyGuardProject/slurmrestapispawner).

Users log in with **Keycloak** (OIDC). At spawn time the Hub resolves the user's
email and asks the
[token-store service](https://github.com/EnergyGuardProject/keycloak_meluxina_map)
for their team's Slurm token, MeluXina project and service user; the token
authenticates the Slurm job submission, the project drives the Slurm account and
working directory, and the service user is the Slurm username used for the REST
requests. Users with no team token are denied HPC access.

## Login & spawn flow

1. User clicks sign in and authenticates against Keycloak.
2. The Hub reads the user's email from the (encrypted) OAuth `auth_state`.
3. `pre_spawn_hook` calls `GET /users/{email}/token` on the token store
   (`X-API-Key`), which resolves the user's team and returns that team's
   `slurm_token`, `meluxina_project_name` and `service_user`.
4. The Hub sets, per user, on the spawner:
   - `slurm_token` — authenticates the job submission,
   - `account` — the MeluXina project name,
   - `slurm_user` — the team's service user (Slurm username for REST requests),
   - `current_working_directory` — `/project/home/<project>/jovyan/work`.
   None of these are user-editable in the spawn form.
5. The job is submitted to `slurmrestd`. No token (or no project / service user)
   → the user sees a "no HPC access" page instead of a server.

## EnergyGuard kernel (`eg-default`)

Replicates the kernel from
[EnergyGuard-JupyterHub](https://github.com/epu-ntua/EnergyGuard-JupyterHub)'s
`Dockerfile.singleuser`, adapted from a container image to a venv on shared
storage. The `energyguard-sdk` / MLflow SSO layer is **not** installed yet.

Two deliberate deviations from upstream:

- **PyTorch comes from a MeluXina module**, not the PyPI wheel, so it is built
  against the cluster's CUDA. A constraints file pins that version so pip
  cannot install a PyPI torch over it (`pytorch_lightning` would otherwise
  drag one in). `numpy` is left unpinned for the same reason — forcing
  upstream's version risks an ABI mismatch with the module's torch.
- **`jupyterhub` is not pinned to 4.1.6.** The Hub here runs 5.x, and the
  singleuser server must match it.

The build runs inline in the spawner prologue, guarded by a stamp file:

| Path | Written | Purpose |
|------|---------|---------|
| `$HOME/eg-kernel/` | once | Kernel venv: module PyTorch + mlflow, pandas, sklearn, … |
| `$HOME/eg-kernel/bin/eg-kernel-launch` | once | Re-loads the PyTorch module, then execs `ipykernel_launcher` |
| `$VENV/share/jupyter/kernels/eg-default/kernel.json` | once | Makes the kernel visible to JupyterLab |
| `$VENV/etc/jupyter/jupyter_server_config.py` | once | `default_kernel_name = 'eg-default'` |
| `$HOME/eg-kernel/.eg-complete-v${EG_VERSION}` | once | Stamp; its absence triggers a rebuild |

Because every member of a team spawns as the same Slurm **service user**, this
builds once per team: the first spawn pays for it, everyone after inherits it,
and new users do nothing. A team with a different `service_user` gets its own
build. Bump `EG_VERSION` in `values.yaml` to force all teams to rebuild after a
package change.

A failed build writes no stamp and removes the partial venv, so the next spawn
retries rather than serving a broken kernel forever. The spawn itself still
succeeds — a kernel problem must not cost the user their server.

> **Set `EG_TORCH_MODULE` in `values.yaml` before deploying.** It ships as
> `PyTorch/UNSET`; use the exact string from `module spider PyTorch` on a login
> node. Until then every spawn logs a build failure and offers no kernel.

## Repository contents

| File | Purpose |
|------|---------|
| `values.yaml` | Helm values: hub image, env, and all spawner/authenticator config (`hub.extraConfig`). |
| `Dockerfile` | Custom `k8s-hub` image that installs the SlurmRESTAPISpawner (`keycloak_integration` branch). |
| `ingress.yaml` | Cilium Ingress + TLS for the public hostname. |

## Deploy


```bash
docker build --no-cache --platform linux/amd64 \
  -t theopnt12/jupyterhub-meluxina:v4-amd64 .
docker push theopnt12/jupyterhub-meluxina:v4-amd64
```
Apply secrets and install the chart:

```bash
kubectl apply -n jupyterhub -f meluxina-secret.yaml
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub --create-namespace -f values.yaml

# optional: public access
HOSTNAME=**** envsubst < ingress.yaml | kubectl apply -f -
```
</content>
</invoke>
