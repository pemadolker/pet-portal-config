#!/usr/bin/env python3
"""Builds the seven Grafana dashboards (proposal section 9) as JSON files.

Dashboards as code: edit this file, run `python3 build.py`, commit the JSON.
Kustomize turns each JSON into a ConfigMap labelled grafana_dashboard=1, and
Grafana's sidecar loads it, so the dashboards come back on their own after a
cluster rebuild (E1).

Methods: RED (rate, errors, duration) for services; USE (utilisation,
saturation, errors) for nodes, data stores and queues.
"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
TEMPO = {"type": "tempo", "uid": "tempo"}
OUT = pathlib.Path(__file__).parent


class Board:
    def __init__(self, uid, title, description, tags, variables=()):
        self.uid, self.title, self.description, self.tags = uid, title, description, tags
        self.variables = list(variables)
        self.panels = []
        self.y = 0
        self.x = 0
        self.row_h = 0
        self.next_id = 1

    def _place(self, w, h):
        if self.x + w > 24:
            self.x, self.y = 0, self.y + self.row_h
            self.row_h = 0
        pos = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.x += w
        self.row_h = max(self.row_h, h)
        return pos

    def row(self, title):
        if self.x:
            self.x, self.y, self.row_h = 0, self.y + self.row_h, 0
        self.panels.append({"type": "row", "title": title, "id": self._id(), "collapsed": False,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def _id(self):
        self.next_id += 1
        return self.next_id

    def ts(self, title, targets, w=12, h=8, unit="short", desc="", stack=False, thresholds=None, legend="table", min_=None, max_=None):
        fc = {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 12 if stack else 6,
                                                    "stacking": {"mode": "normal" if stack else "none"},
                                                    "showPoints": "never"}},
              "overrides": []}
        if min_ is not None:
            fc["defaults"]["min"] = min_
        if max_ is not None:
            fc["defaults"]["max"] = max_
        if thresholds:
            fc["defaults"]["thresholds"] = {"mode": "absolute", "steps": thresholds}
            fc["defaults"]["custom"]["thresholdsStyle"] = {"mode": "line+area"}
        self.panels.append({
            "type": "timeseries", "title": title, "description": desc, "id": self._id(),
            "datasource": targets[0].get("datasource", PROM), "gridPos": self._place(w, h),
            "fieldConfig": fc, "targets": targets,
            "options": {"legend": {"displayMode": legend, "placement": "bottom", "calcs": ["lastNotNull", "max"] if legend == "table" else []},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
        })

    def stat(self, title, expr, w=4, h=4, unit="short", desc="", steps=None, decimals=None, text_mode="auto", mappings=None):
        fc = {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps or [{"color": "green", "value": None}]},
                           "mappings": mappings or []}, "overrides": []}
        if decimals is not None:
            fc["defaults"]["decimals"] = decimals
        self.panels.append({
            "type": "stat", "title": title, "description": desc, "id": self._id(), "datasource": PROM,
            "gridPos": self._place(w, h), "fieldConfig": fc,
            "targets": [q(expr, "")],
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "background", "graphMode": "area", "textMode": text_mode, "justifyMode": "center"},
        })

    def table(self, title, targets, w=12, h=8, desc="", transformations=None):
        self.panels.append({"type": "table", "title": title, "description": desc, "id": self._id(),
                            "datasource": targets[0].get("datasource", PROM), "gridPos": self._place(w, h),
                            "targets": targets, "transformations": transformations or [],
                            "fieldConfig": {"defaults": {}, "overrides": []}, "options": {"showHeader": True}})

    def logs(self, title, expr, w=24, h=10, desc=""):
        self.panels.append({"type": "logs", "title": title, "description": desc, "id": self._id(), "datasource": LOKI,
                            "gridPos": self._place(w, h),
                            "targets": [{"datasource": LOKI, "expr": expr, "refId": "A", "queryType": "range"}],
                            "options": {"showTime": True, "wrapLogMessage": True, "prettifyLogMessage": False,
                                        "enableLogDetails": True, "sortOrder": "Descending", "dedupStrategy": "none"}})

    def traces(self, title, query, w=24, h=10, desc=""):
        self.panels.append({"type": "table", "title": title, "description": desc, "id": self._id(), "datasource": TEMPO,
                            "gridPos": self._place(w, h),
                            "targets": [{"datasource": TEMPO, "queryType": "traceql", "query": query, "limit": 20, "tableType": "traces", "refId": "A"}],
                            "fieldConfig": {"defaults": {}, "overrides": []}, "options": {"showHeader": True}})

    def node_graph(self, title, w=24, h=12, desc=""):
        self.panels.append({"type": "nodeGraph", "title": title, "description": desc, "id": self._id(), "datasource": TEMPO,
                            "gridPos": self._place(w, h),
                            "targets": [{"datasource": TEMPO, "queryType": "serviceMap", "refId": "A",
                                         "serviceMapQuery": '{k8s_namespace_name="$namespace"}'}]})

    def text(self, content, w=24, h=3):
        self.panels.append({"type": "text", "title": "", "id": self._id(), "gridPos": self._place(w, h),
                            "options": {"mode": "markdown", "content": content}})

    def json(self):
        return {
            "uid": self.uid, "title": self.title, "description": self.description, "tags": ["pet-portal"] + self.tags,
            "timezone": "browser", "schemaVersion": 39, "version": 1, "editable": True, "graphTooltip": 1,
            "refresh": "10s", "time": {"from": "now-30m", "to": "now"},
            "templating": {"list": self.variables}, "annotations": {"list": [{
                "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True,
                "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
            "links": [{"title": "Pet Portal dashboards", "type": "dashboards", "tags": ["pet-portal"], "asDropdown": True}],
            "panels": self.panels,
        }


def q(expr, legend="{{service}}", ref="A", instant=False):
    t = {"datasource": PROM, "expr": expr, "legendFormat": legend, "refId": ref}
    if instant:
        t["instant"] = True
        t["format"] = "table"
    return t


def var_query(name, label, query, multi=False, include_all=False, ds=PROM, regex=""):
    return {"name": name, "label": label, "type": "query", "datasource": ds, "query": {"query": query, "refId": name},
            "definition": query, "refresh": 2, "multi": multi, "includeAll": include_all, "regex": regex,
            "current": {}, "sort": 1}


NS_VAR = var_query("namespace", "Environment", "label_values(kube_namespace_labels, namespace)", regex="pet-portal-.*")
NS_VAR["current"] = {"text": "pet-portal-prod", "value": "pet-portal-prod"}
SVC_VAR = var_query("service", "Service", 'label_values(http_requests_total{namespace="$namespace"}, service)', multi=True, include_all=True)
GREEN, AMBER, RED = "green", "orange", "red"


# 1 --------------------------------------------------------------- cluster
b = Board("pp-cluster", "1. Cluster and nodes", "USE view of the Kind cluster: is any node short of CPU or memory?", ["cluster", "use"])
b.row("Nodes")
b.stat("Nodes ready", 'sum(kube_node_status_condition{condition="Ready",status="true"})', steps=[{"color": RED, "value": None}, {"color": AMBER, "value": 3}, {"color": GREEN, "value": 4}])
b.stat("Pods running", 'sum(kube_pod_status_phase{phase="Running"})')
b.stat("Pods not ready", 'sum(kube_pod_status_ready{condition="false"} * on(namespace,pod) group_left() (kube_pod_status_phase{phase="Running"}==1)) or vector(0)', steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 3}])
b.stat("Restarts (1 h)", 'sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)', decimals=0, steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}])
b.stat("Cluster CPU used", '1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))', unit="percentunit", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 0.7}, {"color": RED, "value": 0.9}])
b.stat("Cluster memory used", '1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)', unit="percentunit", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 0.75}, {"color": RED, "value": 0.9}])
b.ts("CPU utilisation per node", [q('1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m]))', "{{instance}}")], unit="percentunit", max_=1)
b.ts("Memory utilisation per node", [q('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}")], unit="percentunit", max_=1)
b.ts("Pods per node", [q('sum by (node) (kube_pod_info{node!=""})', "{{node}}")])
b.ts("CPU saturation (load per core)", [q('node_load1 / on(instance) count by (instance) (node_cpu_seconds_total{mode="idle"})', "{{instance}}")], desc="Above 1 means work is queuing for CPU.")
b.ts("Network received per node", [q('sum by (instance) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|cali.*"}[2m]))', "{{instance}}")], unit="Bps")
b.ts("Disk used (Kind node volume)", [q('1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}', "{{instance}}")], unit="percentunit", max_=1)
b.row("Delivery")
b.table("Argo CD applications", [q('argocd_app_info', "", instant=True)], w=24, h=9, desc="Sync and health of every Argo CD application (E1, E6).",
        transformations=[{"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True, "__name__": True, "container": True, "endpoint": True, "instance": True, "job": True, "pod": True, "service": True, "namespace": True, "repo": True, "autosync_enabled": False},
                                                         "indexByName": {"name": 0, "project": 1, "dest_namespace": 2, "sync_status": 3, "health_status": 4}}}])
(OUT / "01-cluster.json").write_text(json.dumps(b.json(), indent=2))


# 2 --------------------------------------------------------------- namespaces
b = Board("pp-namespaces", "2. Namespaces, resources and quotas", "What each namespace uses against its ResourceQuota, and which pods use it.", ["capacity"], [NS_VAR])
b.row("Quota ($namespace)")
for res, title in [("requests.cpu", "CPU requests"), ("requests.memory", "Memory requests"), ("limits.memory", "Memory limits"), ("pods", "Pods")]:
    b.stat(f"{title} used of quota",
           f'max(kube_resourcequota{{namespace="$namespace",resource="{res}",type="used"}}) / max(kube_resourcequota{{namespace="$namespace",resource="{res}",type="hard"}})',
           w=6, unit="percentunit", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 0.75}, {"color": RED, "value": 0.9}],
           desc="Alert PortalQuotaNearlyUsed fires at 90 %.")
b.row("Usage by pod")
b.ts("CPU by pod", [q('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="$namespace",container!="",container!="POD"}[2m]))', "{{pod}}")], unit="cores", stack=True, legend="list")
b.ts("Memory (working set) by pod", [q('sum by (pod) (container_memory_working_set_bytes{namespace="$namespace",container!="",container!="POD"})', "{{pod}}")], unit="bytes", stack=True, legend="list")
b.ts("Memory used vs limit (top 10)", [q('topk(10, max by (pod, container) (container_memory_working_set_bytes{namespace="$namespace",container!=""} / on(namespace,pod,container) kube_pod_container_resource_limits{namespace="$namespace",resource="memory"}))', "{{pod}} / {{container}}")], unit="percentunit", max_=1, desc="Near 100 % means the next spike gets the container OOM-killed.", legend="list")
b.ts("Container restarts", [q('sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="$namespace"}[10m]))', "{{pod}}")], legend="list")
b.row("All namespaces")
b.ts("CPU by namespace", [q('sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[2m]))', "{{namespace}}")], unit="cores", stack=True)
b.ts("Memory by namespace", [q('sum by (namespace) (container_memory_working_set_bytes{container!=""})', "{{namespace}}")], unit="bytes", stack=True)
(OUT / "02-namespaces.json").write_text(json.dumps(b.json(), indent=2))


# 3 --------------------------------------------------------------- service RED
b = Board("pp-services", "3. Service overview (RED)", "Rate, errors and duration for every portal service. Start here when something is slow or failing.", ["red", "services"], [NS_VAR, SVC_VAR])
b.row("Core path SLO ($namespace)")
core = 'service=~"frontend|api-gateway|login|pet|search|adoption"'
# "or vector(0)": with no 5xx at all the error series does not exist, and the panel must say 100 %, not "No data".
b.stat("Availability, core path (1 h)", f'1 - ((sum(rate(http_requests_total{{namespace="$namespace",{core},status_code=~"5.."}}[1h])) or vector(0)) / sum(rate(http_requests_total{{namespace="$namespace",{core}}}[1h])))',
       w=6, unit="percentunit", decimals=2, steps=[{"color": RED, "value": None}, {"color": AMBER, "value": 0.99}, {"color": GREEN, "value": 0.999}], desc="Target: above 99 % (proposal section 12).")
b.stat("p95 latency at the gateway (5 m)", 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="$namespace",service="api-gateway"}[5m])))',
       w=6, unit="s", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 0.3}, {"color": RED, "value": 0.5}], desc="Target: below 500 ms.")
b.stat("Requests per second", 'sum(rate(http_requests_total{namespace="$namespace",service="api-gateway"}[1m]))', w=6, unit="reqps")
b.stat("5xx per second", 'sum(rate(http_requests_total{namespace="$namespace",status_code=~"5.."}[1m])) or vector(0)', w=6, unit="reqps", steps=[{"color": GREEN, "value": None}, {"color": RED, "value": 0.1}])
b.row("Rate, errors, duration by service")
sel = 'namespace="$namespace",service=~"$service"'
b.ts("Rate", [q(f'sum by (service) (rate(http_requests_total{{{sel}}}[1m]))')], unit="reqps")
b.ts("Error ratio (5xx)", [q(f'(sum by (service) (rate(http_requests_total{{{sel},status_code=~"5.."}}[5m])) or (0 * sum by (service) (rate(http_requests_total{{{sel}}}[5m])))) / sum by (service) (rate(http_requests_total{{{sel}}}[5m]))')], unit="percentunit", thresholds=[{"color": "transparent", "value": None}, {"color": RED, "value": 0.05}])
b.ts("p95 duration", [q(f'histogram_quantile(0.95, sum by (service, le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))')], unit="s", thresholds=[{"color": "transparent", "value": None}, {"color": RED, "value": 0.5}])
b.ts("p50 duration", [q(f'histogram_quantile(0.5, sum by (service, le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m])))')], unit="s")
b.ts("4xx by service (refused requests)", [q(f'sum by (service, status_code) (rate(http_requests_total{{{sel},status_code=~"4.."}}[5m]))', "{{service}} {{status_code}}")], unit="reqps", desc="409 on adoption is the one-winner rule saying no; 401/403 are auth refusals; 429 is the gateway rate limit.")
b.ts("Slowest routes (p95)", [q(f'topk(8, histogram_quantile(0.95, sum by (service, route, le) (rate(http_request_duration_seconds_bucket{{{sel}}}[5m]))))', "{{service}} {{route}}")], unit="s", legend="list")
b.row("Dependencies")
b.ts("Calls to other services by outcome", [q(f'sum by (service, target, outcome) (rate(upstream_requests_total{{{sel}}}[5m]))', "{{service}} -> {{target}} ({{outcome}})")], unit="reqps", legend="list", desc="circuit_open means the caller is failing fast because the target kept failing.")
b.ts("Gateway: time spent in each upstream (p95)", [q('histogram_quantile(0.95, sum by (upstream, le) (rate(gateway_upstream_duration_seconds_bucket{namespace="$namespace"}[5m])))', "{{upstream}}")], unit="s")
b.ts("Gateway: rate-limited and auth failures", [q('sum(rate(gateway_rate_limited_total{namespace="$namespace"}[5m])) or vector(0)', "rate-limited"), q('sum by (reason) (rate(gateway_auth_failures_total{namespace="$namespace"}[5m]))', "auth: {{reason}}", "B")], unit="reqps")
b.ts("Pods ready per service", [q('sum by (deployment) (kube_deployment_status_replicas_ready{namespace="$namespace"})', "{{deployment}}")], legend="list")
(OUT / "03-services.json").write_text(json.dumps(b.json(), indent=2))


# 4 --------------------------------------------------------------- adoption rush
b = Board("pp-adoption", "4. Adoption rush", "The hot path during a rush (E2, E3): who wins, how fast, how many pods.", ["adoption", "e2", "e3"], [NS_VAR])
b.text("**One-winner rule.** `accepted` can never exceed the number of pets on offer; every other attempt gets `409 PET_TAKEN`. "
       "In E2, 2,000 users for 10 pets must show exactly 10 accepted.", h=2)
b.stat("Accepted (since start of range)", 'sum(increase(adoption_attempts_total{namespace="$namespace",result="accepted"}[$__range])) or vector(0)', w=6, decimals=0)
b.stat("Taken (409)", 'sum(increase(adoption_attempts_total{namespace="$namespace",result="taken"}[$__range])) or vector(0)', w=6, decimals=0, steps=[{"color": "blue", "value": None}])
b.stat("Adoption pods", 'kube_deployment_status_replicas_ready{namespace="$namespace",deployment="adoption"}', w=6, steps=[{"color": "blue", "value": None}, {"color": AMBER, "value": 6}], desc="2 at rest, up to 6 under load (KEDA).")
b.stat("Requests/s per adoption pod", 'sum(rate(http_requests_total{namespace="$namespace",service="adoption"}[1m])) / sum(kube_deployment_status_replicas_ready{namespace="$namespace",deployment="adoption"})', w=6, unit="reqps", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 50}], desc="KEDA target: 50 per pod.")
b.ts("Applications by result", [q('sum by (result) (rate(adoption_attempts_total{namespace="$namespace"}[1m]))', "{{result}}")], unit="reqps", stack=True)
b.ts("Adoption request rate vs scale target", [q('sum(rate(http_requests_total{namespace="$namespace",service="adoption"}[1m]))', "requests/s"),
                                                   q('50 * sum(kube_deployment_status_replicas_ready{namespace="$namespace",deployment="adoption"})', "capacity at 50/s per pod", "B")], unit="reqps")
b.ts("POST /adoptions duration", [q('histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="$namespace",service="adoption",route="/adoptions",method="POST"}[1m])))', "p50"),
                                  q('histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="$namespace",service="adoption",route="/adoptions",method="POST"}[1m])))', "p95", "B"),
                                  q('histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="$namespace",service="adoption",route="/adoptions",method="POST"}[1m])))', "p99", "C")], unit="s")
b.ts("Adoption pods: desired vs ready", [q('kube_horizontalpodautoscaler_status_desired_replicas{namespace="$namespace",horizontalpodautoscaler="keda-hpa-adoption"}', "desired"),
                                         q('kube_deployment_status_replicas_ready{namespace="$namespace",deployment="adoption"}', "ready", "B"),
                                         q('kube_horizontalpodautoscaler_spec_max_replicas{namespace="$namespace",horizontalpodautoscaler="keda-hpa-adoption"}', "max", "C")])
b.ts("CPU per adoption pod", [q('sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="$namespace",container="adoption"}[1m]))', "{{pod}}")], unit="cores", legend="list")
b.ts("PostgreSQL connections from adoption", [q('sum(pg_stat_activity_count{namespace="$namespace",usename="svc_adoption"}) or sum(pg_stat_activity_count{namespace="$namespace"})', "connections")])
b.ts("Decisions by staff", [q('sum by (decision) (increase(adoption_decisions_total{namespace="$namespace"}[5m]))', "{{decision}}")], stack=True)
b.ts("Gateway 429s during the rush", [q('sum(rate(gateway_rate_limited_total{namespace="$namespace"}[1m])) or vector(0)', "rate-limited/s")], unit="reqps")
(OUT / "04-adoption-rush.json").write_text(json.dumps(b.json(), indent=2))


# 5 --------------------------------------------------------------- autoscaling
b = Board("pp-autoscaling", "5. Autoscaling", "Every KEDA-scaled service: replicas against min/max and the signal driving them (E3, E4).", ["keda", "hpa", "e3", "e4"], [NS_VAR])
b.row("Replicas")
b.ts("Current replicas per scaled service", [q('kube_horizontalpodautoscaler_status_current_replicas{namespace="$namespace"}', "{{horizontalpodautoscaler}}")], w=24, h=9, legend="table")
b.table("Scaling limits", [q('kube_horizontalpodautoscaler_spec_min_replicas{namespace="$namespace"}', "", "A", instant=True),
                           q('kube_horizontalpodautoscaler_spec_max_replicas{namespace="$namespace"}', "", "B", instant=True),
                           q('kube_horizontalpodautoscaler_status_current_replicas{namespace="$namespace"}', "", "C", instant=True)],
        w=24, h=7, transformations=[{"id": "merge"}, {"id": "organize", "options": {"excludeByName": {"Time": True, "__name__": True, "container": True, "endpoint": True, "instance": True, "job": True, "pod": True, "service": True},
                                                                                     "renameByName": {"Value #A": "min", "Value #B": "max", "Value #C": "current"}}}])
b.row("Signals")
b.ts("KEDA scaler metric value", [q('keda_scaler_metrics_value{exported_namespace="$namespace"} or keda_scaler_metrics_value{namespace="$namespace"}', "{{scaledObject}} {{scaler}}")], desc="The number KEDA compares with each trigger's target.")
b.ts("KEDA scaler errors", [q('sum by (scaledObject) (rate(keda_scaler_errors_total[5m])) or vector(0)', "{{scaledObject}}")], desc="Non-zero means KEDA cannot read a trigger (Prometheus or Redis unreachable).")
b.ts("email.queue: waiting and in progress", [q('max(event_consumer_lag{namespace="$namespace",stream="email.queue"})', "lag (not yet read)"),
                                              q('max(event_consumer_pending{namespace="$namespace",stream="email.queue"})', "pending (read, not acked)", "B")],
     desc="email-worker scales at 20 waiting emails per pod.")
b.ts("Emails sent per second", [q('sum(rate(emails_sent_total{namespace="$namespace",result="sent"}[1m]))', "sent/s"), q('sum(rate(emails_sent_total{namespace="$namespace",result="failed"}[1m])) or vector(0)', "failed/s", "B")], unit="reqps")
b.ts("CPU vs request for CPU-scaled services", [q('sum by (container) (rate(container_cpu_usage_seconds_total{namespace="$namespace",container=~"frontend|api-gateway|login|pet|search"}[2m])) / sum by (container) (kube_pod_container_resource_requests{namespace="$namespace",resource="cpu",container=~"frontend|api-gateway|login|pet|search"})', "{{container}}")],
     unit="percentunit", thresholds=[{"color": "transparent", "value": None}, {"color": AMBER, "value": 0.7}], desc="They scale out above 70 %.")
b.ts("Event consumer lag, all streams", [q('max by (stream, group) (event_consumer_lag{namespace="$namespace"})', "{{stream}} -> {{group}}")], legend="list")
(OUT / "05-autoscaling.json").write_text(json.dumps(b.json(), indent=2))


# 6 --------------------------------------------------------------- data stores
b = Board("pp-data", "6. Data stores", "PostgreSQL, Redis Streams and the etcd registry (USE).", ["postgres", "redis", "etcd"], [NS_VAR])
b.row("PostgreSQL ($namespace)")
b.stat("PostgreSQL up", 'max(pg_up{namespace="$namespace"})', w=4, mappings=[{"type": "value", "options": {"0": {"text": "DOWN", "color": RED}, "1": {"text": "UP", "color": GREEN}}}], steps=[{"color": RED, "value": None}, {"color": GREEN, "value": 1}])
b.stat("Connections used", 'sum(pg_stat_activity_count{namespace="$namespace"}) / max(pg_settings_max_connections{namespace="$namespace"})', w=4, unit="percentunit", steps=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 0.7}, {"color": RED, "value": 0.9}])
b.stat("Database size", 'max(pg_database_size_bytes{namespace="$namespace",datname="petportal"})', w=4, unit="bytes")
b.stat("Deadlocks (1 h)", 'sum(increase(pg_stat_database_deadlocks{namespace="$namespace"}[1h])) or vector(0)', w=4, decimals=0, steps=[{"color": GREEN, "value": None}, {"color": RED, "value": 1}])
b.stat("Redis up", 'max(redis_up{namespace="$namespace"})', w=4, mappings=[{"type": "value", "options": {"0": {"text": "DOWN", "color": RED}, "1": {"text": "UP", "color": GREEN}}}], steps=[{"color": RED, "value": None}, {"color": GREEN, "value": 1}])
b.stat("Registry members with a leader", 'sum(etcd_server_has_leader{namespace="registry"})', w=4, steps=[{"color": RED, "value": None}, {"color": AMBER, "value": 2}, {"color": GREEN, "value": 3}], desc="3 of 3 normally; 2 still has quorum (E8).")
b.ts("Transactions per second", [q('sum(rate(pg_stat_database_xact_commit{namespace="$namespace",datname="petportal"}[1m]))', "commits"), q('sum(rate(pg_stat_database_xact_rollback{namespace="$namespace",datname="petportal"}[1m]))', "rollbacks", "B")])
b.ts("Connections by role (service)", [q('sum by (usename) (pg_stat_activity_count{namespace="$namespace",usename=~"svc_.*"})', "{{usename}}")], stack=True, legend="list")
b.ts("Row locks waiting", [q('sum by (mode) (pg_locks_count{namespace="$namespace",datname="petportal"})', "{{mode}}")], legend="list", desc="RowExclusiveLock spikes during an adoption rush are the one-winner rule serialising updates.")
b.ts("Rows changed per second", [q('sum(rate(pg_stat_database_tup_updated{namespace="$namespace",datname="petportal"}[1m]))', "updated"), q('sum(rate(pg_stat_database_tup_inserted{namespace="$namespace",datname="petportal"}[1m]))', "inserted", "B")])
b.row("Redis Streams ($namespace)")
b.ts("Stream length", [q('max by (stream) (redis_stream_length{namespace="$namespace"})', "{{stream}}")], legend="list")
b.ts("Consumer group lag", [q('max by (stream, group) (redis_stream_group_lag{namespace="$namespace"}) or max by (stream, group) (event_consumer_lag{namespace="$namespace"})', "{{stream}} -> {{group}}")], legend="list")
b.ts("Redis memory used vs max", [q('max(redis_memory_used_bytes{namespace="$namespace"})', "used"), q('max(redis_memory_max_bytes{namespace="$namespace"})', "maxmemory", "B")], unit="bytes")
b.ts("Events consumed by outcome", [q('sum by (outcome) (rate(events_consumed_total{namespace="$namespace"}[5m]))', "{{outcome}}")], unit="reqps", desc="dead_lettered > 0 means a message failed 5 times and went to <stream>.dlq.")
b.row("etcd service registry")
b.ts("Live instances per service (registry)", [q('max by (upstream) (gateway_registry_instances{namespace="$namespace"})', "{{upstream}}")], legend="list", desc="As seen by the gateway's watch. Drops to 0 for a service mean the gateway is using Service DNS.")
b.ts("Leader changes and failed proposals", [q('sum(increase(etcd_server_leader_changes_seen_total{namespace="registry"}[10m]))', "leader changes"), q('sum(rate(etcd_server_proposals_failed_total{namespace="registry"}[5m]))', "failed proposals/s", "B")])
b.ts("Registry DB size", [q('max by (pod) (etcd_mvcc_db_total_size_in_bytes{namespace="registry"})', "{{pod}}")], unit="bytes")
b.ts("Gateway upstream discovery", [q('sum by (source) (rate(gateway_upstream_discovery_total{namespace="$namespace"}[5m]))', "{{source}}")], unit="reqps", desc="registry = pod address from etcd; dns = fallback to the Kubernetes Service.")
(OUT / "06-data-stores.json").write_text(json.dumps(b.json(), indent=2))


# 7 --------------------------------------------------------------- logs and traces
b = Board("pp-logs-traces", "7. Logs and traces", "From a symptom to the cause: errors in logs, slow traces, and the service map (E10).", ["loki", "tempo", "e10"],
          [NS_VAR, var_query("svc", "Service", 'label_values(http_requests_total{namespace="$namespace"}, service)', include_all=True)])
b.text("Click a **trace id** in a log line to open the trace in Tempo; from a span, **Logs for this span** goes back to Loki. "
       "Slow (> 500 ms) and failed traces are always kept by the collector; 20 % of the rest.", h=2)
b.ts("Log lines by level", [{"datasource": LOKI, "expr": 'sum by (level) (count_over_time({namespace="$namespace", app=~"$svc"} [1m]))', "legendFormat": "{{level}}", "refId": "A"}], w=12, stack=True)
b.ts("Error logs by service", [{"datasource": LOKI, "expr": 'sum by (app) (count_over_time({namespace="$namespace", level=~"error|fatal"} [1m]))', "legendFormat": "{{app}}", "refId": "A"}], w=12, stack=True)
b.logs("Errors and warnings", '{namespace="$namespace", app=~"$svc", level=~"warn|error|fatal"}', h=10)
b.traces("Slow or failed requests (TraceQL)", '{ resource.k8s.namespace.name = "$namespace" && (status = error || duration > 500ms) }', h=9)
b.node_graph("Service map (from traces)", h=12)
b.ts("Requests between services (from spans)", [q('sum by (client, server) (rate(traces_service_graph_request_total[5m]))', "{{client}} -> {{server}}")], w=12, legend="list", unit="reqps")
b.ts("Failed calls between services (from spans)", [q('sum by (client, server) (rate(traces_service_graph_request_failed_total[5m])) or vector(0)', "{{client}} -> {{server}}")], w=12, legend="list", unit="reqps")
b.logs("All logs for the selected service", '{namespace="$namespace", app=~"$svc"}', h=12)
(OUT / "07-logs-traces.json").write_text(json.dumps(b.json(), indent=2))

print("wrote", sorted(p.name for p in OUT.glob("*.json")))
