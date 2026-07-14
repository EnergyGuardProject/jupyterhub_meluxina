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
