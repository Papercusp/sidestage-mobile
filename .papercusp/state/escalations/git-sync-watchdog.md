---
authority: null
body_embedding_mode: "gemma"
body_embedding_profile: null
body_tsv: "'-09':21A '-14':22A '0':28A '03.758':25A '05':24A '1789371075517':33A '2026':20A '3':53A '3070':76A '3h':49A 'activ':50A 'claim':102A 'commit':68A,81A,119A 'commitstal':11A 'common':83A 'cron':51A 'dbos':86A 'deploy':65A 'detail':36A 'edit':72A 'emit':31A 'engin':94A 'error':106A 'errorstal':15A 'everi':52A 'executor':87A 'fals':12A,16A,18A 'fire':47A,93A 'firestal':13A 'fix':100A 'git':3A,38A,79A,91A,113A 'git-sync':37A,78A,90A,112A 'git-sync-watchdog':2A 'har':6A 'head':69A 'headunchangedhr':27A 'inspect':104A 'kind':1A 'lastfiredat':19A 'laststatus':29A 'lock/restart':97A 'matter':63A 'metadata.last':105A 'min':54A 'mobil':10A,111A 'noth':30A 'persistentreap':17A 'reach':75A 'reap':88A 'rescu':118A 'rescue-commit':117A 'root':84A 'routin':44A,115A 'run':59A 'scheduler/engine':56A 'ship':66A 'sidestag':9A,110A 'sidestage-mobil':8A,109A 'silent':40A 'slug':7A 'stall':41A 'strand':34A,71A,124A 'stuck':89A 'sync':4A,39A,80A,92A,114A 't04':23A 'tree':121A 'true':14A,35A 'urgent':126A 'watchdog':5A,42A 'wedg':95A 'won':98A 'z':26A"
escalation: "{\"kind\":\"git-sync-watchdog\",\"harness_slug\":\"sidestage-mobile\",\"commitStale\":false,\"fireStale\":true,\"errorStall\":false,\"persistentReap\":false,\"lastFiredAt\":\"2026-09-14T04:05:03.758Z\",\"headUnchangedHrs\":0,\"lastStatus\":\"nothing\",\"emitted_at\":1789371075517,\"stranding\":true,\"detail\":\"git-sync silent stall (watchdog): the routine has not FIRED in ~3h (active, cron every 3 min) — the scheduler/engine is not running it. Why it matters: a deploy ships only COMMITTED HEAD, so stranded edits can't reach :3070 until git-sync commits them. Common root: a DBOS executor reaping stuck git-sync fires (engine wedge — a lock/restart won't fix it). Claim it: inspect metadata.last_error on the sidestage-mobile git-sync routine, and rescue-commit the tree if the strand is urgent.\"}"
mtime_ms: 1789371075517
phase: "git-sync-watchdog"
risk_tier: null
supervisor_notes: null
---


