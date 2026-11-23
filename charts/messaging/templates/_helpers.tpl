{{- define "msg.cluster" -}}
{{- required "cluster.name é obrigatório (injetado pelo ApplicationSet)" .Values.cluster.name -}}
{{- end }}

{{- define "msg.meta" -}}
namespace: argocd
finalizers:
  - resources-finalizer.argocd.argoproj.io
labels:
  cluster: {{ include "msg.cluster" . }}
{{- end }}

{{- define "msg.syncPolicy" -}}
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
