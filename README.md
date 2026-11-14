# platform-gitops

O que o Argo CD do **hub** (`mgmt`) reconcilia. O Terraform cria uma única Application (`root`) apontando para
`bootstrap/hub`, e a partir dela todo o resto é derivado do Git **e dos labels dos clusters**.

```
root (Terraform) ─► bootstrap/hub
                    ├─ AppProjects: platform, workloads
                    ├─ ApplicationSet cluster-addons   (clusters com mesh=istio)
                    │    └─ addons-<cluster>  ─► charts/cluster-addons
                    │         ├─ wave -3 <cluster>-istio-base
                    │         ├─ wave -2 <cluster>-istiod
                    │         ├─ wave -1 <cluster>-istio-ingressgateway   (NodePort no kind, NLB na AWS)
                    │         └─ wave  0 <cluster>-istio-config           (Gateway + mTLS STRICT)
                    └─ ApplicationSet sample-app        (workloads=enabled  x  envs/<cluster>/ no sample-app-deploy)
                         └─ sample-app-<cluster>
```

## O contrato: labels do Secret de cluster (criados pelo `infra-live`)

| label | efeito |
|---|---|
| `cloud=kind\|aws` | escolhe `values-<cloud>.yaml` |
| `mesh=istio` | o cluster ganha Istio |
| `workloads=enabled` | o cluster pode receber apps |

Overrides de um cluster específico ficam em `clusters/<nome>/addons.yaml`, por exemplo para testar um upgrade do Istio só no `kind-dev`.

## Ideias para quebrar e consertar

* Mude o label `mesh` do hub para `istio` no `infra-live` e veja o Argo CD instalar o Istio nele sozinho.
* Suba `istio.version` só em `clusters/kind-dev/addons.yaml`: é um canary de upgrade de plataforma.
* Apague um Deployment na mão e veja o `selfHeal` recriá-lo.
