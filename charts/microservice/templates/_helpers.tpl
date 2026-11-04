{{/* Name of every object for this service: the service name itself (adoption, pet, ...). */}}
{{- define "ms.name" -}}
{{- required "name is required (set it in apps/<service>/values.yaml)" .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ms.schema" -}}
{{- default .Values.name .Values.database.schema -}}
{{- end -}}

{{/* Labels on every object. */}}
{{- define "ms.labels" -}}
app.kubernetes.io/name: {{ include "ms.name" . }}
app.kubernetes.io/instance: {{ include "ms.name" . }}-{{ .Values.global.environment }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: pet-portal
app.kubernetes.io/managed-by: {{ .Release.Service }}
pet-portal.bt/group: {{ .Values.group }}
pet-portal.bt/environment: {{ .Values.global.environment }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector for the running server pods (not the migration Job). */}}
{{- define "ms.selector" -}}
app.kubernetes.io/name: {{ include "ms.name" . }}
app.kubernetes.io/component: server
{{- end -}}

{{/* Labels that data stores' NetworkPolicies use to let a pod in. */}}
{{- define "ms.clientLabels" -}}
{{- if .Values.database.enabled }}
pet-portal.bt/postgres-client: "true"
{{- end }}
{{- if .Values.redis.enabled }}
pet-portal.bt/redis-client: "true"
{{- end }}
{{- if .Values.registry.enabled }}
pet-portal.bt/registry-client: "true"
{{- end }}
{{- end -}}

{{- define "ms.image" -}}
{{- $repo := default (printf "%s/%s" .Values.global.imageRegistry .Values.name) .Values.image.repository -}}
{{- printf "%s:%s" $repo (required "image.tag is required (CI writes it into apps/<service>/values-<env>.yaml)" .Values.image.tag) -}}
{{- end -}}

{{/* Upstream URL variable name: shelter -> SHELTER_URL, email-worker -> EMAIL_WORKER_URL */}}
{{- define "ms.urlVar" -}}
{{- printf "%s_URL" (. | upper | replace "-" "_") -}}
{{- end -}}

{{- define "ms.minReplicas" -}}
{{- if .Values.autoscaling.enabled -}}{{ .Values.autoscaling.minReplicas }}{{- else -}}{{ .Values.replicas }}{{- end -}}
{{- end -}}

{{/* Pod security settings that satisfy the "restricted" Pod Security Standard. */}}
{{- define "ms.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/* Environment shared by the server and the migration Job. */}}
{{- define "ms.dbEnv" -}}
- name: DB_SCHEMA
  value: {{ include "ms.schema" . | quote }}
- name: PGHOST
  value: {{ .Values.database.host | quote }}
- name: PGDATABASE
  value: {{ .Values.database.name | quote }}
- name: PGUSER
  value: {{ printf "svc_%s" (include "ms.schema" .) | quote }}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.passwordSecret }}
      key: {{ include "ms.schema" . }}
- name: DB_POOL_MAX
  value: {{ .Values.database.poolMax | quote }}
{{- end -}}
