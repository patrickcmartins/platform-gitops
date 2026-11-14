{{- define "addons.cluster" -}}
{{- required "cluster.name é obrigatório (injetado pelo ApplicationSet)" .Values.cluster.name -}}
{{- end }}

{{- define "addons.meta" -}}
namespace: argocd
finalizers:
  - resources-finalizer.argocd.argoproj.io
labels:
  cluster: {{ include "addons.cluster" . }}
{{- end }}

{{- define "addons.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 5
    backoff: { duration: 10s, factor: 2, maxDuration: 3m }
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
{{- end }}
