{{- define "obs.cluster" -}}
{{- required "cluster.name é obrigatório (injetado pelo ApplicationSet)" .Values.cluster.name -}}
{{- end }}

{{- define "obs.meta" -}}
namespace: argocd
finalizers:
  - resources-finalizer.argocd.argoproj.io
labels:
  cluster: {{ include "obs.cluster" . }}
{{- end }}

{{- define "obs.syncPolicy" -}}
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
