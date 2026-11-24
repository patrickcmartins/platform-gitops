# ADR 0002: Exposição do gateway no EKS (NLB em modo IP, portas não privilegiadas)

- **Status:** proposta
- **Data:** 2026-11-24
- **Decisão:** o gateway do Istio escuta em **8080/8443** no pod (o Service continua 80/443) e é exposto por um **NLB em modo IP**, criado pelo **AWS Load Balancer Controller**, com health check em `15021 /healthz/ready`, cross-zone ligado, topology spread por AZ, PDB e readiness gate.

---

## O incidente que motivou esta ADR

Em 2026-11-24, `https://app.prod.patricktf.neosix.me` respondia só ~1 em 3 requisições. As outras davam timeout, nos dois IPs do NLB.

| Evidência | O que mostrou |
|---|---|
| Target groups do NLB | **443**: 1 node unhealthy. **80**: os 2 unhealthy. **15021**: os 2 healthy. |
| `istioctl proxy-config listener` | Os dois pods do gateway escutavam em 80 e 443 normalmente. |
| `curl` do sidecar de um pod no node B | Gateway no **mesmo node**: 200 sempre. Gateway no **outro node**: timeout sempre. |
| Security group dos nodes | Node ↔ node só em **TCP 1025–65535** (e 53). |

**Causa.** O NLB estava em modo *instance* (criado pelo cloud provider do EKS): ele entrega no **NodePort** do node e o kube-proxy (`externalTrafficPolicy: Cluster`) escolhe um pod do gateway em **qualquer** node. Quando escolhia o pod do outro node, o pacote ia para a porta 80/443 do pod, que fica **fora** da faixa liberada entre nodes. A 15021 passava porque está dentro da faixa, então o health check que "parecia" o principal estava verde.

**Por que o chart escutava em 80/443:** o chart `gateway` do Istio, sem `securityContext`, põe o sysctl `net.ipv4.ip_unprivileged_port_start=0` no pod para poder abrir porta baixa sem root.

## Opções

| Opção | Onde muda | Ganha | Perde |
|---|---|---|---|
| **1. Gateway em 8080/8443** | `platform-gitops` | Corrige a causa; tira o sysctl (menos privilégio); cai na faixa já liberada | Ainda passa por NodePort e salto entre nodes |
| **2. Liberar 80/443 entre nodes no SG** | `terraform-modules` | Não toca no app | Abre o SG para acomodar porta privilegiada; a lista cresce a cada porta baixa nova |
| **3. `externalTrafficPolicy: Local`** | `platform-gitops` | Sem salto entre nodes; preserva o IP do cliente | Só é seguro com um pod do gateway por node; continua em NodePort |
| **4. NLB em modo IP + 1** (escolhida) | `infra-live` (IAM) + `platform-gitops` | O NLB fala **direto com o IP do pod**: sem NodePort, sem kube-proxy, sem salto entre nodes. Health check de prontidão do Envoy. | Mais uma peça para operar (o controller) e uma role IAM |

## Decisão

1. **Portas não privilegiadas.** `targetPort` 8080/8443 e `securityContext` explícito (`runAsNonRoot`, `seccompProfile: RuntimeDefault`), em todos os clusters (kind também, por paridade). O `Gateway` do Istio continua declarando 80/443: o Istio cria o listener no `targetPort` do Service.
2. **NLB em modo IP pelo AWS Load Balancer Controller** (chart 3.6.3, Pod Identity, policy oficial da mesma versão em `infra-live/aws/shared/iam`).
   - `loadBalancerClass: service.k8s.aws/nlb`: o cloud provider do EKS nunca mais mexe neste Service.
   - `allocateLoadBalancerNodePorts: false`: não há NodePort.
   - Health check HTTP em `15021 /healthz/ready`.
   - `load_balancing.cross_zone.enabled=true` e `deregistration_delay.timeout_seconds=30`.
3. **Disponibilidade.** Topology spread por AZ e por node (`ScheduleAnyway`), PDB `minAvailable: 1`, e **readiness gate** (`elbv2.k8s.aws/pod-readiness-gate-inject` no namespace): o rollout só avança quando o NLB marca o pod novo como healthy.
4. **Security group.** O controller cria um SG para o NLB e libera nos nodes **só** as portas dos targets, vindo **só** desse SG. As regras `0.0.0.0/0` nos NodePorts, criadas pelo cloud provider, somem com o Service antigo.

### Escolhas para não repetir o postmortem do webhook do Istio

- **Webhook de Service do controller desligado** (`enableServiceMutatorWebhook: false`). Com `failurePolicy: Fail`, ele barraria a criação de **qualquer** Service com o controller fora do ar. Não é necessário porque o gateway declara `loadBalancerClass`.
- O webhook de pod (readiness gate) só atua no namespace com o label, ou seja, só no `istio-ingress`. Trade-off aceito: com o controller fora do ar, pods **novos** do gateway não sobem; os que estão rodando continuam servindo (2 réplicas e PDB).
- O certificado do webhook é gerado pelo chart a cada render: `ignoreDifferences` no Secret e no `caBundle`, como no istiod.

## Migração (uma vez por cluster: stg, depois prod)

`loadBalancerClass` é **imutável**: o Service antigo não vira o novo. O sync do Argo falha no Service com `field is immutable` e o Service antigo **continua de pé** (nada quebra até o passo 3).

1. Aplicar `infra-live` (role + annotations `vpc-id`/`region` no cluster). Conferir no hub:
   `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster -o custom-columns='NAME:.metadata.name,VPC:.metadata.annotations.vpc-id'`
2. Merge deste PR. Esperar o `aws-load-balancer-controller` ficar `Healthy` e os pods `Running`:
   `kubectl -n kube-system get deploy aws-load-balancer-controller`
3. Apagar o Service **antigo** (ainda com a spec antiga, então o cloud provider apaga o NLB e as regras de SG dele):
   `kubectl -n istio-ingress delete svc istio-ingressgateway`
4. O Argo recria o Service com a spec nova; o controller cria o NLB em modo IP; o external-dns atualiza o registro.
   **Indisponibilidade esperada:** de 2 a 5 minutos (provisionamento do NLB e TTL do DNS).
5. Verificar (ver `docs/runbooks`): targets `healthy` nas 3 portas, `curl` repetido 20 vezes só com 200, e o header `x-version: canary` chegando ao green.

**Rollback:** reverter este PR e repetir o passo 3; o cloud provider recria o NLB em modo instance.

## Consequências

- Mais uma peça na plataforma: o controller precisa de upgrade junto com a policy IAM (mesma versão).
- O NLB e o hostname mudam uma vez, na migração.
- Lição de diagnóstico: **health check verde em uma porta não prova as outras**. Testar por porta e por node; ter um teste sintético de fora (blackbox) com alerta de taxa de erro.
