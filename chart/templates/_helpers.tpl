{{- define "temp-poc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "temp-poc.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "temp-poc.labels" -}}
app.kubernetes.io/name: {{ include "temp-poc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: temp-poc
scalex.io/release: {{ .Release.Name }}
{{- end }}

{{- define "temp-poc.image" -}}
{{- if .digest -}}
{{- printf "%s:%s@%s" .repository .tag .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end }}

{{- define "temp-poc.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "temp-poc.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end }}
