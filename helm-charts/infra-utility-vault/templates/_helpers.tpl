{{/*
Chart name, overridable.
trunc 63 because Kubernetes names are limited to 63 characters; trimSuffix "-"
stops a truncation landing on a trailing dash, which is not a legal name.
*/}}
{{- define "vault.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name. If the release is already called "vault", avoid
producing "vault-vault".
*/}}
{{- define "vault.fullname" -}}
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
Chart name + version, for the helm.sh/chart label. The "+" in a semver build
tag is illegal in a label value, so it is replaced.
*/}}
{{- define "vault.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full label set. Goes on every object's metadata.
*/}}
{{- define "vault.labels" -}}
helm.sh/chart: {{ include "vault.chart" . }}
{{ include "vault.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels -- MUST stay stable forever. A StatefulSet's selector is
immutable, so anything that changes between releases (version, chart) must
never appear here.
*/}}
{{- define "vault.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vault.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "vault.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "vault.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Scheme-dependent values, derived from tls.enabled so no template repeats
the conditional.
*/}}
{{- define "vault.portName" -}}
{{- if .Values.tls.enabled }}https{{ else }}http{{ end }}
{{- end }}

{{- define "vault.probeScheme" -}}
{{- if .Values.tls.enabled }}HTTPS{{ else }}HTTP{{ end }}
{{- end }}
