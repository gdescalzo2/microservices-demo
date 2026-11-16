{{- define "bs.namespace" -}}
{{- printf "boutique-%s-%s" .Values.service.name .Values.environment -}}
{{- end -}}

{{- define "bs.appName" -}}
{{- printf "%s-%s" .Values.service.name .Values.environment -}}
{{- end -}}

{{- define "bs.host" -}}
{{- default (printf "%s.%s.boutique.local" .Values.service.name .Values.environment) .Values.ingress.host -}}
{{- end -}}

{{- define "bs.maxReplicas" -}}
{{- get (dict "bronze" 2 "silver" 4 "gold" 6) .Values.service.tier -}}
{{- end -}}
