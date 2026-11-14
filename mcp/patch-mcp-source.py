import sys

ROOT = sys.argv[1]

PATCHES = {
    "src/electron/electron/server.cljs": [
        (
            '(defn get-host [] (or (cfgs/get-item :server/host) "127.0.0.1"))',
            '''(defn- env-value [k]
  (let [v (aget js/process.env k)]
    (when-not (string/blank? v) v)))

(defn- env-mcp-enabled? []
  (= "true" (env-value "LOGSEQ_MCP_ENABLED")))

(defn get-host [] (or (env-value "LOGSEQ_MCP_HOST") (cfgs/get-item :server/host) "127.0.0.1"))''',
        ),
        (
            '(defn get-port [] (or (cfgs/get-item :server/port) 12315))',
            '(defn get-port [] (or (some-> (env-value "LOGSEQ_MCP_PORT") (js/parseInt 10)) (cfgs/get-item :server/port) 12315))',
        ),
        (
            ':mcp-enabled? (cfgs/get-item :server/mcp-enabled?)}))',
            ':mcp-enabled? (or (env-mcp-enabled?) (cfgs/get-item :server/mcp-enabled?))}))',
        ),
        (
            '''(defn- validate-auth-token
  [token]
  (let [token (string/replace token "Bearer " "")]
    (when-let [valid-tokens (cfgs/get-item :server/tokens)]
      (when (or (string/blank? token)
                (not (some #(or (= % token)
                                (= (:value %) token)) valid-tokens)))
        (throw (js/Error. "Access Denied!"))))))''',
            '''(defn- validate-auth-token
  [token]
  (let [token (string/replace token "Bearer " "")
        env-token (env-value "LOGSEQ_MCP_TOKEN")
        valid-tokens (cfgs/get-item :server/tokens)]
    (when (or env-token valid-tokens)
      (when (or (string/blank? token)
                (not (or (and env-token (= env-token token))
                         (some #(or (= % token)
                                    (= (:value %) token)) valid-tokens))))
        (throw (js/Error. "Access Denied!"))))))''',
        ),
        (
            '''  (let [t (setup-state-watch!)]
    (reset-state!) t))''',
            '''  (let [t (setup-state-watch!)]
    (reset-state!)
    (when (env-mcp-enabled?) (start!))
    t))''',
        ),
        (
            ':requestTimeout        (* 1000 42)',
            ':requestTimeout        (* 1000 60 30)',
        ),
    ],
    "src/main/frontend/handler/common/developer.cljs": [
        (
            '''(defn ^:export rtc-start []
  (rtc-handler/<rtc-start! (state/get-current-repo)))''',
            '''(defn ^:export rtc-start []
  (rtc-handler/<rtc-start! (state/get-current-repo)))

(defn ^:export download-graph-by-name! [id-token access-token refresh-token sync-url graph-name]
  (state/set-auth-id-token id-token)
  (state/set-auth-access-token access-token)
  (state/set-auth-refresh-token refresh-token)
  (js/localStorage.setItem "id-token" id-token)
  (js/localStorage.setItem "access-token" access-token)
  (js/localStorage.setItem "refresh-token" refresh-token)
  (js/localStorage.setItem "sync-server-url" sync-url)
  (state/set-current-repo! (str "logseq_db_" graph-name))
  (p/let [graphs (rtc-handler/<get-remote-graphs)
          graph (some #(when (= graph-name (:GraphName %)) %) graphs)]
    (if graph
      (rtc-handler/<rtc-download-graph! graph-name (:GraphUUID graph) (:graph-e2ee? graph))
      (throw (js/Error. (str "remote graph not found: " graph-name))))))''',
        ),
    ],
    "src/main/frontend/worker/sync/download.cljs": [
        (
            '(defn download-graph-by-id!\n',
            '''(defn- rebase-snapshot-url
  "The sync server builds the snapshot stream URL from its own origin, which is localhost
  inside the server container. Keep the path and query, fetch through the configured base."
  [url base]
  (let [u (js/URL. url)]
    (str base (.-pathname u) (.-search u))))

(defn download-graph-by-id!\n''',
        ),
        (
            '(js/fetch (:url snapshot-resp)',
            '(js/fetch (rebase-snapshot-url (:url snapshot-resp) base)',
        ),
    ],
    "src/main/logseq/api.cljs": [
        (
            '[logseq.api.editor :as api-editor]',
            '[logseq.api.editor :as api-editor]\n            [frontend.handler.common.developer :as developer]',
        ),
        (
            '(def ^:export quit api-app/quit)',
            '(def ^:export quit api-app/quit)\n(def ^:export download_graph_by_name developer/download-graph-by-name!)',
        ),
    ],
    "src/electron/electron/mcp_server.cljs": [
        (
            ':allowedHosts #js [(str host ":" port)]})',
            ':allowedHosts #js [(str host ":" port) (str "localhost:" port) (str "127.0.0.1:" port)]})',
        ),
    ],
}


def apply(path, replacements):
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    crlf = "\r\n" in text
    for old, new in replacements:
        if crlf:
            old = old.replace("\n", "\r\n")
            new = new.replace("\n", "\r\n")
        count = text.count(old)
        if count != 1:
            sys.exit(f"expected one match in {path}, found {count}: {old[:60]!r}")
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print("patched", path, len(replacements), "edits")


for rel, replacements in PATCHES.items():
    apply(f"{ROOT}/{rel}", replacements)
