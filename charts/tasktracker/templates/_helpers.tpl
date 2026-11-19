{{- /*
=============================================================================
File       : charts/tasktracker/templates/_helpers.tpl
Assignment : DSO202 Assignment 4
Descriptor : Unit III 3.2 - named templates
Purpose    : Names and labels shared by every template. Renders nothing.
=============================================================================
*/ -}}

{{/*
tasktracker.fullname - prefix of every object name. The Argo CD
Applications fix the release name to "tasktracker", so objects are named
tasktracker-backend, tasktracker-db, ... in both environments; the namespace
is what tells them apart.
*/}}
{{- define "tasktracker.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 52 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
tasktracker.labels - put on object metadata. The chart version is here and
NOT in Pod template labels: Assignment 3 showed that a chart-version label
in a Pod template restarts every Pod on any chart bump.
*/}}
{{- define "tasktracker.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tasktracker
{{- end -}}

{{/*
tasktracker.selectorLabels - stable labels for selectors and Pod templates.
Call with (dict "ctx" $ "component" "backend").
*/}}
{{- define "tasktracker.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* tasktracker.image - "repository:tag" for one tier's image block. */}}
{{- define "tasktracker.image" -}}
{{- printf "%s:%s" .repository (toString .tag) -}}
{{- end -}}
