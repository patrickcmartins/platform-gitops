# ADR 0001: Tráfego (Ingress, Gateway API, Envoy Gateway, service mesh)

- **Status:** aceita
- **Data:** 2026-11-23
- **Decisão:** Istio (modo sidecar) como mesh e ingress, com o plano de migrar o roteamento de borda para a **Gateway API** (`Gateway` + `HTTPRoute`). Ver "Decisão neste lab".

## Antes de tudo: separar dois problemas

| Problema | Pergunta | Ferramentas |
|---|---|---|
| **Norte-sul** (borda) | Como o tráfego **de fora** entra no cluster? | Ingress, Gateway API, Envoy Gateway, AWS Load Balancer Controller, ingress do Istio |
| **Leste-oeste** (entre serviços) | Como os serviços **conversam entre si** com segurança e controle? | Service mesh: Istio, Linkerd, Cilium |

Muita confusão em entrevista vem de misturar os dois. **Você pode precisar de uma boa borda sem precisar de mesh.** O contrário é raro.

E um terceiro termo que aparece no meio: o **Envoy** é um *proxy* (o motor). Istio, Envoy Gateway, Contour e Emissary **usam** o Envoy por baixo. Dizer "usar Envoy" quase sempre significa usar um desses produtos, não configurar o Envoy na mão.

## As opções de borda (norte-sul)

### Ingress (API `networking.k8s.io/v1 Ingress`)

| Ganha | Perde |
|---|---|
| Simples, conhecido e suportado em todo lugar. | **A API está congelada**: não recebe features novas. Tudo além de host/path (header, peso de canary, timeout, retries) vira **annotation específica do controller**, e o YAML deixa de ser portável. |
| | Um só recurso mistura o papel do time de infra (TLS, IP) com o do time de app (rotas). |
| | O **ingress-nginx**, o controller mais usado, foi **aposentado** pela comunidade do Kubernetes (manutenção só até março de 2026). Quem usa precisa migrar. |

**Quando usar:** sistema legado que já funciona, ou um caso muito simples. **Projeto novo não deveria começar com Ingress.**

### Gateway API (`gateway.networking.k8s.io`: `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`)

O sucessor oficial do Ingress (GA desde 2023). É uma **especificação**, implementada por vários produtos.

| Ganha | Perde |
|---|---|
| **Separação de papéis**: `GatewayClass` (provedor ou infra), `Gateway` (plataforma: listeners, TLS, IP) e `HTTPRoute` (time de app: rotas do **seu** serviço, no **seu** namespace). Encaixa no modelo de plataforma com times. | É mais recurso para entender do que um Ingress. |
| **Portável**: header match, pesos (canary), redirect e rewrite estão **na spec**, não em annotations. Trocar Istio por Envoy Gateway ou Cilium quase não muda as rotas. | Features avançadas ainda variam por implementação (os níveis de conformidade "Core", "Extended" e "Implementation-specific"). |
| Suportada por Istio, Envoy Gateway, Cilium, NGINX Gateway Fabric, Kong, Traefik e AWS Load Balancer Controller. | |

**Quando usar:** **padrão para qualquer projeto novo**, com ou sem mesh.

### Envoy Gateway (implementação da Gateway API, com Envoy)

| Ganha | Perde |
|---|---|
| Borda moderna, poderosa (rate limit, auth, retries, circuit breaker) e sem o peso de um mesh. | Resolve **só a borda**: não dá mTLS nem telemetria entre serviços. |
| Projeto da própria comunidade do Envoy, focado em Gateway API. | Mais um componente, se você também tiver um mesh, que muitas vezes já traz o próprio gateway. |

**Quando usar:** você precisa de uma **borda boa** (L7, canary, auth, rate limit) e **não** precisa de mesh. É o caso mais comum em times pequenos e médios, e foi o caso citado na conversa de preparação ("o Envoy substitui o Ingress tradicional").

### AWS Load Balancer Controller (ALB/NLB gerenciados)

| Ganha | Perde |
|---|---|
| O ALB é gerenciado pela AWS: WAF, Cognito/OIDC, certificados do ACM e targets direto no **IP do pod** (sem hop extra). | Fica preso à AWS, com recursos de LB por serviço ou grupo (custo) e menos controle fino de L7 que o Envoy. |
| O NLB (L4) na frente de um gateway Envoy/Istio é um padrão muito comum. | |

**Quando usar:** na AWS quando você quer integração nativa (WAF, ACM). Na prática, aparece **junto** com Envoy/Istio: NLB (L4) → gateway Envoy (L7), que é o que este lab faz.

## As opções de mesh (leste-oeste)

### Service mesh: o que ele dá, e o que custa

