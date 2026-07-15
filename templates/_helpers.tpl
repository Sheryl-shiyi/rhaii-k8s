{{- define "rhaii.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rhaii.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rhaii.labels" -}}
app.kubernetes.io/name: {{ include "rhaii.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.vllm.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rhaii.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rhaii.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "rhaii.registrySecretName" -}}
{{- if .Values.registrySecret.existingSecret }}
{{- .Values.registrySecret.existingSecret }}
{{- else }}
{{- include "rhaii.fullname" . }}-registry
{{- end }}
{{- end }}

{{- define "rhaii.pvcName" -}}
{{- if .Values.storage.existingClaim }}
{{- .Values.storage.existingClaim }}
{{- else }}
{{- include "rhaii.fullname" . }}-model-cache
{{- end }}
{{- end }}
