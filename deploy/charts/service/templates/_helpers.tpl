{{/* The name of every object: the release name, or nameOverride. */}}
{{- define "service.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* CLAUDE.md → Conventions: name, part-of, owner and tier, the last two from catalog/<service>.yaml.
     The pods' labels: nothing that changes with the chart's own version, so a chart release alone
     never restarts a pod. */}}
{{- define "service.podLabels" -}}
{{ include "service.selectorLabels" . }}
app.kubernetes.io/part-of: rarebit
app.kubernetes.io/version: {{ .Values.image.tag | splitList "@" | first | trunc 63 | trimSuffix "-" | quote }}
owner: {{ .Values.owner | quote }}
tier: {{ .Values.tier | quote }}
{{- end -}}

{{/* The other objects' labels also say which chart made them. */}}
{{- define "service.labels" -}}
{{ include "service.podLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "service.image" -}}
{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}

{{- define "service.probe" -}}
{{- if eq .type "http" }}
httpGet:
  path: {{ .probe.path }}
  port: {{ .portName }}
{{- else }}
tcpSocket:
  port: {{ .portName }}
{{- end }}
timeoutSeconds: {{ .probe.timeoutSeconds }}
periodSeconds: {{ .probe.periodSeconds }}
failureThreshold: {{ .probe.failureThreshold }}
{{- with .probe.initialDelaySeconds }}
initialDelaySeconds: {{ . }}
{{- end }}
{{- end -}}

{{/* The pod spec a Deployment and a Job share: non-root, read-only, no capabilities, no token. */}}
{{- define "service.podSpec" -}}
serviceAccountName: {{ include "service.name" . }}
automountServiceAccountToken: false
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .Values.securityContext.runAsUser }}
  runAsGroup: {{ .Values.securityContext.runAsGroup }}
  seccompProfile:
    type: RuntimeDefault
{{- if eq .Values.mode "job" }}
restartPolicy: Never
{{- else }}
terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
{{- if gt (int .Values.replicas) 1 }}
# Spread across zones and nodes, counting only this rollout's pods (pod-template-hash), so the old
# pods leaving don't pile the new ones onto one node.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    matchLabelKeys: [pod-template-hash]
    labelSelector:
      matchLabels:
        {{- include "service.selectorLabels" . | nindent 8 }}
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    matchLabelKeys: [pod-template-hash]
    labelSelector:
      matchLabels:
        {{- include "service.selectorLabels" . | nindent 8 }}
{{- end }}
{{- if .Values.fastNodeFailover }}
tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
{{- end }}
{{- end }}
containers:
  - name: {{ include "service.name" . }}
    image: {{ include "service.image" . }}
    imagePullPolicy: IfNotPresent
    {{- with .Values.args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if eq .Values.mode "deployment" }}
    ports:
      - name: {{ .Values.portName }}
        containerPort: {{ .Values.port }}
      {{- with .Values.metricsPort }}
      - name: metrics
        containerPort: {{ . }}
      {{- end }}
    {{- end }}
    {{- $env := concat .Values.env .Values.extraEnv }}
    {{- with $env }}
    env:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    resources:
      {{- toYaml .Values.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      privileged: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    {{- if eq .Values.mode "deployment" }}
    readinessProbe:
      {{- include "service.probe" (dict "probe" .Values.probes.readiness "type" .Values.probes.type "portName" .Values.portName) | nindent 6 }}
    livenessProbe:
      {{- include "service.probe" (dict "probe" .Values.probes.liveness "type" .Values.probes.type "portName" .Values.portName) | nindent 6 }}
    {{- if gt (int .Values.lifecycle.preStopSleepSeconds) 0 }}
    lifecycle:
      preStop:
        sleep:
          seconds: {{ .Values.lifecycle.preStopSleepSeconds }}
    {{- end }}
    {{- end }}
    {{- if or .Values.tmpVolume .Values.volumeMounts }}
    volumeMounts:
      {{- if .Values.tmpVolume }}
      - name: tmp
        mountPath: /tmp
      {{- end }}
      {{- with .Values.volumeMounts }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
{{- if or .Values.tmpVolume .Values.volumes }}
volumes:
  {{- if .Values.tmpVolume }}
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
  {{- end }}
  {{- with .Values.volumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end -}}
