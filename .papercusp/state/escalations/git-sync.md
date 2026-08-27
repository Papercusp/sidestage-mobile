---
authority: null
body_embedding_mode: "gemma"
body_tsv: "'1787845027120':62A '33':18A,74A 'admiss':32A,36A 'admissionpersistenceerror':34A 'attent':68A 'block':48A 'canon':25A 'commit':50A,77A 'config':23A 'consecut':15A,75A 'could':38A,51A 'declar':46A,57A 'detail':63A 'dirti':54A 'durabl':35A 'emit':60A 'error':5A,16A,19A 'fail':29A,33A,73A 'failur':14A,71A 'generat':45A 'git':3A,65A 'git-sync':64A 'git-sync-error':2A 'har':6A 'inspect':53A 'kind':1A 'messag':24A,44A 'mobil':10A 'need':67A 'origin':80A 'overs':59A 'path':55A 'persist':41A 'push':13A,70A,72A 'push-failur':12A,69A 'reach':79A 'reason':11A 'record':37A 'regener':58A 'repair':47A 'scope':20A,42A 'sidecar':31A 'sidestag':9A 'sidestage-mobil':8A 'slug':7A 'spawner':30A 'submodul':22A,26A 'submodule-config':21A 'superproject':43A 'sync':4A,28A,66A 'tick':17A,76A 'url':27A"
escalation: "{\"kind\":\"git-sync-error\",\"harness_slug\":\"sidestage-mobile\",\"reasons\":[\"push-failure\"],\"consecutive_error_ticks\":33,\"errors\":[{\"scope\":\"submodule-config\",\"message\":\"canonical submodule URL sync failed: spawner sidecar admission failed: AdmissionPersistenceError: durable admission record could not be persisted\"},{\"scope\":\"superproject\",\"message\":\"generated declaration repair blocked the commit: could not inspect dirty paths before declaration regeneration\"}],\"oversized\":[],\"emitted_at\":1787845027120,\"detail\":\"git-sync needs attention: push-failure — push failed 33 consecutive ticks (commits NOT reaching origin)\"}"
mtime_ms: 1787845027120
phase: "git-sync"
risk_tier: null
supervisor_notes: null
---


