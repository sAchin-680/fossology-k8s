{{/*
Expand the name of the chart.
*/}}
{{- define "fossology.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
If the release name already contains the chart name, we skip adding it again.
*/}}
{{- define "fossology.fullname" -}}
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

{{/*
Common labels applied to every resource.
*/}}
{{- define "fossology.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "fossology.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in pod selectors and Service selectors.
*/}}
{{- define "fossology.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fossology.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full image reference for the main fossology/fossology image.
If image.registry is set, prepends it with a /; otherwise uses unqualified name
so kind-loaded images work without a registry prefix.
Usage: {{ include "fossology.image" . }}
*/}}
{{- define "fossology.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | default "latest" -}}
{{- if .Values.image.registry -}}
{{- printf "%s/fossology/fossology:%s" .Values.image.registry $tag }}
{{- else -}}
{{- printf "fossology/fossology:%s" $tag }}
{{- end }}
{{- end }}

{{/*
Full image reference for the fossology-worker image.
Respects workers.image override when set (useful for kind where the image is
built locally as e.g. fossology-worker:poc). Falls back to image.registry/name.
Usage: {{ include "fossology.workerImage" . }}
*/}}
{{- define "fossology.workerImage" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | default "latest" -}}
{{- if .Values.workers.image -}}
{{- .Values.workers.image }}
{{- else if .Values.image.registry -}}
{{- printf "%s/fossology-worker:%s" .Values.image.registry $tag }}
{{- else -}}
{{- printf "fossology-worker:%s" $tag }}
{{- end }}
{{- end }}

{{/*
Name of the workers headless Service (also the StatefulSet's serviceName).
The StatefulSet pod FQDN pattern is:
  <name>-<ordinal>.<workerServiceName>.<namespace>.svc.cluster.local
*/}}
{{- define "fossology.workerServiceName" -}}
{{- printf "%s-workers" (include "fossology.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resolved database host — uses fossology.db.host when set, otherwise auto-derives
from the release's postgres Service name so out-of-box deploys work correctly.
*/}}
{{- define "fossology.dbHost" -}}
{{- if .Values.fossology.db.host -}}
{{- .Values.fossology.db.host -}}
{{- else -}}
{{- printf "%s-postgres" (include "fossology.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Name of the shared database Secret.
*/}}
{{- define "fossology.dbSecretName" -}}
{{- if .Values.fossology.db.existingSecret -}}
{{- .Values.fossology.db.existingSecret -}}
{{- else -}}
{{- printf "%s-db" (include "fossology.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Name of the SSH keypair Secret.
*/}}
{{- define "fossology.sshSecretName" -}}
{{- printf "%s-ssh-keys" (include "fossology.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of the shared repository PersistentVolumeClaim.
*/}}
{{- define "fossology.repoPVCName" -}}
{{- printf "%s-repo" (include "fossology.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