| Ganha | Perde |
|---|---|
| **mTLS automático** entre todos os serviços, com identidade por ServiceAccount (SPIFFE) e autorização por identidade (`AuthorizationPolicy`). É a base de **zero trust** e responde a auditoria ("o tráfego interno é criptografado?"). | **Custo de recurso**: um sidecar por pod (≈ 50–100 MB e um pouco de CPU cada). Em mil pods, isso pesa. |
| **Controle de tráfego por request** entre serviços: canary por peso ou header, retries, timeouts, circuit breaker e outlier detection, **sem mudar o código**. | **Latência**: dois hops de proxy por chamada (≈ 1–3 ms no p99). |
| **Telemetria uniforme**: golden signals (taxa, erros, latência) e traces de todo serviço, em qualquer linguagem. | **Complexidade operacional**: upgrade do control plane, CRDs, webhooks, depuração de proxy. Exemplo real deste lab: o webhook do `istiod` na porta 15017 bloqueado pelo security group do EKS fez os pods **não nascerem**. |
| Multi-cluster e failover entre clusters. | Curva de aprendizado alta para o time inteiro. |

### Istio vs Linkerd vs Cilium

| | Istio | Linkerd | Cilium (mesh) |
|---|---|---|---|
| Proxy | Envoy (sidecar) ou **ambient** (ztunnel L4 + waypoint L7, sem sidecar) | micro-proxy em Rust, leve | eBPF no kernel, mais Envoy por node para L7 |
| Forte em | Recursos completos (L7 rico, multi-cluster, extensões), maior ecossistema | Simplicidade e baixo overhead; "funciona sem tunar" | Performance; une CNI, NetworkPolicy, observabilidade (Hubble) e mesh |
| Fraco em | Complexidade (menor no modo ambient) | Menos features L7 avançadas | L7 avançado menos maduro que o Istio; troca o CNI |
| Escolha quando | Precisa de controle L7 fino, multi-cluster, ou já é o padrão da empresa | Quer mTLS e observabilidade sem um time dedicado ao mesh | Já usa ou vai usar Cilium como CNI e quer eBPF |

**Istio ambient** (GA desde a 1.24) muda a conta de custo: o mTLS L4 sai do sidecar para um agente por node (ztunnel), e o L7 só existe onde você coloca um *waypoint*. É a escolha natural para **adotar** Istio hoje em escala grande.

### Quando **não** usar mesh

- Um monolito ou poucos serviços (menos de ~10): o custo operacional não se paga.
- O time não tem capacidade de operar e atualizar o mesh. **Um mesh mal operado é um ponto único de falha** para todos os serviços.
- O único requisito é "TLS na borda": isso é cert-manager + gateway, não mesh.
- O requisito é "isolar namespaces": isso é `NetworkPolicy` (CNI), não mesh.

## Resumo para decidir rápido

| Situação | Escolha |
|---|---|
| Projeto novo, só precisa expor HTTP com TLS | Gateway API + uma implementação leve (Envoy Gateway, ou o gateway do Cilium se já usar Cilium) |
| Precisa de canary e retries **na borda**, sem mTLS interno | Envoy Gateway |
| Muitos microsserviços, exigência de mTLS ou zero trust, telemetria uniforme | Mesh (Istio, de preferência ambient; ou Linkerd se quiser simplicidade) |
| AWS, precisa de WAF ou ACM nativos | AWS Load Balancer Controller (ALB), opcionalmente na frente do gateway |
| Sistema legado em Ingress funcionando | Manter, mas planejar a migração para Gateway API (o ingress-nginx foi aposentado) |

## Decisão neste lab

- **Istio, modo sidecar**, como mesh **e** ingress: o objetivo do lab é demonstrar mTLS STRICT, `AuthorizationPolicy` por identidade, canary por peso e header, retries, timeouts e tracing do mesh. Esses são requisitos de mesh, não só de borda.
- **NLB (L4) → gateway do Istio (Envoy, L7)** no EKS. No kind é NodePort, porque o kind não tem LoadBalancer.
- **Dívida assumida:** as rotas ainda usam as APIs próprias do Istio (`networking.istio.io` `Gateway`/`VirtualService`). **Próximo passo:** migrar a borda para `Gateway`/`HTTPRoute` (o Istio implementa a Gateway API) e manter `VirtualService`/`DestinationRule` só onde a Gateway API ainda não cobre (outlier detection, por exemplo).
- **Avaliar depois:** o modo **ambient**, para tirar os sidecars e reduzir custo, e o Argo Rollouts usando o plugin de Gateway API para canary.

## Quando revisitar

- Se o custo dos sidecars ficar relevante: migrar para o modo ambient.
- Se o mesh deixar de ser necessário (poucos serviços, sem requisito de mTLS interno): trocar por Envoy Gateway e simplificar.
