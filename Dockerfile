FROM jupyterhub/k8s-hub:5.0.0-0.dev.git.7319.h966efb50

RUN pip install --upgrade pip
RUN pip install git+https://github.com/EnergyGuardProject/slurmrestapispawner.git@keycloak_integration
#